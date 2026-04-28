// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "./TestBase.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Bounded Morpho-view-gas setter
/// @notice The Morpho `convertToAssets` view call inside `_planWithdrawCapacity`
///         is forwarded a bounded gas stipend.
///
///         Fix: replace the constant with a state variable `morphoViewGas`
///         initialised to the floor `MIN_MORPHO_VIEW_GAS = 350_000`, gated by
///         a `setMorphoViewGas` setter (only `EMERGENCY_MULTISIG`) and
///         bounded by `[MIN_MORPHO_VIEW_GAS, MAX_MORPHO_VIEW_GAS]`.
contract DivigentVaultRouterMorphoViewGasTest is TestBase {
    // The values pinned in the contract — duplicated here so a regression
    // that lowers the floor surfaces in this test file rather than silently
    // weakening the security property.
    uint256 internal constant EXPECTED_MIN = 350_000;
    uint256 internal constant EXPECTED_MAX = 1_000_000;

    // ── Default state ────────────────────────────────────────────────────────

    function test_default_morphoViewGas_isFloor() public view {
        assertEq(
            router.morphoViewGas(),
            EXPECTED_MIN,
            "fresh router must start with morphoViewGas == MIN_MORPHO_VIEW_GAS"
        );
    }

    function test_minMorphoViewGas_pinned() public view {
        assertEq(
            router.MIN_MORPHO_VIEW_GAS(),
            EXPECTED_MIN,
            "MIN_MORPHO_VIEW_GAS must remain >= cold-path measured cost"
        );
    }

    function test_maxMorphoViewGas_pinned() public view {
        assertEq(
            router.MAX_MORPHO_VIEW_GAS(),
            EXPECTED_MAX,
            "MAX_MORPHO_VIEW_GAS must remain a finite gas-bomb cap"
        );
    }

    // ── Authorisation ────────────────────────────────────────────────────────

    function test_setMorphoViewGas_revertsWhenNotMultisig() public {
        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.setMorphoViewGas(500_000);
    }

    function test_setMorphoViewGas_revertsForArbitraryNonMultisig() public {
        vm.prank(bob);
        vm.expectRevert(IDivigentVaultRouter.NotEmergencyMultisig.selector);
        router.setMorphoViewGas(500_000);
    }

    // ── Bounds ───────────────────────────────────────────────────────────────

    function test_setMorphoViewGas_revertsBelowMin() public {
        uint256 tooLow = EXPECTED_MIN - 1;
        vm.prank(emergencyMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.MorphoViewGasOutOfBounds.selector,
                tooLow,
                EXPECTED_MIN,
                EXPECTED_MAX
            )
        );
        router.setMorphoViewGas(tooLow);
    }

    function test_setMorphoViewGas_revertsAtZero() public {
        vm.prank(emergencyMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.MorphoViewGasOutOfBounds.selector,
                0,
                EXPECTED_MIN,
                EXPECTED_MAX
            )
        );
        router.setMorphoViewGas(0);
    }

    function test_setMorphoViewGas_revertsAboveMax() public {
        uint256 tooHigh = EXPECTED_MAX + 1;
        vm.prank(emergencyMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.MorphoViewGasOutOfBounds.selector,
                tooHigh,
                EXPECTED_MIN,
                EXPECTED_MAX
            )
        );
        router.setMorphoViewGas(tooHigh);
    }

    function test_setMorphoViewGas_acceptsMinBoundary() public {
        vm.prank(emergencyMultisig);
        router.setMorphoViewGas(EXPECTED_MIN);
        assertEq(router.morphoViewGas(), EXPECTED_MIN, "min boundary must be inclusive");
    }

    function test_setMorphoViewGas_acceptsMaxBoundary() public {
        vm.prank(emergencyMultisig);
        router.setMorphoViewGas(EXPECTED_MAX);
        assertEq(router.morphoViewGas(), EXPECTED_MAX, "max boundary must be inclusive");
    }

    // ── Happy path ───────────────────────────────────────────────────────────

    function test_setMorphoViewGas_updatesState() public {
        uint256 newGas = 600_000;
        vm.prank(emergencyMultisig);
        router.setMorphoViewGas(newGas);
        assertEq(router.morphoViewGas(), newGas, "state must reflect new value");
    }

    function test_setMorphoViewGas_emitsEvent() public {
        uint256 oldGas = router.morphoViewGas();
        uint256 newGas = 750_000;

        vm.expectEmit(false, false, false, true, address(router));
        emit IDivigentVaultRouter.MorphoViewGasUpdated(oldGas, newGas);

        vm.prank(emergencyMultisig);
        router.setMorphoViewGas(newGas);
    }

    function test_setMorphoViewGas_emitsEvent_idempotentValue() public {
        uint256 sameValue = router.morphoViewGas();

        // Even when the value does not change, the event still fires —
        // governance actions should always be observable on-chain.
        vm.expectEmit(false, false, false, true, address(router));
        emit IDivigentVaultRouter.MorphoViewGasUpdated(sameValue, sameValue);

        vm.prank(emergencyMultisig);
        router.setMorphoViewGas(sameValue);
    }
}
