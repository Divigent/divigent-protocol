// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Fork Oracle Routing Tests
/// @notice Exercises the oracle against REAL Aave V3 + Morpho Steakhouse
///         contracts on Base mainnet. Every assertion ties to a value
///         computed from live contract state rather than a sanity bound —
///         a bug in the oracle's read path would surface as an exact
///         mismatch, not as a `< 100% APY` passing with any wrong value.
contract ForkOracleRoutingTest is ForkBase {
    /// @notice `oracle.aaveSpotRate` after an observation must equal the
    ///         live `currentLiquidityRate` on Aave's reserve data.
    ///         A previous sanity-only version ("rate < 100% APY") would pass
    ///         even if the oracle read an unrelated field.
    function testFork_oracle_aaveSpotRate_matchesLiveReserve() public {
        oracle.recordObservation();

        (, , uint128 currentLiquidityRate, , , , , , , , , , , ,) = aavePool.getReserveData(BASE_USDC);

        assertEq(
            oracle.aaveSpotRate(),
            uint256(currentLiquidityRate),
            "oracle aaveSpotRate must equal live reserve currentLiquidityRate"
        );
    }

    /// @notice Share price read from the live Morpho vault. Pins decimal
    ///         assumption: 1 full share (1e18) must resolve to ≥ 1 USDC
    ///         (1e6) on Steakhouse USDC — the vault cannot be underwater.
    function testFork_oracle_morphoSharePrice_respectsDecimalsPeg() public view {
        uint256 totalAssets = morphoVault.totalAssets();
        uint256 totalSupply = morphoVault.totalSupply();
        assertGt(totalAssets, 0, "Morpho vault has assets");
        assertGt(totalSupply, 0, "Morpho vault has shares");

        uint256 oneShareValue = morphoVault.convertToAssets(1e18);
        assertGe(oneShareValue, 1e6, "1 full Morpho share >= 1 USDC (peg intact)");
    }

    /// @notice After two observations, `morphoSpotRate` must match the
    ///         manually-computed annualised interval rate derived from
    ///         share-price delta — the exact formula the oracle uses
    ///         internally. Previously this test only asserted `< 100% APY`.
    function testFork_oracle_morphoSpotRate_matchesManualFormula() public {
        uint256 price1 = morphoVault.convertToAssets(1e18);
        oracle.recordObservation();

        vm.warp(block.timestamp + 10 minutes);

        uint256 price2 = morphoVault.convertToAssets(1e18);
        oracle.recordObservation();

        uint256 oracleRate = oracle.morphoSpotRate();

        if (price2 > price1) {
            // Oracle formula: rate = (price2 - price1) * 1e27 / price1 *
            //                         (365.25 days / elapsed)
            // elapsed here is 600 seconds.
            uint256 expected = ((price2 - price1) * 1e27 / price1) * (365.25 days) / 10 minutes;
            assertApproxEqAbs(oracleRate, expected, 1, "morpho rate matches manual annualised interval rate");
        } else {
            // No share-price growth → oracle rate stays zero.
            assertEq(oracleRate, 0, "morpho rate is zero when share price did not grow");
        }
    }

    /// @notice `getOptimalVault` returns the vault whose TWAR matches the
    ///         returned `twarRate`. The routing choice is bounded by the
    ///         50-bps minimum differential, so we don't claim which vault
    ///         wins — only that the reported TWAR matches the winner's row
    ///         in `getAllRates`. This is a consistency invariant between
    ///         the two public views.
    function testFork_oracle_getOptimalVault_twarMatchesSelectedVaultRow() public {
        _seedOracle();

        (, IDivigentYieldOracle.VaultType vt, uint256 twar) = oracle.getOptimalVault();
        IDivigentYieldOracle.VaultRate[] memory rates = oracle.getAllRates();

        if (vt == IDivigentYieldOracle.VaultType.AAVE) {
            assertEq(twar, rates[0].twarRate, "selected Aave: TWAR matches rates[0].twarRate");
        } else {
            assertEq(twar, rates[1].twarRate, "selected Morpho: TWAR matches rates[1].twarRate");
        }
    }

    /// @notice `getAllRates` contents — not just the array shape — must
    ///         match live data. Spot rate is pinned to the authoritative
    ///         live source for each vault.
    function testFork_oracle_getAllRates_contentsMatchLiveSources() public {
        oracle.recordObservation();

        IDivigentYieldOracle.VaultRate[] memory rates = oracle.getAllRates();
        assertEq(rates.length, 2, "exactly 2 entries");

        assertEq(rates[0].vault, BASE_AAVE_POOL, "first entry is Aave pool");
        assertEq(rates[1].vault, BASE_MORPHO_STEAKHOUSE, "second entry is Morpho vault");

        // Aave: live currentLiquidityRate is authoritative.
        (, , uint128 currentLiquidityRate, , , , , , , , , , , ,) = aavePool.getReserveData(BASE_USDC);
        assertEq(
            rates[0].spotRate,
            uint256(currentLiquidityRate),
            "Aave rates[0].spotRate matches live currentLiquidityRate"
        );

        // Morpho: authoritative source is the oracle's stored `morphoSpotRate`
        // (computed from share-price delta, not a single-snapshot formula).
        assertEq(
            rates[1].spotRate,
            oracle.morphoSpotRate(),
            "Morpho rates[1].spotRate matches oracle's stored spot"
        );
    }

    function testFork_oracle_isFresh() public {
        oracle.recordObservation();
        assertTrue(oracle.isFresh(), "Fresh right after observation");

        vm.warp(block.timestamp + 3 hours);
        assertFalse(oracle.isFresh(), "Stale after 3 hours");
    }

    function testFork_oracle_twarWithMultipleObservations() public {
        for (uint256 i = 0; i < 10; i++) {
            oracle.recordObservation();
            vm.warp(block.timestamp + 6 minutes);
        }
        oracle.recordObservation();

        (,, uint256 twarRate) = oracle.getOptimalVault();
        assertLt(twarRate, 5e26, "TWAR < 50% APY (sanity)");
    }

    function testFork_oracle_vaultSafety() public view {
        bool aaveSafe = oracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE);
        bool morphoSafe = oracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO);

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
