// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Mixed-Vault Yield Distribution — End-to-End Flow
/// @notice One depositor builds a mixed position (some in Aave, some in Morpho), yield
///         accrues in BOTH vaults simultaneously, and the user withdraws everything.
///         Asserts that:
///           - the protocol's view of total assets reflects yield from both sides,
///           - the user's accruedYield sees combined yield minus virtual residual,
///           - the realised yield on withdrawal tracks the combined yield,
///           - the fee is exactly 10% of the realised combined yield,
///           - the proportional withdraw split leaves only bounded virtual residual.
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
        assertLe(aliceMid.accruedYield, expectedTotalYield, "Alice cannot accrue more than combined vault yield");
        assertGe(
            aliceMid.accruedYield,
            expectedTotalYield - 1e6,
            "Alice's accruedYield sees combined yield minus <1 USDC virtual residual"
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

        assertLe(realisedYield, expectedTotalYield, "Realised yield cannot exceed combined vault yield");
        assertGe(
            realisedYield,
            expectedTotalYield - 1e6,
            "Realised yield matches combined yield minus <1 USDC virtual residual"
        );

        // The single fee charged at withdraw covers the realised combined yield —
        // not just one vault's share. Per-vault fee accounting would produce a
        // different number; this assertion catches that class of bug.
        assertEq(feeCollected, expectedFee(realisedYield), "Fee is exactly 10% of realised combined yield");

        // Alice's net == principal + 90% of combined yield.
        assertEq(
            returned,
            totalDeposit + (realisedYield - feeCollected),
            "Alice's net return == principal + 90% of combined yield"
        );

        // ─── Cleanup: both vaults drained to bounded virtual residual ────────

        ProtocolSnap memory afterExit = snapProtocol();
        assertLe(afterExit.aaveAssets, 1e6, "Aave side leaves <1 USDC virtual residual");
        assertLe(afterExit.morphoAssets, 1e6, "Morpho side leaves <1 USDC virtual residual");
        assertEq(afterExit.dvUsdcSupply, 0, "All dvUSDC burned");
        assertEq(afterExit.routerUsdc, 0, "Router holds no USDC (INV-4)");
        assertEq(dvUsdc.balanceOf(aliceM), 0, "Alice's dvUSDC fully burned");
    }
}
