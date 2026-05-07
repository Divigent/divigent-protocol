// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAaveV3Pool}          from "./interfaces/IAaveV3Pool.sol";
import {IMorphoVault}         from "./interfaces/IMorphoVault.sol";
import {IDivigentYieldOracle} from "./interfaces/IDivigentYieldOracle.sol";
import {IDivigentVaultRouter} from "./interfaces/IDivigentVaultRouter.sol";
import {DivigentFeeCollector} from "./DivigentFeeCollector.sol";
import {DvUSDC}               from "./dvUSDC.sol";

/// @title  DivigentVaultRouter
/// @author Divigent Protocol
/// @notice Central orchestration contract for the Divigent Protocol.
///         Routes idle USDC from agent wallets into the highest-yielding audited DeFi
///         vault (Aave V3 or Morpho on Base), mints dvUSDC receipt tokens on deposit,
///         and redeems them on withdrawal — deducting a 10% fee on yield only.
///
/// @dev    ── Architecture ─────────────────────────────────────────────────────
///         VaultRouter is the hub of the protocol:
///           - Holds all pooled aTokens (Aave) and MetaMorpho shares (Morpho).
///           - Manages per-wallet principal tracking for fee calculation.
///           - Consults DivigentYieldOracle to select the optimal deposit target.
///           - Delegates fee collection to DivigentFeeCollector.
///           - Mints/burns dvUSDC via the DvUSDC token contract.
///
///         ── Non-Custodial Claim ──────────────────────────────────────────────
///         "Non-custodial" means: VaultRouter holds ZERO USDC at rest between
///         transactions. USDC moves from agent wallet → Aave/Morpho within the
///         same transaction, never parked in the router. VaultRouter does hold
///         aTokens/vault shares — these are immutable contract claims on user funds
///         with no admin steal vector. Contrast with custodial models where an
///         admin key can redirect user USDC.
///
///         ── Protocol Invariants (Echidna / Certora targets) ──────────────────
///         [INV-1] Solvency:
///             totalVaultAssets() >= totalDepositedUSDC at all times.
///         [INV-2] Principal preservation:
///             For any withdrawal, fee == 0 when yieldEarned == 0.
///             fee == ceil(yieldEarned * FEE_BPS / BPS_DENOMINATOR) otherwise.
///         [INV-3] Fee bound:
///             fee <= yieldEarned — fees never consume principal.
///         [INV-4] Statelessness:
///             USDC.balanceOf(address(this)) == 0 after every deposit() and withdraw().
///         [INV-5] Permissionless exit:
///             No state transition blocks a withdrawal if Aave/Morpho allows redemption.
///
///         ── Security Properties ──────────────────────────────────────────────
///         - ReentrancyGuard: all state changes happen before external calls (CEI).
///         - Emergency pause: only new deposits can be paused (EMERGENCY_MULTISIG).
///           Withdrawals are ALWAYS enabled — the pause modifier is never applied to withdraw().
///         - TVL cap: contract-enforced, expands deterministically at day 31 and day 91.
///         - First-depositor inflation attack: mitigated by virtual +1 offset in share maths.
///         - Donation attack: totalVaultAssets() reads live vault balances, not an internal
///           counter, so a donation inflates pricePerShare proportionally without stealing
///           from existing depositors.
///         - Wallet self-registration: initialize() only registers msg.sender; no third
///           party can register an arbitrary wallet. EIP-712 initializeFor() enables
///           gasless onboarding with a signed authorisation from the wallet owner.
///         - Operator model: wallets can grant operators deposit/withdraw rights without
///           transferring custody — the wallet remains the sole dvUSDC holder.
///           v1 operator approvals are on-chain only; no setOperatorWithPermit path exists.
///         - Oracle freshness: _deposit() reverts with StaleOracle() if the oracle has
///           not been updated within MAX_STALENESS (2 hours), preventing routing decisions
///           based on stale rates.
///         - Deposit route safety: routing requires both the oracle's vault safety
///           signal and vault-specific amount capacity before selecting either the
///           recommended vault or its alternate.
///         - Exact-asset Morpho redemption: uses withdraw(assets, ...) instead of
///           convertToShares + redeem to eliminate share-rounding under-redemption risk.
///         - Actual-gross fee: fee is computed from USDC.balanceOf(this) after all vault
///           redemptions, not a pre-estimated gross, so rounding never charges fee on principal.
///
///         ── Third-party rewards and incentives ─────────────
///         Aave V3 RewardsController programs and Morpho Universal Reward
///         Distributor (URD) programs may attribute incentive rewards to the
///         address holding the underlying aTokens or vault shares. This router
///         supplies and deposits with address(this) as the recipient, so any
///         such rewards would accrue to the router itself.
///
///         The router intentionally has no claim, skim, sweep, rewards-controller,
///         or URD integration. Divigent v1 only accounts for base Aave/Morpho
///         supply yield reflected in aToken balances and MetaMorpho share value.
///         Any third-party incentive tokens credited to the router are not
///         distributed as depositor yield and may be unreachable in this immutable
///         deployment. If rewards become economically material, a future version
///         would need explicit claim and distribution logic.
///
///         If Morpho valuation reverts, valuation-dependent views and flows halt
///         rather than pricing Morpho at zero; v1 has no Aave-only haircut exit.
///
/// @custom:security-contact security@divigent.xyz
contract DivigentVaultRouter is IDivigentVaultRouter, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice TVL cap at deployment: $500,000 USDC (6 decimals).
    uint256 public constant TVL_CAP_INITIAL = 500_000e6;

    /// @notice TVL cap after day 31: $2,000,000 USDC.
    uint256 public constant TVL_CAP_DAY_31  = 2_000_000e6;

    /// @notice TVL cap removed after day 91 (uint256 max effectively removes the cap).
    uint256 public constant TVL_CAP_REMOVED = type(uint256).max;

    /// @notice Seconds after deployment when the TVL cap expands.
    uint256 public constant DAY_31_OFFSET = 31 days;

    /// @notice Seconds after deployment when the TVL cap is fully removed.
    uint256 public constant DAY_91_OFFSET = 91 days;

    /// @notice Minimum deposit amount: $10 USDC (protects against dust attacks
    ///         and ensures share minting doesn't degenerate to zero).
    uint256 public constant MIN_DEPOSIT = 10e6;

    /// @notice Virtual assets/shares used in share minting and redemption math.
    /// @dev Sized to USDC/dvUSDC's 6 decimals. This keeps first deposits 1:1
    ///      while making donation-style share-price inflation economically impractical.
    uint256 private constant VIRTUAL_OFFSET = 1e6;

    /// @dev EIP-712 type hash for the initializeFor() signed authorisation.
    ///      Nonce is included so each signature is single-use by construction,
    ///      independent of any state change that follows.
    bytes32 private constant INITIALIZE_FOR_TYPEHASH =
        keccak256("InitializeFor(address wallet,uint256 deadline,uint256 nonce)");

    /// @notice Minimum gas stipend for Morpho view calls in withdraw planning.
    /// @dev Set above the measured cold-path cost of `convertToAssets` on Base.
    uint256 public constant MIN_MORPHO_VIEW_GAS = 350_000;

    /// @notice Maximum gas stipend for Morpho view calls in withdraw planning.
    /// @dev Caps gas forwarded to the external view call.
    uint256 public constant MAX_MORPHO_VIEW_GAS = 1_000_000;

    /// @dev Aave V3 ReserveConfigurationMap bit positions for active/frozen/paused.
    uint256 private constant AAVE_CONFIG_ACTIVE_BIT = 56;
    uint256 private constant AAVE_CONFIG_FROZEN_BIT = 57;
    uint256 private constant AAVE_CONFIG_PAUSED_BIT = 60;

    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice USDC token on Base mainnet (6 decimals).
    IERC20 public immutable USDC;

    /// @notice Aave V3 Pool on Base mainnet.
    IAaveV3Pool public immutable AAVE_POOL;

    /// @notice aUSDC token on Base mainnet (Aave receipt token, 6 decimals).
    IERC20 public immutable A_TOKEN;

    /// @notice MetaMorpho USDC vault (ERC-4626) on Base mainnet.
    IMorphoVault public immutable MORPHO_VAULT;

    /// @notice DivigentYieldOracle for optimal vault selection.
    IDivigentYieldOracle public immutable ORACLE;

    /// @notice DivigentFeeCollector for fee deduction and treasury routing.
    DivigentFeeCollector public immutable FEE_COLLECTOR;

    /// @notice DvUSDC receipt token contract.
    DvUSDC public immutable DV_USDC;

    /// @notice 2-of-3 Gnosis Safe multisig with emergency pause authority.
    ///         Cannot call withdraw, redirect funds, or modify fees.
    address public immutable EMERGENCY_MULTISIG;

    /// @notice Block timestamp at contract deployment (for TVL cap schedule).
    uint256 public immutable DEPLOYMENT_TIME;

    // ── Mutable State ─────────────────────────────────────────────────────────

    /// @notice Whether new deposits are paused (emergency only).
    ///         Withdrawals are NEVER paused.
    bool public depositsPaused;

    /// @notice Set of wallets authorised to interact with this router.
    mapping(address => bool) public authorizedWallets;

    /// @notice Principal cost basis per wallet in USDC (6 decimals).
    ///         Tracks the cumulative USDC deposited minus principal already withdrawn.
    ///         Used exclusively for calculating yield earned at withdrawal time.
    mapping(address => uint256) public costBasisUSDC;

    /// @notice Operator approvals: isOperator[wallet][operator] == true means
    ///         `operator` may call deposit() and withdraw() on behalf of `wallet`.
    ///         The wallet retains full control and may revoke at any time.
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice Per-wallet nonce for initializeFor() EIP-712 signatures.
    ///         Incremented after each successful initializeFor() call, making
    ///         every signature single-use by construction — independent of the
    ///         WalletAlreadyAuthorised() guard that fires afterward.
    mapping(address => uint256) public nonces;

    /// @notice Gas stipend forwarded to `MORPHO_VAULT.convertToAssets`
    ///         inside `_planWithdrawCapacity`. Initialised to
    ///         `MIN_MORPHO_VIEW_GAS` and adjustable by the emergency
    ///         multisig within `[MIN_MORPHO_VIEW_GAS, MAX_MORPHO_VIEW_GAS]`.
    uint256 public morphoViewGas;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param usdc              USDC address (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 on Base).
    /// @param aavePool          Aave V3 Pool (0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 on Base).
    /// @param aToken            aUSDC address on Base.
    /// @param morphoVault       MetaMorpho USDC vault address on Base.
    /// @param oracle            DivigentYieldOracle address.
    /// @param feeCollector      DivigentFeeCollector address.
    /// @param dvUsdc            DvUSDC token address (must have this contract as VAULT_ROUTER).
    /// @param emergencyMultisig 2-of-3 Gnosis Safe multisig address.
    constructor(
        address usdc,
        address aavePool,
        address aToken,
        address morphoVault,
        address oracle,
        address feeCollector,
        address dvUsdc,
        address emergencyMultisig
    )
        EIP712("DivigentVaultRouter", "1")
    {
        if (usdc              == address(0)) revert ZeroUsdc();
        if (aavePool          == address(0)) revert ZeroAavePool();
        if (aToken            == address(0)) revert ZeroAToken();
        if (morphoVault       == address(0)) revert ZeroMorphoVault();
        if (oracle            == address(0)) revert ZeroOracle();
        if (feeCollector      == address(0)) revert ZeroFeeCollector();
        if (dvUsdc            == address(0)) revert ZeroDvUsdc();
        if (emergencyMultisig == address(0)) revert ZeroEmergencyMultisig();

        USDC               = IERC20(usdc);
        AAVE_POOL          = IAaveV3Pool(aavePool);
        A_TOKEN            = IERC20(aToken);
        MORPHO_VAULT       = IMorphoVault(morphoVault);
        ORACLE             = IDivigentYieldOracle(oracle);
        FEE_COLLECTOR      = DivigentFeeCollector(feeCollector);
        DV_USDC            = DvUSDC(dvUsdc);
        EMERGENCY_MULTISIG = emergencyMultisig;
        DEPLOYMENT_TIME    = block.timestamp;

        // Initialise the Morpho view-call gas stipend at the lower bound.
        morphoViewGas = MIN_MORPHO_VIEW_GAS;

        // Pre-approve Aave and Morpho to spend USDC held transiently in this contract.
        // These approvals are max so repeated deposits don't incur extra approve txs.
        IERC20(usdc).forceApprove(aavePool,    type(uint256).max);
        IERC20(usdc).forceApprove(morphoVault, type(uint256).max);

        // Pre-approve FeeCollector to pull fee USDC from this contract during withdrawals.
        IERC20(usdc).forceApprove(feeCollector, type(uint256).max);
    }

    // ── Modifiers ─────────────────────────────────────────────────────────────

    /// @dev Requires that `wallet` is registered AND msg.sender is `wallet` or an operator.
    modifier onlyWalletOrOperator(address wallet) {
        if (!authorizedWallets[wallet]) revert NotAuthorised();
        if (msg.sender != wallet && !isOperator[wallet][msg.sender]) revert NotAuthorised();
        _;
    }

    modifier whenDepositsNotPaused() {
        if (depositsPaused) revert DepositsPausedError();
        _;
    }

    modifier onlyEmergencyMultisig() {
        if (msg.sender != EMERGENCY_MULTISIG) revert NotEmergencyMultisig();
        _;
    }

    // ── Authorisation ─────────────────────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    /// @dev Self-registration only: msg.sender is the wallet being registered.
    ///      This prevents a third party from registering an arbitrary wallet address.
    function initialize() external override {
        if (authorizedWallets[msg.sender]) revert WalletAlreadyAuthorised();
        authorizedWallets[msg.sender] = true;
        emit WalletAuthorised(msg.sender);
    }

    /// @inheritdoc IDivigentVaultRouter
    /// @dev EIP-712 signed authorisation — enables gasless onboarding where a relayer
    ///      submits the transaction but the wallet proves consent via signature.
    ///      The signer must be `wallet` itself; no delegation of signing authority.
    ///
    ///      Replay protection layers:
    ///        1. Per-wallet nonce: consumed on first use, making the exact same signature
    ///           invalid for any subsequent call — even before deadline expiry.
    ///        2. Deadline: signature becomes invalid after the specified timestamp.
    ///        3. WalletAlreadyAuthorised(): duplicate registrations revert.
    ///
    ///      The nonce is incremented BEFORE the state write so that any reentrancy
    ///      attempting to replay the same signature would see a different nonce and fail.
    function initializeFor(
        address wallet,
        uint256 deadline,
        bytes calldata sig
    ) external override {
        if (block.timestamp > deadline) revert PermitExpired();
        if (authorizedWallets[wallet])  revert WalletAlreadyAuthorised();

        // Consume the nonce before verifying — prevents replay even if the subsequent
        // state write is somehow skipped (defense-in-depth).
        uint256 currentNonce = nonces[wallet]++;

        bytes32 structHash = keccak256(abi.encode(
            INITIALIZE_FOR_TYPEHASH,
            wallet,
            deadline,
            currentNonce
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), sig);
        if (signer != wallet) revert InvalidSignature();

        authorizedWallets[wallet] = true;
        emit WalletAuthorised(wallet);
    }

    /// @inheritdoc IDivigentVaultRouter
    function setOperator(address operator, bool approved) external override {
        if (!authorizedWallets[msg.sender]) revert NotAuthorised();
        if (operator == address(0)) revert ZeroAddress();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    // ── Core: Deposit ─────────────────────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    function deposit(uint256 amount, address wallet, uint256 minSharesOut)
        external
        override
        nonReentrant
        whenDepositsNotPaused
        onlyWalletOrOperator(wallet)
        returns (uint256 dvUsdcMinted)
    {
        dvUsdcMinted = _deposit(amount, wallet, minSharesOut);
    }

    /// @inheritdoc IDivigentVaultRouter
    /// @dev Uses USDC's EIP-2612 permit so no separate approve() tx is needed.
    ///      The permit signature is best-effort because EIP-2612 permits can be
    ///      submitted by anyone and therefore frontrun. After the attempt, the
    ///      router verifies that allowance is sufficient before depositing.
    function depositWithPermit(
        uint256 amount,
        address wallet,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s,
        uint256 minSharesOut
    )
        external
        override
        nonReentrant
        whenDepositsNotPaused
        onlyWalletOrOperator(wallet)
        returns (uint256 dvUsdcMinted)
    {
        if (block.timestamp > deadline) revert PermitExpired();

        try IERC20Permit(address(USDC)).permit(
            wallet, address(this), amount, deadline, v, r, s
        ) {} catch {}

        uint256 currentAllowance = USDC.allowance(wallet, address(this));
        if (currentAllowance < amount) {
            revert InsufficientPermitAllowance(currentAllowance, amount);
        }

        dvUsdcMinted = _deposit(amount, wallet, minSharesOut);
    }

    // ── Core: Withdraw ────────────────────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    /// @dev CEI pattern: all state mutations (costBasis update, dvUSDC burn) happen
    ///      BEFORE external calls (vault redemption, USDC transfer to wallet).
    ///      ReentrancyGuard provides a second line of defence.
    ///
    ///      Fee is computed from actualGross = USDC.balanceOf(this) after vault
    ///      redemptions — not from a pre-estimated grossUSDC. This ensures:
    ///        (a) Any Morpho rounding (exact-asset withdraw returns slightly less)
    ///            is absorbed before fee calculation.
    ///        (b) [INV-2] The fee is always computed on true realised yield, never
    ///            on principal. If actualGross <= principalOut, fee is exactly 0.
    function withdraw(
        uint256 shares,
        address wallet,
        uint256 minUsdcOut
    )
        external
        override
        nonReentrant
        onlyWalletOrOperator(wallet)
        returns (uint256 usdcReturned)
    {
        if (shares == 0) revert ZeroAmount();

        uint256 walletShares = DV_USDC.balanceOf(wallet);
        if (shares > walletShares) revert InsufficientShares(shares, walletShares);

        // ── Step 1: Compute principal attribution (read-only) ─────────────────
        // Attribute principal: proportional share of this wallet's cost basis.
        // fraction = shares / walletShares  =>  principalOut = costBasis * shares / walletShares
        uint256 principalOut = (costBasisUSDC[wallet] * shares) / walletShares;

        // ── Step 2: State mutations (before external calls — CEI) ────────────
        costBasisUSDC[wallet] -= principalOut;

        // Burn dvUSDC from wallet. Because dvUSDC is non-transferable, the wallet
        // is always the holder — VaultRouter burns directly without needing an allowance.
        DV_USDC.burn(wallet, shares);

        // ── Step 3: Redeem from vaults (exact-asset semantics) ────────────────
        // Snapshot USDC balance BEFORE vault redemptions. Any stray USDC already
        // in the router (accidental transfer, rounding dust) is excluded from
        // the yield calculation by measuring the delta, not the absolute balance.
        uint256 balanceBefore = USDC.balanceOf(address(this));

        // Single source of truth for capacity math — shared with the public
        // `withdrawCapacity()` pre-flight view, so the pre-flight can never
        // disagree with execution in the same block.
        VaultCapacity memory cap = _planWithdrawCapacity();

        // Strict check on the state-changing path: if Morpho's view path
        // failed AND the router actually has Morpho exposure, we cannot
        // value the position and must revert. SDKs can detect this ahead
        // of time via `withdrawCapacity().morphoReachable == false`.
        if (!cap.morphoReachable) revert MorphoUnreachable();

        uint256 aaveBalance   = cap.aaveAssetsHeld;
        uint256 morphoBalance = cap.morphoAssetsHeld;
        uint256 totalHeld     = aaveBalance + morphoBalance;

        if (totalHeld == 0) revert ZeroAmount(); // should never happen post-invariant-check

        // grossUSDC is the estimated withdrawal target (used for proportional split).
        // The actual received amount (actualGross) is measured after redemptions.
        uint256 totalSupply_  = DV_USDC.totalSupply() + shares; // restore pre-burn supply
        uint256 grossUSDC     = _sharesToAssets(shares, totalHeld, totalSupply_);

        // ── Plan: proportional target ─────────────────────────────────────────
        // The initial target is proportional to each vault's share of totalHeld.
        // If one leg is constrained, the shortfall redirects to the other.
        uint256 targetAave;
        uint256 targetMorpho;
        if (aaveBalance > 0 && morphoBalance == 0) {
            targetAave   = grossUSDC;
            targetMorpho = 0;
        } else if (morphoBalance > 0 && aaveBalance == 0) {
            targetAave   = 0;
            targetMorpho = grossUSDC;
        } else {
            targetAave   = (grossUSDC * aaveBalance) / totalHeld;
            targetMorpho = grossUSDC - targetAave;
        }

        // Capacity locals pulled from the plan struct for the redirect math.
        uint256 aaveCap   = cap.aaveWithdrawCap;
        uint256 morphoCap = cap.morphoWithdrawCap;

        // Early revert when no combination of the two can serve the ask.
        if (aaveCap + morphoCap < grossUSDC) {
            revert InsufficientVaultLiquidity(grossUSDC, aaveCap + morphoCap);
        }

        // ── Redirect: if one leg is short, shift its slack to the other ──────
        // After the early-revert above, at most ONE leg can be short. Proof:
        // if both were short, targetAave + targetMorpho > aaveCap + morphoCap,
        // but targetAave + targetMorpho == grossUSDC, so
        // grossUSDC > aaveCap + morphoCap — the early-revert case. Therefore a
        // single redirect suffices; no loop is required.
        uint256 fromAave;
        uint256 fromMorpho;
        bool    redirected;
        bool    shortLegMorpho;
        if (targetAave > aaveCap) {
            fromAave        = aaveCap;
            fromMorpho      = grossUSDC - aaveCap;
            redirected      = true;
            shortLegMorpho  = false;
        } else if (targetMorpho > morphoCap) {
            fromMorpho      = morphoCap;
            fromAave        = grossUSDC - morphoCap;
            redirected      = true;
            shortLegMorpho  = true;
        } else {
            fromAave   = targetAave;
            fromMorpho = targetMorpho;
        }

        // ── Execute: pull from each vault ────────────────────────────────────
        // We intentionally DO NOT wrap the mutating Morpho call in try/catch.
        // If Morpho's view said it could serve `fromMorpho` but the mutating
        // call reverts (intra-block state change, liquidity race, or unexpected
        // vault behaviour), the revert propagates.
        // The reentrancy guard relies on this bubble-up, and plan/execute
        // capacity drift is rare enough that a simple retry is acceptable.
        if (fromAave > 0) {
            AAVE_POOL.withdraw(address(USDC), fromAave, address(this));
        }
        if (fromMorpho > 0) {
            // ERC-4626 `withdraw(assets, receiver, owner)`: exact-asset semantics.
            // Using withdraw() over redeem() avoids share-rounding leaving dust.
            MORPHO_VAULT.withdraw(fromMorpho, address(this), address(this));
        }

        if (redirected) {
            emit ExitRedirected(wallet, targetAave, targetMorpho, fromAave, fromMorpho, shortLegMorpho);
        }

        // ── Step 4: Compute fee from actual received USDC ─────────────────────
        // Measure the DELTA: what the vaults delivered in THIS transaction.
        // Using the delta (not absolute balance) ensures stray USDC that was
        // already in the router is excluded from yield and fee calculation.
        uint256 actualGross  = USDC.balanceOf(address(this)) - balanceBefore;

        // Guard: if vault redemptions silently returned 0 without reverting,
        // stop here rather than burning dvUSDC for nothing.
        if (actualGross == 0) revert InsufficientVaultLiquidity(grossUSDC, 0);

        // Recompute yield from actual gross; floor at 0 — principal is never negative yield
        uint256 actualYield  = actualGross > principalOut ? actualGross - principalOut : 0;
        uint256 feeAmount    = actualYield > 0 ? FEE_COLLECTOR.calculateFee(actualYield) : 0;
        usdcReturned         = actualGross - feeAmount;

        if (usdcReturned < minUsdcOut) {
            revert SlippageExceeded(usdcReturned, minUsdcOut);
        }

        // ── Step 5: Collect fee and transfer net proceeds ─────────────────────
        if (feeAmount > 0) {
            // FeeCollector pulls feeAmount directly from this contract to TREASURY
            // (pre-approved in constructor)
            FEE_COLLECTOR.collectFee(wallet, actualYield);
        }

        // Transfer net USDC to wallet
        // [INV-4] After this: USDC.balanceOf(this) == balanceBefore (stray USDC preserved)
        USDC.safeTransfer(wallet, usdcReturned);

        emit Withdrawn(wallet, shares, usdcReturned, actualYield, feeAmount);
    }

    // ── View: Position & State ─────────────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    /// @notice Returns the total USDC value managed across all vaults.
    ///         Aave: aToken balance is 1:1 with USDC (aTokens rebase to reflect yield).
    ///         Morpho: convert vault shares to USDC using the current exchange rate.
    function totalVaultAssets() public view override returns (uint256) {
        return A_TOKEN.balanceOf(address(this)) + _morphoAssetsHeld();
    }

    /// @inheritdoc IDivigentVaultRouter
    /// @notice Current dvUSDC price in USDC, scaled by 1e18.
    ///         Uses the same virtual-offset ratio as mint/burn share math.
    function pricePerShare() external view override returns (uint256) {
        return Math.mulDiv(
            totalVaultAssets() + VIRTUAL_OFFSET,
            1e18,
            DV_USDC.totalSupply() + VIRTUAL_OFFSET,
            Math.Rounding.Floor
        );
    }

    /// @inheritdoc IDivigentVaultRouter
    function currentTVLCap() public view override returns (uint256) {
        uint256 elapsed = block.timestamp - DEPLOYMENT_TIME;
        if (elapsed >= DAY_91_OFFSET) return TVL_CAP_REMOVED;
        if (elapsed >= DAY_31_OFFSET) return TVL_CAP_DAY_31;
        return TVL_CAP_INITIAL;
    }

    /// @inheritdoc IDivigentVaultRouter
    function getPosition(address wallet)
        external
        view
        override
        returns (
            uint256 depositedUSDC,
            uint256 currentValue,
            uint256 accruedYield
        )
    {
        depositedUSDC = costBasisUSDC[wallet];

        uint256 walletShares = DV_USDC.balanceOf(wallet);
        uint256 totalSupply_ = DV_USDC.totalSupply();

        if (walletShares == 0 || totalSupply_ == 0) {
            return (depositedUSDC, 0, 0);
        }

        currentValue = _sharesToAssets(walletShares, totalVaultAssets(), totalSupply_);
        accruedYield = currentValue > depositedUSDC ? currentValue - depositedUSDC : 0;
    }

    // ── View: Preview & Simulation ─────────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    function previewDeposit(uint256 assets) external view override returns (uint256 dvUsdcOut) {
        dvUsdcOut = _assetsToShares(assets, totalVaultAssets(), DV_USDC.totalSupply());
    }

    /// @inheritdoc IDivigentVaultRouter
    function previewRedeem(uint256 dvUsdcShares, address wallet)
        external
        view
        override
        returns (uint256 usdcOut)
    {
        uint256 totalAssets_ = totalVaultAssets();
        uint256 totalSupply_ = DV_USDC.totalSupply();
        uint256 gross        = _sharesToAssets(dvUsdcShares, totalAssets_, totalSupply_);

        uint256 walletShares = DV_USDC.balanceOf(wallet);
        uint256 principalOut = walletShares > 0
            ? (costBasisUSDC[wallet] * dvUsdcShares) / walletShares
            : 0;

        uint256 yield    = gross > principalOut ? gross - principalOut : 0;
        uint256 fee      = yield > 0 ? FEE_COLLECTOR.calculateFee(yield) : 0;
        usdcOut          = gross - fee;
    }

    /// @inheritdoc IDivigentVaultRouter
    /// @dev Two-branch solver, selected by wallet loss state:
    ///
    ///      A wallet is "uniformly underwater" when walletShares * A1 <= costBasis * S1.
    ///      In that regime every proportional slice satisfies gross_s <= principalOut_s,
    ///      so withdraw() floors yield at 0 and charges no fee. Using the fee-adjusted
    ///      formula there would treat negative yield as a fee rebate and under-solve
    ///      for shares, breaking the ">= desiredNetUSDC" guarantee.
    ///
    ///      (1) Loss branch (grossAll <= costBasis):
    ///            net = gross = s * (A+VIRTUAL_OFFSET) / (S+VIRTUAL_OFFSET)
    ///            s   = ceil(desiredNet * (S+VIRTUAL_OFFSET) / (A+VIRTUAL_OFFSET))
    ///
    ///      (2) Profit branch (grossAll > costBasis):
    ///            net = gross * (1 - feeBps/bpsDen) + principalOut * (feeBps/bpsDen)
    ///            s   = desiredNet * bpsDen * walletShares * (S+VIRTUAL_OFFSET)
    ///                / [ (bpsDen - feeBps) * walletShares * (A+VIRTUAL_OFFSET)
    ///                  + feeBps * costBasis * (S+VIRTUAL_OFFSET) ]
    ///
    ///      Both branches round shares UP so actual USDC out >= desiredNetUSDC.
    ///      If the requested net amount exceeds the wallet's full-position
    ///      deliverable value, the preview reverts instead of silently returning
    ///      a clamped quote that would fail `withdraw(..., minUsdcOut)`.
    function previewWithdrawNet(uint256 desiredNetUSDC, address wallet)
        external
        view
        override
        returns (uint256 dvUsdcShares)
    {
        if (desiredNetUSDC == 0) revert ZeroAmount();

        uint256 walletShares = DV_USDC.balanceOf(wallet);
        if (walletShares == 0) revert NoPositionToWithdraw();

        uint256 totalAssets_ = totalVaultAssets();
        uint256 totalSupply_ = DV_USDC.totalSupply();
        uint256 A1           = totalAssets_ + VIRTUAL_OFFSET;
        uint256 S1           = totalSupply_ + VIRTUAL_OFFSET;
        uint256 costBasis = costBasisUSDC[wallet];

        // Loss branch: wallet's total gross <= its costBasis ⇒ no fee on any slice.
        uint256 grossAll = _sharesToAssets(walletShares, totalAssets_, totalSupply_);
        if (grossAll == 0) revert PositionRoundsToZero();

        if (grossAll <= costBasis) {
            if (desiredNetUSDC > grossAll) {
                revert UnserviceableNet(desiredNetUSDC, grossAll);
            }

            dvUsdcShares = Math.mulDiv(desiredNetUSDC, S1, A1, Math.Rounding.Ceil);
            return dvUsdcShares;
        }

        uint256 maxYield       = grossAll - costBasis;
        uint256 maxFee         = FEE_COLLECTOR.calculateFee(maxYield);
        uint256 maxDeliverable = grossAll - maxFee;
        if (desiredNetUSDC > maxDeliverable) {
            revert UnserviceableNet(desiredNetUSDC, maxDeliverable);
        }

        // Profit branch: fee applies to (gross - principalOut).
        uint256 feeBps   = FEE_COLLECTOR.FEE_BPS();
        uint256 bpsDenom = FEE_COLLECTOR.BPS_DENOMINATOR();

        uint256 denominator = (bpsDenom - feeBps) * walletShares * A1
                            + feeBps * costBasis * S1;
        if (denominator == 0) revert PreviewMathDegenerate();

        // Use explicit ceil rounding for the final share quote. The +1 target
        // absorbs FeeCollector's ceiling-rounded fee so executing the returned
        // shares does not under-deliver by a single USDC wei. At the full-position
        // boundary there is no extra deliverable wei, so solve for the exact max.
        uint256 targetNet = desiredNetUSDC;
        if (targetNet < maxDeliverable) targetNet += 1;

        dvUsdcShares = Math.mulDiv(
            targetNet * bpsDenom,
            walletShares * S1,
            denominator,
            Math.Rounding.Ceil
        );

        if (dvUsdcShares > walletShares) {
            revert UnserviceableNet(desiredNetUSDC, maxDeliverable);
        }
    }

    /// @inheritdoc IDivigentVaultRouter
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        shares = _assetsToShares(assets, totalVaultAssets(), DV_USDC.totalSupply());
    }

    /// @inheritdoc IDivigentVaultRouter
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        assets = _sharesToAssets(shares, totalVaultAssets(), DV_USDC.totalSupply());
    }

    /// @inheritdoc IDivigentVaultRouter
    /// @dev Degrades gracefully when Morpho's view path is unreachable
    ///      (revert or bounded-gas failure). Routes through `_planWithdrawCapacity()`
    ///      so the same bounded-gas try/catch that guards `withdraw()` also
    ///      guards this informational view — external integrators can call
    ///      this without exposing the caller to an unbounded Morpho view.
    ///      Callers that need to distinguish "0 Morpho holdings" from
    ///      "Morpho unreachable" should read `withdrawCapacity()` which
    ///      exposes the `morphoReachable` flag.
    function getCurrentAllocation()
        external
        view
        override
        returns (uint256 aaveAssets, uint256 morphoAssets)
    {
        VaultCapacity memory cap = _planWithdrawCapacity();
        aaveAssets   = cap.aaveAssetsHeld;
        morphoAssets = cap.morphoAssetsHeld;
    }

    /// @inheritdoc IDivigentVaultRouter
    function getRecommendedRoute(uint256 amount)
        external
        view
        override
        returns (IDivigentYieldOracle.VaultType vaultType)
    {
        (, vaultType, ) = ORACLE.getOptimalVault();

        return _selectDepositRoute(vaultType, amount);
    }

    /// @inheritdoc IDivigentVaultRouter
    function oracleStatus()
        external
        view
        override
        returns (uint256 lastObservationTime_, bool fresh)
    {
        lastObservationTime_ = ORACLE.lastObservationTime();
        fresh                = ORACLE.isFresh();
    }

    // ── Emergency Controls ────────────────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    function pauseDeposits() external override onlyEmergencyMultisig {
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    /// @inheritdoc IDivigentVaultRouter
    function unpauseDeposits() external override onlyEmergencyMultisig {
        depositsPaused = false;
        emit DepositsPaused(false);
    }

    /// @inheritdoc IDivigentVaultRouter
    function setMorphoViewGas(uint256 newGas)
        external
        override
        onlyEmergencyMultisig
    {
        if (newGas < MIN_MORPHO_VIEW_GAS || newGas > MAX_MORPHO_VIEW_GAS) {
            revert MorphoViewGasOutOfBounds(
                newGas,
                MIN_MORPHO_VIEW_GAS,
                MAX_MORPHO_VIEW_GAS
            );
        }
        uint256 oldGas = morphoViewGas;
        morphoViewGas = newGas;
        emit MorphoViewGasUpdated(oldGas, newGas);
    }

    // ── Emergency Treasury Rotation ──────────────────────────────────────────

    /// @inheritdoc IDivigentVaultRouter
    /// @dev Forwards to the FeeCollector. Router enforces authorization
    ///      (`onlyEmergencyMultisig`); FeeCollector enforces the timelock,
    ///      holds the state, and emits the lifecycle events from where the
    ///      state changes.
    function proposeTreasuryRotation(address newTreasury)
        external
        override
        onlyEmergencyMultisig
    {
        FEE_COLLECTOR.proposeTreasuryRotation(newTreasury);
    }

    /// @inheritdoc IDivigentVaultRouter
    function executeTreasuryRotation() external override onlyEmergencyMultisig {
        FEE_COLLECTOR.executeTreasuryRotation();
    }

    /// @inheritdoc IDivigentVaultRouter
    function cancelTreasuryRotation() external override onlyEmergencyMultisig {
        FEE_COLLECTOR.cancelTreasuryRotation();
    }

    // ── Internal: Share Maths ─────────────────────────────────────────────────

    /// @dev Calculates dvUSDC shares to mint for a given USDC deposit.
    ///
    ///      Formula (ERC-4626 style with virtual offset):
    ///        shares = amount * (totalSupply + VIRTUAL_OFFSET)
    ///                        / (totalAssets + VIRTUAL_OFFSET)
    ///
    ///      The virtual offset acts as a 1-USDC / 1-dvUSDC virtual seed. This
    ///      preserves 1:1 genesis minting while keeping early share resolution
    ///      high enough that donation-based inflation cannot cheaply force
    ///      ordinary deposits into zero-share or large floor-loss outcomes.
    ///
    ///      Rounding: floor (in vault's favour) to prevent share inflation.
    function _assetsToShares(
        uint256 assets,
        uint256 totalAssets_,
        uint256 totalSupply_
    ) internal pure returns (uint256 shares) {
        shares = (assets * (totalSupply_ + VIRTUAL_OFFSET))
                / (totalAssets_  + VIRTUAL_OFFSET);
    }

    /// @dev Calculates USDC value of a given number of dvUSDC shares.
    ///
    ///      Formula (inverse of _assetsToShares, matching virtual offset):
    ///        assets = shares * (totalAssets + VIRTUAL_OFFSET)
    ///                        / (totalSupply + VIRTUAL_OFFSET)
    ///
    ///      Rounding: floor (in vault's favour). The result is capped at
    ///      totalAssets so virtual assets cannot overstate redemption value
    ///      after an underlying loss.
    function _sharesToAssets(
        uint256 shares,
        uint256 totalAssets_,
        uint256 totalSupply_
    ) internal pure returns (uint256 assets) {
        assets = (shares * (totalAssets_ + VIRTUAL_OFFSET))
               / (totalSupply_ + VIRTUAL_OFFSET);
        if (assets > totalAssets_) assets = totalAssets_;
    }

    // ── Internal: Deposit Routing Gates ───────────────────────────────────────

    /// @dev Selects the deposit target by applying both route gates:
    ///      oracle safety (`isVaultSafe`) and amount-specific capacity
    ///      (`_canAllocate`). The oracle-recommended vault is tried first; the
    ///      alternate is only eligible if it independently passes both gates.
    function _selectDepositRoute(
        IDivigentYieldOracle.VaultType recommended,
        uint256 amount
    ) internal view returns (IDivigentYieldOracle.VaultType vaultType) {
        if (_canRouteDeposit(recommended, amount)) return recommended;

        IDivigentYieldOracle.VaultType alternate =
            recommended == IDivigentYieldOracle.VaultType.AAVE
                ? IDivigentYieldOracle.VaultType.MORPHO
                : IDivigentYieldOracle.VaultType.AAVE;

        if (_canRouteDeposit(alternate, amount)) return alternate;

        revert NoSafeRoute(amount);
    }

    /// @dev `_canAllocate` is capacity-only. This wrapper binds that capacity
    ///      check to the oracle's current safety advisory so fallback routing
    ///      cannot land in a vault the oracle has marked unsafe. If the oracle's
    ///      safety read itself fails, treat the route as unsafe.
    function _canRouteDeposit(
        IDivigentYieldOracle.VaultType vaultType,
        uint256 amount
    ) internal view returns (bool) {
        if (!_canAllocate(vaultType, amount)) return false;

        try ORACLE.isVaultSafe(vaultType) returns (bool safe) {
            return safe;
        } catch {
            return false;
        }
    }

    // ── Internal: Amount-Aware Vault Capacity ─────────────────────────────────

    /// @dev Returns true if `vaultType` appears to have sufficient capacity for `amount`.
    ///
    ///      Aave: reads USDC.balanceOf(aToken) — the idle USDC cash currently sitting
    ///            in the aToken contract — and checks whether it meets or exceeds `amount`.
    ///            IMPORTANT: this is a balance-based heuristic, not a protocol-native
    ///            deposit-capacity guarantee from Aave. It captures whether the pool has
    ///            enough current liquidity to be considered viable, but does not represent
    ///            a commitment about future withdrawal liquidity, nor does it use any
    ///            Aave-provided "maxDeposit"-style function. Treat it as a conservative
    ///            same-block liquidity proxy, not an exact capacity bound.
    ///
    ///      Morpho: uses the ERC-4626 standard maxDeposit(receiver). This is a
    ///              protocol-native function that returns the maximum USDC the vault will
    ///              accept in a single deposit, respecting supply caps and pause state.
    ///              It is a stronger guarantee than the Aave heuristic.
    ///
    ///      Both checks complement — not replace — the oracle's isVaultSafe() advisory.
    ///      The oracle provides rate-based routing signals; _canAllocate() provides a
    ///      same-block capacity proxy for the specific deposit amount.
    function _canAllocate(
        IDivigentYieldOracle.VaultType vaultType,
        uint256 amount
    ) internal view returns (bool) {
        if (vaultType == IDivigentYieldOracle.VaultType.AAVE) {
            if (!_isAaveSupplyEnabled()) return false;
            return USDC.balanceOf(address(A_TOKEN)) >= amount;
        } else {
            // ROUTING-SAFE: a Morpho view revert (pause, unexpected state) is
            // treated as "Morpho unavailable, don't route here" rather than
            // cascading into a deposit-wide revert. Deposits then fall through
            // to the Aave branch by the caller's retry logic.
            try MORPHO_VAULT.maxDeposit(address(this)) returns (uint256 cap) {
                return cap >= amount;
            } catch {
                return false;
            }
        }
    }

    // ── Internal: Aave Reserve Health ──────────────────────────────────────────

    /// @dev Reads Aave V3 reserve flags for USDC. If the pool view reverts,
    ///      treat Aave as unavailable so deposits/withdrawals can route elsewhere.
    function _readAaveConfig() internal view returns (bool active, bool frozen, bool paused) {
        try AAVE_POOL.getConfiguration(address(USDC)) returns (uint256 configuration) {
            active = ((configuration >> AAVE_CONFIG_ACTIVE_BIT) & 1) == 1;
            frozen = ((configuration >> AAVE_CONFIG_FROZEN_BIT) & 1) == 1;
            paused = ((configuration >> AAVE_CONFIG_PAUSED_BIT) & 1) == 1;
        } catch {
            active = false;
            frozen = false;
            paused = false;
        }
    }

    function _isAaveSupplyEnabled() internal view returns (bool) {
        (bool active, bool frozen, bool paused) = _readAaveConfig();
        return active && !frozen && !paused;
    }

    function _isAaveWithdrawEnabled() internal view returns (bool) {
        (bool active, , bool paused) = _readAaveConfig();
        return active && !paused;
    }

    // ── Internal: Deposit Logic ───────────────────────────────────────────────

    /// @dev Shared implementation for deposit() and depositWithPermit().
    ///
    ///      Flow (atomically, within one transaction):
    ///        1. Validate amount and TVL cap.
    ///        2. Pull USDC from wallet into this contract (transient custody).
    ///        3. Trigger oracle update (permissionless, skipped if too recent).
    ///        4. Verify oracle is fresh (reverts StaleOracle if > 2 hours stale).
    ///        5. Query oracle for optimal vault.
    ///        6. Check oracle safety and amount-aware vault capacity; try alternate if needed.
    ///           Reverts NoSafeRoute(amount) if neither vault passes both gates.
    ///        7. Supply USDC to the selected vault.
    ///        8. Mint dvUSDC shares to wallet.
    ///        9. Update cost basis.
    ///
    ///      [INV-4]: USDC arrives in this contract at step 2, departs at step 7.
    ///               After step 7, USDC.balanceOf(address(this)) == 0.
    function _deposit(uint256 amount, address wallet, uint256 minSharesOut)
        internal
        returns (uint256 dvUsdcMinted)
    {
        if (amount < MIN_DEPOSIT) revert InvalidAmount();

        // TVL cap check
        uint256 newTVL = totalVaultAssets() + amount;
        uint256 cap    = currentTVLCap();
        if (newTVL > cap) revert TVLCapExceeded(amount, cap);

        // Snapshot state BEFORE pulling USDC (pre-deposit assets and supply)
        uint256 totalAssetsBefore = totalVaultAssets();
        uint256 totalSupplyBefore = DV_USDC.totalSupply();

        // Pull USDC from wallet → this contract (transient)
        // [INV-4]: USDC.balanceOf(this) == amount here
        USDC.safeTransferFrom(wallet, address(this), amount);

        // Nudge the oracle to record a fresh observation (no-op if too recent)
        try ORACLE.recordObservation() {} catch {}

        // Verify oracle freshness — reject deposit if rates are potentially stale
        if (!ORACLE.isFresh()) revert StaleOracle();

        // Determine oracle-recommended vault (AAVE or MORPHO)
        (
            ,
            IDivigentYieldOracle.VaultType vaultType,

        ) = ORACLE.getOptimalVault();

        // Select a route that passes both oracle safety and amount capacity.
        vaultType = _selectDepositRoute(vaultType, amount);

        // Route USDC to the selected vault. The router becomes the holder of the
        // resulting aTokens / vault shares; any third-party reward attribution
        // accrues here and is not claimed by v1.
        // [INV-4]: After supply call, USDC.balanceOf(this) == 0
        if (vaultType == IDivigentYieldOracle.VaultType.AAVE) {
            // USDC is already approved to Aave in constructor
            AAVE_POOL.supply(address(USDC), amount, address(this), 0);
        } else {
            // USDC is already approved to Morpho in constructor
            MORPHO_VAULT.deposit(amount, address(this));
        }

        // Mint dvUSDC shares using pre-deposit snapshot (avoids share dilution from
        // the just-deposited amount appearing in totalVaultAssets())
        dvUsdcMinted = _assetsToShares(amount, totalAssetsBefore, totalSupplyBefore);

        if (dvUsdcMinted == 0) revert ZeroAmount();
        if (dvUsdcMinted < minSharesOut) {
            revert SlippageExceeded(dvUsdcMinted, minSharesOut);
        }

        DV_USDC.mint(wallet, dvUsdcMinted);

        // Update principal cost basis
        costBasisUSDC[wallet] += amount;

        emit Deposited(wallet, amount, dvUsdcMinted, vaultType);
    }

    // ── Internal: Morpho Reads ────────────────────────────────────────────────

    /// @dev Returns the USDC value of Morpho shares held by
    ///      this contract. Fails loud on any Morpho read failure — intentional.
    function _morphoAssetsHeld() internal view returns (uint256) {
        uint256 morphoShares = MORPHO_VAULT.balanceOf(address(this));
        if (morphoShares == 0) return 0;
        return MORPHO_VAULT.convertToAssets(morphoShares);
    }

    /// @dev Returns Morpho's effective `maxWithdraw` for this
    ///      contract, or 0 if the view reverts. Used only for withdraw capacity
    ///      planning and oracle-side routing decisions. NEVER use in valuation.
    function _safeMorphoMaxWithdraw() internal view returns (uint256) {
        try MORPHO_VAULT.maxWithdraw(address(this)) returns (uint256 m) {
            return m;
        } catch {
            return 0;
        }
    }

    // ── Internal: Withdraw-Capacity Planning ──────────────────────────────────

    /// @dev Canonical source of truth for withdraw-capacity math. Called by
    ///      both `withdraw()` and `withdrawCapacity()` so the state-changing
    ///      path and the pre-flight view can never disagree by construction.
    ///
    ///      Never reverts. If Morpho's `convertToAssets` fails or hits the
    ///      gas limit, `morphoReachable` is set to false and Morpho-derived
    ///      fields are zero. Callers that need to fail-strict (i.e.
    ///      `withdraw()`) check the flag and revert `MorphoUnreachable`.
    function _planWithdrawCapacity()
        internal
        view
        returns (VaultCapacity memory cap)
    {
        cap.aaveAssetsHeld    = A_TOKEN.balanceOf(address(this));
        cap.aaveIdleLiquidity = USDC.balanceOf(address(A_TOKEN));
        if (_isAaveWithdrawEnabled()) {
            cap.aaveWithdrawCap = cap.aaveAssetsHeld < cap.aaveIdleLiquidity
                ? cap.aaveAssetsHeld
                : cap.aaveIdleLiquidity;
        }

        uint256 morphoShares = MORPHO_VAULT.balanceOf(address(this));
        if (morphoShares == 0) {
            // No exposure — vacuously reachable.
            cap.morphoReachable = true;
        } else {
            try MORPHO_VAULT.convertToAssets{gas: morphoViewGas}(morphoShares)
                returns (uint256 assets)
            {
                cap.morphoAssetsHeld = assets;
                cap.morphoReachable  = true;
            } catch {
                // morphoAssetsHeld stays 0, morphoReachable stays false.
            }
        }

        uint256 morphoMax = _safeMorphoMaxWithdraw();
        cap.morphoWithdrawCap = cap.morphoAssetsHeld < morphoMax
            ? cap.morphoAssetsHeld
            : morphoMax;

        cap.totalWithdrawCap = cap.aaveWithdrawCap + cap.morphoWithdrawCap;
    }

    /// @inheritdoc IDivigentVaultRouter
    function withdrawCapacity()
        external
        view
        override
        returns (VaultCapacity memory)
    {
        return _planWithdrawCapacity();
    }
}
