// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Mixed-Vault Yield Distribution — End-to-End Flow
/// @notice One depositor builds a mixed position (some in Aave, some in Morpho), yield
///         accrues in BOTH vaults simultaneously, and the user withdraws everything.
///         Asserts that:
///           - the protocol's view of total assets reflects yield from both sides,
///           - the user's accruedYield (combined view) matches the sum,
///           - the realised yield on withdrawal equals the combined yield within rounding,
///           - the fee is exactly 10% of the *combined* yield (not per-vault),
///           - the proportional withdraw split drains both vaults to dust.
///
///         This is the gap the existing integration tests miss: they only ever exercise
///         yield in ONE vault at a time. A subtle accounting bug that double-counts or
///         omits one side's yield would survive the existing suite but fail this one.
contract MixedVaultYieldTest is Actions {
    function test_mixedVaultYield_chargesFeeOnCombinedYield() public {
        address aliceM = makeActor("alice_mixed", 1_000_000e6);

        // ─── Build a mixed position: 60% Aave / 40% Morpho ───────────────────

        uint256 aaveDeposit = 60_000e6;
        uint256 morphoDeposit = 40_000e6;
        uint256 totalDeposit = aaveDeposit + morphoDeposit;

        useAaveRoute();
        uint256 aaveShares = userDeposits(aliceM, aaveDeposit);

        useMorphoRoute();
        uint256 morphoShares = userDeposits(aliceM, morphoDeposit);

        uint256 aliceTotalShares = aaveShares + morphoShares;
        assertEq(
            dvUsdc.balanceOf(aliceM), aliceTotalShares, "Sanity: total shares == sum of the two deposits' minted shares"
        );

        // ProtocolSnap should show both vault sides reflecting their respective deposits.
        ProtocolSnap memory beforeYield = snapProtocol();
        assertApproxEqAbs(beforeYield.aaveAssets, aaveDeposit, 1, "Aave-side assets reflect Aave deposit");
        assertApproxEqAbs(beforeYield.morphoAssets, morphoDeposit, 1, "Morpho-side assets reflect Morpho deposit");
        assertApproxEqAbs(beforeYield.totalVaultAssets, totalDeposit, 1, "Combined vault assets == total deposited");

        // ─── Yield accrues in BOTH vaults simultaneously ─────────────────────

        fastForward(30 days);
        uint256 aaveYield = 1_200e6;
        uint256 morphoYield = 800e6;
        uint256 expectedTotalYield = aaveYield + morphoYield;

        accrueYieldInBothVaults(aaveYield, morphoYield);

        ProtocolSnap memory afterYield = snapProtocol();
        assertApproxEqAbs(afterYield.aaveAssets, aaveDeposit + aaveYield, 1, "Aave-side reflects Aave-only yield");
        assertApproxEqAbs(
            afterYield.morphoAssets, morphoDeposit + morphoYield, 1, "Morpho-side reflects Morpho-only yield"
        );
        assertApproxEqAbs(
            afterYield.totalVaultAssets,
            totalDeposit + expectedTotalYield,
            1,
            "Combined vault assets reflect yield from both sides"
        );

        // The view-side `getPosition` should already see the combined yield.
        WalletSnap memory aliceMid = snap(aliceM);
        assertApproxEqAbs(
            aliceMid.accruedYield, expectedTotalYield, 2, "Alice's accruedYield (view) == sum of yield from both vaults"
        );

        // ─── Alice withdraws everything ──────────────────────────────────────
        // The router will compute a proportional split:
        //   fromAave   = grossUSDC * aaveAssets / totalAssets   ≈ 60% of grossUSDC
        //   fromMorpho = grossUSDC - fromAave                   ≈ 40% of grossUSDC
        // Both vault.withdraw calls run; combined USDC arrives at the router; fee is
        // computed on the combined gross.

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 returned = userWithdraws(aliceM, aliceTotalShares);

        uint256 feeCollected = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 grossReceived = returned + feeCollected;
        uint256 realisedYield = grossReceived - totalDeposit;

        // The realised yield must equal the combined accrued yield within rounding.
        // 4 wei tolerance covers worst-case compound rounding from Morpho's exact-asset
        // withdraw + the virtual-offset share math.
        assertApproxEqAbs(
            realisedYield, expectedTotalYield, 4, "Realised yield matches combined accrued yield (Aave + Morpho)"
        );

        // The single fee charged at withdraw covers the full combined yield —
        // not just one vault's share. Per-vault fee accounting would produce a
        // different number; this assertion catches that class of bug.
        assertEq(feeCollected, expectedFee(realisedYield), "Fee is exactly 10% of the COMBINED yield, not per-vault");

        // Alice's net == principal + 90% of combined yield.
        assertEq(
            returned,
            totalDeposit + (realisedYield - feeCollected),
            "Alice's net return == principal + 90% of combined yield"
        );

        // ─── Cleanup: both vaults drained, dvUSDC fully burned ───────────────

        ProtocolSnap memory afterExit = snapProtocol();
        assertLe(afterExit.aaveAssets, 4, "Aave side drained to at most a few wei of dust");
        assertLe(afterExit.morphoAssets, 4, "Morpho side drained to at most a few wei of dust");
        assertEq(afterExit.dvUsdcSupply, 0, "All dvUSDC burned");
        assertEq(afterExit.routerUsdc, 0, "Router holds no USDC (INV-4)");
        assertEq(dvUsdc.balanceOf(aliceM), 0, "Alice's dvUSDC fully burned");
    }
}
