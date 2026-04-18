// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Property Fuzz Suite
/// @notice One property per function, Aave V4 style: `test_<op>_fuzz_<property>`.
///         Bounds are semantic (MIN_AMOUNT, MAX_DEPOSIT, MAX_YIELD), not type
///         limits, so the fuzzer spends its runs on realistic inputs.
///
///         Properties covered here are the ones journey tests can't reach
///         exhaustively: any single-call accounting leak, fee miscalc, or
///         share-math drift surfaces as soon as the fuzzer picks a bad input.
///
///         Structural invariants (INV-4: router holds zero USDC) are asserted
///         inside `Actions.userDeposits`/`userWithdraws`, so every fuzz run
///         exercises them automatically.
contract PropertyFuzzTest is Actions {
    // Semantic bounds. MAX_DEPOSIT stays under the 500k day-0 TVL cap so
    // deposits don't revert for reasons unrelated to the property under test.
    uint256 internal constant MIN_AMOUNT = 10e6; // router.MIN_DEPOSIT
    uint256 internal constant MAX_DEPOSIT = 400_000e6;
    uint256 internal constant MIN_YIELD = 100e6; // below this, per-wei rounding dominates
    uint256 internal constant MAX_YIELD = 100_000e6;
    // Fresh actors get 2x MAX_DEPOSIT so they can cover any bounded amount
    // plus a second deposit if the test needs one.
    uint256 internal constant ACTOR_FUNDING = MAX_DEPOSIT * 2;

    // ─────────────────────────────────────────────────────────────────────────
    // pricePerShare properties
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Accruing yield never decreases pricePerShare.
    function test_pricePerShare_fuzz_nonDecreasing_onYield(uint96 yieldAmount) public {
        uint256 yld = bound(uint256(yieldAmount), 1, MAX_YIELD);
        address user = makeActor("yield_user", ACTOR_FUNDING);

        useAaveRoute();
        userDeposits(user, 100_000e6);

        uint256 ppsBefore = router.pricePerShare();
        accrueAaveYield(yld);
        uint256 ppsAfter = router.pricePerShare();

        assertGe(ppsAfter, ppsBefore, "pps non-decreasing on yield accrual");
    }

    /// @notice A deposit with no yield between it and the prior state preserves
    ///         pricePerShare (within virtual-offset rounding of a few wei).
    function test_pricePerShare_fuzz_preserved_onDepositNoYield(uint128 amount) public {
        uint256 amt = bound(uint256(amount), MIN_AMOUNT, MAX_DEPOSIT - MIN_AMOUNT);
        address seedUser = makeActor("pps_seed", ACTOR_FUNDING);
        address follower = makeActor("pps_follower", ACTOR_FUNDING);

        useAaveRoute();
        userDeposits(seedUser, MIN_AMOUNT); // seed so pps is well-defined

        uint256 ppsBefore = router.pricePerShare();
        userDeposits(follower, amt);
        uint256 ppsAfter = router.pricePerShare();

        // Virtual-offset share math introduces O(1) wei drift per op.
        assertApproxEqAbs(ppsAfter, ppsBefore, 2, "pps preserved on deposit with no yield");
    }

    /// @notice A loss event (aToken balance drops) strictly decreases pps.
    function test_pricePerShare_fuzz_strictlyDecreases_onLoss(uint128 deposit_, uint96 loss_) public {
        uint256 dep = bound(uint256(deposit_), 50_000e6, MAX_DEPOSIT);
        // Minimum 0.1% of deposit so the loss is large enough to move pps past
        // rounding noise; max 50% so the vault isn't wiped out entirely.
        uint256 lossAmt = bound(uint256(loss_), dep / 1000, dep / 2);
        address user = makeActor("loss_user", ACTOR_FUNDING);

        useAaveRoute();
        userDeposits(user, dep);

        uint256 ppsBefore = router.pricePerShare();
        aToken.setBalance(address(router), dep - lossAmt);
        uint256 ppsAfter = router.pricePerShare();

        assertLt(ppsAfter, ppsBefore, "pps strictly decreases on loss event");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fee properties
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Fee charged on withdraw equals exactly 10% of realised yield,
    ///         within tight rounding tolerance.
    function test_fee_fuzz_exactlyTenPercentOfRealisedYield(uint128 deposit_, uint96 yield_) public {
        uint256 dep = bound(uint256(deposit_), 10_000e6, MAX_DEPOSIT);
        uint256 yld = bound(uint256(yield_), MIN_YIELD, MAX_YIELD);
        address user = makeActor("fee_user", ACTOR_FUNDING);

        useAaveRoute();
        uint256 shares = userDeposits(user, dep);

        fastForward(30 days);
        accrueAaveYield(yld);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        userWithdraws(user, shares);
        uint256 feeCharged = usdc.balanceOf(treasury) - treasuryBefore;

        // Withdraw path has one vault-redemption rounding step; fee is computed
        // on the post-redemption gross. Tolerance of 2 wei covers that.
        assertApproxEqAbs(feeCharged, yld / 10, 2, "fee == 10% of realised yield");
    }

    /// @notice A same-block deposit + withdraw pays no fee, regardless of
    ///         the deposit amount.
    function test_fee_fuzz_zeroOnSameBlockRoundTrip(uint128 deposit_) public {
        uint256 dep = bound(uint256(deposit_), MIN_AMOUNT, MAX_DEPOSIT);
        address user = makeActor("sameblock_user", ACTOR_FUNDING);

        useAaveRoute();
        uint256 shares = userDeposits(user, dep);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        userWithdraws(user, shares);

        assertEq(usdc.balanceOf(treasury), treasuryBefore, "no fee when no yield realised");
    }

    /// @notice Yield accrued then fully erased by loss pays no fee on exit --
    ///         the clamp at `actualGross > principalOut ? ... : 0` holds.
    function test_fee_fuzz_zeroOnYieldThenEqualLoss(uint128 deposit_, uint96 yield_) public {
        uint256 dep = bound(uint256(deposit_), 50_000e6, MAX_DEPOSIT);
        uint256 yld = bound(uint256(yield_), MIN_YIELD, dep / 2);
        address user = makeActor("yieldloss_user", ACTOR_FUNDING);

        useAaveRoute();
        uint256 shares = userDeposits(user, dep);

        fastForward(30 days);
        accrueAaveYield(yld);
        // Equal loss wipes out the yield.
        aToken.setBalance(address(router), dep);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        userWithdraws(user, shares);

        assertEq(usdc.balanceOf(treasury), treasuryBefore, "no fee on yield-then-equal-loss round trip");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cost-basis conservation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After an arbitrary partial withdrawal, costBasis equals the
    ///         untouched remainder: `initialDep - (initialDep * sharesBurnt / totalShares)`.
    function test_costBasis_fuzz_conservedAcrossPartialWithdraw(uint128 d1, uint128 d2, uint256 withdrawBps) public {
        uint256 dep1 = bound(uint256(d1), MIN_AMOUNT, MAX_DEPOSIT / 2);
        uint256 dep2 = bound(uint256(d2), MIN_AMOUNT, MAX_DEPOSIT / 2);
        uint256 bps = bound(withdrawBps, 0, 10_000);
        address user = makeActor("costbasis_user", ACTOR_FUNDING);

        useAaveRoute();
        uint256 s1 = userDeposits(user, dep1);
        uint256 s2 = userDeposits(user, dep2);
        uint256 totalShares = s1 + s2;
        uint256 totalDep = dep1 + dep2;

        (uint256 costBefore,,) = router.getPosition(user);
        assertEq(costBefore, totalDep, "costBasis == total deposited before any withdraw");

        uint256 sharesToBurn = (totalShares * bps) / 10_000;
        uint256 expectedPrincipalOut = (totalDep * sharesToBurn) / totalShares;

        if (sharesToBurn > 0) {
            userWithdraws(user, sharesToBurn);
        }

        (uint256 costAfter,,) = router.getPosition(user);
        assertEq(costAfter, totalDep - expectedPrincipalOut, "costBasis == deposited - principalOut");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mixed-vault proportional split
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice For a mixed position, a partial withdrawal pulls from each
    ///         vault in proportion to that vault's share of total holdings.
    function test_withdraw_fuzz_proportionalSplitFromMixedPosition(
        uint128 aaveDep,
        uint128 morphoDep,
        uint256 withdrawBps
    ) public {
        uint256 aDep = bound(uint256(aaveDep), 10_000e6, MAX_DEPOSIT / 2);
        uint256 mDep = bound(uint256(morphoDep), 10_000e6, MAX_DEPOSIT / 2);
        // 5%-95% so both sides of the split have enough to round cleanly.
        uint256 bps = bound(withdrawBps, 500, 9500);
        address user = makeActor("split_user", ACTOR_FUNDING);

        useAaveRoute();
        userDeposits(user, aDep);
        useMorphoRoute();
        userDeposits(user, mDep);

        (uint256 aaveBefore, uint256 morphoBefore) = router.getCurrentAllocation();
        uint256 totalShares = dvUsdc.balanceOf(user);
        uint256 sharesToBurn = (totalShares * bps) / 10_000;

        userWithdraws(user, sharesToBurn);

        (uint256 aaveAfter, uint256 morphoAfter) = router.getCurrentAllocation();
        uint256 aaveDrop = aaveBefore - aaveAfter;
        uint256 morphoDrop = morphoBefore - morphoAfter;

        // 1% relative tolerance covers rounding in the proportional-split
        // divisions for realistic deposit sizes.
        assertApproxEqRel(aaveDrop, (aaveBefore * bps) / 10_000, 0.01e18, "aave side drop proportional");
        assertApproxEqRel(morphoDrop, (morphoBefore * bps) / 10_000, 0.01e18, "morpho side drop proportional");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Boundary-failure fuzz (Aave V4 pattern: fuzz the revert paths too)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Withdraw with minOut above the realisable gross must always
    ///         revert, whatever the deposit amount.
    function test_withdraw_fuzz_revertsOnMinOutTooHigh(uint128 deposit_) public {
        uint256 dep = bound(uint256(deposit_), MIN_AMOUNT, MAX_DEPOSIT);
        address user = makeActor("slippage_user", ACTOR_FUNDING);

        useAaveRoute();
        uint256 shares = userDeposits(user, dep);

        // minOut one wei above what's withdrawable -> always reverts with
        // SlippageExceeded(received, minExpected). Parametrized error: match
        // on selector only (the received/expected values are fuzz-dependent).
        uint256 minOutTooHigh = dep + 1;

        vm.prank(user);
        vm.expectPartialRevert(IDivigentVaultRouter.SlippageExceeded.selector);
        router.withdraw(shares, user, minOutTooHigh);
    }
}
