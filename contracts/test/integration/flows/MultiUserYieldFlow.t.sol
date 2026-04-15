// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Multi-User Yield Distribution — End-to-End Flow
/// @notice Two depositors enter the pool at different prices, yield accrues across
///         multiple periods, and they exit at different times. Asserts the protocol
///         distributes yield proportionally to share-weighted time-in-pool, charges
///         exactly 10% on each user's *realised* yield (not pool-wide yield), keeps
///         users isolated from each other's actions, never decreases pricePerShare,
///         and reconciles all USDC flows so nothing leaks.
///
///         This is the "if any subtle accounting bug exists, this test catches it"
///         scenario — multi-actor + time + yield + fees in one continuous journey.
contract MultiUserYieldFlowTest is Actions {
    function test_multiUserYield_distributesProportionallyAcrossTime() public {
        // ─── Actors with realistic stakes ────────────────────────────────────
        address aliceJ = makeActor("alice_journey", 1_000_000e6);
        address bobJ = makeActor("bob_journey", 1_000_000e6);

        // Both deposits route to Aave so we can simulate yield deterministically
        // by minting aTokens to the router (mirrors Aave's rebasing aToken).
        useAaveRoute();

        // ━━━ PHASE 1 — Alice deposits as the pool's first depositor ━━━━━━━━━━

        uint256 aliceDeposit = 50_000e6;
        uint256 aliceShares = userDeposits(aliceJ, aliceDeposit);

        // Sole depositor at zero pool state: 1 USDC → 1 dvUSDC, modulo virtual offset.
        // With virtual offset and an empty pool, shares = amount * 1 / 1 = amount.
        assertEq(aliceShares, aliceDeposit, "Phase1: first deposit should mint 1:1 shares");
        assertEq(router.pricePerShare(), 1e18, "Phase1: pricePerShare = 1.0 with sole depositor");

        // ━━━ PHASE 2 — Yield accrues over a week. Alice owns 100% of pool. ━━━

        fastForward(7 days);
        uint256 phase2Yield = 1_000e6; // $1,000 of yield
        accrueAaveYield(phase2Yield);

        // Alice is sole holder, so the entire yield boosts pricePerShare.
        uint256 ppsAfterPhase2 = router.pricePerShare();
        assertGt(ppsAfterPhase2, 1e18, "Phase2: pricePerShare must rise with yield");

        // Alice's accrued yield (unrealised) should equal phase2Yield within rounding.
        WalletSnap memory aliceMid = snap(aliceJ);
        assertApproxEqAbs(
            aliceMid.accruedYield, phase2Yield, 1, "Phase2: Alice's accruedYield equals all yield (sole holder)"
        );

        // ━━━ PHASE 3 — Bob deposits at the post-yield price ━━━━━━━━━━━━━━━━━━

        uint256 bobDeposit = 30_000e6;
        uint256 bobShares = userDeposits(bobJ, bobDeposit);

        // Bob enters at higher pricePerShare, so should receive fewer shares per USDC.
        assertLt(bobShares, bobDeposit, "Phase3: Bob enters at PPS > 1, must receive fewer shares than dollars");

        // Critical: Bob's deposit must NOT affect Alice's position.
        WalletSnap memory aliceAfterBob = snap(aliceJ);
        assertEq(aliceAfterBob.dvUsdcBalance, aliceShares, "Phase3: Alice's dvUSDC unchanged by Bob's deposit");
        assertEq(aliceAfterBob.costBasis, aliceDeposit, "Phase3: Alice's costBasis unchanged by Bob's deposit");

        // pricePerShare should not move materially across a deposit (virtual-offset rounding only).
        // 0.01% relative tolerance generously absorbs sub-wei rounding.
        assertApproxEqRel(
            router.pricePerShare(), ppsAfterPhase2, 0.0001e18, "Phase3: deposit must not shift pricePerShare materially"
        );

        // ━━━ PHASE 4 — Another week passes, more yield accrues ━━━━━━━━━━━━━━

        fastForward(7 days);
        uint256 phase4Yield = 1_600e6; // $1,600 of yield, distributed proportionally
        accrueAaveYield(phase4Yield);

        // Save state for later cross-checks.
        uint256 ppsBeforeAliceExit = router.pricePerShare();
        WalletSnap memory bobBeforeAliceExit = snap(bobJ);

        // ━━━ PHASE 5 — Alice exits everything ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        uint256 treasuryBeforeAlice = usdc.balanceOf(treasury);
        uint256 aliceReturned = userWithdraws(aliceJ, aliceShares);

        // Reconstruct Alice's gross / yield / fee from observed transfers.
        uint256 aliceFeeCollected = usdc.balanceOf(treasury) - treasuryBeforeAlice;
        uint256 aliceGross = aliceReturned + aliceFeeCollected;
        uint256 aliceYield = aliceGross - aliceDeposit;

        // Principal is fully recovered.
        assertGe(aliceReturned, aliceDeposit, "Phase5: Alice must recover at least her principal");

        // Fee is exactly 10% of Alice's *realised* yield — not pool-wide yield.
        assertEq(aliceFeeCollected, expectedFee(aliceYield), "Phase5: Alice's fee == 10% of her realised yield");

        // Net = principal + 90% of yield.
        assertEq(
            aliceReturned,
            aliceDeposit + (aliceYield - aliceFeeCollected),
            "Phase5: Alice's net = principal + 90% of yield"
        );

        // Alice's realised yield should be approximately her share of the pool times
        // total accrued yield since she joined.
        // Pool yield since Alice joined: phase2Yield + phase4Yield = 2_600e6.
        // Phase 2 yield is 100% Alice's (sole holder).
        // Phase 4 yield split: aliceShares / (aliceShares + bobShares) of 1_600e6.
        uint256 expectedAliceYield_lower = phase2Yield + (phase4Yield * aliceShares) / (aliceShares + bobShares) - 2;
        uint256 expectedAliceYield_upper = expectedAliceYield_lower + 4;
        assertGe(aliceYield, expectedAliceYield_lower, "Phase5: Alice's yield >= proportional expectation");
        assertLe(aliceYield, expectedAliceYield_upper, "Phase5: Alice's yield <= proportional expectation + dust");

        // Bob's position must be untouched by Alice's exit.
        WalletSnap memory bobAfterAliceExit = snap(bobJ);
        assertEq(bobAfterAliceExit.dvUsdcBalance, bobBeforeAliceExit.dvUsdcBalance, "Phase5: Bob's shares untouched");
        assertEq(bobAfterAliceExit.costBasis, bobBeforeAliceExit.costBasis, "Phase5: Bob's costBasis untouched");
        assertEq(bobAfterAliceExit.usdcBalance, bobBeforeAliceExit.usdcBalance, "Phase5: Bob's USDC untouched");

        // pricePerShare must not decrease across a withdraw (virtual-offset rounding favours the pool).
        assertGe(
            router.pricePerShare() + 1,
            ppsBeforeAliceExit,
            "Phase5: pricePerShare must not decrease across Alice's exit (sub-wei tolerance)"
        );

        // ━━━ PHASE 6 — Bob holds alone for two more weeks ━━━━━━━━━━━━━━━━━━━

        fastForward(16 days);
        uint256 phase6Yield = 500e6;
        accrueAaveYield(phase6Yield);

        // ━━━ PHASE 7 — Bob exits everything ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        uint256 treasuryBeforeBob = usdc.balanceOf(treasury);
        uint256 bobReturned = userWithdraws(bobJ, bobShares);

        uint256 bobFeeCollected = usdc.balanceOf(treasury) - treasuryBeforeBob;
        uint256 bobGross = bobReturned + bobFeeCollected;
        uint256 bobYield = bobGross - bobDeposit;

        assertGe(bobReturned, bobDeposit, "Phase7: Bob must recover at least his principal");
        assertEq(bobFeeCollected, expectedFee(bobYield), "Phase7: Bob's fee == 10% of his realised yield");
        assertEq(bobReturned, bobDeposit + (bobYield - bobFeeCollected), "Phase7: Bob's net = principal + 90% yield");

        // Bob's yield sources:
        //   Phase 4 (1_600e6, shared with Alice — Bob's slice):
        //     bobShares / (aliceShares + bobShares) of 1_600e6
        //   Phase 6 (500e6, Bob is sole holder).
        uint256 expectedBobYield_lower = (phase4Yield * bobShares) / (aliceShares + bobShares) + phase6Yield - 2;
        uint256 expectedBobYield_upper = expectedBobYield_lower + 4;
        assertGe(bobYield, expectedBobYield_lower, "Phase7: Bob's yield >= proportional expectation");
        assertLe(bobYield, expectedBobYield_upper, "Phase7: Bob's yield <= proportional expectation + dust");

        // ━━━ FINAL — Conservation of value across the whole journey ━━━━━━━━━

        // After both exit, all dvUSDC is burned.
        assertEq(dvUsdc.totalSupply(), 0, "Final: all dvUSDC burned");

        // Sum of everything that came IN (deposits + accrued yield) must equal sum of
        // everything that went OUT (to users + to treasury), within accumulated rounding.
        // 4 wei tolerance covers two withdraws each rounding down by up to 2 wei.
        uint256 totalDeposited = aliceDeposit + bobDeposit;
        uint256 totalYield = phase2Yield + phase4Yield + phase6Yield;
        uint256 totalToUsers = aliceReturned + bobReturned;
        uint256 totalToTreas = aliceFeeCollected + bobFeeCollected;

        assertApproxEqAbs(
            totalToUsers + totalToTreas,
            totalDeposited + totalYield,
            4,
            "Final: users + treasury == deposits + yield (within rounding)"
        );

        // Treasury collected ~10% of total yield in aggregate (sum of per-user fees).
        // Per-user fee is exact, so the aggregate is exact too — the only fuzz comes
        // from each user's yield being computed against their realised gross, which
        // can differ by <= 1 wei from the share-weighted ideal.
        assertApproxEqAbs(totalToTreas, totalYield / 10, 4, "Final: treasury accumulated ~10% of total yield");

        // The router should hold zero USDC and approximately zero aTokens.
        // Any residual aToken dust comes from share-math floor rounding favouring the pool.
        assertEq(usdc.balanceOf(address(router)), 0, "Final: router holds no USDC (INV-4)");
        assertLe(
            aToken.balanceOf(address(router)), 4, "Final: router holds at most a few wei of aTokens (rounding dust)"
        );
    }
}
