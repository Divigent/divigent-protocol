// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IDivigentYieldOracle} from "../../../src/interfaces/IDivigentYieldOracle.sol";
import {RouterIntegrationBase} from "../RouterIntegrationBase.sol";

/// @title  Actions — integration-test helper layer
/// @notice Bundles common protocol actions with their structural post-conditions.
///         Flow tests inherit from `Actions` (which inherits `RouterIntegrationBase`)
///         and read like user journeys instead of `vm.prank` boilerplate.
///
///         What this layer DOES enforce automatically:
///           - dvUSDC balance moved by the right amount.
///           - costBasis moved by the right amount.
///           - Wallet's USDC moved by the right amount.
///           - INV-4: router holds zero USDC after every deposit/withdraw.
///
///         What this layer DOES NOT enforce — left to the test body:
///           - Fee correctness on yield (different per scenario).
///           - Cross-user fairness.
///           - pricePerShare monotonicity.
///           - Treasury accumulation.
///         Domain assertions belong in tests, not helpers, so they read explicitly.
abstract contract Actions is RouterIntegrationBase {
    // ═══════════════════════════════════════════════════════════════════════
    // Structs — point-in-time state snapshots
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Captures wallet-level state for pre/post assertions.
    struct WalletSnap {
        uint256 usdcBalance; // ERC20 USDC the wallet holds
        uint256 dvUsdcBalance; // dvUSDC shares the wallet holds
        uint256 costBasis; // router.costBasisUSDC[wallet]
        uint256 currentValue; // dvUSDC's USDC-denominated current value
        uint256 accruedYield; // currentValue - costBasis (or 0 under loss)
    }

    /// @dev Captures protocol-wide state for cross-test assertions.
    struct ProtocolSnap {
        uint256 totalVaultAssets; // aTokens + Morpho-share-value held by router
        uint256 dvUsdcSupply; // dvUSDC.totalSupply()
        uint256 pricePerShare; // router.pricePerShare()
        uint256 aaveAssets; // router's Aave-side holdings, USDC-denominated
        uint256 morphoAssets; // router's Morpho-side holdings, USDC-denominated
        uint256 treasuryUsdc; // USDC accumulated at the fee treasury
        uint256 routerUsdc; // USDC sitting in the router (must be 0 at rest)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Wallet lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Mint USDC to `wallet`. Used to onboard fresh actors.
    function fund(address wallet, uint256 usdcAmount) internal {
        usdc.mint(wallet, usdcAmount);
    }

    /// @notice Self-register `wallet` with the router.
    function register(address wallet) internal {
        vm.prank(wallet);
        router.initialize();
    }

    /// @notice Mint USDC to `wallet` and self-register it. Convenience for new actors.
    function fundAndRegister(address wallet, uint256 usdcAmount) internal {
        fund(wallet, usdcAmount);
        register(wallet);
    }

    /// @notice Create a new named, funded, registered actor in one call.
    function makeActor(string memory name, uint256 usdcAmount) internal returns (address actor) {
        actor = makeAddr(name);
        fundAndRegister(actor, usdcAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Routing
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Force the next deposit to route to Aave by setting the mock oracle.
    function useAaveRoute() internal {
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
    }

    /// @notice Force the next deposit to route to Morpho by setting the mock oracle.
    function useMorphoRoute() internal {
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Core actions — wallet deposits / withdraws
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice `wallet` deposits `amount` USDC for itself. Approves + deposits in one call.
    ///         Asserts structural post-conditions: dvUSDC moved, costBasis moved, USDC moved,
    ///         router holds no residual USDC (INV-4).
    /// @return sharesMinted Number of dvUSDC shares minted to `wallet`.
    function userDeposits(address wallet, uint256 amount) internal returns (uint256 sharesMinted) {
        WalletSnap memory pre = snap(wallet);

        vm.prank(wallet);
        usdc.approve(address(router), amount);

        vm.prank(wallet);
        sharesMinted = router.deposit(amount, wallet);

        WalletSnap memory post = snap(wallet);

        assertEq(
            post.dvUsdcBalance,
            pre.dvUsdcBalance + sharesMinted,
            "userDeposits: dvUSDC balance must increase by mintedShares"
        );
        assertEq(post.costBasis, pre.costBasis + amount, "userDeposits: costBasis must increase by deposit amount");
        assertEq(
            post.usdcBalance, pre.usdcBalance - amount, "userDeposits: wallet USDC must decrease by deposit amount"
        );
        assertEq(usdc.balanceOf(address(router)), 0, "userDeposits: router must hold zero USDC after deposit (INV-4)");
    }

    /// @notice `wallet` withdraws `shares` of dvUSDC for itself. No slippage protection.
    ///         Asserts structural post-conditions including INV-4.
    /// @return returned Net USDC delivered to `wallet` after fee.
    function userWithdraws(address wallet, uint256 shares) internal returns (uint256 returned) {
        return userWithdraws(wallet, shares, 0);
    }

    /// @notice `wallet` withdraws with explicit `minOut` slippage guard.
    /// @return returned Net USDC delivered to `wallet`.
    function userWithdraws(address wallet, uint256 shares, uint256 minOut) internal returns (uint256 returned) {
        WalletSnap memory pre = snap(wallet);

        // Mirror the router's principalOut calculation for costBasis assertions.
        uint256 expectedPrincipalOut = pre.dvUsdcBalance > 0 ? (pre.costBasis * shares) / pre.dvUsdcBalance : 0;

        vm.prank(wallet);
        returned = router.withdraw(shares, wallet, minOut);

        WalletSnap memory post = snap(wallet);

        assertEq(
            post.dvUsdcBalance,
            pre.dvUsdcBalance - shares,
            "userWithdraws: dvUSDC balance must decrease by burned shares"
        );
        assertEq(
            post.costBasis,
            pre.costBasis - expectedPrincipalOut,
            "userWithdraws: costBasis must decrease by principalOut"
        );
        assertEq(
            post.usdcBalance, pre.usdcBalance + returned, "userWithdraws: wallet USDC must increase by returned amount"
        );
        assertEq(usdc.balanceOf(address(router)), 0, "userWithdraws: router must hold zero USDC after withdraw (INV-4)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Operator-driven actions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice `operator_` deposits `amount` of `wallet`'s USDC on behalf of `wallet`.
    ///         Wallet must pre-grant operator status; this helper handles the approval too.
    function operatorDeposits(address operator_, address wallet, uint256 amount)
        internal
        returns (uint256 sharesMinted)
    {
        WalletSnap memory pre = snap(wallet);
        uint256 operatorUsdcBefore = usdc.balanceOf(operator_);

        // Wallet must approve router to pull its USDC; operator merely triggers.
        vm.prank(wallet);
        usdc.approve(address(router), amount);

        vm.prank(operator_);
        sharesMinted = router.deposit(amount, wallet);

        WalletSnap memory post = snap(wallet);

        assertEq(post.dvUsdcBalance, pre.dvUsdcBalance + sharesMinted, "operatorDeposits: shares to wallet");
        assertEq(post.costBasis, pre.costBasis + amount, "operatorDeposits: costBasis on wallet");
        assertEq(post.usdcBalance, pre.usdcBalance - amount, "operatorDeposits: USDC pulled from wallet, not operator");
        assertEq(usdc.balanceOf(operator_), operatorUsdcBefore, "operatorDeposits: operator's USDC untouched");
        assertEq(usdc.balanceOf(address(router)), 0, "operatorDeposits: router holds no USDC (INV-4)");
    }

    /// @notice `operator_` withdraws on behalf of `wallet`. USDC always returns to `wallet`.
    function operatorWithdraws(address operator_, address wallet, uint256 shares) internal returns (uint256 returned) {
        WalletSnap memory pre = snap(wallet);
        uint256 operatorUsdcBefore = usdc.balanceOf(operator_);

        vm.prank(operator_);
        returned = router.withdraw(shares, wallet, 0);

        WalletSnap memory post = snap(wallet);

        assertEq(post.dvUsdcBalance, pre.dvUsdcBalance - shares, "operatorWithdraws: shares burned from wallet");
        assertEq(post.usdcBalance, pre.usdcBalance + returned, "operatorWithdraws: USDC returned to wallet");
        assertEq(usdc.balanceOf(operator_), operatorUsdcBefore, "operatorWithdraws: operator receives no USDC");
        assertEq(usdc.balanceOf(address(router)), 0, "operatorWithdraws: router holds no USDC (INV-4)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Yield simulation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Simulate Aave yield by minting aTokens to the router. Mirrors how Aave's
    ///         rebasing aToken grows over time as borrowers pay interest.
    function accrueAaveYield(uint256 yieldAmount) internal {
        aToken.mint(address(router), yieldAmount);
    }

    /// @notice Simulate Morpho yield by inflating the vault's totalAssets without
    ///         minting new shares. Router's share value rises proportionally.
    function accrueMorphoYield(uint256 yieldAmount) internal {
        morphoVault.accrueYield(yieldAmount);
    }

    /// @notice Convenience: accrue equal yield in both vaults at once.
    function accrueYieldInBothVaults(uint256 aaveYield, uint256 morphoYield) internal {
        accrueAaveYield(aaveYield);
        accrueMorphoYield(morphoYield);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // State snapshots
    // ═══════════════════════════════════════════════════════════════════════

    function snap(address wallet) internal view returns (WalletSnap memory s) {
        s.usdcBalance = usdc.balanceOf(wallet);
        s.dvUsdcBalance = dvUsdc.balanceOf(wallet);
        (s.costBasis, s.currentValue, s.accruedYield) = router.getPosition(wallet);
    }

    function snapProtocol() internal view returns (ProtocolSnap memory s) {
        (uint256 aave, uint256 morpho) = router.getCurrentAllocation();
        s.totalVaultAssets = router.totalVaultAssets();
        s.dvUsdcSupply = dvUsdc.totalSupply();
        s.pricePerShare = router.pricePerShare();
        s.aaveAssets = aave;
        s.morphoAssets = morpho;
        s.treasuryUsdc = usdc.balanceOf(treasury);
        s.routerUsdc = usdc.balanceOf(address(router));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Time
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Advance `block.timestamp` by `secs`. Wraps `skip()` for readability;
    ///         use `fastForward(7 days)` over `vm.warp(block.timestamp + 7 days)` —
    ///         the latter doesn't re-read inside loops (Foundry quirk).
    function fastForward(uint256 secs) internal {
        skip(secs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Fee math (mirror of FeeCollector.calculateFee for test-side expectations)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The fee the protocol would charge on `yield_`.
    function expectedFee(uint256 yield_) internal view returns (uint256) {
        return feeCollector.calculateFee(yield_);
    }

    /// @notice What the user nets after the fee is deducted from `yield_`.
    function expectedNetYield(uint256 yield_) internal view returns (uint256) {
        return yield_ - expectedFee(yield_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Struct equality — field-by-field assertEq with precise failure messages
    // (Aave V4-style: one assert on the whole snap, diagnostics point at the
    //  specific field that diverged)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Field-by-field equality check on two WalletSnap structs.
    ///         On failure, the error message identifies the specific field.
    function assertEq(WalletSnap memory a, WalletSnap memory b, string memory context) internal pure {
        assertEq(a.usdcBalance, b.usdcBalance, string.concat(context, ": usdcBalance"));
        assertEq(a.dvUsdcBalance, b.dvUsdcBalance, string.concat(context, ": dvUsdcBalance"));
        assertEq(a.costBasis, b.costBasis, string.concat(context, ": costBasis"));
        assertEq(a.currentValue, b.currentValue, string.concat(context, ": currentValue"));
        assertEq(a.accruedYield, b.accruedYield, string.concat(context, ": accruedYield"));
    }

    /// @notice Field-by-field equality check on two ProtocolSnap structs.
    function assertEq(ProtocolSnap memory a, ProtocolSnap memory b, string memory context) internal pure {
        assertEq(a.totalVaultAssets, b.totalVaultAssets, string.concat(context, ": totalVaultAssets"));
        assertEq(a.dvUsdcSupply, b.dvUsdcSupply, string.concat(context, ": dvUsdcSupply"));
        assertEq(a.pricePerShare, b.pricePerShare, string.concat(context, ": pricePerShare"));
        assertEq(a.aaveAssets, b.aaveAssets, string.concat(context, ": aaveAssets"));
        assertEq(a.morphoAssets, b.morphoAssets, string.concat(context, ": morphoAssets"));
        assertEq(a.treasuryUsdc, b.treasuryUsdc, string.concat(context, ": treasuryUsdc"));
        assertEq(a.routerUsdc, b.routerUsdc, string.concat(context, ": routerUsdc"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EIP-712 signing — initializeFor (gasless onboarding)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Mirrors `INITIALIZE_FOR_TYPEHASH` defined inside DivigentVaultRouter.
    bytes32 internal constant INITIALIZE_FOR_TYPEHASH =
        keccak256("InitializeFor(address wallet,uint256 deadline,uint256 nonce)");

    /// @notice Build and sign an `initializeFor` EIP-712 typed-data digest.
    /// @param  privateKey  The signing key (owned by `wallet`).
    /// @param  wallet      The wallet being authorised.
    /// @param  deadline    Unix timestamp after which the signature is invalid.
    /// @return sig         The 65-byte signature ready to pass to `router.initializeFor`.
    function signInitializeFor(uint256 privateKey, address wallet, uint256 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        uint256 nonce = router.nonces(wallet);

        bytes32 structHash = keccak256(abi.encode(INITIALIZE_FOR_TYPEHASH, wallet, deadline, nonce));

        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DivigentVaultRouter")),
                keccak256(bytes("1")),
                block.chainid,
                address(router)
            )
        );

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSep, structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EIP-2612 signing — USDC permit (gasless deposit)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Build and sign an EIP-2612 permit digest against USDC's domain.
    ///         Produced values go straight into `router.depositWithPermit`.
    /// @param  privateKey  The signing key (owned by `owner`).
    /// @param  owner       The token holder granting the allowance.
    /// @param  spender     The address receiving the allowance — always the router
    ///                     for `depositWithPermit`.
    /// @param  value       Permit amount.
    /// @param  deadline    Unix timestamp after which the signature is invalid.
    function signPermit(uint256 privateKey, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = usdc.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(usdc.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));

        (v, r, s) = vm.sign(privateKey, digest);
    }
}
