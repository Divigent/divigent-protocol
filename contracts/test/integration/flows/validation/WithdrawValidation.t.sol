// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Withdraw — Validation Suite
/// @notice Systematically enumerates every revert path for `withdraw`.
///         one file per operation, one test per revert reason,
///         named `test_withdraw_revertsWith_<Error>_when_<cause>`.
///
///         Revert map (per `DivigentVaultRouter.withdraw`):
///           • `NotAuthorised`         — wallet not registered.
///           • `NotAuthorised`         — caller neither wallet nor operator.
///           • `ZeroAmount`            — `shares == 0`.
///           • `InsufficientShares`    — `shares > walletShares`.
///           • `ZeroAmount`            — `totalHeld == 0` (vault fully drained).
///           • `SlippageExceeded`      — `usdcReturned < minUsdcOut`.
///
///         `ReentrancyGuardReentrantCall` is exercised in a dedicated file
///         (`ReentrancyFlow.t.sol`) because it requires a custom hostile mock;
///         it's intentionally omitted from this enumeration to avoid duplication.
contract WithdrawValidationTest is Actions {
    // ─────────────────────────────────────────────────────────────────────────
    // Authorization
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdraw_revertsWith_NotAuthorised_whenWalletIsNotRegistered() public {
        address unregistered = makeAddr("unreg_withdraw");

        vm.prank(unregistered);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.withdraw(1, unregistered, 0);
    }

    function test_withdraw_revertsWith_NotAuthorised_whenCallerIsNeitherWalletNorOperator() public {
        address stranger = makeAddr("stranger_withdraw");

        // alice is registered; stranger is not her operator.
        vm.prank(stranger);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.withdraw(1, alice, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Input amounts
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdraw_revertsWith_ZeroAmount_whenSharesIsZero() public {
        useAaveRoute();
        userDeposits(alice, 10_000e6);

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.ZeroAmount.selector);
        router.withdraw(0, alice, 0);
    }

    function test_withdraw_revertsWith_InsufficientShares_whenSharesExceedsBalance() public {
        useAaveRoute();
        uint256 shares = userDeposits(alice, 10_000e6);
        uint256 tooMany = shares + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.InsufficientShares.selector, tooMany, shares));
        router.withdraw(tooMany, alice, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Vault state
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The `totalHeld == 0` branch fires when the router holds zero aTokens
    ///      AND zero Morpho shares while someone still has dvUSDC. This is an
    ///      unreachable-by-happy-path state, exercised here by wiping the
    ///      router's aToken balance to simulate a catastrophic external loss.
    function test_withdraw_revertsWith_ZeroAmount_whenTotalHeldIsZero() public {
        useAaveRoute();
        uint256 shares = userDeposits(alice, 10_000e6);

        // Simulate a full aToken wipe (e.g., Aave insolvency write-down).
        aToken.setBalance(address(router), 0);

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.ZeroAmount.selector);
        router.withdraw(shares, alice, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slippage
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdraw_revertsWith_SlippageExceeded_whenNetBelowMinOut() public {
        useAaveRoute();
        uint256 deposit_ = 10_000e6;
        uint256 shares = userDeposits(alice, deposit_);

        // No yield accrued, so net will equal principal (~deposit_). Request
        // strictly more than that.
        uint256 minOut = deposit_ + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.SlippageExceeded.selector, deposit_, minOut));
        router.withdraw(shares, alice, minOut);
    }
}
