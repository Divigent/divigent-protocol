// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RouterIntegrationBase} from "./integration/RouterIntegrationBase.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";
import {IDivigentYieldOracle} from "../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Aave reserve config gates
/// @notice Pins Minor-11: balance-based Aave liquidity checks must also respect
///         the reserve's active/frozen/paused flags before routing deposits or
///         planning withdrawals.
contract DivigentVaultRouterAaveReserveGateTest is RouterIntegrationBase {
    uint256 internal constant DEPOSIT_AMOUNT = 50_000e6;

    function test_deposit_routesToAaveWhenReserveActive() public {
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);

        uint256 minted = _deposit(alice, alice, DEPOSIT_AMOUNT);

        assertGt(minted, 0, "deposit mints shares");
        assertEq(aToken.balanceOf(address(router)), DEPOSIT_AMOUNT, "active Aave receives deposit");
        assertEq(morphoVault.balanceOf(address(router)), 0, "Morpho remains untouched");
    }

    function test_deposit_fallsBackToMorphoWhenAavePaused() public {
        aavePool.setReservePaused(true);

        _depositWithAavePreferredAndExpectMorpho(DEPOSIT_AMOUNT);
    }

    function test_deposit_fallsBackToMorphoWhenAaveFrozen() public {
        aavePool.setReserveFrozen(true);

        _depositWithAavePreferredAndExpectMorpho(DEPOSIT_AMOUNT);
    }

    function test_deposit_fallsBackToMorphoWhenAaveInactive() public {
        aavePool.setReserveActive(false);

        _depositWithAavePreferredAndExpectMorpho(DEPOSIT_AMOUNT);
    }

    function test_deposit_revertsNoSafeRouteWhenAavePausedAndMorphoCannotAccept() public {
        aavePool.setReservePaused(true);
        morphoVault.setMaxDeposit(0);
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);

        vm.prank(alice);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.NoSafeRoute.selector, DEPOSIT_AMOUNT));
        router.deposit(DEPOSIT_AMOUNT, alice, 0);
    }

    function test_deposit_fallsBackToMorphoWhenAaveConfigurationReverts() public {
        aavePool.setRevertConfiguration(true);

        _depositWithAavePreferredAndExpectMorpho(DEPOSIT_AMOUNT);
    }

    function test_withdrawCapacity_zerosAaveCapWhenPaused() public {
        _depositToAave(DEPOSIT_AMOUNT);

        aavePool.setReservePaused(true);
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.aaveAssetsHeld, DEPOSIT_AMOUNT, "Aave position still valued");
        assertEq(cap.aaveWithdrawCap, 0, "paused reserve has zero withdraw cap");
    }

    function test_withdrawCapacity_zerosAaveCapWhenInactive() public {
        _depositToAave(DEPOSIT_AMOUNT);

        aavePool.setReserveActive(false);
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.aaveAssetsHeld, DEPOSIT_AMOUNT, "Aave position still valued");
        assertEq(cap.aaveWithdrawCap, 0, "inactive reserve has zero withdraw cap");
    }

    function test_withdrawCapacity_keepsAaveCapWhenOnlyFrozen() public {
        _depositToAave(DEPOSIT_AMOUNT);

        aavePool.setReserveFrozen(true);
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.aaveAssetsHeld, DEPOSIT_AMOUNT, "Aave position still valued");
        assertEq(cap.aaveWithdrawCap, DEPOSIT_AMOUNT, "frozen reserve still allows exits");
    }

    function test_withdrawCapacity_zerosAaveCapWhenAaveConfigurationReverts() public {
        _depositToAave(DEPOSIT_AMOUNT);

        aavePool.setRevertConfiguration(true);
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.aaveAssetsHeld, DEPOSIT_AMOUNT, "Aave position still valued");
        assertEq(cap.aaveWithdrawCap, 0, "unknown reserve state has zero withdraw cap");
    }

    function test_withdraw_redirectsAwayFromAaveWhenPausedAndMorphoCanCover() public {
        _depositToAave(DEPOSIT_AMOUNT);
        _depositToMorpho(DEPOSIT_AMOUNT);

        aavePool.setReservePaused(true);

        uint256 halfShares = dvUsdc.balanceOf(alice) / 2;

        vm.prank(alice);
        uint256 returned = router.withdraw(halfShares, alice, 0);

        assertGt(returned, 0, "withdraw succeeds via Morpho");

        (uint256 aaveAssets, uint256 morphoAssets) = router.getCurrentAllocation();
        assertApproxEqAbs(aaveAssets, DEPOSIT_AMOUNT, 10, "Aave side untouched while paused");
        assertApproxEqAbs(morphoAssets, 0, 10, "Morpho covers the exit");
    }

    function test_withdraw_revertsWhenAavePausedAndMorphoCannotCover() public {
        _depositToAave(DEPOSIT_AMOUNT);

        aavePool.setReservePaused(true);

        uint256 shares = dvUsdc.balanceOf(alice);

        vm.prank(alice);
        vm.expectPartialRevert(IDivigentVaultRouter.InsufficientVaultLiquidity.selector);
        router.withdraw(shares, alice, 0);
    }

    function _depositWithAavePreferredAndExpectMorpho(uint256 amount) internal {
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);

        uint256 minted = _deposit(alice, alice, amount);

        assertGt(minted, 0, "deposit mints shares");
        assertEq(aToken.balanceOf(address(router)), 0, "Aave remains untouched");
        assertGt(morphoVault.balanceOf(address(router)), 0, "Morpho receives deposit");
        assertEq(router.totalVaultAssets(), amount, "position remains fully backed");
    }

    function _depositToAave(uint256 amount) internal returns (uint256 shares) {
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        shares = _deposit(alice, alice, amount);
        assertEq(aToken.balanceOf(address(router)), amount, "Aave deposit setup");
    }

    function _depositToMorpho(uint256 amount) internal returns (uint256 shares) {
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);
        shares = _deposit(alice, alice, amount);
        assertGt(morphoVault.balanceOf(address(router)), 0, "Morpho deposit setup");
    }
}
