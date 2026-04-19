// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "./TestBase.sol";

/// @title  Constructor Allowance Wiring
/// @notice Pins the router's constructor-time `forceApprove(...)` calls by
///         reading live allowances on a freshly-deployed router.
///
///         The router pre-approves three spenders to `type(uint256).max`:
///           - Aave V3 Pool       (for `supply`)
///           - Morpho Vault       (for `deposit`)
///           - DivigentFeeCollector (for `collectFee`)
///
///         If any of those approvals is missing, the protocol's first
///         deposit or first fee-bearing withdraw reverts, and the failure
///         mode is not obvious from the constructor code. This file makes
///         the wiring a first-class invariant: the moment the router is
///         deployed, these three allowances must exist at max.
contract DivigentVaultRouterAllowanceTest is TestBase {
    function test_constructor_approvesAavePoolToMax() public view {
        assertEq(
            usdc.allowance(address(router), address(aavePool)),
            type(uint256).max,
            "Router must pre-approve Aave to spend USDC at max"
        );
    }

    function test_constructor_approvesMorphoVaultToMax() public view {
        assertEq(
            usdc.allowance(address(router), address(morphoVault)),
            type(uint256).max,
            "Router must pre-approve Morpho to spend USDC at max"
        );
    }

    function test_constructor_approvesFeeCollectorToMax() public view {
        assertEq(
            usdc.allowance(address(router), address(feeCollector)),
            type(uint256).max,
            "Router must pre-approve FeeCollector to pull fee at max"
        );
    }

    /// @notice Proves the three approvals are MUTUALLY EXCLUSIVE (no
    ///         spill-over): only the three intended spenders have max, and
    ///         nothing else does. A regression that accidentally approved a
    ///         stale address would leak capital.
    function test_constructor_noUnintendedApprovals() public view {
        address[6] memory arbitrary = [
            address(this),
            address(0x1),
            address(0xBEEF),
            alice,
            bob,
            emergencyMultisig
        ];

        for (uint256 i = 0; i < arbitrary.length; i++) {
            assertEq(
                usdc.allowance(address(router), arbitrary[i]),
                0,
                "Router must NOT pre-approve arbitrary addresses"
            );
        }
    }
}
