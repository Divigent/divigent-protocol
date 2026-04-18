// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Precision End-to-End Flows
/// @notice Stresses arithmetic precision and ordering guarantees: the kinds
///         of bugs that hide under small amounts, long sequences, or round-trip
///         scenarios where a correct protocol should net to zero.
///
///           1. Deposit and withdraw in the same block with no yield: user
///              must get the principal back. Any bug that leaks wei on the
///              deposit-withdraw round trip surfaces here.
///
///           2. Twenty partial withdrawals on a yielding position: cumulative
///              returns must match what a single full exit would have produced,
///              within O(n) rounding, not O(n^2).
///
///           3. Yield up, then equal loss (round trip): a sole depositor who
///              holds through both events breaks even. Any bug that charges
///              fee on the round trip, or that distorts principal accounting
///              across the cycle, shows up as a mismatched return.
///
///           4. Multiple depositors over yield-then-loss: who pays the fee
///              on the phantom yield that later disappears? Answer: nobody.
///              Fees are only charged at withdraw time on realised yield.
contract PrecisionTest is Actions {
    // ─────────────────────────────────────────────────────────────────────────
    // 1. Same-block deposit + withdraw: user gets principal back
    // ─────────────────────────────────────────────────────────────────────────

    function test_precision_depositAndWithdrawSameBlock_returnsPrincipalExactly() public {
        address alice1 = makeActor("alice_roundtrip", 500_000e6);

        useAaveRoute();
        uint256 deposit_ = 100_000e6;
        uint256 shares = userDeposits(alice1, deposit_);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // No time passage, no yield accrual.
        uint256 returned = userWithdraws(alice1, shares);

        // Fee must be exactly zero: no yield was realised.
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "Same-block round trip: fee must be zero");

        // User must recover exactly the principal, modulo 1 wei of
        // virtual-offset rounding. Any larger drift signals an accounting leak.
        assertApproxEqAbs(
            returned, deposit_, 1, "Same-block round trip: user receives principal exactly (within 1 wei)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Twenty partial withdrawals: cumulative accuracy is O(n), not O(n^2)
    // ─────────────────────────────────────────────────────────────────────────

    function test_precision_twentyPartialWithdraws_cumulativeDriftIsBoundedLinearly() public {
        address aliceP = makeActor("alice_20partials", 1_000_000e6);

        useAaveRoute();
        uint256 deposit_ = 100_000e6;
        uint256 shares = userDeposits(aliceP, deposit_);

        fastForward(30 days);
        uint256 yieldAmount = 5_000e6;
        accrueAaveYield(yieldAmount);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(aliceP);

        // 20 partial withdraws of 5% each.
        uint256 chunk = shares / 20;
        for (uint256 i = 0; i < 20; i++) {
            uint256 thisRound = (i == 19) ? dvUsdc.balanceOf(aliceP) : chunk;
            userWithdraws(aliceP, thisRound);
        }
        assertEq(dvUsdc.balanceOf(aliceP), 0, "All shares burned after 20 partials");

        uint256 totalReturned = usdc.balanceOf(aliceP) - aliceBefore;
        uint256 totalFee = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 totalGross = totalReturned + totalFee;

        // Gross should equal deposit + yield within 40 wei (2 wei per partial * 20).
        assertApproxEqAbs(
            totalGross,
            deposit_ + yieldAmount,
            40,
            "20-partial cumulative gross == deposit + yield (drift bounded linearly in n)"
        );

        // Total fee should equal 10% of yield, within the same linear bound.
        assertApproxEqAbs(totalFee, yieldAmount / 10, 40, "20-partial cumulative fee == 10% of yield");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Yield then equal loss round trip: sole holder breaks even
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The sole depositor scenario has the cleanest accounting: yield
    ///      accrues, then equal loss happens, then user exits. They should
    ///      receive the principal back. This catches any bug that charges fee
    ///      on "peak" yield before loss wipes it out.
    function test_precision_yieldThenEqualLoss_soleHolderBreaksEven() public {
        address aliceY = makeActor("alice_roundtrip_y", 500_000e6);

        useAaveRoute();
        uint256 deposit_ = 100_000e6;
        uint256 shares = userDeposits(aliceY, deposit_);

        // Peak yield accrues.
        fastForward(30 days);
        uint256 peakYield = 10_000e6;
        accrueAaveYield(peakYield);

        // Alice DOES NOT withdraw during the peak: she holds.
        // Now equal loss wipes out all the yield.
        aToken.setBalance(address(router), deposit_);

        // Pool is back to the principal baseline.
        assertEq(aToken.balanceOf(address(router)), deposit_, "Pool restored to baseline (yield then loss)");

        // Alice exits now.
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 returned = userWithdraws(aliceY, shares);

        // Fee must be zero: she did not realise yield, even though yield
        // briefly existed on paper. The realised gross == principal; actualYield
        // clamps to zero at the `actualGross > principalOut ? ... : 0` guard.
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "No fee charged on yield-then-loss round trip");

        // Alice recovers her principal within rounding.
        assertApproxEqAbs(returned, deposit_, 2, "Sole holder through yield-then-loss breaks even (within 2 wei)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Mid-journey exit during peak: that user pays fee, later holders lose
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The adversarial variant of test #3: a mid-journey exit during the
    ///      peak DOES realise yield, so that user pays a fee. The remaining
    ///      holders then take the loss. This is the correct, fair behaviour --
    ///      the system doesn't "rebate" fee after the fact.
    function test_precision_midJourneyExitDuringPeak_thenLoss_feeNotRefunded() public {
        address aliceEarly = makeActor("alice_early", 500_000e6);
        address bobLate = makeActor("bob_late", 500_000e6);

        useAaveRoute();

        // Alice deposits first.
        userDeposits(aliceEarly, 50_000e6);
        // Bob deposits too.
        userDeposits(bobLate, 50_000e6);

        // Yield accrues.
        fastForward(30 days);
        uint256 peakYield = 10_000e6;
        accrueAaveYield(peakYield);

        // Alice realises her slice of the yield at peak and exits.
        uint256 treasuryBeforeAlice = usdc.balanceOf(treasury);
        uint256 aliceShares = dvUsdc.balanceOf(aliceEarly);
        userWithdraws(aliceEarly, aliceShares);
        uint256 aliceFee = usdc.balanceOf(treasury) - treasuryBeforeAlice;

        // Alice paid a fee: she realised yield.
        assertGt(aliceFee, 0, "Alice paid fee on realised peak yield");

        // Now the pool takes a loss equal to what yield remained.
        // After Alice exited, pool assets = (original_total + yield) - aliceGross.
        // Loss drops pool to Bob's deposit roughly.
        uint256 currentAave = aToken.balanceOf(address(router));
        uint256 bobDeposit = 50_000e6;
        if (currentAave > bobDeposit) {
            aToken.setBalance(address(router), bobDeposit);
        }

        // Bob exits: takes the loss.
        uint256 treasuryBeforeBob = usdc.balanceOf(treasury);
        uint256 bobShares = dvUsdc.balanceOf(bobLate);
        uint256 bobReturned = userWithdraws(bobLate, bobShares);

        // Bob paid no fee (his realised gross <= his principal).
        assertEq(usdc.balanceOf(treasury), treasuryBeforeBob, "Bob paid no fee when exiting into loss");

        // Bob's returned amount is capped at what remained after loss.
        // He put in 50k, but got back only ~50k (the loss wiped the 5k of yield
        // that would have been his share).
        assertLe(bobReturned, bobDeposit + 1, "Bob's return <= principal (loss absorbed)");

        // Alice's earlier fee is NOT refunded: the protocol does not rebate.
        // Treasury retains Alice's fee.
        assertEq(usdc.balanceOf(treasury) - treasuryBeforeAlice, aliceFee, "Alice's fee not refunded");
    }
}
