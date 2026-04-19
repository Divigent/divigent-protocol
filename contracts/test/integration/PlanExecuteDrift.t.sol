// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./helpers/Actions.sol";

/// @title  Plan / Execute Drift
/// @notice The router's `withdraw` path reads vault capacity in a planning
///         block (`aaveCap + morphoCap` vs `grossUSDC`) and then issues
///         mutating calls to each vault. In a real deployment, anything
///         can happen between those two events — other withdrawers, the
///         vault's own internal accounting, admin rebalancing — and the
///         effective cap at execution time can be below what planning saw.
///
///         The router does NOT try/catch the mutating Morpho call: if the
///         vault rejects the planned draw, the revert propagates and the
///         transaction is atomically rolled back (CEI + ReentrancyGuard
///         ensures no partial state). This pins that guarantee end-to-end
///         using MockMorphoVault's `setDriftOnNextWithdraw` hook, which
///         rewrites the effective cap right before the require check.
contract PlanExecuteDriftTest is Actions {
    uint256 internal constant AAVE_DEP = 50_000e6;
    uint256 internal constant MORPHO_DEP = 50_000e6;

    /// @notice Planning-time Morpho cap of 50k means the router's planned
    ///         Morpho draw is fine. The drift hook rewrites the cap to 0
    ///         right before the mutating withdraw's require check, so the
    ///         actual call reverts. The router does NOT silently under-pay;
    ///         the entire tx reverts and state is unchanged.
    function test_drift_morphoCapDropsBetweenPlanAndExecute_reverts() public {
        address user = makeActor("drift_user", 200_000e6);

        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        // Arm the hook: next withdraw rewrites cap to 0.
        morphoVault.setDriftOnNextWithdraw(0);

        uint256 aaveBefore = aToken.balanceOf(address(router));
        uint256 morphoBefore = morphoVault.balanceOf(address(router));
        uint256 sharesBefore = dvUsdc.balanceOf(user);
        uint256 costBefore = router.costBasisUSDC(user);

        // Full exit — requires draws from BOTH legs at proportional split.
        // Planning passes (maxWithdraw returns 50k, morphoCap = 50k).
        // Execution fails (Morpho withdraw rewrites cap to 0 and reverts).
        uint256 allShares = dvUsdc.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(bytes("MockMorphoVault: exceeds maxWithdraw"));
        router.withdraw(allShares, user, 0);

        // Atomicity: nothing moved. Shares, cost basis, vault balances all
        // unchanged. Router holds no USDC.
        assertEq(aToken.balanceOf(address(router)), aaveBefore, "aToken unchanged");
        assertEq(morphoVault.balanceOf(address(router)), morphoBefore, "Morpho shares unchanged");
        assertEq(dvUsdc.balanceOf(user), sharesBefore, "dvUSDC balance unchanged");
        assertEq(router.costBasisUSDC(user), costBefore, "cost basis unchanged");
        assertEq(usdc.balanceOf(address(router)), 0, "no USDC stuck in router");
    }

    /// @notice If drift lowers the cap but the new cap is STILL enough to
    ///         serve the planned draw, the withdraw succeeds — only the
    ///         strictly-short case reverts. This distinguishes "drift with
    ///         slack" (harmless) from "drift below target" (reverts).
    function test_drift_morphoCapDropsButStillSufficient_succeeds() public {
        address user = makeActor("drift_slack", 200_000e6);

        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        // 30% withdraw → proportional Morpho target is ~15k.
        // Set post-drift cap to 30k: still above the planned draw.
        morphoVault.setDriftOnNextWithdraw(30_000e6);

        uint256 shares = (dvUsdc.balanceOf(user) * 30) / 100;

        // Should succeed — drift doesn't cross into the insufficiency zone.
        userWithdraws(user, shares);
    }
}
