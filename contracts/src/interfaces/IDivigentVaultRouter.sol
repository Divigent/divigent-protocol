// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDivigentYieldOracle} from "./IDivigentYieldOracle.sol";

/// @title IDivigentVaultRouter
/// @notice Interface for DivigentVaultRouter — the central orchestration contract
///         for the Divigent yield infrastructure protocol.
interface IDivigentVaultRouter {
    // ── Structs ──────────────────────────────────────────────────────────────

    /// @notice Snapshot of the router's withdraw capacity at the current block.
    ///         Returned by `withdrawCapacity()`. Mirrors the exact math the
    ///         router's `withdraw()` uses internally to plan redemptions, so
    ///         a pre-flight read from this struct is guaranteed to agree
    ///         with what the state-changing call sees in the same block.
    ///
    ///         `morphoReachable` distinguishes "Morpho has zero capacity
    ///         right now" (reachable=true, cap=0) from "Morpho's view path
    ///         reverted" (reachable=false). SDKs should treat the latter
    ///         as a hard block for any wallet that holds Morpho-derived
    ///         shares — `withdraw()` will revert `MorphoUnreachable()`.
    struct VaultCapacity {
        uint256 aaveAssetsHeld;       // A_TOKEN.balanceOf(router) — router's Aave position
        uint256 aaveIdleLiquidity;    // USDC.balanceOf(aToken) — pool's paying capacity
        uint256 aaveWithdrawCap;      // min(held, idle) — what Aave can serve right now
        uint256 morphoAssetsHeld;     // Morpho shares valued via convertToAssets (0 if !reachable)
        uint256 morphoWithdrawCap;    // min(held, maxWithdraw) — what Morpho can serve right now
        bool    morphoReachable;      // false if Morpho view path reverted or hit gas limit
        uint256 totalWithdrawCap;     // aaveWithdrawCap + morphoWithdrawCap
    }

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted on every USDC deposit.
    event Deposited(
        address indexed wallet,
        uint256 usdcAmount,
        uint256 dvUsdcMinted,
        IDivigentYieldOracle.VaultType indexed vaultType
    );

    /// @notice Emitted on every withdrawal.
    event Withdrawn(
        address indexed wallet,
        uint256 dvUsdcBurned,
        uint256 usdcReturned,
        uint256 yieldEarned,
        uint256 feePaid
    );

    /// @notice Emitted when a new agent wallet is authorised.
    event WalletAuthorised(address indexed wallet);

    /// @notice Emitted when an operator approval is set or revoked.
    event OperatorSet(
        address indexed wallet,
        address indexed operator,
        bool approved
    );

    /// @notice Emitted when deposit pause state changes.
    event DepositsPaused(bool paused);

    /// @notice Emitted when the emergency multisig adjusts the gas stipend
    ///         forwarded to `MORPHO_VAULT.convertToAssets` inside the
    ///         router's withdraw-planning helper.
    event MorphoViewGasUpdated(uint256 oldGas, uint256 newGas);

    /// @notice Emitted when a withdrawal's proportional split was rebalanced
    ///         because one vault's effective capacity was below its target slice.
    ///         `shortLeg` identifies which vault was short: true = Morpho short,
    ///         false = Aave short. The amount that was rerouted = abs(target - actual)
    ///         on the short leg.
    /// @dev    No event is emitted when the plan executes as originally proportioned.
    event ExitRedirected(
        address indexed wallet,
        uint256 targetAave,
        uint256 targetMorpho,
        uint256 actualAave,
        uint256 actualMorpho,
        bool    shortLeg
    );

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotAuthorised();
    error DepositsPausedError();
    error ZeroAmount();
    error ZeroAddress();
    error TVLCapExceeded(uint256 requested, uint256 cap);
    error InsufficientShares(uint256 requested, uint256 available);
    error NotEmergencyMultisig();
    error WalletAlreadyAuthorised();
    error PermitExpired();
    error InsufficientPermitAllowance(uint256 currentAllowance, uint256 required);
    error NoPositionToWithdraw();
    error PositionRoundsToZero();
    error PreviewMathDegenerate();
    error UnserviceableNet(uint256 desiredNetUSDC, uint256 maxDeliverable);
    error InvalidAmount();
    error SlippageExceeded(uint256 received, uint256 minExpected);
    error InvalidSignature();

