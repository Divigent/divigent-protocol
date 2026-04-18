// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Long Horizon End-to-End Flow
/// @notice Simulates a depositor holding for one full year through 12 monthly yield
///         events. Catches any rounding bug or accounting drift that's invisible
///         at low cycle counts.
///
///         What this catches:
///           - Cumulative-rounding drift in pricePerShare (any non-monotonic dip).
///           - View-vs-realised yield divergence (`getPosition.accruedYield` should
///             always match what the user actually realises on withdrawal).
///           - Fee miscalculation that compounds across cycles.
///           - Any per-tick precision loss that snowballs.
///
///         The test holds across 12 monthly cycles, snaps state mid-flight, and
///         verifies the realised-on-withdraw value matches the sum of yield events
///         within rounding bounds proportional to (cycles ^ 1), not (cycles ^ 2).
contract LongHorizonTest is Actions {
    function test_longHorizon_yearOfMonthlyYield_noCumulativeDrift() public {
        address holder = makeActor("long_holder", 1_000_000e6);

        useAaveRoute();
        uint256 deposit_ = 100_000e6;
        uint256 shares = userDeposits(holder, deposit_);

        uint256 monthlyYield = 1_000e6; // $1k/month -> ~12% APR-ish
        uint256 cycles = 12;
        uint256 totalYieldExpected = monthlyYield * cycles;

        // ----- Loop -----------------------------------------------------------

        uint256 lastPPS = router.pricePerShare();

        for (uint256 i = 0; i < cycles; i++) {
            fastForward(30 days);
            accrueAaveYield(monthlyYield);

            uint256 currentPPS = router.pricePerShare();

            // Monotonicity: PPS must never decrease across a yield event.
            // Allow +/-1 wei rounding noise.
            assertGe(currentPPS + 1, lastPPS, "PPS must be non-decreasing across a yield-only cycle");

            // The view-side accruedYield should track the cumulative yield exactly,
            // because Alice is the sole depositor (no distribution math involved).
            WalletSnap memory mid = snap(holder);
            uint256 expectedAccrued = monthlyYield * (i + 1);
            assertApproxEqAbs(
                mid.accruedYield, expectedAccrued, 4, "accruedYield (view) tracks cumulative cycle yield (sole holder)"
            );

            lastPPS = currentPPS;
        }

        // ----- Final exit ----------------------------------------------------

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 returned = userWithdraws(holder, shares);
        uint256 feeCollected = usdc.balanceOf(treasury) - treasuryBefore;

        uint256 grossReceived = returned + feeCollected;
        uint256 realisedYield = grossReceived - deposit_;

        // The realised yield should equal the sum of all cycle yields within
        // rounding. Crucially, the rounding error should be O(1) wei (independent
        // of cycle count), not O(cycles): otherwise drift would snowball.
        assertApproxEqAbs(
            realisedYield,
            totalYieldExpected,
            4,
            "Realised yield over 12 cycles == sum of monthly yields (drift is O(1) not O(cycles))"
        );

        // Fee is exactly 10% of realised yield.
        assertEq(
            feeCollected,
            expectedFee(realisedYield),
            "Fee == 10% of realised yield (computed once at exit on the cumulative)"
        );

        // Net: principal + 90% yield, exactly.
        assertEq(returned, deposit_ + (realisedYield - feeCollected), "Net return == principal + 90% of realised yield");

        // Final cleanup checks.
        assertEq(dvUsdc.totalSupply(), 0, "All shares burned");
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds no USDC");
        assertLe(aToken.balanceOf(address(router)), 4, "aToken dust <= 4 wei after a 12-cycle hold");
    }
}
