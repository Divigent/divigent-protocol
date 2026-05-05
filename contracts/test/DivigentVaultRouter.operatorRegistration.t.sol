// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "./TestBase.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Operator registration gate
/// @notice Pins the invariant that operator approvals can only be written by
///         wallets that have already registered with the router.
contract DivigentVaultRouterOperatorRegistrationTest is TestBase {
    function test_setOperator_revertsForUnregisteredCaller() public {
        address unregisteredWallet = makeAddr("unregisteredWallet");
        address operator = makeAddr("unregisteredOperator");

        vm.prank(unregisteredWallet);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.setOperator(operator, true);
    }

    function test_setOperator_succeedsAfterRegistration() public {
        address wallet = makeAddr("registeredWallet");
        address operator = makeAddr("registeredOperator");

        vm.prank(wallet);
        router.initialize();

        vm.expectEmit(true, true, false, true, address(router));
        emit IDivigentVaultRouter.OperatorSet(wallet, operator, true);

        vm.prank(wallet);
        router.setOperator(operator, true);

        assertTrue(router.isOperator(wallet, operator), "operator approval must be stored");
    }

    function test_setOperator_unregisteredCallerLeavesMappingClean() public {
        address unregisteredWallet = makeAddr("unregisteredCleanWallet");
        address operator = makeAddr("unregisteredCleanOperator");

        vm.prank(unregisteredWallet);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.setOperator(operator, true);

        assertFalse(router.isOperator(unregisteredWallet, operator), "revert must not leak operator state");
    }

    function test_setOperator_revertsWithNotAuthorised_notZeroAddress() public {
        address unregisteredWallet = makeAddr("unregisteredZeroOperatorWallet");

        vm.prank(unregisteredWallet);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.setOperator(address(0), true);
    }

    function test_setOperator_revokeByUnregisteredCallerAlsoReverts() public {
        address unregisteredWallet = makeAddr("unregisteredRevokeWallet");
        address operator = makeAddr("unregisteredRevokeOperator");

        vm.prank(unregisteredWallet);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.setOperator(operator, false);

        assertFalse(router.isOperator(unregisteredWallet, operator), "revocation path must also be gated");
    }
}
