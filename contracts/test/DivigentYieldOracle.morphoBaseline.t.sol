// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DivigentYieldOracle} from "../src/DivigentYieldOracle.sol";
import {TestBase} from "test/TestBase.sol";

/// @title Morpho Baseline Regression Tests
/// @notice Pins the high-water baseline used by DivigentYieldOracle.
///         Drop-and-recovery paths must not create artificial Morpho yield.
contract DivigentYieldOracleMorphoBaselineTest is TestBase {
    function test_morphoBaseline_dropAndRecoveryToPriorHighProducesZeroRate() public {
        _seedBaseline(1_050_000);

        _recordAtSharePrice(1_040_000);
        assertEq(yieldOracle.morphoSpotRate(), 0, "drop should not produce a Morpho rate");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_050_000), "drop should not lower baseline");

        _recordAtSharePrice(1_050_000);
        assertEq(yieldOracle.morphoSpotRate(), 0, "recovery to baseline should not produce a Morpho rate");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_050_000), "baseline should stay at prior high");
    }

    function test_morphoBaseline_newHighUsesPriorHighNotDroppedPrice() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();

        _seedBaseline(1_050_000);
        _recordAtSharePrice(1_040_000);

        _recordAtSharePrice(1_060_000);

        uint256 expectedFromPriorHigh =
            _expectedMorphoRate(_sampledSharePrice(1_050_000), _sampledSharePrice(1_060_000), elapsed);
        uint256 inflatedFromDrop =
            _expectedMorphoRate(_sampledSharePrice(1_040_000), _sampledSharePrice(1_060_000), elapsed);

        assertEq(yieldOracle.morphoSpotRate(), expectedFromPriorHigh, "rate should use prior high baseline");
        assertLt(yieldOracle.morphoSpotRate(), inflatedFromDrop, "rate should not use lowered baseline");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_060_000), "new high should advance baseline");
    }

    function test_morphoBaseline_multipleDropsPreservePriorHigh() public {
        _seedBaseline(1_050_000);

        _recordAtSharePrice(1_040_000);
        assertEq(yieldOracle.morphoSpotRate(), 0, "first drop should produce zero rate");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_050_000), "first drop should preserve baseline");

        _recordAtSharePrice(1_030_000);
        assertEq(yieldOracle.morphoSpotRate(), 0, "second drop should produce zero rate");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_050_000), "second drop should preserve baseline");

        _recordAtSharePrice(1_020_000);
        assertEq(yieldOracle.morphoSpotRate(), 0, "third drop should produce zero rate");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_050_000), "third drop should preserve baseline");
    }

    function test_morphoBaseline_flatAtBaselineDoesNotAdvanceOrSpike() public {
        _seedBaseline(1_050_000);

        _recordAtSharePrice(1_050_000);

        assertEq(yieldOracle.morphoSpotRate(), 0, "flat baseline should produce zero rate");
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(1_050_000), "flat baseline should remain unchanged");
    }

    function test_morphoBaseline_recoveryBoundaryIsStrictGreater() public {
        _seedBaseline(1_050_000);

        _recordAtSharePrice(1_049_999);
        _recordAtSharePrice(1_050_000);

        assertEq(yieldOracle.morphoSpotRate(), 0, "equal-to-baseline recovery should produce zero rate");
        assertEq(
            yieldOracle.lastMorphoSharePrice(),
            _sampledSharePrice(1_050_000),
            "equal-to-baseline recovery should not advance"
        );
    }

    function test_morphoBaseline_zeroBaselineInitializesWithoutRate() public {
        morphoVault.setSharePrice(0);
        DivigentYieldOracle freshOracle =
            new DivigentYieldOracle(
                address(aavePool),
                address(aToken),
                address(usdc),
                address(morphoVault),
                emergencyMultisig
            );
        assertEq(freshOracle.lastMorphoSharePrice(), 0, "test precondition: fresh baseline is zero");

        morphoVault.setSharePrice(1_000_000);
        vm.warp(block.timestamp + freshOracle.MIN_OBSERVATION_INTERVAL());
        freshOracle.recordObservation();

        assertEq(freshOracle.morphoSpotRate(), 0, "zero baseline should initialize without a rate");
        assertEq(
            freshOracle.lastMorphoSharePrice(),
            _sampledSharePriceFor(freshOracle, 1_000_000),
            "zero baseline should initialize to current price"
        );
    }

    function _seedBaseline(uint256 sharePrice) internal {
        _recordAtSharePrice(sharePrice);
        assertEq(yieldOracle.lastMorphoSharePrice(), _sampledSharePrice(sharePrice), "baseline seed mismatch");
    }

    function _recordAtSharePrice(uint256 sharePrice) internal {
        morphoVault.setSharePrice(sharePrice);
        vm.warp(block.timestamp + yieldOracle.MIN_OBSERVATION_INTERVAL());
        yieldOracle.recordObservation();
    }

    function _expectedMorphoRate(uint256 lastPrice, uint256 currentPrice, uint256 elapsed)
        internal
        view
        returns (uint256)
    {
        return (currentPrice - lastPrice) * yieldOracle.SECONDS_PER_YEAR() * yieldOracle.RAY() / lastPrice / elapsed;
    }

    function _sampledSharePrice(uint256 sharePrice) internal view returns (uint256) {
        return _sampledSharePriceFor(yieldOracle, sharePrice);
    }

    function _sampledSharePriceFor(DivigentYieldOracle oracle, uint256 sharePrice) internal view returns (uint256) {
        return sharePrice * oracle.SHARE_UNIT() / 1e18;
    }
}
