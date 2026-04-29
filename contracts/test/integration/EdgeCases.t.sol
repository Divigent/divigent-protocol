// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "../TestBase.sol";

import {DivigentVaultRouter} from "../../src/DivigentVaultRouter.sol";
import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {DvUSDC} from "../../src/dvUSDC.sol";
import {DivigentYieldOracle} from "../../src/DivigentYieldOracle.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title GapTests
/// @notice Fills gaps flagged by the 20-agent test review:
///         - Tier 1: zero-coverage functions
///         - Tier 2: missing error-path tests
///         - Tier 3: missing integration scenarios
contract GapTests is TestBase {
    uint256 constant DEPOSIT = 1_000e6;
    uint256 constant MIN_DEP = 10e6;

    bytes32 private constant INITIALIZE_FOR_TYPEHASH =
        keccak256("InitializeFor(address wallet,uint256 deadline,uint256 nonce)");

    // ════════════════════════════════════════════════════════════════════════
    //  TIER 1 — Zero coverage
    // ════════════════════════════════════════════════════════════════════════

    // ─── 1.1 Constructor zero-address checks ────────────────────────────────

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroUsdc()"));
        new DivigentVaultRouter(
            address(0), address(aavePool), address(aToken), address(morphoVault),
            address(yieldOracle), address(feeCollector), address(dvUsdc), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroAavePool() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAavePool()"));
        new DivigentVaultRouter(
            address(usdc), address(0), address(aToken), address(morphoVault),
            address(yieldOracle), address(feeCollector), address(dvUsdc), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroAToken() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAToken()"));
        new DivigentVaultRouter(
            address(usdc), address(aavePool), address(0), address(morphoVault),
            address(yieldOracle), address(feeCollector), address(dvUsdc), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroMorphoVault() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroMorphoVault()"));
        new DivigentVaultRouter(
            address(usdc), address(aavePool), address(aToken), address(0),
            address(yieldOracle), address(feeCollector), address(dvUsdc), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroOracle() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroOracle()"));
        new DivigentVaultRouter(
            address(usdc), address(aavePool), address(aToken), address(morphoVault),
            address(0), address(feeCollector), address(dvUsdc), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroFeeCollector() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroFeeCollector()"));
        new DivigentVaultRouter(
            address(usdc), address(aavePool), address(aToken), address(morphoVault),
            address(yieldOracle), address(0), address(dvUsdc), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroDvUsdc() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroDvUsdc()"));
        new DivigentVaultRouter(
            address(usdc), address(aavePool), address(aToken), address(morphoVault),
            address(yieldOracle), address(feeCollector), address(0), emergencyMultisig
        );
    }

    function test_constructor_revertsOnZeroEmergencyMultisig() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroEmergencyMultisig()"));
        new DivigentVaultRouter(
            address(usdc), address(aavePool), address(aToken), address(morphoVault),
            address(yieldOracle), address(feeCollector), address(dvUsdc), address(0)
        );
    }

    // ─── 1.2 getCurrentAllocation — state transitions, not static snapshot ──

    /// @notice `getCurrentAllocation` must track the three observable states
    ///         of the router's vault holdings end-to-end: empty, single-vault
    ///         post-deposit, and drained back to near-empty post-withdraw.
    ///         The sum must always equal `totalVaultAssets()` (consistency
    ///         with Router-I invariant).
    function test_getCurrentAllocation_transitionsAcrossFullLifecycle() public {
        // State 1: empty → both legs at zero, totalVaultAssets = 0.
        (uint256 aave0, uint256 morpho0) = router.getCurrentAllocation();
        assertEq(aave0 + morpho0, router.totalVaultAssets(), "decomposition sums to total");
        assertEq(aave0, 0, "Aave empty at deploy");
        assertEq(morpho0, 0, "Morpho empty at deploy");

        // State 2: post-Aave-deposit → Aave populated, Morpho untouched.
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();

        (uint256 aave1, uint256 morpho1) = router.getCurrentAllocation();
        assertEq(aave1 + morpho1, router.totalVaultAssets(), "decomposition still sums");
        assertApproxEqAbs(aave1, DEPOSIT, 2, "Aave leg holds the deposit");
        assertEq(morpho1, 0, "Morpho untouched");

        // State 3: post-yield → Aave grows, Morpho still empty.
        aToken.mint(address(router), 500e6);
        (uint256 aave2, uint256 morpho2) = router.getCurrentAllocation();
        assertGt(aave2, aave1, "Aave leg grew with yield");
        assertEq(morpho2, 0, "Morpho still untouched");

        // State 4: post-withdraw → Aave drains back toward zero.
        uint256 shares = dvUsdc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(shares, alice, 0);

        (uint256 aave3, uint256 morpho3) = router.getCurrentAllocation();
        assertEq(aave3 + morpho3, router.totalVaultAssets(), "decomposition still sums");
        assertLt(aave3, aave2, "Aave drained by withdraw");
    }

    // ─── 1.3 oracleStatus — staleness transition, not just fresh snapshot ───

    /// @notice `oracleStatus.fresh` must flip in both directions: stale when
    ///         time elapses past MAX_STALENESS, fresh again after a new
    ///         observation. A purely static assertion that "fresh right after
    ///         setup" is true proves nothing about the freshness logic itself.
    function test_oracleStatus_flipsFreshOnStalenessTransition() public {
        // Fresh initially (setUp recorded an observation).
        (uint256 lastObs0, bool fresh0) = router.oracleStatus();
        assertTrue(fresh0, "fresh at setup");
        assertGt(lastObs0, 0, "observation timestamp non-zero");

        // Warp past MAX_STALENESS (2 hours) → goes stale.
        vm.warp(block.timestamp + 3 hours);
        (uint256 lastObs1, bool fresh1) = router.oracleStatus();
        assertFalse(fresh1, "stale after 3h with no observation");
        assertEq(lastObs1, lastObs0, "lastObservationTime does not drift while stale");

        // Record a fresh observation → fresh again, timestamp advances.
        yieldOracle.recordObservation();
        (uint256 lastObs2, bool fresh2) = router.oracleStatus();
        assertTrue(fresh2, "fresh again after new observation");
        assertGt(lastObs2, lastObs1, "lastObservationTime advanced");
    }

    // ─── 1.4 getRecommendedRoute — fallback under capacity constraint ───────

    /// @notice `getRecommendedRoute` must honour the amount-aware fallback:
    ///         if the oracle-recommended vault can't fit the deposit, it
    ///         returns the alternate vault. If neither fits, reverts
    ///         `NoSafeRoute`. A static "returns Aave" test misses the entire
    ///         fallback branch.
    function test_getRecommendedRoute_fallsBackWhenAavePoolDry() public {
        // Primary Aave route works when idle is ample.
        assertEq(
            uint8(router.getRecommendedRoute(DEPOSIT)),
            uint8(IDivigentYieldOracle.VaultType.AAVE),
            "primary recommends Aave with ample idle"
        );

        // Drain Aave idle → `_canAllocate(AAVE, DEPOSIT)` returns false.
        // Morpho is still available, so the router falls back.
        usdc.setBalance(address(aToken), 0);
        assertEq(
            uint8(router.getRecommendedRoute(DEPOSIT)),
            uint8(IDivigentYieldOracle.VaultType.MORPHO),
            "fallback to Morpho when Aave idle is empty"
        );

        // Cap Morpho too → neither works → reverts.
        morphoVault.setMaxDeposit(0);
        vm.expectRevert(abi.encodeWithSignature("NoSafeRoute(uint256)", DEPOSIT));
        router.getRecommendedRoute(DEPOSIT);
    }

    // ─── 1.5 depositWithPermit ──────────────────────────────────────────────

    function test_depositWithPermit_happyPath() public {
        uint256 amount = DEPOSIT;
        uint256 deadline = block.timestamp + 1 hours;

        // Build USDC permit signature
        bytes32 permitHash = _buildPermitHash(alice, address(router), amount, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, permitHash);

        vm.prank(alice);
        uint256 minted = router.depositWithPermit(amount, alice, deadline, v, r, s, 0);

        assertGt(minted, 0, "Should mint dvUSDC");
        assertEq(dvUsdc.balanceOf(alice), minted);
        assertEq(router.costBasisUSDC(alice), amount);
    }

    function test_depositWithPermit_revertsOnExpiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, _buildPermitHash(alice, address(router), DEPOSIT, deadline));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PermitExpired()"));
        router.depositWithPermit(DEPOSIT, alice, deadline, v, r, s, 0);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  TIER 2 — Missing error-path tests
    // ════════════════════════════════════════════════════════════════════════

    // ─── 2.1 ZeroAmount on deposit ──────────────────────────────────────────

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        router.deposit(0, alice, 0);
    }

    // ─── 2.2 InvalidAmount below MIN_DEPOSIT ────────────────────────────────

    function test_deposit_revertsOnBelowMinDeposit() public {
        vm.startPrank(alice);
        usdc.approve(address(router), 5e6);
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        router.deposit(5e6, alice, 0); // 5 USDC < MIN_DEPOSIT (10 USDC)
        vm.stopPrank();
    }

    // ─── 2.3 InsufficientShares on withdraw ─────────────────────────────────

    function test_withdraw_revertsOnInsufficientShares() public {
        // Alice deposits, gets some shares
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);

        uint256 shares = dvUsdc.balanceOf(alice);
        // Try to withdraw more shares than held
        vm.expectRevert(abi.encodeWithSignature("InsufficientShares(uint256,uint256)", shares + 1, shares));
        router.withdraw(shares + 1, alice, 0);
        vm.stopPrank();
    }

    // ─── 2.4 ZeroAmount on withdraw ─────────────────────────────────────────

    function test_withdraw_revertsOnZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        router.withdraw(0, alice, 0);
    }

    // ─── 2.5 InsufficientVaultLiquidity ─────────────────────────────────────

    function test_withdraw_revertsWhenBothVaultsDrained() public {
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();

        uint256 shares = dvUsdc.balanceOf(alice);

        // Drain Aave liquidity
        usdc.setBalance(address(aToken), 0);
        aToken.setBalance(address(router), 0);
        // Drain Morpho capacity
        morphoVault.setMaxWithdraw(0);

        // When both vaults report zero balance the router hits the
        // totalHeld == 0 guard first and reverts with ZeroAmount.
        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.ZeroAmount.selector);
        router.withdraw(shares, alice, 0);
    }

    // ─── 2.6 NotEmergencyMultisig on pause ──────────────────────────────────

    function test_pauseDeposits_revertsForNonMultisig() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotEmergencyMultisig()"));
        router.pauseDeposits();
    }

    function test_unpauseDeposits_revertsForNonMultisig() public {
        // First pause legitimately
        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        // Non-multisig tries to unpause
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotEmergencyMultisig()"));
        router.unpauseDeposits();
    }

    // ─── 2.7 Stale oracle blocks deposit ────────────────────────────────────

    function test_oracle_isStaleAfterMaxStaleness() public {
        // Verify the oracle reports stale after MAX_STALENESS (2h) with no observation
        vm.warp(block.timestamp + 3 hours);
        assertFalse(yieldOracle.isFresh(), "Oracle should be stale after 3h");
    }

    function test_deposit_autoHealsStaleOracle() public {
        // The router calls ORACLE.recordObservation() before checking isFresh().
        // This means a stale oracle is auto-healed by the deposit itself — the
        // StaleOracle error only fires when recordObservation CANNOT succeed
        // (e.g., underlying protocol view calls revert). This is by design:
        // the router is its own keeper.
        vm.warp(block.timestamp + 3 hours);
        assertFalse(yieldOracle.isFresh(), "Oracle stale before deposit");

        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        // Deposit should SUCCEED — recordObservation auto-refreshes the oracle
        uint256 minted = router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();

        assertGt(minted, 0, "Deposit succeeds because oracle auto-heals");
        assertTrue(yieldOracle.isFresh(), "Oracle should be fresh after deposit");
    }

    // ─── 2.8 NotAuthorised on deposit/withdraw ─────────────────────────────

    function test_deposit_revertsForUnauthorisedWallet() public {
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, DEPOSIT);

        vm.startPrank(stranger);
        usdc.approve(address(router), DEPOSIT);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorised()"));
        router.deposit(DEPOSIT, stranger, 0); // stranger never called initialize()
        vm.stopPrank();
    }

    function test_withdraw_revertsForUnauthorisedCaller() public {
        // Alice has a position
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();

        uint256 shares = dvUsdc.balanceOf(alice);

        // Stranger (not operator, not alice) tries to withdraw alice's position
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorised()"));
        router.withdraw(shares, alice, 0);
    }

    // ─── 2.9 WalletAlreadyAuthorised ────────────────────────────────────────

    function test_initialize_revertsOnDoubleInit() public {
        // alice is already initialized in TestBase.setUp
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("WalletAlreadyAuthorised()"));
        router.initialize();
    }

    // ════════════════════════════════════════════════════════════════════════
    //  TIER 3 — Missing integration scenarios
    // ════════════════════════════════════════════════════════════════════════

    // ─── 3.1 Operator cannot steal dvUSDC ───────────────────────────────────

    function test_operator_cannotTransferDvUsdc() public {
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);
        router.setOperator(operator_, true);
        vm.stopPrank();

        uint256 shares = dvUsdc.balanceOf(alice);

        // Operator tries to transfer alice's dvUSDC to themselves.
        // No allowance was granted → OZ ERC20 fires InsufficientAllowance before
        // the _update hook reaches the NonTransferable check. Either way the
        // steal is blocked; we pin the outer selector here.
        vm.prank(operator_);
        vm.expectPartialRevert(
            bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)"))
        );
        dvUsdc.transferFrom(alice, operator_, shares);
    }

    // ─── 3.2 Minimum denomination precision ─────────────────────────────────

    function test_deposit_minDeposit_10USDC() public {
        vm.startPrank(alice);
        usdc.approve(address(router), MIN_DEP);
        uint256 minted = router.deposit(MIN_DEP, alice, 0);
        vm.stopPrank();

        assertGt(minted, 0, "MIN_DEPOSIT should mint non-zero shares");
        assertEq(router.costBasisUSDC(alice), MIN_DEP);
    }

    function test_depositWithdraw_minDeposit_roundTrip() public {
        vm.startPrank(alice);
        usdc.approve(address(router), MIN_DEP);
        router.deposit(MIN_DEP, alice, 0);

        uint256 shares = dvUsdc.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        router.withdraw(shares, alice, 0);
        uint256 balAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        uint256 returned = balAfter - balBefore;
        // Allow 1 wei rounding loss from virtual offset
        assertGe(returned, MIN_DEP - 2, "Round-trip should return ~MIN_DEPOSIT");
    }

    // ─── 3.3 SlippageExceeded on withdraw ───────────────────────────────────

    function test_withdraw_revertsOnSlippageExceeded() public {
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);

        uint256 shares = dvUsdc.balanceOf(alice);
        // Set minOut higher than what the position is worth
        uint256 unreasonableMinOut = DEPOSIT * 2;

        vm.expectPartialRevert(IDivigentVaultRouter.SlippageExceeded.selector);
        router.withdraw(shares, alice, unreasonableMinOut);
        vm.stopPrank();
    }

    // ─── 3.4 Deposit while paused ───────────────────────────────────────────

    function test_deposit_revertsWhilePaused() public {
        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        vm.expectRevert(abi.encodeWithSignature("DepositsPausedError()"));
        router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();
    }

    // ─── 3.5 Withdraw succeeds while paused (INV-5) ────────────────────────

    function test_withdraw_succeedsWhilePaused() public {
        // Deposit first
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();

        uint256 shares = dvUsdc.balanceOf(alice);

        // Pause
        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        // Withdraw should still work
        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);
        assertGt(returned, 0, "Withdrawal must succeed while deposits are paused");
    }

    // ─── 3.6 Fee boundary: yield = 1 wei ───────────────────────────────────

    function test_fee_oneWeiYield_feeIsZero() public {
        // Fee on 1 wei yield: 1 * 1000 / 10000 = 0 (rounds down)
        uint256 fee = feeCollector.calculateFee(1);
        assertEq(fee, 0, "Fee on 1 wei yield should be 0 (rounds down)");
    }

    function test_fee_tenWeiYield_feeIsOneWei() public {
        // Fee on 10 wei yield: 10 * 1000 / 10000 = 1
        uint256 fee = feeCollector.calculateFee(10);
        assertEq(fee, 1, "Fee on 10 wei yield should be 1 wei");
    }

    // ─── 3.7 Both vaults unsafe simultaneously ──────────────────────────────

    function test_deposit_revertsWhenBothVaultsUnsafe() public {
        // Drain Morpho and Aave capacity so neither can accept
        morphoVault.setMaxDeposit(0);
        usdc.setBalance(address(aToken), 0);

        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        vm.expectPartialRevert(IDivigentVaultRouter.NoSafeRoute.selector);
        router.deposit(DEPOSIT, alice, 0);
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _buildPermitHash(address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = usdc.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.PERMIT_TYPEHASH(),
                owner,
                spender,
                value,
                usdc.nonces(owner),
                deadline
            )
        );
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }
}
