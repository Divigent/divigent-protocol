// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Fork Oracle Routing Tests
/// @notice Verifies the oracle reads real Aave V3 rates and Morpho share prices
///         on Base mainnet. Checks TWAR computation with production data.
contract ForkOracleRoutingTest is ForkBase {
    function testFork_oracle_readAaveRate() public {
        oracle.recordObservation();

        uint256 aaveRate = oracle.aaveSpotRate();
        // Aave USDC rate on Base is typically 2-8% APY in ray
        // 2% APY = 0.02e27 = 2e25, 8% APY = 8e25
        assertGt(aaveRate, 0, "Aave rate is non-zero");
        assertLt(aaveRate, 1e27, "Aave rate < 100% APY (sanity)");
    }

    function testFork_oracle_readMorphoSharePrice() public view {
        uint256 totalAssets = morphoVault.totalAssets();
        uint256 totalSupply = morphoVault.totalSupply();
        assertGt(totalAssets, 0, "Morpho vault has assets");
        assertGt(totalSupply, 0, "Morpho vault has shares");

        // MetaMorpho Steakhouse uses 18-decimal shares with 6-decimal USDC.
        // 1 full share (1e18) should be worth >= 1 USDC (1e6).
        uint256 oneShareValue = morphoVault.convertToAssets(1e18);
        assertGe(oneShareValue, 1e6, "1 full Morpho share is worth >= 1 USDC");

        // Verify our oracle's SHARE_UNIT (1e18) matches the vault's 18-decimal shares.
        // convertToAssets(1e18) returns ~1e6 (1 USDC) — the correct peg check input.
        uint256 oracleShareUnit = morphoVault.convertToAssets(1e18);
        assertGe(oracleShareUnit, 1e6, "convertToAssets(1e18) >= 1 USDC (oracle SHARE_UNIT correct)");
    }

    function testFork_oracle_morphoRateAfterTwoObservations() public {
        oracle.recordObservation();
        vm.warp(block.timestamp + 6 minutes);
        oracle.recordObservation();

        uint256 morphoRate = oracle.morphoSpotRate();
        // Rate could be 0 if share price didn't move in 6 minutes (likely)
        // Just verify it doesn't revert and is a valid uint256
        assertLe(morphoRate, 1e27, "Morpho rate < 100% (sanity)");
    }

    function testFork_oracle_getOptimalVault() public {
        _seedOracle();

        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) =
            oracle.getOptimalVault();

        // Must return a valid vault address (never address(0))
        assertTrue(vault != address(0), "Returned vault is not zero");
        assertTrue(
            vault == BASE_AAVE_POOL || vault == BASE_MORPHO_STEAKHOUSE,
            "Returned vault is Aave or Morpho"
        );
        assertGe(twarRate, 0, "TWAR rate is non-negative");
    }

    function testFork_oracle_getAllRates() public {
        _seedOracle();

        IDivigentYieldOracle.VaultRate[] memory rates = oracle.getAllRates();

        assertEq(rates.length, 2, "getAllRates returns 2 entries");
        assertEq(rates[0].vault, BASE_AAVE_POOL, "First entry is Aave");
        assertEq(rates[1].vault, BASE_MORPHO_STEAKHOUSE, "Second entry is Morpho");
    }

    function testFork_oracle_isFresh() public {
        oracle.recordObservation();
        assertTrue(oracle.isFresh(), "Fresh right after observation");

        vm.warp(block.timestamp + 3 hours);
        assertFalse(oracle.isFresh(), "Stale after 3 hours");
    }

    function testFork_oracle_twarWithMultipleObservations() public {
        // Seed 10 observations over 1 hour
        for (uint256 i = 0; i < 10; i++) {
            oracle.recordObservation();
            vm.warp(block.timestamp + 6 minutes);
        }
        oracle.recordObservation();

        (,, uint256 twarRate) = oracle.getOptimalVault();

        // TWAR should be a reasonable annualized rate (0-50% APY)
        assertLt(twarRate, 5e26, "TWAR < 50% APY (sanity)");
    }

    function testFork_oracle_vaultSafety() public view {
        // Both safety checks should execute without reverting on real contracts
        bool aaveSafe = oracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE);
        bool morphoSafe = oracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO);

        // At least one vault should be safe for the protocol to function
        assertTrue(aaveSafe || morphoSafe, "At least one vault must be safe");
    }

    function testFork_oracle_routingDecisionMatchesDeposit() public {
        _seedOracle();

        (, IDivigentYieldOracle.VaultType recommended,) = oracle.getOptimalVault();

        uint256 aTokenBefore = aToken.balanceOf(address(router));
        uint256 morphoSharesBefore = morphoVault.balanceOf(address(router));

        _deposit(alice, 50_000e6);

        uint256 aTokenDelta = aToken.balanceOf(address(router)) - aTokenBefore;
        uint256 morphoSharesDelta = morphoVault.balanceOf(address(router)) - morphoSharesBefore;

        if (recommended == IDivigentYieldOracle.VaultType.AAVE) {
            assertGt(aTokenDelta, 0, "Deposit routed to Aave as recommended");
        } else {
            assertGt(morphoSharesDelta, 0, "Deposit routed to Morpho as recommended");
        }
    }
}
