// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "test/TestBase.sol";

/// @title Morpho Share-Price Precision Regression Tests
/// @notice Demonstrates that a one-share Morpho probe loses realistic
///         per-interval USDC growth to integer quantization.
contract DivigentYieldOracleMorphoPrecisionTest is TestBase {
    uint256 internal constant OLD_SHARE_UNIT = 1e18;
    uint256 internal constant HIGH_PRECISION_SHARE_UNIT = 1e24;

    function test_morphoPrecision_realisticFivePercentTickShouldNotRoundToZero() public {
        assertEq(yieldOracle.SHARE_UNIT(), HIGH_PRECISION_SHARE_UNIT, "oracle should use high-precision probe");
        assertEq(yieldOracle.MORPHO_PEG_ASSETS(), HIGH_PRECISION_SHARE_UNIT / 1e12, "peg threshold scales with probe");

        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 totalShares = 1_000_000e18;
        uint256 startingAssets = 1_000_000e6;

        morphoVault.setTotalShares(totalShares);
        morphoVault.setTotalAssets(startingAssets);

        uint256 oldProbeBefore = morphoVault.convertToAssets(OLD_SHARE_UNIT);
        uint256 preciseProbeBefore = morphoVault.convertToAssets(HIGH_PRECISION_SHARE_UNIT);

        uint256 growth = startingAssets * 500 * interval / 10_000 / yieldOracle.SECONDS_PER_YEAR();
        assertGt(growth, 0, "test precondition: vault-level growth must be visible");

        morphoVault.setTotalAssets(startingAssets + growth);

        uint256 oldProbeDelta = morphoVault.convertToAssets(OLD_SHARE_UNIT) - oldProbeBefore;
        uint256 preciseProbeDelta = morphoVault.convertToAssets(HIGH_PRECISION_SHARE_UNIT) - preciseProbeBefore;

        assertEq(oldProbeDelta, 0, "old one-share probe silently rounds this tick to zero");
        assertGt(preciseProbeDelta, 0, "larger probe preserves the same realistic tick");

        vm.warp(block.timestamp + interval);
        yieldOracle.recordObservation();

        assertGt(yieldOracle.morphoSpotRate(), 0, "oracle should not report zero for a realistic 5 pct APY tick");
    }
}
