// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Mixed-Vault Edge Cases End-to-End Flows
/// @notice Stresses the proportional redemption logic under extreme asymmetry.
///         Existing flow tests cover balanced mixed positions (60/40, 50/50).
///         This file covers the lopsided and low-amount cases where rounding
///         and proportional math most likely misbehave:
///
///           1. 99% Aave / 1% Morpho: most of the redemption from Aave, small
///              slice from Morpho.
///           2. 1% Aave / 99% Morpho: symmetric.
///           3. Very small withdrawal from a mixed position: does the
///              proportional split round either side to 0 cleanly?
///           4. Sequential partial withdrawals from a mixed yielding position --
///              cumulative accuracy over many calls.
contract MixedVaultEdgeCasesTest is Actions {
    // ─────────────────────────────────────────────────────────────────────────
    // 1. 99/1 Aave-dominant mixed position
    // ─────────────────────────────────────────────────────────────────────────

    function test_mixedVault_aaveDominant_99_1_splitIsProportional_bothVaultsHit() public {
        address aliceA = makeActor("alice_99_1", 500_000e6);

        // 99k in Aave, 1k in Morpho
        useAaveRoute();
        uint256 aaveShares = userDeposits(aliceA, 99_000e6);
        useMorphoRoute();
        uint256 morphoShares = userDeposits(aliceA, 1_000e6);

        // Snapshot pool composition.
        ProtocolSnap memory beforeWithdraw = snapProtocol();
        assertApproxEqAbs(beforeWithdraw.aaveAssets, 99_000e6, 1, "99% in Aave");
        assertApproxEqAbs(beforeWithdraw.morphoAssets, 1_000e6, 1, "1% in Morpho");

        // Withdraw half of total shares.
        uint256 totalShares = aaveShares + morphoShares;
        uint256 half = totalShares / 2;

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 returned = userWithdraws(aliceA, half);

        // No yield accrued, so returned ~= principalOut. Fee ~= 0.
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "No yield -> no fee");

        // Pool after withdraw. Aave side should have dropped by ~49,500 (99% of 50k),
        // Morpho side by ~500 (1% of 50k).
        ProtocolSnap memory afterWithdraw = snapProtocol();
        assertApproxEqAbs(
            beforeWithdraw.aaveAssets - afterWithdraw.aaveAssets,
            49_500e6,
            10,
            "Aave side drop ~ 49.5k (proportional 99%)"
        );
        assertApproxEqAbs(
            beforeWithdraw.morphoAssets - afterWithdraw.morphoAssets,
            500e6,
            10,
            "Morpho side drop ~ 500 (proportional 1%)"
        );

        // Returned ~= 50k (principal) since no yield.
        assertApproxEqAbs(returned, 50_000e6, 10, "Returned ~ 50k");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. 1/99 Morpho-dominant mixed position (symmetric)
    // ─────────────────────────────────────────────────────────────────────────

    function test_mixedVault_morphoDominant_1_99_splitIsProportional_bothVaultsHit() public {
        address aliceM = makeActor("alice_1_99", 500_000e6);

        useAaveRoute();
        uint256 aaveShares = userDeposits(aliceM, 1_000e6);
        useMorphoRoute();
        uint256 morphoShares = userDeposits(aliceM, 99_000e6);

        ProtocolSnap memory beforeWithdraw = snapProtocol();
        assertApproxEqAbs(beforeWithdraw.aaveAssets, 1_000e6, 1, "1% in Aave");
        assertApproxEqAbs(beforeWithdraw.morphoAssets, 99_000e6, 1, "99% in Morpho");

        uint256 totalShares = aaveShares + morphoShares;
        uint256 half = totalShares / 2;

        uint256 returned = userWithdraws(aliceM, half);

        ProtocolSnap memory afterWithdraw = snapProtocol();

        // Aave side drop ~ 500 (1% of 50k), Morpho side drop ~ 49.5k (99% of 50k).
        assertApproxEqAbs(beforeWithdraw.aaveAssets - afterWithdraw.aaveAssets, 500e6, 10, "Aave drop ~ 500");
        assertApproxEqAbs(
            beforeWithdraw.morphoAssets - afterWithdraw.morphoAssets, 49_500e6, 10, "Morpho drop ~ 49.5k"
        );

        assertApproxEqAbs(returned, 50_000e6, 10, "Returned ~ 50k");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Very small withdrawal from mixed position: rounding handled
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev When the withdraw amount is tiny relative to the pool, the
    ///      proportional split `fromAave = grossUSDC * aaveBalance / totalHeld`
    ///      can round `fromAave` to 0 while `fromMorpho` absorbs the whole tiny
    ///      gross. The router must handle that cleanly (skip the zero-side vault
    ///      call via the `if (fromX > 0)` guards).
    function test_mixedVault_verySmallWithdraw_roundingToZeroOnOneSide_isSafe() public {
        address aliceS = makeActor("alice_smallw", 1_000_000e6);

        useAaveRoute();
        userDeposits(aliceS, 100_000e6);
        useMorphoRoute();
        userDeposits(aliceS, 100_000e6);

        // Attempt to withdraw just 1 share.
        // With a pool of 200k assets and ~200k supply, grossUSDC ≈ 1 wei.
        // Proportional split: fromAave = 1 * 100k/200k = 0 (floor), fromMorpho = 1.
        uint256 returned = userWithdraws(aliceS, 1);

        // Either returned is 0 (both sides rounded) or returned is a tiny positive.
        // Verifies the call does not revert under extreme
        // rounding on one side of the split.
        assertLe(returned, 2, "tiny withdraw returns at most a few wei");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Sequential partial withdrawals from a mixed yielding position
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Stress: 10 partial withdraws of 10% each on a 60/40 mixed position
    ///      with yield. Cumulative return + fees must match what a single full
    ///      exit would have produced, within O(1) wei per step of rounding.
    function test_mixedVault_tenPartialWithdraws_cumulativeAccuracyWithinRounding() public {
        address aliceP = makeActor("alice_partials", 1_000_000e6);

        useAaveRoute();
        uint256 aaveShares = userDeposits(aliceP, 60_000e6);
        useMorphoRoute();
        uint256 morphoShares = userDeposits(aliceP, 40_000e6);

        uint256 totalShares = aaveShares + morphoShares;

        // Yield accrues in both vaults.
        fastForward(30 days);
        accrueAaveYield(600e6);
        accrueMorphoYield(400e6);
        uint256 totalYield = 1_000e6;

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceUsdcBefore = usdc.balanceOf(aliceP);

        // 10 partial withdraws, last one cleans up remainder.
        uint256 chunkShares = totalShares / 10;
        for (uint256 i = 0; i < 10; i++) {
            uint256 sharesThisRound = (i == 9) ? dvUsdc.balanceOf(aliceP) : chunkShares;
            userWithdraws(aliceP, sharesThisRound);
        }

        // All shares burnt by the 10th partial.
        assertEq(dvUsdc.balanceOf(aliceP), 0, "All shares burned after 10 partials");

        uint256 totalReturned = usdc.balanceOf(aliceP) - aliceUsdcBefore;
        uint256 totalFee = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 totalGross = totalReturned + totalFee;

        // Gross should equal 100k principal + 1k yield, within accumulated
        // O(n) rounding where n = 10 partial withdraws.
        assertApproxEqAbs(
            totalGross,
            100_000e6 + totalYield,
            20,
            "Sum of 10 partial withdraws == single full exit, within O(n) rounding"
        );

        // Total fee should equal 10% of total yield (computed over all 10
        // withdraws, each of which charges 10% of its realised yield slice).
        assertApproxEqAbs(totalFee, totalYield / 10, 20, "Sum of per-withdraw fees == 10% of total yield");
    }
}