    /// @notice Constructor-side zero-address errors. One per dependency so the
    ///         revert reason pinpoints the misconfigured argument.
    error ZeroUsdc();
    error ZeroAavePool();
    error ZeroAToken();
    error ZeroMorphoVault();
    error ZeroOracle();
    error ZeroFeeCollector();
    error ZeroDvUsdc();
    error ZeroEmergencyMultisig();

    /// @notice Reverts when neither vault is both oracle-safe and able to
    ///         accommodate the requested deposit amount. This may occur when
    ///         capacity is unavailable or the oracle marks one or both routes unsafe.
    error NoSafeRoute(uint256 amount);

    /// @notice Reverts on withdrawal when Aave's redeemable cash plus Morpho's
    ///         effective `maxWithdraw` is less than the requested gross USDC —
    ///         i.e. neither vault, alone or combined, can service the exit.
    /// @param  requested  The USDC amount the user is attempting to withdraw.
    /// @param  available  The combined effective capacity across both vaults
    ///                    at the time of the call.
    error InsufficientVaultLiquidity(uint256 requested, uint256 available);

    /// @notice Reverts when the oracle has not been updated within MAX_STALENESS (2 hours).
    ///         Call DivigentYieldOracle.recordObservation() to refresh the oracle,
    ///         then retry the deposit.
    error StaleOracle();

    /// @notice Reverts when the router's Morpho position cannot be valued
    ///         (MORPHO_VAULT.convertToAssets reverted or hit the try/catch
    ///         gas limit) and the router has non-zero Morpho exposure.
    ///         A cleaner version of the previous behaviour where the raw
    ///         Morpho revert would bubble up. SDKs can pre-flight this via
    ///         `withdrawCapacity()` — `morphoReachable == false` means the
    ///         next withdraw for a Morpho-touching wallet will revert with
    ///         this error.
    error MorphoUnreachable();

    /// @notice Reverts when the proposed Morpho view-call gas stipend is
    ///         outside `[MIN_MORPHO_VIEW_GAS, MAX_MORPHO_VIEW_GAS]`.
    /// @param  provided The proposed gas value.
    /// @param  min      The protocol-enforced lower bound (inclusive).
    /// @param  max      The protocol-enforced upper bound (inclusive).
    error MorphoViewGasOutOfBounds(uint256 provided, uint256 min, uint256 max);

    // ── Authorisation ─────────────────────────────────────────────────────────

    /// @notice Registers msg.sender as an authorised agent wallet.
    ///         Each wallet must self-register — no third party can register on their
    ///         behalf without an EIP-712 signature (see initializeFor).
    function initialize() external;

    /// @notice Registers `wallet` using an EIP-712 signature from `wallet`.
    ///         Allows a relayer or smart contract to register a wallet on its behalf,
    ///         enabling gasless onboarding flows where the wallet signs off-chain.
    /// @param wallet   The agent wallet to authorise.
    /// @param deadline Unix timestamp after which the signature is invalid.
    /// @param sig      EIP-712 signature over InitializeFor(address wallet, uint256 deadline, uint256 nonce).
    function initializeFor(
        address wallet,
        uint256 deadline,
        bytes calldata sig
    ) external;

    /// @notice Grants or revokes operator status for msg.sender's wallet.
    ///         An operator can call deposit() and withdraw() on behalf of the wallet.
    ///         The wallet retains full control and may revoke at any time.
    /// @dev    v1 operator approvals are on-chain only; no permit-based approval path.
    /// @param operator Address to approve or revoke.
    /// @param approved True to grant operator status; false to revoke.
    function setOperator(address operator, bool approved) external;

    /// @notice Returns the current EIP-712 nonce for `wallet`.
    ///         The nonce is consumed and incremented on each successful initializeFor() call.
    ///         Off-chain signers should read this value before constructing a signature.
    function nonces(address wallet) external view returns (uint256);

    // ── Core Operations ───────────────────────────────────────────────────────

    /// @notice Deposits `amount` USDC from `wallet` into the optimal yield vault,
    ///         minting dvUSDC receipt tokens back to `wallet`.
    ///         Caller must be `wallet` itself or an authorised operator for `wallet`.
    ///         `wallet` must have pre-approved the router for at least `amount` USDC.
    /// @param amount       USDC amount to deposit (6 decimals).
    /// @param wallet       Agent wallet address (receives dvUSDC).
    /// @param minSharesOut Minimum dvUSDC shares to mint; reverts if slippage exceeded.
    /// @return dvUsdcMinted Number of dvUSDC tokens minted.
    function deposit(uint256 amount, address wallet, uint256 minSharesOut)
        external
        returns (uint256 dvUsdcMinted);

