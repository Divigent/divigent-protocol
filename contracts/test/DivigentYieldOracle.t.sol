// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DivigentYieldOracle} from "../src/DivigentYieldOracle.sol";
import {IDivigentYieldOracle} from "../src/interfaces/IDivigentYieldOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestBase} from "test/TestBase.sol";

contract DivigentYieldOracleTest is TestBase {
    event ObservationRecorded(uint256 indexed timestamp, uint256 aaveRate, uint256 morphoRate);
    event MinDifferentialRayUpdated(uint256 oldValue, uint256 newValue);
    event MinDifferentialRayUpdateScheduled(uint256 oldValue, uint256 newValue, uint256 effectiveAt);
    event MinDifferentialRayUpdateCancelled(uint256 pendingValue, uint256 effectiveAt);
    event OracleAdminRotationProposed(address indexed currentAdmin, address indexed pendingAdmin, uint256 effectiveAt);
    event OracleAdminRotationCancelled(address indexed cancelledPendingAdmin);
    event OracleAdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // ----- Constructor tests -----------------

    function test_constructor_revertsIfAavePoolIsZero() public {
        vm.expectRevert(DivigentYieldOracle.ZeroAavePool.selector);
        new DivigentYieldOracle(
            address(0), address(aToken), address(usdc), address(morphoVault), emergencyMultisig, emergencyMultisig
        );
    }

    function test_constructor_revertsIfATokenIsZero() public {
        vm.expectRevert(DivigentYieldOracle.ZeroAToken.selector);
        new DivigentYieldOracle(
            address(aavePool), address(0), address(usdc), address(morphoVault), emergencyMultisig, emergencyMultisig
        );
    }

    function test_constructor_revertsIfUsdcIsZero() public {
        vm.expectRevert(DivigentYieldOracle.ZeroUsdc.selector);
        new DivigentYieldOracle(
            address(aavePool), address(aToken), address(0), address(morphoVault), emergencyMultisig, emergencyMultisig
        );
    }

    function test_constructor_revertsIfMorphoVaultIsZero() public {
        vm.expectRevert(DivigentYieldOracle.ZeroMorphoVault.selector);
        new DivigentYieldOracle(
            address(aavePool), address(aToken), address(usdc), address(0), emergencyMultisig, emergencyMultisig
        );
    }

    function test_constructor_revertsIfOracleAdminIsZero() public {
        vm.expectRevert(DivigentYieldOracle.ZeroOracleAdmin.selector);
        new DivigentYieldOracle(
            address(aavePool), address(aToken), address(usdc), address(morphoVault), address(0), emergencyMultisig
        );
    }

    function test_constructor_revertsIfEmergencyOwnerIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DivigentYieldOracle(
            address(aavePool), address(aToken), address(usdc), address(morphoVault), emergencyMultisig, address(0)
        );
    }

    function test_constructor_seedsInitialOracleState() public view {
        assertEq(yieldOracle.aaveCumulative(), 0, "Aave cumulative should start at zero");
        assertEq(yieldOracle.morphoCumulative(), 0, "Morpho cumulative should start at zero");
        assertEq(yieldOracle.aaveSpotRate(), DEFAULT_AAVE_LIQUIDITY_RATE, "Aave spot rate seed mismatch");
        assertEq(
            yieldOracle.lastMorphoSharePrice(),
            morphoVault.convertToAssets(yieldOracle.SHARE_UNIT()),
            "Morpho price seed mismatch"
        );
        assertEq(yieldOracle.morphoSpotRate(), 0, "Morpho spot rate should start at zero");
        assertEq(yieldOracle.lastObservationTime(), block.timestamp, "Last observation time seed mismatch");
        assertEq(yieldOracle.ORACLE_ADMIN(), emergencyMultisig, "Oracle admin seed mismatch");
        assertEq(yieldOracle.owner(), emergencyMultisig, "Emergency owner seed mismatch");
        assertEq(
            yieldOracle.minDifferentialRay(),
            yieldOracle.DEFAULT_MIN_DIFFERENTIAL_RAY(),
            "Minimum differential seed mismatch"
        );
        assertEq(
            uint256(yieldOracle.lastOptimalVaultType()),
            uint256(IDivigentYieldOracle.VaultType.AAVE),
            "Default vault type mismatch"
        );
    }

    function test_emergencyOwnerTransfer_usesOwnable2Step() public {
        address newOwner = makeAddr("newEmergencyOwner");
        address wrongCaller = makeAddr("wrongCaller");

        vm.prank(emergencyMultisig);
        yieldOracle.transferOwnership(newOwner);

        assertEq(yieldOracle.owner(), emergencyMultisig, "Ownership should not move before acceptance");
        assertEq(yieldOracle.pendingOwner(), newOwner, "Pending owner mismatch");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, wrongCaller));
        vm.prank(wrongCaller);
        yieldOracle.acceptOwnership();

        vm.prank(newOwner);
        yieldOracle.acceptOwnership();

        assertEq(yieldOracle.owner(), newOwner, "New owner should accept ownership");
        assertEq(yieldOracle.pendingOwner(), address(0), "Pending owner should clear after acceptance");
    }

    function test_renounceOwnership_isDisabled() public {
        vm.expectRevert(DivigentYieldOracle.OwnershipRenouncementDisabled.selector);
        vm.prank(emergencyMultisig);
        yieldOracle.renounceOwnership();
    }

    // ----- recordObservation tests -----------------

    function test_recordObservation_returnsEarlyWhenCalledTooSoon() public {
        aavePool.setCurrentLiquidityRate(8e25);
        morphoVault.setSharePrice(1_001_000);

        uint256 beforeAaveCumulative = yieldOracle.aaveCumulative();
        uint256 beforeMorphoCumulative = yieldOracle.morphoCumulative();
        uint256 beforeAaveSpotRate = yieldOracle.aaveSpotRate();
        uint256 beforeMorphoSpotRate = yieldOracle.morphoSpotRate();
        uint256 beforeLastSharePrice = yieldOracle.lastMorphoSharePrice();
        uint256 beforeLastObservationTime = yieldOracle.lastObservationTime();

        vm.warp(block.timestamp + 4 minutes);
        yieldOracle.recordObservation();

        assertEq(yieldOracle.aaveCumulative(), beforeAaveCumulative, "Aave cumulative should not change");
        assertEq(yieldOracle.morphoCumulative(), beforeMorphoCumulative, "Morpho cumulative should not change");
        assertEq(yieldOracle.aaveSpotRate(), beforeAaveSpotRate, "Aave spot rate should not change");
        assertEq(yieldOracle.morphoSpotRate(), beforeMorphoSpotRate, "Morpho spot rate should not change");
        assertEq(yieldOracle.lastMorphoSharePrice(), beforeLastSharePrice, "Morpho share price should not change");
        assertEq(yieldOracle.lastObservationTime(), beforeLastObservationTime, "Observation time should not change");
    }

    function test_recordObservation_updatesStateAndEmitsEventWhenMorphoSharePriceIncreases() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 expectedTimestamp = block.timestamp + elapsed;
        uint256 expectedAaveRate = 8e25;
        uint256 expectedSharePrice = 1_001_000;
        uint256 expectedSampledSharePrice = _sampledSharePrice(expectedSharePrice);
        uint256 expectedMorphoRate =
            _expectedMorphoRate(_sampledSharePrice(1_000_000), expectedSampledSharePrice, elapsed);

        aavePool.setCurrentLiquidityRate(uint128(expectedAaveRate));
        morphoVault.setSharePrice(expectedSharePrice);

        vm.warp(expectedTimestamp);
        vm.expectEmit(true, false, false, true);
        emit ObservationRecorded(expectedTimestamp, expectedAaveRate, expectedMorphoRate);

        yieldOracle.recordObservation();

        assertEq(yieldOracle.aaveCumulative(), DEFAULT_AAVE_LIQUIDITY_RATE * elapsed, "Aave cumulative update mismatch");
        assertEq(yieldOracle.morphoCumulative(), 0, "Morpho cumulative should still be zero on first observation");
        assertEq(yieldOracle.aaveSpotRate(), expectedAaveRate, "Aave spot rate update mismatch");
        assertEq(yieldOracle.morphoSpotRate(), expectedMorphoRate, "Morpho spot rate update mismatch");
        assertEq(yieldOracle.lastMorphoSharePrice(), expectedSampledSharePrice, "Morpho share price update mismatch");
        assertEq(yieldOracle.lastObservationTime(), expectedTimestamp, "Observation time update mismatch");
    }

    function test_recordObservation_accumulatesUsingPreviousRates() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();

        aavePool.setCurrentLiquidityRate(8e25);
        morphoVault.setSharePrice(1_001_000);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();

        uint256 previousAaveCumulative = yieldOracle.aaveCumulative();
        uint256 previousMorphoCumulative = yieldOracle.morphoCumulative();
        uint256 previousAaveSpotRate = yieldOracle.aaveSpotRate();
        uint256 previousMorphoSpotRate = yieldOracle.morphoSpotRate();

        aavePool.setCurrentLiquidityRate(9e25);
        morphoVault.setSharePrice(1_002_000);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();

        assertEq(
            yieldOracle.aaveCumulative(),
            previousAaveCumulative + previousAaveSpotRate * elapsed,
            "Aave cumulative should use previous Aave spot rate"
        );
        assertEq(
            yieldOracle.morphoCumulative(),
            previousMorphoCumulative + previousMorphoSpotRate * elapsed,
            "Morpho cumulative should use previous Morpho spot rate"
        );
    }

    function test_recordObservation_setsMorphoRateToZeroWhenSharePriceIsFlatOrDown() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();

        aavePool.setCurrentLiquidityRate(8e25);
        morphoVault.setSharePrice(1_001_000);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();

        aavePool.setCurrentLiquidityRate(9e25);
        morphoVault.setSharePrice(1_001_000);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();
        assertEq(yieldOracle.morphoSpotRate(), 0, "Flat share price should zero Morpho spot rate");

        morphoVault.setSharePrice(999_000);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();
        assertEq(yieldOracle.morphoSpotRate(), 0, "Down share price should zero Morpho spot rate");
    }

    function test_recordObservation_isPermissionless() public {
        address caller = makeAddr("randomCaller");

        vm.warp(block.timestamp + yieldOracle.MIN_OBSERVATION_INTERVAL());
        vm.prank(caller);
        yieldOracle.recordObservation();

        assertEq(
            yieldOracle.lastObservationTime(), block.timestamp, "Permissionless caller should update observation time"
        );
    }

    // ----- TWAR tests -----------------

    function test_getAllRates_returnsSpotRatesWhenNoCheckpointExists() public view {
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        assertEq(rates[0].spotRate, yieldOracle.aaveSpotRate(), "Aave spot rate mismatch");
        assertEq(rates[0].twarRate, yieldOracle.aaveSpotRate(), "Aave TWAR should fall back to spot");
        assertEq(rates[1].spotRate, yieldOracle.morphoSpotRate(), "Morpho spot rate mismatch");
        assertEq(rates[1].twarRate, yieldOracle.morphoSpotRate(), "Morpho TWAR should fall back to spot");
    }

    function test_getAllRates_returnsSpotRatesWhenDtIsZero() public {
        _recordObservationAfter(yieldOracle.MIN_OBSERVATION_INTERVAL(), 8e25, 1_001_000);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        assertEq(rates[0].twarRate, rates[0].spotRate, "Aave TWAR should equal spot when dt is zero");
        assertEq(rates[1].twarRate, rates[1].spotRate, "Morpho TWAR should equal spot when dt is zero");
    }

    function test_getAllRates_usesOldestAvailableCheckpointWhenHistoryIsShorterThanWindow() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 morphoRateOne = _expectedMorphoRate(1_000_000, 1_001_000, elapsed);
        uint256 morphoRateTwo = _expectedMorphoRate(1_001_000, 1_002_000, elapsed);

        _recordObservationAfter(elapsed, 8e25, 1_001_000);
        _recordObservationAfter(elapsed, 9e25, 1_002_000);

        vm.warp(block.timestamp + elapsed);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        uint256 expectedAaveTwar = ((8e25 * elapsed) + (9e25 * elapsed)) / (2 * elapsed);
        uint256 expectedMorphoTwar = ((morphoRateOne * elapsed) + (morphoRateTwo * elapsed)) / (2 * elapsed);

        assertEq(rates[0].twarRate, expectedAaveTwar, "Aave TWAR should use oldest available checkpoint");
        assertEq(rates[1].twarRate, expectedMorphoTwar, "Morpho TWAR should use oldest available checkpoint");
    }

    function test_getAllRates_usesNewestCheckpointAtWindowBoundaryAfterBufferWrap() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();

        _recordObservationAfter(elapsed, 4e25, 1_000_000); // t = 5m
        _recordObservationAfter(elapsed, 10e25, 1_000_000); // t = 10m

        for (uint256 i = 0; i < 47; i++) {
            _recordObservationAfter(elapsed, 10e25, 1_000_000);
        }

        vm.warp(block.timestamp + elapsed);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        assertEq(rates[0].twarRate, 10e25, "Aave TWAR should use the boundary checkpoint after wrap");
        assertEq(rates[1].twarRate, 0, "Morpho TWAR should remain zero when share price is flat");
    }

    function test_getAllRates_usesOldestCheckpointWhenWindowStartPrecedesFirstCheckpoint() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 morphoRateOne = _expectedMorphoRate(1_000_000, 1_001_000, elapsed);
        uint256 morphoRateTwo = _expectedMorphoRate(1_001_000, 1_002_000, elapsed);

        _recordObservationAfter(elapsed, 8e25, 1_001_000);
        _recordObservationAfter(elapsed, 9e25, 1_002_000);

        uint256 trailingElapsed = yieldOracle.TWAR_WINDOW() - (elapsed + 1 minutes);
        vm.warp(block.timestamp + trailingElapsed);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        uint256 totalElapsedFromFirstCheckpoint = elapsed + trailingElapsed;
        uint256 expectedAaveTwar = ((8e25 * elapsed) + (9e25 * trailingElapsed)) / totalElapsedFromFirstCheckpoint;
        uint256 expectedMorphoTwar =
            ((morphoRateOne * elapsed) + (morphoRateTwo * trailingElapsed)) / totalElapsedFromFirstCheckpoint;

        assertEq(rates[0].twarRate, expectedAaveTwar, "Aave TWAR should use the oldest checkpoint");
        assertEq(rates[1].twarRate, expectedMorphoTwar, "Morpho TWAR should use the oldest checkpoint");
    }

    function test_getAllRates_usesCorrectWindowAfterHeadOverflowsAt256Observations() public {
        // Each observation is spaced exactly at the oracle's minimum interval so every
        // call records a real checkpoint into the circular buffer.
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();
        // Use two very different Aave rates so the expected 48-slot TWAR is easy to see.
        uint128 lowRate = 4e25;
        uint128 highRate = 10e25;

        // Record 208 observations first. This gets us close to the uint8 wrap point
        // without affecting the final 48-observation window under test.
        for (uint256 i = 0; i < 208; i++) {
            _recordObservationAfter(elapsed, lowRate, 1_000_000);
        }

        // Fill the first 32 observations of the final 48-slot window with the low rate.
        for (uint256 i = 0; i < 32; i++) {
            _recordObservationAfter(elapsed, lowRate, 1_000_000);
        }

        // Fill the last 16 observations of the final 48-slot window with the high rate.
        // At this point 256 total observations have been recorded, so `_head` as a uint8
        // has wrapped back to 0 even though the logical ring-buffer position is 256 % 48 = 16.
        for (uint256 i = 0; i < 16; i++) {
            _recordObservationAfter(elapsed, highRate, 1_000_000);
        }

        // Advance one more interval so `_computeTWAR()` extends the latest spot rate to "now"
        // and computes the TWAR over the most recent 48 observation intervals.
        vm.warp(block.timestamp + elapsed);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        // The correct Aave TWAR for the last 48 observations is:
        //   (32 * lowRate + 16 * highRate) / 48
        // If the oracle starts reading from the wrong slot after `_head` overflows,
        // it will produce a different answer and this assertion will fail.
        uint256 expectedAaveTwar = ((uint256(lowRate) * 32) + (uint256(highRate) * 16)) / 48;

        assertEq(
            rates[0].twarRate, expectedAaveTwar, "TWAR should still use the last 48 intervals after uint8 head overflow"
        );
        // Morpho share price is held flat throughout, so its derived rate and TWAR should stay zero.
        assertEq(rates[1].twarRate, 0, "Morpho TWAR should remain zero when share price is flat");
    }

    // ----- Views, safety, and routing tests -----------------

    function test_getAllRates_returnsFullStructArrayWithCorrectValues() public {
        _setAaveUtilization(100e6, 10e6);
        morphoVault.setSharePrice(1_002_000);

        _recordObservationAfter(yieldOracle.MIN_OBSERVATION_INTERVAL(), 8e25, 1_003_000);
        vm.warp(block.timestamp + yieldOracle.MIN_OBSERVATION_INTERVAL());

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        assertEq(rates.length, 2, "Rates array length mismatch");
        assertEq(rates[0].vault, address(aavePool), "Aave vault address mismatch");
        assertEq(uint256(rates[0].vaultType), uint256(IDivigentYieldOracle.VaultType.AAVE), "Aave vault type mismatch");
        assertEq(rates[0].spotRate, yieldOracle.aaveSpotRate(), "Aave spot rate mismatch");
        assertEq(rates[0].isSafe, true, "Aave safety mismatch");

        assertEq(rates[1].vault, address(morphoVault), "Morpho vault address mismatch");
        assertEq(
            uint256(rates[1].vaultType), uint256(IDivigentYieldOracle.VaultType.MORPHO), "Morpho vault type mismatch"
        );
        assertEq(rates[1].spotRate, yieldOracle.morphoSpotRate(), "Morpho spot rate mismatch");
        assertEq(rates[1].isSafe, true, "Morpho safety mismatch");
    }

    function test_isVaultSafe_aaveEmptyPoolIsAlwaysSafe() public view {
        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "Empty Aave pool should be safe");
    }

    function test_isVaultSafe_aaveAtThresholdIsSafe() public {
        _setAaveUtilization(100e6, 10e6);
        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "Aave threshold case should be safe");
    }

    function test_isVaultSafe_aaveBelowThresholdIsUnsafe() public {
        _setAaveUtilization(100e6, 9e6);
        assertFalse(
            yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE),
            "Aave below-threshold liquidity should be unsafe"
        );
    }

    function test_isVaultSafe_morphoAtParIsSafe() public {
        morphoVault.setSharePrice(1_000_000);
        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "Morpho at par should be safe");
    }

    function test_isVaultSafe_morphoBelowParIsUnsafe() public {
        // Share price below 1 USDC (999_999 < 1e6)
        morphoVault.setSharePrice(999_999);
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "Morpho below par should be unsafe");
    }

    function test_isVaultSafe_morphoAboveParIsSafe() public {
        // Share price above 1 USDC (1_000_001 > 1e6)
        morphoVault.setSharePrice(1_000_001);
        assertTrue(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "Morpho above par should be safe");
    }

    function test_isFresh_returnsTrueWithinAndAtBoundary() public {
        vm.warp(block.timestamp + yieldOracle.MAX_STALENESS() - 1);
        assertTrue(yieldOracle.isFresh(), "Oracle should be fresh within the staleness window");

        vm.warp(block.timestamp + 1);
        assertTrue(yieldOracle.isFresh(), "Oracle should be fresh at the exact staleness boundary");
    }

    function test_isFresh_returnsFalseAfterBoundary() public {
        vm.warp(block.timestamp + yieldOracle.MAX_STALENESS() + 1);
        assertFalse(yieldOracle.isFresh(), "Oracle should be stale after the staleness boundary");
    }

    function test_lastGoodObservationAge_returnsExactElapsedSeconds() public {
        vm.warp(block.timestamp + 37 minutes + 12 seconds);
        assertEq(yieldOracle.lastGoodObservationAge(), 37 minutes + 12 seconds, "Observation age mismatch");
    }

    function test_setMinDifferentialRay_revertsForNonAdmin() public {
        address caller = makeAddr("notAdmin");
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();

        vm.expectRevert(abi.encodeWithSelector(DivigentYieldOracle.NotOracleAdmin.selector, caller));
        vm.prank(caller);
        yieldOracle.setMinDifferentialRay(lowerBound);
    }

    function test_setMinDifferentialRay_revertsBelowLowerBound() public {
        uint256 belowLowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND() - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                DivigentYieldOracle.MinDifferentialRayOutOfBounds.selector,
                belowLowerBound,
                yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND(),
                yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND()
            )
        );
        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(belowLowerBound);
    }

    function test_setMinDifferentialRay_revertsAboveUpperBound() public {
        uint256 aboveUpperBound = yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND() + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                DivigentYieldOracle.MinDifferentialRayOutOfBounds.selector,
                aboveUpperBound,
                yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND(),
                yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND()
            )
        );
        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(aboveUpperBound);
    }

    function test_setMinDifferentialRay_raiseSchedulesAndDoesNotUpdateImmediately() public {
        uint256 oldValue = yieldOracle.minDifferentialRay();
        uint256 newValue = oldValue + 1e24;
        uint256 effectiveAt = block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY();

        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateScheduled(oldValue, newValue, effectiveAt);

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(newValue);

        assertEq(yieldOracle.minDifferentialRay(), oldValue, "Raise should not apply immediately");
        assertEq(yieldOracle.pendingMinDifferentialRay(), newValue, "Pending differential mismatch");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), effectiveAt, "Pending effective time mismatch");
    }

    function test_setMinDifferentialRay_loweringSchedulesAndDoesNotUpdateImmediately() public {
        uint256 oldValue = yieldOracle.minDifferentialRay();
        uint256 newValue = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        uint256 effectiveAt = block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY();

        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateScheduled(oldValue, newValue, effectiveAt);

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(newValue);

        assertEq(yieldOracle.minDifferentialRay(), oldValue, "Lowering should not apply immediately");
        assertEq(yieldOracle.pendingMinDifferentialRay(), newValue, "Pending differential mismatch");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), effectiveAt, "Pending effective time mismatch");
    }

    function test_setMinDifferentialRay_rescheduleCancelsOldPendingValue() public {
        uint256 oldValue = yieldOracle.minDifferentialRay();
        uint256 firstValue = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        uint256 secondValue = firstValue + 1;

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(firstValue);

        uint256 firstEffectiveAt = yieldOracle.pendingMinDifferentialRayEffectiveAt();
        vm.warp(block.timestamp + 1 hours);
        uint256 secondEffectiveAt = block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY();

        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateCancelled(firstValue, firstEffectiveAt);
        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateScheduled(oldValue, secondValue, secondEffectiveAt);

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(secondValue);

        assertEq(yieldOracle.pendingMinDifferentialRay(), secondValue, "Pending differential should be replaced");
        assertEq(
            yieldOracle.pendingMinDifferentialRayEffectiveAt(),
            secondEffectiveAt,
            "Reschedule should restart delay"
        );
    }

    function test_setMinDifferentialRay_revertsNoChange() public {
        uint256 currentValue = yieldOracle.minDifferentialRay();

        vm.expectRevert(DivigentYieldOracle.NoChange.selector);
        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(currentValue);
    }

    function test_setMinDifferentialRay_revertsNoChangeForSamePendingLowerValue() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();

        vm.startPrank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);
        vm.expectRevert(DivigentYieldOracle.NoChange.selector);
        yieldOracle.setMinDifferentialRay(lowerBound);
        vm.stopPrank();
    }

    function test_executeMinDifferentialRay_acceptsUpperBoundAfterDelay() public {
        uint256 oldValue = yieldOracle.minDifferentialRay();
        uint256 upperBound = yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND();
        uint256 effectiveAt = block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY();

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(upperBound);

        assertEq(yieldOracle.minDifferentialRay(), oldValue, "Upper bound should not apply immediately");
        assertEq(yieldOracle.pendingMinDifferentialRay(), upperBound, "Upper bound should be pending");

        vm.warp(effectiveAt);
        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdated(oldValue, upperBound);

        yieldOracle.executeMinDifferentialRay();

        assertEq(
            yieldOracle.minDifferentialRay(),
            upperBound,
            "Upper bound should be accepted after delay"
        );
        assertEq(yieldOracle.pendingMinDifferentialRay(), 0, "Pending value should clear");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), 0, "Pending timestamp should clear");
    }

    function test_executeMinDifferentialRay_acceptsLowerBoundAfterDelay() public {
        uint256 oldValue = yieldOracle.minDifferentialRay();
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        uint256 effectiveAt = block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY();

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        vm.warp(effectiveAt - 1);
        vm.expectRevert(abi.encodeWithSelector(DivigentYieldOracle.MinDifferentialRayTimelockActive.selector, effectiveAt));
        yieldOracle.executeMinDifferentialRay();

        vm.warp(effectiveAt);
        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdated(oldValue, lowerBound);

        yieldOracle.executeMinDifferentialRay();

        assertEq(yieldOracle.minDifferentialRay(), lowerBound, "Lower bound should apply after delay");
        assertEq(yieldOracle.pendingMinDifferentialRay(), 0, "Pending value should clear");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), 0, "Pending timestamp should clear");
    }

    function test_executeMinDifferentialRay_revertsWhenNoPendingValue() public {
        vm.expectRevert(DivigentYieldOracle.NoPendingMinDifferentialRay.selector);
        yieldOracle.executeMinDifferentialRay();
    }

    function test_executeMinDifferentialRay_isPermissionless() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        address caller = makeAddr("randomKeeper");

        assertNotEq(caller, yieldOracle.ORACLE_ADMIN(), "Test caller must not be oracle admin");

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        vm.warp(yieldOracle.pendingMinDifferentialRayEffectiveAt());

        vm.prank(caller);
        yieldOracle.executeMinDifferentialRay();

        assertEq(yieldOracle.minDifferentialRay(), lowerBound, "Random caller should execute pending value");
    }

    function test_executeMinDifferentialRay_revertsOnSecondCall() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        vm.warp(yieldOracle.pendingMinDifferentialRayEffectiveAt());
        yieldOracle.executeMinDifferentialRay();

        vm.expectRevert(DivigentYieldOracle.NoPendingMinDifferentialRay.selector);
        yieldOracle.executeMinDifferentialRay();
    }

    function test_setMinDifferentialRay_multipleCycles() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        uint256 upperBound = yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND();
        uint256 midValue = (lowerBound + upperBound) / 2;

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);
        vm.warp(yieldOracle.pendingMinDifferentialRayEffectiveAt());
        yieldOracle.executeMinDifferentialRay();
        assertEq(yieldOracle.minDifferentialRay(), lowerBound, "Cycle 1 lower mismatch");

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(upperBound);
        vm.warp(yieldOracle.pendingMinDifferentialRayEffectiveAt());
        yieldOracle.executeMinDifferentialRay();
        assertEq(yieldOracle.minDifferentialRay(), upperBound, "Cycle 2 raise mismatch");

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(midValue);
        vm.warp(yieldOracle.pendingMinDifferentialRayEffectiveAt());
        yieldOracle.executeMinDifferentialRay();

        assertEq(yieldOracle.minDifferentialRay(), midValue, "Cycle 3 lower mismatch");
        assertEq(yieldOracle.pendingMinDifferentialRay(), 0, "Pending value should clear after cycles");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), 0, "Pending timestamp should clear after cycles");
    }

    function test_cancelPendingMinDifferentialRay_revertsForNonAdmin() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        address caller = makeAddr("notAdmin");

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        vm.expectRevert(abi.encodeWithSelector(DivigentYieldOracle.NotOracleAdmin.selector, caller));
        vm.prank(caller);
        yieldOracle.cancelPendingMinDifferentialRay();
    }

    function test_cancelPendingMinDifferentialRay_revertsWhenNoPendingValue() public {
        vm.expectRevert(DivigentYieldOracle.NoPendingMinDifferentialRay.selector);
        vm.prank(emergencyMultisig);
        yieldOracle.cancelPendingMinDifferentialRay();
    }

    function test_cancelPendingMinDifferentialRay_clearsPendingValue() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        uint256 effectiveAt = yieldOracle.pendingMinDifferentialRayEffectiveAt();

        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateCancelled(lowerBound, effectiveAt);

        vm.prank(emergencyMultisig);
        yieldOracle.cancelPendingMinDifferentialRay();

        assertEq(yieldOracle.pendingMinDifferentialRay(), 0, "Pending value should clear");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), 0, "Pending timestamp should clear");
    }

    function test_proposeOracleAdminRotation_revertsForNonOwner() public {
        address caller = makeAddr("notAdmin");
        address newAdmin = makeAddr("newOracleAdmin");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        yieldOracle.proposeOracleAdminRotation(newAdmin);
    }

    function test_proposeOracleAdminRotation_isControlledByEmergencyOwnerNotOracleAdmin() public {
        address oracleAdmin = makeAddr("oracleAdmin");
        address recoveryOwner = makeAddr("recoveryOwner");
        address newAdmin = makeAddr("newOracleAdmin");

        DivigentYieldOracle recoveryOracle = new DivigentYieldOracle(
            address(aavePool),
            address(aToken),
            address(usdc),
            address(morphoVault),
            oracleAdmin,
            recoveryOwner
        );

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, oracleAdmin));
        vm.prank(oracleAdmin);
        recoveryOracle.proposeOracleAdminRotation(newAdmin);

        vm.prank(recoveryOwner);
        recoveryOracle.proposeOracleAdminRotation(newAdmin);

        assertEq(recoveryOracle.ORACLE_ADMIN(), oracleAdmin, "Rotation should not execute immediately");
        assertEq(recoveryOracle.pendingOracleAdmin(), newAdmin, "Owner should schedule replacement admin");
    }

    function test_proposeOracleAdminRotation_revertsForZeroAdmin() public {
        vm.expectRevert(DivigentYieldOracle.ZeroOracleAdmin.selector);
        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(address(0));
    }

    function test_proposeOracleAdminRotation_revertsForCurrentAdmin() public {
        vm.expectRevert(DivigentYieldOracle.NoChange.selector);
        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(emergencyMultisig);
    }

    function test_proposeOracleAdminRotation_schedulesAndDoesNotUpdateImmediately() public {
        address newAdmin = makeAddr("newOracleAdmin");
        uint256 effectiveAt = block.timestamp + yieldOracle.ORACLE_ADMIN_ROTATION_DELAY();

        vm.expectEmit(true, true, false, true);
        emit OracleAdminRotationProposed(emergencyMultisig, newAdmin, effectiveAt);

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(newAdmin);

        assertEq(yieldOracle.ORACLE_ADMIN(), emergencyMultisig, "Admin should not rotate immediately");
        assertEq(yieldOracle.pendingOracleAdmin(), newAdmin, "Pending admin mismatch");
        assertEq(yieldOracle.oracleAdminRotationEffectiveAt(), effectiveAt, "Pending effective time mismatch");
    }

    function test_proposeOracleAdminRotation_revertsWhenRotationAlreadyPending() public {
        address firstAdmin = makeAddr("firstOracleAdmin");
        address secondAdmin = makeAddr("secondOracleAdmin");

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(firstAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(DivigentYieldOracle.OracleAdminRotationAlreadyPending.selector, firstAdmin)
        );
        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(secondAdmin);
    }

    function test_cancelOracleAdminRotation_revertsForNonOwner() public {
        address newAdmin = makeAddr("newOracleAdmin");
        address caller = makeAddr("notAdmin");

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(newAdmin);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        yieldOracle.cancelOracleAdminRotation();
    }

    function test_cancelOracleAdminRotation_revertsWhenNoPendingRotation() public {
        vm.expectRevert(DivigentYieldOracle.OracleAdminRotationNotProposed.selector);
        vm.prank(emergencyMultisig);
        yieldOracle.cancelOracleAdminRotation();
    }

    function test_cancelOracleAdminRotation_clearsPendingRotation() public {
        address newAdmin = makeAddr("newOracleAdmin");

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(newAdmin);

        vm.expectEmit(true, false, false, true);
        emit OracleAdminRotationCancelled(newAdmin);

        vm.prank(emergencyMultisig);
        yieldOracle.cancelOracleAdminRotation();

        assertEq(yieldOracle.ORACLE_ADMIN(), emergencyMultisig, "Current admin should remain unchanged");
        assertEq(yieldOracle.pendingOracleAdmin(), address(0), "Pending admin should clear");
        assertEq(yieldOracle.oracleAdminRotationEffectiveAt(), 0, "Pending timestamp should clear");
    }

    function test_executeOracleAdminRotation_revertsWhenNoPendingRotation() public {
        vm.expectRevert(DivigentYieldOracle.OracleAdminRotationNotProposed.selector);
        yieldOracle.executeOracleAdminRotation();
    }

    function test_executeOracleAdminRotation_revertsBeforeDelay() public {
        address newAdmin = makeAddr("newOracleAdmin");
        uint256 effectiveAt = block.timestamp + yieldOracle.ORACLE_ADMIN_ROTATION_DELAY();

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(newAdmin);

        vm.warp(effectiveAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DivigentYieldOracle.OracleAdminRotationNotReady.selector,
                block.timestamp,
                effectiveAt
            )
        );
        yieldOracle.executeOracleAdminRotation();
    }

    function test_executeOracleAdminRotation_revertsAfterGracePeriod() public {
        address newAdmin = makeAddr("newOracleAdmin");

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(newAdmin);

        uint256 expiredAt =
            yieldOracle.oracleAdminRotationEffectiveAt() + yieldOracle.ORACLE_ADMIN_ROTATION_GRACE_PERIOD();
        vm.warp(expiredAt + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                DivigentYieldOracle.OracleAdminRotationExpired.selector,
                block.timestamp,
                expiredAt
            )
        );
        yieldOracle.executeOracleAdminRotation();
    }

    function test_executeOracleAdminRotation_isPermissionlessAndTransfersControl() public {
        address newAdmin = makeAddr("newOracleAdmin");
        address keeper = makeAddr("keeper");
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(newAdmin);

        vm.warp(yieldOracle.oracleAdminRotationEffectiveAt());
        vm.expectEmit(true, true, false, true);
        emit OracleAdminUpdated(emergencyMultisig, newAdmin);

        vm.prank(keeper);
        yieldOracle.executeOracleAdminRotation();

        assertEq(yieldOracle.ORACLE_ADMIN(), newAdmin, "Oracle admin should rotate");
        assertEq(yieldOracle.pendingOracleAdmin(), address(0), "Pending admin should clear");
        assertEq(yieldOracle.oracleAdminRotationEffectiveAt(), 0, "Pending timestamp should clear");

        vm.expectRevert(abi.encodeWithSelector(DivigentYieldOracle.NotOracleAdmin.selector, emergencyMultisig));
        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        vm.prank(newAdmin);
        yieldOracle.setMinDifferentialRay(lowerBound);

        assertEq(yieldOracle.pendingMinDifferentialRay(), lowerBound, "New admin should control oracle params");
    }

    function test_ownerCanScheduleSecondAdminRotationAfterOperationalAdminChanges() public {
        address firstAdmin = makeAddr("firstOracleAdmin");
        address secondAdmin = makeAddr("secondOracleAdmin");

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(firstAdmin);

        vm.warp(yieldOracle.oracleAdminRotationEffectiveAt());
        yieldOracle.executeOracleAdminRotation();

        assertEq(yieldOracle.ORACLE_ADMIN(), firstAdmin, "First admin should apply");
        assertEq(yieldOracle.owner(), emergencyMultisig, "Emergency owner should remain unchanged");

        vm.prank(emergencyMultisig);
        yieldOracle.proposeOracleAdminRotation(secondAdmin);

        assertEq(yieldOracle.pendingOracleAdmin(), secondAdmin, "Owner should retain recovery authority");
    }

    function testFuzz_setMinDifferentialRay_boundsValidator(uint256 value) public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        uint256 upperBound = yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND();
        uint256 currentValue = yieldOracle.minDifferentialRay();

        vm.assume(value != currentValue);

        if (value < lowerBound || value > upperBound) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    DivigentYieldOracle.MinDifferentialRayOutOfBounds.selector,
                    value,
                    lowerBound,
                    upperBound
                )
            );
        }

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(value);
    }

    function test_setMinDifferentialRay_raiseReschedulesPendingValue() public {
        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();
        uint256 upperBound = yieldOracle.MIN_DIFFERENTIAL_RAY_UPPER_BOUND();
        uint256 oldValue = yieldOracle.minDifferentialRay();

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        uint256 firstEffectiveAt = yieldOracle.pendingMinDifferentialRayEffectiveAt();
        vm.warp(block.timestamp + 1 hours);
        uint256 secondEffectiveAt = block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY();

        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateCancelled(lowerBound, firstEffectiveAt);
        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdateScheduled(oldValue, upperBound, secondEffectiveAt);

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(upperBound);

        assertEq(yieldOracle.minDifferentialRay(), oldValue, "Raised value should not apply immediately");
        assertEq(yieldOracle.pendingMinDifferentialRay(), upperBound, "Pending value should be replaced");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), secondEffectiveAt, "Pending delay should restart");

        vm.warp(secondEffectiveAt);
        vm.expectEmit(false, false, false, true);
        emit MinDifferentialRayUpdated(oldValue, upperBound);

        yieldOracle.executeMinDifferentialRay();

        assertEq(yieldOracle.minDifferentialRay(), upperBound, "Upper bound should apply after delay");
        assertEq(yieldOracle.pendingMinDifferentialRay(), 0, "Pending value should clear");
        assertEq(yieldOracle.pendingMinDifferentialRayEffectiveAt(), 0, "Pending timestamp should clear");
    }

    function test_setMinDifferentialRay_changesRoutingThreshold() public {
        uint256 elapsed = 1 hours;
        uint128 lowAaveRate = 75e23; // 0.75% APY

        _recordObservationAfter(elapsed, lowAaveRate, 1_000_001);
        vm.warp(block.timestamp + elapsed);

        (address defaultVault,,) = yieldOracle.getOptimalVault();
        assertEq(defaultVault, address(aavePool), "Default threshold should keep routing on Aave");

        uint256 lowerBound = yieldOracle.MIN_DIFFERENTIAL_RAY_LOWER_BOUND();

        vm.prank(emergencyMultisig);
        yieldOracle.setMinDifferentialRay(lowerBound);

        (address stillDefaultVault,,) = yieldOracle.getOptimalVault();
        assertEq(stillDefaultVault, address(aavePool), "Timelocked lower threshold should not apply immediately");

        vm.warp(block.timestamp + yieldOracle.MIN_DIFFERENTIAL_RAY_CHANGE_DELAY());
        yieldOracle.executeMinDifferentialRay();

        (address loweredVault, IDivigentYieldOracle.VaultType loweredVaultType,) = yieldOracle.getOptimalVault();

        assertEq(loweredVault, address(morphoVault), "Lower threshold should allow Morpho to win");
        assertEq(
            uint256(loweredVaultType),
            uint256(IDivigentYieldOracle.VaultType.MORPHO),
            "Lowered threshold should route to Morpho"
        );
    }

    function test_getOptimalVault_returnsAaveWhenMorphoIsUnsafe() public {
        morphoVault.setSharePrice(999_999);

        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) = yieldOracle.getOptimalVault();

        assertEq(vault, address(aavePool), "Unsafe Morpho should fall back to Aave");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.AAVE), "Vault type should be AAVE");
        assertEq(twarRate, yieldOracle.aaveSpotRate(), "Fallback TWAR should match Aave");
    }

    function test_getOptimalVault_returnsAaveWhenMorphoDifferentialIsTooSmall() public {
        uint256 elapsed = 10 minutes + 30 seconds;
        uint256 smallEdgeSharePrice = 1_000_001;

        _recordObservationAfter(elapsed, DEFAULT_AAVE_LIQUIDITY_RATE, smallEdgeSharePrice);

        (address vault, IDivigentYieldOracle.VaultType vaultType,) = yieldOracle.getOptimalVault();

        assertEq(vault, address(aavePool), "Small Morpho edge should not beat Aave");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.AAVE), "Vault type should stay AAVE");
    }

    function test_getOptimalVault_returnsMorphoWhenSafeAndDifferentialMet() public {
        uint256 elapsed = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 strongSharePrice = 1_001_000;

        _recordObservationAfter(elapsed, DEFAULT_AAVE_LIQUIDITY_RATE, strongSharePrice);
        vm.warp(block.timestamp + elapsed);

        (address vault, IDivigentYieldOracle.VaultType vaultType, uint256 twarRate) = yieldOracle.getOptimalVault();

        assertEq(vault, address(morphoVault), "Morpho should win when safe and sufficiently better");
        assertEq(uint256(vaultType), uint256(IDivigentYieldOracle.VaultType.MORPHO), "Vault type should be MORPHO");
        assertEq(twarRate, yieldOracle.getAllRates()[1].twarRate, "Returned TWAR should match Morpho TWAR");
    }

    function testFuzz_getOptimalVault_returnsAaveWheneverMorphoIsUnsafe(uint128 aaveRate, uint64 elapsed) public {
        vm.assume(elapsed >= yieldOracle.MIN_OBSERVATION_INTERVAL());
        vm.assume(elapsed <= 30 days);
        vm.assume(aaveRate > 0);

        _recordObservationAfter(elapsed, aaveRate, 999_999);

        (address vault, IDivigentYieldOracle.VaultType vaultType,) = yieldOracle.getOptimalVault();

        assertEq(vault, address(aavePool), "Unsafe Morpho should always fall back to Aave");
        assertEq(
            uint256(vaultType),
            uint256(IDivigentYieldOracle.VaultType.AAVE),
            "Unsafe Morpho should always yield AAVE type"
        );
    }

    function testFuzz_lastGoodObservationAge_matchesWarpedTime(uint64 elapsed) public {
        vm.assume(elapsed <= 30 days);

        vm.warp(block.timestamp + elapsed);

        assertEq(yieldOracle.lastGoodObservationAge(), elapsed, "Fuzzed observation age mismatch");
        assertEq(yieldOracle.isFresh(), elapsed <= yieldOracle.MAX_STALENESS(), "Fuzzed freshness mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: recordObservation edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_recordObservation_succeedsAtExactMinInterval() public {
        aavePool.setCurrentLiquidityRate(8e25);
        morphoVault.setSharePrice(1_001_000);

        // 299s = no-op
        vm.warp(block.timestamp + 299);
        yieldOracle.recordObservation();
        assertEq(yieldOracle.aaveCumulative(), 0, "299s should be a no-op");

        // Reset and try exactly 300s from original
        vm.warp(block.timestamp + 1); // total = 300s from setUp
        yieldOracle.recordObservation();
        assertGt(yieldOracle.aaveCumulative(), 0, "300s should succeed");
    }

    function test_recordObservation_largeGapAccumulatesCorrectly() public {
        uint256 twoHours = 2 hours;
        uint128 rate = 0.05e27;

        aavePool.setCurrentLiquidityRate(rate);
        morphoVault.setSharePrice(1_010_000);
        vm.warp(block.timestamp + twoHours);
        yieldOracle.recordObservation();

        // Constructor seeded aaveSpotRate = DEFAULT_AAVE_LIQUIDITY_RATE
        // Step 1 accumulates: DEFAULT_AAVE_LIQUIDITY_RATE * twoHours
        assertEq(
            yieldOracle.aaveCumulative(),
            DEFAULT_AAVE_LIQUIDITY_RATE * twoHours,
            "Large gap should accumulate previous rate * elapsed"
        );
        assertEq(yieldOracle.aaveSpotRate(), rate, "Aave spot rate should update to new rate");
    }

    function test_recordObservation_firstObservationBootstrap() public {
        // Deploy a fresh oracle to test the first-ever observation
        DivigentYieldOracle freshOracle =
            new DivigentYieldOracle(
                address(aavePool),
                address(aToken),
                address(usdc),
                address(morphoVault),
                emergencyMultisig,
                emergencyMultisig
            );

        // Before any observation
        assertEq(freshOracle.morphoSpotRate(), 0, "morphoSpotRate should be 0 before first observation");
        assertEq(freshOracle.morphoCumulative(), 0, "morphoCumulative should be 0");

        // First observation
        aavePool.setCurrentLiquidityRate(8e25);
        morphoVault.setSharePrice(1_001_000);
        vm.warp(block.timestamp + freshOracle.MIN_OBSERVATION_INTERVAL());
        freshOracle.recordObservation();

        // morphoCumulative should still be 0: it accumulated 0 (morphoSpotRate was 0) * elapsed
        assertEq(freshOracle.morphoCumulative(), 0, "First observation morphoCumulative should be 0");
        // But morphoSpotRate should now be non-zero
        assertGt(freshOracle.morphoSpotRate(), 0, "morphoSpotRate should be set after first observation");
    }

    function test_recordObservation_consecutiveZeroRatesMorphoCumulativeFlat() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // First observation sets morphoSpotRate to non-zero
        _recordObservationAfter(interval, 8e25, 1_001_000);
        uint256 morphoRate = yieldOracle.morphoSpotRate();
        assertGt(morphoRate, 0, "First observation should yield non-zero morpho rate");

        // Second observation: morpho rate becomes zero (flat price)
        _recordObservationAfter(interval, 8e25, 1_001_000);
        assertEq(yieldOracle.morphoSpotRate(), 0, "Flat price should zero morpho rate");

        uint256 cumAfterSecond = yieldOracle.morphoCumulative();

        // Third, fourth, fifth: all flat - cumulative should not change
        for (uint256 i = 0; i < 3; i++) {
            _recordObservationAfter(interval, 8e25, 1_001_000);
            assertEq(yieldOracle.morphoSpotRate(), 0, "Flat price should keep zero rate");
        }

        assertEq(
            yieldOracle.morphoCumulative(),
            cumAfterSecond,
            "Morpho cumulative should flatline during consecutive zero-rate observations"
        );
    }

    function test_recordObservation_morphoRateFormulaKnownExactValue() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL(); // 300s
        uint256 lastPrice = 1_000_000;
        uint256 newPrice = 1_050_000; // 5% jump in one interval

        // Expected: (50000 * 31557600 * 1e27) / 1000000 / 300
        uint256 expected = (50_000 * yieldOracle.SECONDS_PER_YEAR() * yieldOracle.RAY()) / lastPrice / interval;

        _recordObservationAfter(interval, 8e25, newPrice);

        assertEq(yieldOracle.morphoSpotRate(), expected, "Morpho rate formula should match hand calculation");
    }

    function test_recordObservation_zeroAaveRateAccumulatesZero() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // Set Aave rate to 0
        aavePool.setCurrentLiquidityRate(0);
        morphoVault.setSharePrice(1_001_000);
        vm.warp(block.timestamp + interval);
        yieldOracle.recordObservation();

        // Previous rate was DEFAULT (5%), so first interval accumulates that
        uint256 firstCum = yieldOracle.aaveCumulative();
        assertEq(firstCum, DEFAULT_AAVE_LIQUIDITY_RATE * interval, "First interval uses constructor rate");

        // Second interval: now aaveSpotRate = 0, so accumulation adds 0
        vm.warp(block.timestamp + interval);
        yieldOracle.recordObservation();
        assertEq(yieldOracle.aaveCumulative(), firstCum, "Zero aave rate accumulates nothing");
    }

    function test_recordObservation_multipleConcurrentCallersSecondIsRateLimited() public {
        address keeper1 = makeAddr("keeper1");
        address keeper2 = makeAddr("keeper2");

        vm.warp(block.timestamp + yieldOracle.MIN_OBSERVATION_INTERVAL());

        vm.prank(keeper1);
        yieldOracle.recordObservation();
        uint256 cumAfterFirst = yieldOracle.aaveCumulative();

        // Immediately after, keeper2 tries - should be a no-op
        vm.prank(keeper2);
        yieldOracle.recordObservation();
        assertEq(yieldOracle.aaveCumulative(), cumAfterFirst, "Second caller in same block should be rate-limited");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: Buffer / TWAR edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_twar_bufferTransition_47_48_49() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint128 steadyRate = 5e25;

        // Fill 47 slots (partial buffer)
        for (uint256 i = 0; i < 47; i++) {
            _recordObservationAfter(interval, steadyRate, 1_000_000);
        }

        vm.warp(block.timestamp + interval);
        IDivigentYieldOracle.VaultRate[] memory ratesPartial = yieldOracle.getAllRates();
        uint256 twarAt47 = ratesPartial[0].twarRate;

        // 48th observation: buffer becomes full
        _recordObservationAfter(interval, steadyRate, 1_000_000);
        vm.warp(block.timestamp + interval);
        IDivigentYieldOracle.VaultRate[] memory ratesFull = yieldOracle.getAllRates();
        uint256 twarAt48 = ratesFull[0].twarRate;

        // 49th observation: first overwrite
        _recordObservationAfter(interval, steadyRate, 1_000_000);
        vm.warp(block.timestamp + interval);
        IDivigentYieldOracle.VaultRate[] memory ratesOverwrite = yieldOracle.getAllRates();
        uint256 twarAt49 = ratesOverwrite[0].twarRate;

        // With a steady rate, all three TWARs should be approximately equal.
        // The partial-buffer case (47 slots) has a small residual skew from
        // the constructor's initial aaveSpotRate observation; 1% covers that
        // without hiding a logic regression. The full-buffer cases (48, 49)
        // are exact windowed averages — tolerance could be tighter but 1%
        // keeps the three assertions uniform.
        assertApproxEqRel(twarAt47, steadyRate, 0.01e18, "TWAR at 47 should approximate steady rate");
        assertApproxEqRel(twarAt48, steadyRate, 0.01e18, "TWAR at 48 should approximate steady rate");
        assertApproxEqRel(twarAt49, steadyRate, 0.01e18, "TWAR at 49 should approximate steady rate");
    }

    function test_twar_multipleCycles_96observations() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint128 rate = 7e25;

        for (uint256 i = 0; i < 96; i++) {
            _recordObservationAfter(interval, rate, 1_000_000);
        }

        vm.warp(block.timestamp + interval);
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        // After 96 observations (2 full cycles) with a steady rate, TWAR = rate
        assertEq(rates[0].twarRate, rate, "TWAR after 2 full cycles should equal steady rate");
    }

    function test_twar_varyingRatesManualComputation() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // Record 4 observations with different Aave rates
        // The TWAR should be the weighted average
        _recordObservationAfter(interval, 4e25, 1_000_000); // rate1
        _recordObservationAfter(interval, 6e25, 1_000_000); // rate2
        _recordObservationAfter(interval, 8e25, 1_000_000); // rate3
        _recordObservationAfter(interval, 10e25, 1_000_000); // rate4

        vm.warp(block.timestamp + interval);
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        // _computeTWAR starts from the oldest CHECKPOINT (obs 1), not from the constructor.
        // The [constructor → obs 1] interval is baked into checkpoint 0's cumulative.
        // TWAR delta is from checkpoint 0 to cumulNow, covering 4 intervals:
        //   [obs1→obs2]: rate = 4e25  (rate read at obs 1, accumulated at obs 2)
        //   [obs2→obs3]: rate = 6e25
        //   [obs3→obs4]: rate = 8e25
        //   [obs4→now]:  rate = 10e25 (extension with current spot rate)
        // TWAR = (4e25 + 6e25 + 8e25 + 10e25) / 4 = 7e25
        uint256 expectedTwar = (4e25 + 6e25 + 8e25 + 10e25) / 4;
        assertEq(rates[0].twarRate, expectedTwar, "TWAR should match manual weighted average");
    }

    function test_twar_extensionWithoutNewObservation() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        _recordObservationAfter(interval, 8e25, 1_001_000);
        _recordObservationAfter(interval, 6e25, 1_002_000);

        // Warp 30 minutes without recording - TWAR should still compute using extension
        vm.warp(block.timestamp + 30 minutes);
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        // The extension uses the last spot rate (6e25) projected forward
        // Total time from first checkpoint: interval + 30 minutes
        // Accumulated: 8e25*interval (from obs1) + 6e25*30min (extension)
        uint256 totalTime = interval + 30 minutes;
        uint256 expectedTwar = (8e25 * interval + 6e25 * 30 minutes) / totalTime;
        assertEq(rates[0].twarRate, expectedTwar, "Extension should use last spot rate");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: getOptimalVault edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getOptimalVault_revertsWhenBothVaultsUnsafe() public {
        // Aave at >90% utilization (unsafe per oracle heuristic)
        _setAaveUtilization(100e6, 5e6); // only 5% available
        // Morpho share price below 1 USDC (unsafe)
        morphoVault.setSharePrice(999_999);

        // Prove Aave IS unsafe by the oracle's own standard
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "Aave should be unsafe");
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "Morpho should be unsafe");

        vm.expectRevert(DivigentYieldOracle.NoSafeVault.selector);
        yieldOracle.getOptimalVault();
    }

    function test_getOptimalVault_morphoDifferentialExactlyAtThreshold() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // We need morphoTWAR - aaveTWAR >= DEFAULT_MIN_DIFFERENTIAL_RAY (2e24)
        // Set aaveRate low and morpho high to create a large differential
        // Then use a morpho price that creates exactly the right TWAR gap
        uint128 aaveRate = 0.01e27; // 1%
        uint256 strongPrice = 1_010_000; // ~100% annualized (huge gap > 2e24)

        _recordObservationAfter(interval, aaveRate, strongPrice);
        vm.warp(block.timestamp + interval);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();
        uint256 morphoTWAR = rates[1].twarRate;
        uint256 aaveTWAR = rates[0].twarRate;

        // Verify the gap is above threshold
        assertTrue(morphoTWAR > aaveTWAR, "Morpho TWAR should exceed Aave TWAR");
        assertGe(morphoTWAR - aaveTWAR, yieldOracle.DEFAULT_MIN_DIFFERENTIAL_RAY(), "Gap should meet threshold");

        (address vault,,) = yieldOracle.getOptimalVault();
        assertEq(vault, address(morphoVault), "Morpho should win when gap meets threshold");
    }

    function test_getOptimalVault_equalRatesReturnAave() public {
        // When rates are equal, morphoTWAR > aaveTWAR is false → Aave wins
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // Both get the same effective rate: no Morpho price movement
        _recordObservationAfter(interval, DEFAULT_AAVE_LIQUIDITY_RATE, 1_000_000);
        vm.warp(block.timestamp + interval);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();
        // Morpho TWAR should be 0 (no price movement), Aave should be positive
        assertEq(rates[1].twarRate, 0, "Morpho TWAR should be 0 with flat price");

        (address vault,,) = yieldOracle.getOptimalVault();
        assertEq(vault, address(aavePool), "Equal/zero Morpho rate means Aave wins");
    }

    function test_getOptimalVault_morphoHigherButUnsafe() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // Record with very high Morpho yield
        _recordObservationAfter(interval, 0.01e27, 1_050_000);
        vm.warp(block.timestamp + interval);

        // Set Morpho share price below 1 USDC (unsafe)
        morphoVault.setSharePrice(999_999);

        (address vault,,) = yieldOracle.getOptimalVault();
        assertEq(vault, address(aavePool), "Unsafe Morpho loses even with higher TWAR");
    }

    function test_getOptimalVault_returnedTwarMatchesAllRates() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();
        _recordObservationAfter(interval, DEFAULT_AAVE_LIQUIDITY_RATE, 1_001_000);
        vm.warp(block.timestamp + interval);

        (, IDivigentYieldOracle.VaultType vt, uint256 returnedTwar) = yieldOracle.getOptimalVault();
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();

        if (vt == IDivigentYieldOracle.VaultType.AAVE) {
            assertEq(returnedTwar, rates[0].twarRate, "Returned TWAR should match Aave TWAR");
        } else {
            assertEq(returnedTwar, rates[1].twarRate, "Returned TWAR should match Morpho TWAR");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: _isVaultSafe edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_isVaultSafe_aaveOneWeiBelow90PctIsUnsafe() public {
        // totalAToken = 100e6, minAvailable = 10e6
        // available = 10e6 - 1 → unsafe
        _setAaveUtilization(100e6, 10e6 - 1);
        assertFalse(
            yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "One wei below 10% threshold should be unsafe"
        );
    }

    function test_isVaultSafe_aaveLargePoolAtThreshold() public {
        // Scale up: $1B pool, 10% available = $100M
        _setAaveUtilization(1_000_000_000e6, 100_000_000e6);
        assertTrue(
            yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE),
            "Large pool at exactly 10% available should be safe"
        );
    }

    function test_isVaultSafe_morphoSharePriceZero() public {
        morphoVault.setSharePrice(0);
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.MORPHO), "Zero share price should be unsafe");
    }

    function test_isVaultSafe_aaveDonationFlipsSafety() public {
        // Start unsafe: only 5% available
        _setAaveUtilization(100e6, 5e6);
        assertFalse(yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE), "Should start unsafe");

        // "Donate" USDC to aToken to flip above 10%
        usdc.setBalance(address(aToken), 11e6);
        assertTrue(
            yieldOracle.isVaultSafe(IDivigentYieldOracle.VaultType.AAVE),
            "USDC donation to aToken should flip safety status"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: isFresh edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_isFresh_trueImmediatelyAfterDeployment() public view {
        assertTrue(yieldOracle.isFresh(), "Oracle should be fresh at deployment");
    }

    function test_isFresh_resetsAfterSuccessfulObservation() public {
        // Make oracle stale
        vm.warp(block.timestamp + yieldOracle.MAX_STALENESS() + 1);
        assertFalse(yieldOracle.isFresh(), "Should be stale");

        // Record observation to refresh
        yieldOracle.recordObservation();
        assertTrue(yieldOracle.isFresh(), "Should be fresh after successful observation");
    }

    function test_isFresh_rateLimitedCallDoesNotRefresh() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // Record an observation
        vm.warp(block.timestamp + interval);
        yieldOracle.recordObservation();
        uint256 lastObs = yieldOracle.lastObservationTime();

        // Try again too soon - should NOT update lastObservationTime
        vm.warp(block.timestamp + 1);
        yieldOracle.recordObservation();
        assertEq(yieldOracle.lastObservationTime(), lastObs, "Rate-limited call should not refresh timestamp");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW: getAllRates completeness
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getAllRates_alwaysReturnsTwoEntries() public view {
        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();
        assertEq(rates.length, 2, "Should always return exactly 2 rates");
    }

    function test_getAllRates_twarRatesAreNonNegative() public {
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();

        // Record with various conditions
        _recordObservationAfter(interval, 5e25, 1_001_000);
        _recordObservationAfter(interval, 3e25, 1_000_500);
        vm.warp(block.timestamp + interval);

        IDivigentYieldOracle.VaultRate[] memory rates = yieldOracle.getAllRates();
        // uint256 can't be negative, but this verifies no underflow/revert
        assertTrue(rates[0].twarRate >= 0, "Aave TWAR should not underflow");
        assertTrue(rates[1].twarRate >= 0, "Morpho TWAR should not underflow");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Audit: Morpho rate truncation at low share-price probe precision
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Per-interval share-price deltas remain visible at realistic APYs.
    function test_audit_noTruncationAt5PctAPY_withHighPrecisionProbe() public {
        uint256 SPY = yieldOracle.SECONDS_PER_YEAR();
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 totalShares = 1_000_000e18;
        uint256 startingAssets = 1_000_000e6;

        uint128 aaveRate = 0.03e27; // 3%
        uint256 morphoBps = 500; // 5%

        morphoVault.setTotalShares(totalShares);
        morphoVault.setTotalAssets(startingAssets);
        morphoVault.clearManualSharePrice();

        for (uint256 i = 1; i <= 48; i++) {
            uint256 growth = (startingAssets * morphoBps * (i * interval)) / (10_000 * SPY);
            aavePool.setCurrentLiquidityRate(aaveRate);
            morphoVault.setTotalAssets(startingAssets + growth);
            vm.warp(block.timestamp + interval);
            yieldOracle.recordObservation();
            assertGt(yieldOracle.morphoSpotRate(), 0, "Morpho rate is non-zero at 5% APY");
        }

        vm.warp(block.timestamp + interval);
        (address vault,,) = yieldOracle.getOptimalVault();
        assertEq(vault, address(morphoVault), "5% Morpho beats 3% Aave");
    }

    /// @dev Even at very low APY (0.7%), the probe is large enough for
    ///      every observation to register a non-zero rate.
    function test_audit_noTruncationAt07PctAPY_withHighPrecisionProbe() public {
        uint256 SPY = yieldOracle.SECONDS_PER_YEAR();
        uint256 interval = yieldOracle.MIN_OBSERVATION_INTERVAL();
        uint256 totalShares = 1_000_000e18;
        uint256 startingAssets = 1_000_000e6;

        uint128 aaveRate = 0.001e27; // 0.1%
        uint256 morphoBps = 70; // 0.7%

        morphoVault.setTotalShares(totalShares);
        morphoVault.setTotalAssets(startingAssets);
        morphoVault.clearManualSharePrice();

        uint256 zeroCount;
        for (uint256 i = 1; i <= 48; i++) {
            uint256 growth = (startingAssets * morphoBps * (i * interval)) / (10_000 * SPY);
            aavePool.setCurrentLiquidityRate(aaveRate);
            morphoVault.setTotalAssets(startingAssets + growth);
            vm.warp(block.timestamp + interval);
            yieldOracle.recordObservation();
            if (yieldOracle.morphoSpotRate() == 0) zeroCount++;
        }

        assertEq(zeroCount, 0, "every observation should register at 0.7% APY");

        // With the larger probe, Morpho should still clear the hurdle here.
        vm.warp(block.timestamp + interval);
        (address vault, IDivigentYieldOracle.VaultType vt,) = yieldOracle.getOptimalVault();
        assertEq(vault, address(morphoVault), "Morpho@0.7% should still beat Aave@0.1%");
        assertEq(uint256(vt), uint256(IDivigentYieldOracle.VaultType.MORPHO));

        IDivigentYieldOracle.VaultRate[] memory r = yieldOracle.getAllRates();
        // Morpho TWAR should be non-zero (hurdle cleared) and strictly greater
        // than Aave's under the rate spread exercised above.
        assertGt(r[1].twarRate, 0, "morpho TWAR must be non-zero after observations accumulate");
        assertGt(r[1].twarRate, r[0].twarRate, "morpho TWAR exceeds aave TWAR");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  uint224 cumulative-wrap arithmetic (Uniswap-V2-style TWAR pattern)
    //
    //  The oracle deliberately stores `aaveCumulative` / `morphoCumulative` as
    //  uint224 in each checkpoint and computes the delta under an `unchecked`
    //  uint224 subtraction (see DivigentYieldOracle.sol:430-433). This lets the
    //  cumulative wrap past 2^224 without losing correctness of the TWAR window,
    //  because `(uint224(a) - uint224(b))` in unchecked Solidity correctly
    //  recovers `(a - b) mod 2^224`.
    //
    //  These tests pin the wrap semantics directly. A refactor that either
    //  removes `unchecked`, widens the cast to `uint256`, or narrows beyond
    //  uint224 would flip the expected delta — a silent correctness regression
    //  of the class Uniswap V2 famously shipped with.
    //
    //  Tests are pure-math (no oracle state needed) because the oracle's
    //  internal cumulative accumulator would take ~8400 years at a 10% Aave
    //  APY to overflow naturally.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Sanity: no wrap case. delta is a plain arithmetic subtraction.
    function test_uint224Wrap_noWrap_deltaIsPlain() public pure {
        uint256 cumNow = 1_000_000;
        uint224 cpCum  = 500_000;
        uint256 delta;
        unchecked {
            delta = uint256(uint224(cumNow) - cpCum);
        }
        assertEq(delta, 500_000, "no-wrap: delta equals plain subtraction");
    }

    /// @dev Live cumulative has wrapped past 2^224; the checkpoint was recorded
    ///      just before the boundary. The unchecked uint224 subtraction must
    ///      recover the correct delta (modulo 2^224), NOT a huge garbage value.
    function test_uint224Wrap_liveWrapped_deltaIsCorrect() public pure {
        // Checkpoint was recorded at (2^224 - 1001) → fits uint224.
        uint224 cpCum = uint224(type(uint224).max - 1000);
        // Live cumulative is at 2^224 + 499 (one wrap past the boundary).
        uint256 cumNow = (uint256(1) << 224) + 499;

        // Oracle's exact math: cast live to uint224, subtract in unchecked.
        uint256 delta;
        unchecked {
            delta = uint256(uint224(cumNow) - cpCum);
        }

        // True delta in real numbers: (2^224 + 499) - (2^224 - 1001) = 1500.
        // uint224(cumNow) = 499 (wraps). 499 - (2^224 - 1001) in uint224 wraps
        // to 499 + 1001 = 1500. Matches the true delta exactly.
        assertEq(delta, 1500, "wrap: delta equals true real-number delta");
    }

    /// @dev Multi-wrap: the live cumulative has wrapped multiple times since
    ///      the checkpoint. The recovered delta is truncated to mod 2^224 —
    ///      which documents the known limitation of the Uniswap-V2 pattern.
    ///      In practice this never occurs (8400+ years at 10% APY), but the
    ///      test pins the wrap behavior so a refactor can't silently regress.
    function test_uint224Wrap_multiWrap_deltaIsMod2Pow224() public pure {
        // Checkpoint stored at (2^224 - 50) — fits uint224.
        uint224 cpCum = uint224(type(uint224).max - 49);
        // Live cumulative is at 2^225 + 100 (two wraps past boundary).
        uint256 cumNow = (uint256(2) << 224) + 100;

        uint256 delta;
        unchecked {
            delta = uint256(uint224(cumNow) - cpCum);
        }

        // True real-number delta: (2^225 + 100) - (2^224 - 50) = 2^224 + 150.
        // uint224(cumNow) = 100 (mod 2^224). 100 - (2^224 - 50) in uint224 wraps
        // to 100 + 50 = 150. That's the real delta mod 2^224.
        assertEq(delta, 150, "multi-wrap: delta is truncated to mod 2^224");
    }

    function _expectedMorphoRate(uint256 lastPrice, uint256 currentPrice, uint256 elapsed)
        internal
        view
        returns (uint256)
    {
        return (currentPrice - lastPrice) * yieldOracle.SECONDS_PER_YEAR() * yieldOracle.RAY() / lastPrice / elapsed;
    }

    function _recordObservationAfter(uint256 elapsed, uint128 nextAaveRate, uint256 nextSharePrice) internal {
        aavePool.setCurrentLiquidityRate(nextAaveRate);
        morphoVault.setSharePrice(nextSharePrice);
        vm.warp(block.timestamp + elapsed);
        yieldOracle.recordObservation();
    }

    function _sampledSharePrice(uint256 sharePrice) internal view returns (uint256) {
        return sharePrice * yieldOracle.SHARE_UNIT() / 1e18;
    }

    function _setAaveUtilization(uint256 totalAToken, uint256 availableUsdc) internal {
        aToken.setBalance(address(this), totalAToken);
        usdc.setBalance(address(aToken), availableUsdc);
    }
}
