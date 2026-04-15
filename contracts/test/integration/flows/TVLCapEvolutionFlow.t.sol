// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  TVL Cap Evolution -- End-to-End Flow
/// @notice Verifies the protocol's TVL cap behaves correctly across its three
///         scheduled phases and across the boundary transitions:
///           - Day 0   - Day 30:  cap is 500k USDC.
///           - Day 31  - Day 90:  cap is 2M USDC.
///           - Day 91+:           cap removed (type(uint256).max).
///
///         What this catches:
///           - Off-by-one on the boundary (deposit at exactly cap should succeed).
///           - Wrong threshold timing (cap should expand AT day 31, not after).
///           - Wrong second threshold (cap should fully lift AT day 91).
///           - Any bug that makes the cap permanent (i.e., never expands).
///           - Any bug where a partial withdraw doesn't free up cap headroom.
contract TVLCapEvolutionFlowTest is Actions {
    function test_tvlCap_evolvesAcrossDay31_Day91_correctly() public {
        // Need a wallet with enough USDC to push every cap.
        address whale = makeActor("whale_cap", 5_000_000e6);

        useAaveRoute();

        // ===== Phase 1 ===== Day 0 -- initial cap 500k =======================

        assertEq(router.currentTVLCap(), 500_000e6, "Phase1: initial cap == 500k");

        // Deposits below cap succeed.
        uint256 first = userDeposits(whale, 400_000e6);
        assertGt(first, 0, "Phase1: first deposit succeeds well under cap");

        // Deposit pushing TVL exactly to the cap succeeds.
        userDeposits(whale, 100_000e6);
        assertApproxEqAbs(router.totalVaultAssets(), 500_000e6, 4, "Phase1: TVL exactly at cap (500k)");

        // Any further deposit above MIN_DEPOSIT must revert with the cap-breach
        // amount and current cap. (Below MIN_DEPOSIT, the MIN_DEPOSIT gate
        // fires first and we'd be testing the wrong thing.)
        uint256 minDeposit = router.MIN_DEPOSIT();
        vm.prank(whale);
        usdc.approve(address(router), minDeposit);
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.TVLCapExceeded.selector, minDeposit, 500_000e6));
        router.deposit(minDeposit, whale);

        // ===== Phase 2 ===== Cap not yet expanded at day 30 ==================

        fastForward(30 days);
        assertEq(router.currentTVLCap(), 500_000e6, "Phase2: at day 30, cap still initial (expansion is at day 31)");

        vm.prank(whale);
        usdc.approve(address(router), minDeposit);
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.TVLCapExceeded.selector, minDeposit, 500_000e6));
        router.deposit(minDeposit, whale);

        // ===== Phase 3 ===== Day 31 -- cap expands to 2M =====================

        fastForward(1 days + 1); // tip past day 31
        assertEq(router.currentTVLCap(), 2_000_000e6, "Phase3: cap expanded to 2M at day 31");

        // Existing TVL is 500k. New room: 1.5M.
        uint256 nextRoom = 1_500_000e6;
        userDeposits(whale, nextRoom);
        assertApproxEqAbs(router.totalVaultAssets(), 2_000_000e6, 4, "Phase3: TVL exactly at 2M cap");

        // Further deposit above MIN_DEPOSIT reverts under the 2M cap.
        vm.prank(whale);
        usdc.approve(address(router), minDeposit);
        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.TVLCapExceeded.selector, minDeposit, 2_000_000e6));
        router.deposit(minDeposit, whale);

        // ===== Phase 4 ===== Withdraw frees up cap headroom ==================

        // A partial withdraw should free room under the cap.
        uint256 walletShares = dvUsdc.balanceOf(whale);
        uint256 sharesToWithdraw = walletShares / 4; // free roughly 500k
        userWithdraws(whale, sharesToWithdraw);

        uint256 freedRoom = router.currentTVLCap() - router.totalVaultAssets();
        assertGt(freedRoom, 100_000e6, "Phase4: withdraw freed substantial room (>100k) under cap");

        // We can deposit back into the freed room.
        userDeposits(whale, 100_000e6);

        // ===== Phase 5 ===== Day 91 -- cap removed ===========================

        fastForward(60 days + 1); // tip past day 91 (already at day 31+, plus 60 more)
        assertEq(router.currentTVLCap(), type(uint256).max, "Phase5: cap fully removed at day 91+");

        // Any sized deposit succeeds (within wallet's USDC).
        uint256 walletUsdc = usdc.balanceOf(whale);
        userDeposits(whale, walletUsdc);

        // Sanity: TVL has grown well past the old caps.
        assertGt(router.totalVaultAssets(), 2_000_000e6, "Phase5: TVL exceeded the old 2M cap once the cap was removed");
    }
}