    /// @notice EIP-2612 permit variant — no prior USDC.approve() required.
    ///         Combines permit + deposit in a single transaction.
    /// @param amount   USDC amount to deposit (6 decimals).
    /// @param wallet   Agent wallet that owns the USDC and receives dvUSDC.
    /// @param deadline Unix timestamp after which the permit signature is invalid.
    /// @param v        ECDSA signature component v.
    /// @param r        ECDSA signature component r.
    /// @param s        ECDSA signature component s.
    /// @param minSharesOut Minimum dvUSDC shares to mint; reverts if slippage exceeded.
    /// @return dvUsdcMinted Number of dvUSDC tokens minted.
    function depositWithPermit(
        uint256 amount,
        address wallet,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s,
        uint256 minSharesOut
    ) external returns (uint256 dvUsdcMinted);

    /// @notice Redeems `shares` dvUSDC from `wallet`, withdrawing USDC from the
    ///         underlying vault, deducting the 10% yield fee, and returning the
    ///         remainder to `wallet`.
    ///         Caller must be `wallet` itself or an authorised operator.
    ///         Fee is computed on the actual USDC received from vaults, not an estimate,
    ///         ensuring the principal is never touched regardless of vault rounding.
    /// @param shares      dvUSDC amount to redeem (6 decimals).
    /// @param wallet      Agent wallet address (source of dvUSDC, receives USDC).
    /// @param minUsdcOut  Minimum USDC to receive; reverts if slippage exceeded.
    /// @return usdcReturned Net USDC returned to the wallet after fee deduction.
    function withdraw(
        uint256 shares,
        address wallet,
        uint256 minUsdcOut
    ) external returns (uint256 usdcReturned);

    // ── View: Position & State ─────────────────────────────────────────────────

    /// @notice Returns the total USDC value managed across all vaults.
    function totalVaultAssets() external view returns (uint256);

    /// @notice Returns the current dvUSDC price in USDC (scaled by 1e18).
    ///         Monotonically non-decreasing as yield accrues.
    function pricePerShare() external view returns (uint256);

    /// @notice Returns the current TVL cap in USDC (6 decimals).
    ///         Expands automatically at day 31 and day 91 post-deployment.
    function currentTVLCap() external view returns (uint256);

    /// @notice Returns the agent's current position.
    /// @return depositedUSDC   Original principal deposited (cost basis).
    /// @return currentValue    Current USDC value of the agent's dvUSDC holdings.
    /// @return accruedYield    Current unrealised yield (currentValue - depositedUSDC).
    function getPosition(address wallet)
        external
        view
        returns (
            uint256 depositedUSDC,
            uint256 currentValue,
            uint256 accruedYield
        );

    // ── View: Preview & Simulation ─────────────────────────────────────────────

    /// @notice Preview how many dvUSDC shares would be minted for a given USDC deposit.
    ///         Uses the current live exchange rate. Note: the actual deposit uses a
    ///         pre-transfer snapshot, so the minted amount may differ slightly.
    /// @param assets USDC amount to simulate depositing (6 decimals).
    /// @return dvUsdcOut Expected dvUSDC minted.
    function previewDeposit(uint256 assets) external view returns (uint256 dvUsdcOut);

    /// @notice Preview the net USDC returned if `wallet` redeems `dvUsdcShares`.
    ///         Accounts for the 10% yield fee on accrued yield.
    /// @param dvUsdcShares Shares to simulate redeeming.
    /// @param wallet       Wallet whose cost basis is used for fee computation.
    /// @return usdcOut     Expected net USDC after fee.
    function previewRedeem(uint256 dvUsdcShares, address wallet)
        external view returns (uint256 usdcOut);

    /// @notice Preview how many dvUSDC shares must be redeemed to receive at least
    ///         `desiredNetUSDC` after the yield fee is deducted.
    ///         Rounds up to ensure the user receives at least the requested amount;
    ///         reverts when the requested net amount is not serviceable.
    /// @param desiredNetUSDC Target net USDC after fee (6 decimals).
    /// @param wallet         Wallet whose cost basis is used for fee computation.
    /// @return dvUsdcShares  Shares to redeem.
    function previewWithdrawNet(uint256 desiredNetUSDC, address wallet)
        external view returns (uint256 dvUsdcShares);

