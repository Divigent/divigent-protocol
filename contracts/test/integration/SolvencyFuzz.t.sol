// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "../TestBase.sol";

/// @title SolvencyInvariantTest
/// @notice Fuzz tests for the solvency invariant:
///         totalVaultAssets() >= sum of costBasisUSDC across all depositors
///
///         This is the most critical accounting invariant — if it breaks,
///         the protocol is insolvent (dvUSDC holders have claims exceeding
///         the underlying vault assets).
contract SolvencyInvariantTest is TestBase {
    address internal charlie;
    uint256 constant MIN_AMT = 10e6;     // MIN_DEPOSIT
    uint256 constant MAX_AMT = 50_000e6; // 50k USDC

    function setUp() public override {
        super.setUp();
        charlie = makeAddr("charlie");
        usdc.mint(charlie, 1_000_000e6);
        vm.prank(charlie);
        router.initialize();
    }

    // ─── Invariant: totalVaultAssets >= sum(costBasis) ──────────────────────

    /// @notice After N deposits from different users, the total vault assets
    ///         must be >= the sum of all cost bases.
    function testFuzz_solvency_afterDeposits(
        uint256 aliceAmt,
        uint256 bobAmt,
        uint256 charlieAmt
    ) public {
        aliceAmt = bound(aliceAmt, MIN_AMT, MAX_AMT);
        bobAmt = bound(bobAmt, MIN_AMT, MAX_AMT);
        charlieAmt = bound(charlieAmt, MIN_AMT, MAX_AMT);

        _deposit(alice, aliceAmt);
        _deposit(bob, bobAmt);
        _deposit(charlie, charlieAmt);

        _assertSolvency();
    }

    /// @notice After deposits + partial withdrawals, solvency still holds.
    function testFuzz_solvency_afterPartialWithdrawals(
        uint256 depositAmt,
        uint256 withdrawPct
    ) public {
        depositAmt = bound(depositAmt, MIN_AMT, MAX_AMT);
        withdrawPct = bound(withdrawPct, 1, 99); // 1-99%

        _deposit(alice, depositAmt);
        _deposit(bob, depositAmt);

        uint256 aliceShares = dvUsdc.balanceOf(alice);
        uint256 toWithdraw = (aliceShares * withdrawPct) / 100;
        if (toWithdraw > 0) {
            vm.prank(alice);
            router.withdraw(toWithdraw, alice, 0);
        }

        _assertSolvency();
    }

    /// @notice After deposits + yield accrual + withdrawals, solvency holds.
    function testFuzz_solvency_withYield(
        uint256 depositAmt,
        uint256 yieldAmt,
        uint256 withdrawPct
    ) public {
        depositAmt = bound(depositAmt, MIN_AMT, MAX_AMT);
        yieldAmt = bound(yieldAmt, 1, depositAmt / 10); // up to 10% yield
        withdrawPct = bound(withdrawPct, 1, 100);

        _deposit(alice, depositAmt);

        aToken.mint(address(router), yieldAmt);

        _assertSolvency();

        uint256 shares = dvUsdc.balanceOf(alice);
        uint256 toWithdraw = (shares * withdrawPct) / 100;
        if (toWithdraw > 0) {
            vm.prank(alice);
            router.withdraw(toWithdraw, alice, 0);
        }

        _assertSolvency();
    }

    /// @notice Multi-user deposit-withdraw interleaving preserves solvency.
    function testFuzz_solvency_interleaved(
        uint256 a1,
        uint256 b1,
        uint256 aWithdrawPct,
        uint256 a2
    ) public {
        a1 = bound(a1, MIN_AMT, MAX_AMT);
        b1 = bound(b1, MIN_AMT, MAX_AMT);
        aWithdrawPct = bound(aWithdrawPct, 1, 100);
        a2 = bound(a2, MIN_AMT, MAX_AMT);

        _deposit(alice, a1);
        _assertSolvency();

        _deposit(bob, b1);
        _assertSolvency();

        uint256 aliceShares = dvUsdc.balanceOf(alice);
        uint256 toWithdraw = (aliceShares * aWithdrawPct) / 100;
        if (toWithdraw > 0) {
            vm.prank(alice);
            router.withdraw(toWithdraw, alice, 0);
        }
        _assertSolvency();

        _deposit(alice, a2);
        _assertSolvency();
    }

    /// @notice Share round-trip: deposit then full withdraw returns ~deposit (within rounding).
    function testFuzz_roundTrip_noFundLeak(uint256 amt) public {
        amt = bound(amt, MIN_AMT, MAX_AMT);

        uint256 balBefore = usdc.balanceOf(alice);
        _deposit(alice, amt);

        uint256 shares = dvUsdc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(shares, alice, 0);

        uint256 balAfter = usdc.balanceOf(alice);
        // Allow 2 wei rounding from virtual offset
        assertGe(balAfter, balBefore - 2, "Round-trip should not leak more than 2 wei");
        assertLe(balAfter, balBefore, "Round-trip should not create USDC from nothing");
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(router), amount);
        router.deposit(amount, user);
        vm.stopPrank();
    }

    function _assertSolvency() internal view {
        uint256 totalAssets = router.totalVaultAssets();
        uint256 sumCostBasis = router.costBasisUSDC(alice)
            + router.costBasisUSDC(bob)
            + router.costBasisUSDC(charlie);

        assertGe(
            totalAssets,
            sumCostBasis,
            "SOLVENCY VIOLATED: totalVaultAssets < sum(costBasis)"
        );
    }

    /// @notice Minimal reproduction: deposit, yield, partial withdraw, check.
    ///         Repeats to verify rounding drift stays within tolerance.
    function test_solvencyDrift_minimalRepro() public {
        uint256 deposit = 50_000e6;

        _deposit(alice, deposit);
        aToken.mint(address(router), 5_000e6);
        _assertSolvency();

        uint256 half = dvUsdc.balanceOf(alice) / 2;
        vm.prank(alice);
        router.withdraw(half, alice, 0);
        _assertSolvency();

        aToken.mint(address(router), 3_000e6);
        uint256 remaining = dvUsdc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(remaining, alice, 0);

        assertEq(router.costBasisUSDC(alice), 0, "Alice fully exited");

        _assertSolvency();
    }

    /// @notice Multi-user version: Alice + Bob deposit, yield, Alice exits with fee
    ///         Bob's remaining position should still be solvent.
    function test_solvencyDrift_multiUser() public {
        uint256 dep = 50_000e6;

        _deposit(alice, dep);
        _deposit(bob, dep);
        _assertSolvency(); // 100k deposited, 100k in vault

        aToken.mint(address(router), 20_000e6);
        _assertSolvency(); // vault = 120k, costBasis = 100k, surplus = 20k

        uint256 aliceShares = dvUsdc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(aliceShares, alice, 0);

        _assertSolvency();

        aToken.mint(address(router), 5_000e6);
        uint256 bobShares = dvUsdc.balanceOf(bob);
        vm.prank(bob);
        router.withdraw(bobShares, bob, 0);

        _assertSolvency();
    }
}
