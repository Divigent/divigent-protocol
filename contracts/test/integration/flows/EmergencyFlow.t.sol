// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Emergency Pause — End-to-End Flow
/// @notice Asserts the asymmetric pause invariant: the multisig can halt new
///         deposits, but existing depositors must always be able to exit (INV-5
///         in spirit). Realistic state: wallets enter, yield accrues, the multisig
///         pauses, a new depositor is rejected, an existing depositor exits with
///         their realised yield + fee correctly accounted, the multisig unpauses,
///         deposits resume.
///
///         Plus: only the multisig can flip the pause bit; random EOAs are rejected.
contract EmergencyFlowTest is Actions {
    function test_emergencyPause_blocksDepositsButPreservesExits() public {
        // ─── Setup: an existing depositor with accrued yield ────────────────

        address existingUser = makeActor("existing_user", 100_000e6);
        address newUser = makeActor("new_user", 100_000e6);

        useAaveRoute();
        uint256 existingDeposit = 50_000e6;
        uint256 existingShares = userDeposits(existingUser, existingDeposit);

        fastForward(30 days);
        uint256 yieldAccrued = 2_000e6;
        accrueAaveYield(yieldAccrued);

        assertFalse(router.depositsPaused(), "Pre: deposits not paused at start");

        // ─── Phase 1 — Multisig pauses ──────────────────────────────────────

        vm.prank(emergencyMultisig);
        router.pauseDeposits();
        assertTrue(router.depositsPaused(), "Phase1: pause flipped on");

        // ─── Phase 2 — A new depositor's tx must revert ─────────────────────

        vm.prank(newUser);
        usdc.approve(address(router), 10_000e6);

        vm.prank(newUser);
        vm.expectRevert(IDivigentVaultRouter.DepositsPausedError.selector);
        router.deposit(10_000e6, newUser);

        // The existing user's USDC and dvUSDC must not have changed.
        WalletSnap memory existingDuringPause = snap(existingUser);
        assertEq(existingDuringPause.dvUsdcBalance, existingShares, "Phase2: existing user untouched");
        assertEq(existingDuringPause.costBasis, existingDeposit, "Phase2: existing costBasis untouched");

        // ─── Phase 3 — Existing user can still partially exit during pause ──

        uint256 treasuryBeforePartial = usdc.balanceOf(treasury);
        uint256 partialShares = existingShares / 2;
        uint256 partialReturn = userWithdraws(existingUser, partialShares);

        // Partial withdraw realised some yield (and therefore some fee).
        uint256 partialFee = usdc.balanceOf(treasury) - treasuryBeforePartial;
        assertGt(partialFee, 0, "Phase3: partial withdraw realised yield => fee collected even during pause");
        assertGt(partialReturn, existingDeposit / 2, "Phase3: partial return > half-principal (yield included)");

        // ─── Phase 4 — Existing user fully exits during pause ───────────────

        uint256 remainingShares = dvUsdc.balanceOf(existingUser);
        uint256 finalReturn = userWithdraws(existingUser, remainingShares);
        assertGt(finalReturn, 0, "Phase4: full exit succeeds during pause");
        assertEq(dvUsdc.balanceOf(existingUser), 0, "Phase4: all shares burned");

        // ─── Phase 5 — Multisig unpauses ────────────────────────────────────

        vm.prank(emergencyMultisig);
        router.unpauseDeposits();
        assertFalse(router.depositsPaused(), "Phase5: pause flipped off");

        // ─── Phase 6 — Deposits resume normally ─────────────────────────────

        uint256 newShares = userDeposits(newUser, 10_000e6);
        assertGt(newShares, 0, "Phase6: post-unpause deposit succeeds and mints shares");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pause access control — only the immutable multisig
    // ─────────────────────────────────────────────────────────────────────────

    function test_emergencyPause_onlyMultisigCanFlipBits() public {
        address bystander = makeAddr("bystander");

        // Random EOA cannot pause.
        vm.prank(bystander);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.pauseDeposits();

        // Even after multisig pauses, bystander cannot unpause.
        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        vm.prank(bystander);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.unpauseDeposits();

        // The multisig itself can.
        vm.prank(emergencyMultisig);
        router.unpauseDeposits();
        assertFalse(router.depositsPaused(), "Multisig can unpause");
    }
}