    /// @notice Convert a USDC amount to dvUSDC shares at the current exchange rate.
    ///         Uses the same virtual-offset formula as deposit().
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Convert dvUSDC shares to USDC at the current exchange rate.
    ///         Uses the same virtual-offset formula as withdraw().
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the USDC value currently held in each yield vault.
    /// @return aaveAssets   USDC value of aToken balance in Aave.
    /// @return morphoAssets USDC value of MetaMorpho shares held by this router.
    function getCurrentAllocation()
        external view returns (uint256 aaveAssets, uint256 morphoAssets);

    /// @notice Safe pre-flight view for withdraw planning. Returns the
    ///         router's current exit capacity decomposed per vault.
    ///
    ///         Never reverts. If Morpho's view path is unavailable, the
    ///         call still returns with `morphoReachable = false` and Morpho
    ///         fields zeroed. Callers can compare `totalWithdrawCap` against a
    ///         desired gross and decide whether to submit the withdraw
    ///         tx — avoiding wasted gas on a predictable revert.
    ///
    ///         Mirrors `withdraw()`'s internal planning math exactly. A
    ///         successful read at block N is a strong (but not atomic)
    ///         guarantee that a withdraw at the same block will clear
    ///         for `gross <= totalWithdrawCap`.
    function withdrawCapacity() external view returns (VaultCapacity memory);

    /// @notice Returns the oracle's recommended vault for a given deposit amount,
    ///         accounting for oracle safety and amount-aware capacity checks.
    ///         Reverts with NoSafeRoute if neither vault passes both gates.
    /// @param amount USDC amount to route.
    /// @return vaultType Recommended VaultType (AAVE or MORPHO).
    function getRecommendedRoute(uint256 amount)
        external view returns (IDivigentYieldOracle.VaultType vaultType);

    /// @notice Returns the oracle's current freshness status.
    /// @return lastObservationTime_ Unix timestamp of the most recent observation.
    /// @return fresh                True if the oracle is within MAX_STALENESS.
    function oracleStatus()
        external view returns (uint256 lastObservationTime_, bool fresh);

    // ── Emergency Controls (multisig only) ────────────────────────────────────

    /// @notice Pauses new deposits. Withdrawals remain unaffected at all times.
    ///         Only callable by the immutable emergency multisig.
    function pauseDeposits() external;

    /// @notice Resumes deposits after a pause.
    ///         Only callable by the immutable emergency multisig.
    function unpauseDeposits() external;

    /// @notice Update the gas stipend forwarded to Morpho's `convertToAssets`
    ///         view inside the router's withdraw-planning helper. Bounded by
    ///         `[MIN_MORPHO_VIEW_GAS, MAX_MORPHO_VIEW_GAS]`. Reverts with
    ///         `MorphoViewGasOutOfBounds` outside that range. Only callable
    ///         by the immutable emergency multisig.
    /// @param newGas The new gas stipend (inclusive of bounds).
    function setMorphoViewGas(uint256 newGas) external;

    // ── Emergency Treasury Rotation (multisig only, timelocked) ───────────────

    /// @dev Rotation lifecycle events (`TreasuryRotationProposed`,
    ///      `TreasuryRotationCancelled`, `TreasuryUpdated`) are emitted by
    ///      `DivigentFeeCollector` — where the state mutation happens.
    ///      Indexers watching the treasury-rotation lifecycle must subscribe
    ///      to the FeeCollector address.

    /// @notice Propose rotating the fee treasury to `newTreasury`. Starts
    ///         a 7-day timelock; the rotation must be finalised via
    ///         `executeTreasuryRotation`. Users can watch the
    ///         `TreasuryRotationProposed` event and exit before the delay
    ///         elapses if they disagree with the new treasury.
    ///
    ///         Only callable by the immutable emergency multisig. Intended
    ///         for recovery when the current treasury is blocklisted by
    ///         USDC (Circle's `blacklist(...)` admin action) — the fee
    ///         transfer would revert and withdrawals would DoS.
    function proposeTreasuryRotation(address newTreasury) external;

    /// @notice Finalise a previously-proposed rotation after the 7-day
    ///         delay elapses. Only callable by the emergency multisig.
    function executeTreasuryRotation() external;

    /// @notice Cancel a pending rotation before it executes. Only callable
    ///         by the emergency multisig.
    function cancelTreasuryRotation() external;
}
