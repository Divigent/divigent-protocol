// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Operator Delegation — End-to-End Flow
/// @notice Exercises the full operator surface: appointment, action, isolation between
///         operators, isolation across wallets, revocation, post-revocation lockout,
///         and — most importantly — that the operator's own funds and dvUSDC are
///         **never** touched by acting as someone's operator. The security-critical
///         property is "operator can move the wallet's funds *only* between the wallet
///         and the vaults, never to themselves."
///
///         Two tests:
///           1. End-to-end delegation journey for a single wallet/operator pair.
///           2. Cross-isolation: two operators on one wallet, and one operator on two
///              wallets — revoking one binding never affects the other.
contract OperatorDelegationTest is Actions {
    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 — End-to-end delegation journey
    // ─────────────────────────────────────────────────────────────────────────

    function test_operator_delegationJourney_walletAlwaysReceivesFunds() public {
        address wallet = makeActor("delegator", 100_000e6);
        address aliceOp = makeAddr("alice_operator");
        address bobIntruder = makeAddr("bob_intruder");

        // Operators hold their own USDC; delegation must never touch it.
        usdc.mint(aliceOp, 50_000e6);
        usdc.mint(bobIntruder, 50_000e6);
        uint256 aliceOpUsdcAtStart = usdc.balanceOf(aliceOp);
        uint256 bobIntruderUsdcAtStart = usdc.balanceOf(bobIntruder);

        useAaveRoute();

        // ━━━ Phase 1 — Unauthorised attempts fail before any approval is granted ━

        vm.prank(wallet);
        usdc.approve(address(router), 10_000e6); // wallet pre-approves; intruder still can't act

        vm.prank(bobIntruder);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(10_000e6, wallet, 0);

        // ━━━ Phase 2 — Wallet appoints alice as operator ━━━━━━━━━━━━━━━━━━━━━

        vm.prank(wallet);
        router.setOperator(aliceOp, true);
        assertTrue(router.isOperator(wallet, aliceOp), "Phase2: alice is now operator");

        // Bob (still unapproved) can't act, even after Alice is appointed.
        vm.prank(bobIntruder);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(10_000e6, wallet, 0);

        // ━━━ Phase 3 — Alice deposits on wallet's behalf ━━━━━━━━━━━━━━━━━━━━

        // The helper bakes the security-critical assertions in: shares to wallet
        // (not operator), USDC pulled from wallet (not operator), operator's USDC
        // untouched, INV-4 holds.
        uint256 firstShares = operatorDeposits(aliceOp, wallet, 30_000e6);

        // ━━━ Phase 4 — Yield accrues, alice partially withdraws on wallet's behalf ━

        fastForward(15 days);
        accrueAaveYield(900e6);

        // Withdraw half. Funds return to wallet, fee to treasury, alice receives nothing.
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 walletUsdcBefore = usdc.balanceOf(wallet);
        operatorWithdraws(aliceOp, wallet, firstShares / 2);
        uint256 treasuryAfter = usdc.balanceOf(treasury);

        // Treasury did receive a fee (yield realised on the partial withdraw).
        assertGt(treasuryAfter, treasuryBefore, "Phase4: fee on partial withdraw was collected");
        // Wallet got its proceeds.
        assertGt(usdc.balanceOf(wallet), walletUsdcBefore, "Phase4: wallet received withdraw proceeds");

        // ━━━ Phase 5 — Wallet revokes alice ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        vm.prank(wallet);
        router.setOperator(aliceOp, false);
        assertFalse(router.isOperator(wallet, aliceOp), "Phase5: alice revoked");

        // Alice can no longer deposit or withdraw on wallet's behalf.
        vm.prank(wallet);
        usdc.approve(address(router), 1_000e6);
        vm.prank(aliceOp);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(1_000e6, wallet, 0);

        uint256 sharesLeft = dvUsdc.balanceOf(wallet);
        vm.prank(aliceOp);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.withdraw(sharesLeft, wallet, 0);

        // ━━━ Phase 6 — Wallet still operates fine post-revocation ━━━━━━━━━━━

        // Wallet itself can still deposit and withdraw — it never lost its own access.
        uint256 newShares = userDeposits(wallet, 5_000e6);
        assertGt(newShares, 0, "Phase6: wallet itself can still deposit");

        userWithdraws(wallet, dvUsdc.balanceOf(wallet));

        // ━━━ Final — Operators' own funds were never touched ━━━━━━━━━━━━━━━━

        // Operator USDC unchanged across the entire flow.
        assertEq(
            usdc.balanceOf(aliceOp), aliceOpUsdcAtStart, "Final: alice's USDC untouched throughout her time as operator"
        );
        assertEq(
            usdc.balanceOf(bobIntruder),
            bobIntruderUsdcAtStart,
            "Final: bob's USDC untouched (his unauthorised attempts moved nothing)"
        );
        assertEq(dvUsdc.balanceOf(aliceOp), 0, "Final: alice received no dvUSDC");
        assertEq(dvUsdc.balanceOf(bobIntruder), 0, "Final: bob received no dvUSDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 — Cross-isolation between operator and wallet bindings
    // ─────────────────────────────────────────────────────────────────────────

    function test_operator_isolation_revokingOneBindingPreservesOthers() public {
        // Setup: two wallets, two operators. Various crossing approvals.
        address wallet1 = makeActor("iso_wallet1", 100_000e6);
        address wallet2 = makeActor("iso_wallet2", 100_000e6);
        address opA = makeAddr("opA");
        address opB = makeAddr("opB");

        // wallet1 appoints both opA and opB.
        vm.startPrank(wallet1);
        router.setOperator(opA, true);
        router.setOperator(opB, true);
        vm.stopPrank();

        // wallet2 only appoints opA.
        vm.prank(wallet2);
        router.setOperator(opA, true);

        // Before-state: verify all bindings match configuration.
        assertTrue(router.isOperator(wallet1, opA), "Pre: wallet1->opA");
        assertTrue(router.isOperator(wallet1, opB), "Pre: wallet1->opB");
        assertTrue(router.isOperator(wallet2, opA), "Pre: wallet2->opA");
        assertFalse(router.isOperator(wallet2, opB), "Pre: wallet2->opB never set");

        // ━━━ Action — opA deposits for both wallets, opB deposits for wallet1 ━

        useAaveRoute();
        operatorDeposits(opA, wallet1, 20_000e6);
        operatorDeposits(opA, wallet2, 30_000e6);
        operatorDeposits(opB, wallet1, 10_000e6);

        // ━━━ Revocation 1 — wallet1 revokes opA ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        vm.prank(wallet1);
        router.setOperator(opA, false);

        // opA can no longer act for wallet1.
        vm.prank(wallet1);
        usdc.approve(address(router), 1_000e6);
        vm.prank(opA);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(1_000e6, wallet1, 0);

        // But the OTHER bindings are intact:
        // opA still acts for wallet2.
        operatorDeposits(opA, wallet2, 5_000e6);
        // opB still acts for wallet1.
        operatorDeposits(opB, wallet1, 5_000e6);

        // ━━━ Revocation 2 — wallet2 revokes opA ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        vm.prank(wallet2);
        router.setOperator(opA, false);

        vm.prank(wallet2);
        usdc.approve(address(router), 1_000e6);
        vm.prank(opA);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(1_000e6, wallet2, 0);

        // opB still works for wallet1 — completely independent.
        operatorWithdraws(opB, wallet1, dvUsdc.balanceOf(wallet1) / 4);

        // ━━━ Final — Each binding flipped independently ━━━━━━━━━━━━━━━━━━━━

        assertFalse(router.isOperator(wallet1, opA), "Final: wallet1->opA revoked");
        assertTrue(router.isOperator(wallet1, opB), "Final: wallet1->opB unchanged");
        assertFalse(router.isOperator(wallet2, opA), "Final: wallet2->opA revoked");
        assertFalse(router.isOperator(wallet2, opB), "Final: wallet2->opB still false");
    }
}
