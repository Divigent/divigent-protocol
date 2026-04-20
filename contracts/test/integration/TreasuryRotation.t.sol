// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./helpers/Actions.sol";
import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Treasury Rotation Tests
/// @notice Pins the end-to-end behaviour of the emergency treasury-rotation
///         mechanism introduced to recover from USDC blocklist events
///         against the current treasury.
///
///         Four invariants:
///
///           1. ONLY the emergency multisig can propose, execute, or cancel.
///              Non-multisig callers revert on the router-side gate.
///
///           2. TIMELOCK: `executeTreasuryRotation` only succeeds after the
///              full `TREASURY_ROTATION_DELAY` has elapsed. Early execution
///              reverts with a selector that encodes the remaining time.
///
///           3. EVENTS: `TreasuryRotationProposed`, `TreasuryUpdated`, and
///              `TreasuryRotationCancelled` fire on the appropriate lifecycle
///              transitions with the correct payload. Indexers and end-users
///              rely on these to watch for pending rotations.
///
///           4. EFFECT: after a successful rotation, subsequent `collectFee`
///              calls transfer fees to the NEW treasury only; the old
///              treasury receives nothing further.
contract TreasuryRotationTest is Actions {
    // Mirrored from the FeeCollector / router interface for event matching.
    event TreasuryRotationProposed(
        address indexed currentTreasury,
        address indexed pendingTreasury,
        uint256 effectiveAt
    );
    event TreasuryRotationCancelled(address indexed cancelledPendingTreasury);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    address internal newTreasury = makeAddr("newTreasury");

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Access control — multisig only
    // ─────────────────────────────────────────────────────────────────────────

    function test_propose_nonMultisigReverts() public {
        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.proposeTreasuryRotation(newTreasury);
    }

    function test_execute_nonMultisigReverts() public {
        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.executeTreasuryRotation();
    }

    function test_cancel_nonMultisigReverts() public {
        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.cancelTreasuryRotation();
    }

    /// @notice Even if a caller reaches the FeeCollector directly (bypassing
    ///         the router's multisig gate), `onlyVaultRouter` rejects them.
    ///         Proves the two-hop gate is non-bypassable.
    function test_proposeDirect_nonRouterReverts() public {
        vm.prank(emergencyMultisig); // even the multisig fails here
        vm.expectRevert(
            abi.encodeWithSelector(DivigentFeeCollector.OnlyVaultRouter.selector, emergencyMultisig)
        );
        feeCollector.proposeTreasuryRotation(newTreasury);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Propose — happy path + validation
    // ─────────────────────────────────────────────────────────────────────────

    function test_propose_setsPendingAndEmits() public {
        uint256 expectedEffectiveAt = block.timestamp + feeCollector.TREASURY_ROTATION_DELAY();

        vm.expectEmit(true, true, false, true, address(feeCollector));
        emit TreasuryRotationProposed(treasury, newTreasury, expectedEffectiveAt);

        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        assertEq(feeCollector.pendingTreasury(), newTreasury, "pendingTreasury set");
        assertEq(feeCollector.treasuryRotationEffectiveAt(), expectedEffectiveAt, "effectiveAt set");
        assertEq(feeCollector.treasury(), treasury, "current treasury unchanged until execute");
    }

    function test_propose_zeroAddressReverts() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(DivigentFeeCollector.ZeroTreasury.selector);
        router.proposeTreasuryRotation(address(0));
    }

    function test_propose_sameAsCurrentReverts() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(DivigentFeeCollector.InvalidNewTreasury.selector);
        router.proposeTreasuryRotation(treasury);
    }

    function test_propose_whileAnotherPendingReverts() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        address other = makeAddr("otherTreasury");
        vm.prank(emergencyMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(DivigentFeeCollector.RotationAlreadyPending.selector, newTreasury)
        );
        router.proposeTreasuryRotation(other);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Execute — timelock + effect
    // ─────────────────────────────────────────────────────────────────────────

    function test_execute_beforeDelayReverts() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        uint256 effectiveAt = feeCollector.treasuryRotationEffectiveAt();

        // One second before delay elapses — must revert.
        vm.warp(effectiveAt - 1);
        vm.prank(emergencyMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                DivigentFeeCollector.RotationNotReady.selector,
                block.timestamp,
                effectiveAt
            )
        );
        router.executeTreasuryRotation();
    }

    function test_execute_withoutProposeReverts() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(DivigentFeeCollector.RotationNotProposed.selector);
        router.executeTreasuryRotation();
    }

    function test_execute_afterDelaySwapsTreasuryAndEmits() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        vm.warp(block.timestamp + feeCollector.TREASURY_ROTATION_DELAY());

        address oldTreasury = feeCollector.treasury();

        vm.expectEmit(true, true, false, true, address(feeCollector));
        emit TreasuryUpdated(oldTreasury, newTreasury);

        vm.prank(emergencyMultisig);
        router.executeTreasuryRotation();

        assertEq(feeCollector.treasury(), newTreasury, "treasury rotated");
        assertEq(feeCollector.pendingTreasury(), address(0), "pending cleared");
        assertEq(feeCollector.treasuryRotationEffectiveAt(), 0, "effectiveAt cleared");
    }

    /// @notice Execution past `effectiveAt + TREASURY_ROTATION_GRACE_PERIOD`
    ///         reverts `RotationExpired`. The stale proposal must be cancelled
    ///         + re-proposed to execute, preventing a later-compromised
    ///         multisig from resurrecting a forgotten pending rotation.
    function test_execute_pastGracePeriodReverts() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        uint256 effectiveAt = feeCollector.treasuryRotationEffectiveAt();
        uint256 grace = feeCollector.TREASURY_ROTATION_GRACE_PERIOD();
        uint256 expiredAt = effectiveAt + grace;

        // One second past the grace window → expired.
        vm.warp(expiredAt + 1);
        vm.prank(emergencyMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                DivigentFeeCollector.RotationExpired.selector,
                block.timestamp,
                expiredAt
            )
        );
        router.executeTreasuryRotation();

        // Treasury unchanged; pending still sits until cancelled / re-proposed.
        assertEq(feeCollector.treasury(), treasury, "treasury unchanged after expiry");
    }

    /// @notice Execution at the last second of the grace window still succeeds.
    ///         Pins the boundary as inclusive.
    function test_execute_atGracePeriodBoundarySucceeds() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        uint256 effectiveAt = feeCollector.treasuryRotationEffectiveAt();
        uint256 grace = feeCollector.TREASURY_ROTATION_GRACE_PERIOD();

        vm.warp(effectiveAt + grace); // exactly at expiry boundary — still valid
        vm.prank(emergencyMultisig);
        router.executeTreasuryRotation();

        assertEq(feeCollector.treasury(), newTreasury, "boundary execution succeeds");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Cancel — clears pending without touching current
    // ─────────────────────────────────────────────────────────────────────────

    function test_cancel_clearsPendingAndEmits() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        vm.expectEmit(true, false, false, true, address(feeCollector));
        emit TreasuryRotationCancelled(newTreasury);

        vm.prank(emergencyMultisig);
        router.cancelTreasuryRotation();

        assertEq(feeCollector.pendingTreasury(), address(0), "pending cleared");
        assertEq(feeCollector.treasuryRotationEffectiveAt(), 0, "effectiveAt cleared");
        assertEq(feeCollector.treasury(), treasury, "current treasury untouched by cancel");
    }

    function test_cancel_withoutProposeReverts() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(DivigentFeeCollector.RotationNotProposed.selector);
        router.cancelTreasuryRotation();
    }

    /// @notice After cancel, a fresh propose must work (not locked out).
    function test_cancel_thenReproposeWorks() public {
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);

        vm.prank(emergencyMultisig);
        router.cancelTreasuryRotation();

        address secondTarget = makeAddr("secondTarget");
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(secondTarget);

        assertEq(feeCollector.pendingTreasury(), secondTarget, "re-propose works after cancel");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. End-to-end — rotate and fees follow the new treasury
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After a rotation, subsequent withdraw fee transfers land at
    ///         the NEW treasury. The old treasury's balance does not grow.
    ///         This is the load-bearing recovery path for the R8 blocklist
    ///         scenario — flipping the target unblocks yield withdrawals.
    function test_rotate_feesFollowNewTreasuryAfterExecute() public {
        address a = makeActor("rot_alice", 200_000e6);

        // Pre-rotation deposit + yield + withdraw: fee lands at OLD treasury.
        useAaveRoute();
        uint256 sharesPre = userDeposits(a, 50_000e6);
        fastForward(30 days);
        accrueAaveYield(5_000e6);

        uint256 oldTreasuryBalBefore = usdc.balanceOf(treasury);
        uint256 newTreasuryBalBefore = usdc.balanceOf(newTreasury);

        userWithdraws(a, sharesPre);

        uint256 oldTreasuryBalAfterPre = usdc.balanceOf(treasury);
        assertGt(oldTreasuryBalAfterPre, oldTreasuryBalBefore, "pre-rotation fee lands at old treasury");
        assertEq(usdc.balanceOf(newTreasury), newTreasuryBalBefore, "new treasury still empty pre-rotation");

        // Propose + execute rotation.
        vm.prank(emergencyMultisig);
        router.proposeTreasuryRotation(newTreasury);
        vm.warp(block.timestamp + feeCollector.TREASURY_ROTATION_DELAY());
        vm.prank(emergencyMultisig);
        router.executeTreasuryRotation();

        // Post-rotation deposit + yield + withdraw: fee lands at NEW treasury.
        uint256 sharesPost = userDeposits(a, 50_000e6);
        fastForward(30 days);
        accrueAaveYield(5_000e6);

        uint256 oldTreasuryBalBeforePost = usdc.balanceOf(treasury);
        uint256 newTreasuryBalBeforePost = usdc.balanceOf(newTreasury);

        userWithdraws(a, sharesPost);

        assertEq(
            usdc.balanceOf(treasury),
            oldTreasuryBalBeforePost,
            "old treasury balance frozen after rotation"
        );
        assertGt(
            usdc.balanceOf(newTreasury),
            newTreasuryBalBeforePost,
            "new treasury receives fees after rotation"
        );
    }
}
