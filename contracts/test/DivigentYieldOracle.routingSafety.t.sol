// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDivigentYieldOracle} from "../src/interfaces/IDivigentYieldOracle.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../src/DivigentYieldOracle.sol";
import {TestBase} from "test/TestBase.sol";

/// @title  Oracle routing safety
/// @notice Pins that deposit routing cannot fall back to Aave unless Aave
///         passes the same utilization safety check exposed by getAllRates().
contract DivigentYieldOracleRoutingSafetyTest is TestBase {
    function test_getOptimalVault_revertsWhenBothVaultsUnsafe() public {
        _setAaveUtilization(100e6, 5e6);
        morphoVault.setSharePrice(999_999);

        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "precondition: Aave unsafe");
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "precondition: Morpho unsafe");

        vm.expectRevert(DivigentYieldOracle.NoSafeVault.selector);
        yieldOracle.getOptimalVault();
    }

    function test_getOptimalVault_routesToMorphoWhenAaveUnsafeAndMorphoSafe() public {
        _setAaveUtilization(100e6, 5e6);
        morphoVault.setSharePrice(1_000_000);

        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) = yieldOracle.getOptimalVault();

        assertEq(vault, address(morphoVault), "unsafe Aave must not be fallback route");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.MORPHO), "vault type");
        assertEq(twarRate, yieldOracle.morphoSpotRate(), "fallback TWAR should be Morpho");
    }

    function test_getOptimalVault_routesToAaveWhenMorphoUnsafeAndAaveSafe() public {
        morphoVault.setSharePrice(999_999);

        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) = yieldOracle.getOptimalVault();

        assertEq(vault, address(aavePool), "safe Aave remains fallback when Morpho is unsafe");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.AAVE), "vault type");
        assertEq(twarRate, yieldOracle.aaveSpotRate(), "fallback TWAR should be Aave");
    }

    function test_getOptimalVault_keepsAaveWhenBothSafeAndMorphoDoesNotClearDifferential() public view {
        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) = yieldOracle.getOptimalVault();

        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "precondition: Aave safe");
        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "precondition: Morpho safe");
        assertEq(vault, address(aavePool), "rate logic should still prefer Aave");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.AAVE), "vault type");
        assertEq(twarRate, yieldOracle.aaveSpotRate(), "returned TWAR should be Aave");
    }

    function test_getOptimalVault_keepsMorphoRatePreferenceWhenBothSafe() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        _recordObservationAfter(interval, DEFAULT_AAVE_LIQUIDITY_RATE, 1_001_000);
        vm.warp(block.timestamp + interval);

        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) = yieldOracle.getOptimalVault();
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        assertEq(vault, address(morphoVault), "Morpho should still win on sufficient safe-rate edge");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.MORPHO), "vault type");
        assertEq(twarRate, rates[1].twarRate, "returned TWAR should be Morpho");
    }

    function test_getOptimalVault_routesToMorphoWhenAaveOneUnitBelowSafetyFloor() public {
        _setAaveUtilization(100e6, 10e6 - 1);
        morphoVault.setSharePrice(1_000_000);

        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "precondition: Aave unsafe");

        (address vault, IDivigentYieldOracle.VaultType vaultType,) = yieldOracle.getOptimalVault();

        assertEq(vault, address(morphoVault), "Aave one unit below safety floor must be excluded");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.MORPHO), "vault type");
    }

    function test_deposit_propagatesNoSafeVaultWhenBothVaultsUnsafe() public {
        uint256 amount = 1_000e6;
        _setAaveUtilization(100e6, 5e6);
        morphoVault.setSharePrice(999_999);

        uint256 walletUsdcBefore = usdc.balanceOf(alice);
        uint256 walletSharesBefore = dvUsdc.balanceOf(alice);
        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 totalSupplyBefore = dvUsdc.totalSupply();

        vm.prank(alice);
        usdc.approve(address(router), amount);

        vm.prank(alice);
        vm.expectRevert(DivigentYieldOracle.NoSafeVault.selector);
        router.deposit(amount, alice, 0);

        assertEq(usdc.balanceOf(alice), walletUsdcBefore, "wallet USDC unchanged");
        assertEq(dvUsdc.balanceOf(alice), walletSharesBefore, "wallet shares unchanged");
        assertEq(usdc.balanceOf(address(router)), routerUsdcBefore, "router USDC unchanged");
        assertEq(dvUsdc.totalSupply(), totalSupplyBefore, "share supply unchanged");
    }

    function test_deposit_doesNotFallbackToMorphoWhenOracleFlagsMorphoUnsafe() public {
        uint256 amount = 20_000e6;

        // Aave is oracle-safe at exactly 10% idle liquidity, but it cannot
        // allocate this deposit amount. Morpho has capacity, but is unsafe.
        _setAaveUtilization(100_000e6, 10_000e6);
        morphoVault.setSharePrice(999_999);
        morphoVault.setMaxDeposit(type(uint256).max);

        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "precondition: Aave safe");
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "precondition: Morpho unsafe");

        (, IDivigentYieldOracle.VaultType recommended,) = yieldOracle.getOptimalVault();
        assertEq(uint256(recommended), uint256(IDivigentYieldOracle.VaultType.AAVE), "oracle recommends safe Aave");

        uint256 walletUsdcBefore = usdc.balanceOf(alice);
        uint256 morphoAssetsBefore = morphoVault.totalAssets_();

        vm.prank(alice);
        usdc.approve(address(router), amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.NoSafeRoute.selector, amount));
        router.deposit(amount, alice, 0);

        assertEq(usdc.balanceOf(alice), walletUsdcBefore, "wallet USDC unchanged");
        assertEq(morphoVault.totalAssets_(), morphoAssetsBefore, "unsafe Morpho receives no assets");
    }

    function _recordObservationAfter(uint256 elapsed, uint128 nextAaveRate, uint256 nextSharePrice) internal {
        aavePool.setCurrentLiquidityRate(nextAaveRate);
        morphoVault.setSharePrice(nextSharePrice);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();
    }

    function _setAaveUtilization(uint256 totalAToken, uint256 availableUsdc) internal {
        aToken.setBalance(address(this), totalAToken);
        usdc.setBalance(address(aToken), availableUsdc);
    }
}
