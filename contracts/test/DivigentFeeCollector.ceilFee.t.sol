// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DivigentFeeCollector} from "../src/DivigentFeeCollector.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title  Fee ceiling rounding
/// @notice Pins that fractional protocol fees round in the treasury's favour
///         instead of silently leaking the remainder to the withdrawing user.
contract DivigentFeeCollectorCeilFeeTest is Test {
    DivigentFeeCollector internal collector;
    MockERC20 internal usdc;

    address internal treasury = makeAddr("treasury");
    address internal wallet = makeAddr("wallet");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        collector = new DivigentFeeCollector(address(usdc), treasury, address(this));
    }

    function test_calculateFee_zeroYieldStillReturnsZero() public view {
        assertEq(collector.calculateFee(0), 0);
    }

    function test_calculateFee_oneWeiYieldReturnsOneWeiFee() public view {
        assertEq(collector.calculateFee(1), 1);
    }

    function test_calculateFee_divisibleYieldUnchanged() public view {
        assertEq(collector.calculateFee(100e6), 10e6);
        assertEq(collector.calculateFee(10), 1);
    }

    function test_calculateFee_nonDivisibleYieldRoundsUp() public view {
        assertEq(collector.calculateFee(11), 2);
        assertEq(collector.calculateFee(99), 10);
    }

    function testFuzz_calculateFee_matchesCeilProduct(uint128 yieldRaw) public view {
        uint256 y = uint256(yieldRaw);
        uint256 expected =
            (y * collector.FEE_BPS() + collector.BPS_DENOMINATOR() - 1) / collector.BPS_DENOMINATOR();

        assertEq(collector.calculateFee(y), expected);
    }

    function testFuzz_calculateFee_neverExceedsCeilTenPercent(uint128 yieldRaw) public view {
        uint256 y = uint256(yieldRaw);
        uint256 fee = collector.calculateFee(y);

        assertLe(
            fee * collector.BPS_DENOMINATOR(),
            y * collector.FEE_BPS() + collector.BPS_DENOMINATOR() - 1
        );
        assertLe(fee, y);
    }

    function test_calculateFee_protocolNeverUnderpaid() public view {
        uint256[9] memory samples = [uint256(1), 9, 10, 11, 99, 100, 999, 1_000, 12_345];

        for (uint256 i = 0; i < samples.length; i++) {
            uint256 y = samples[i];
            uint256 floorFee = (y * collector.FEE_BPS()) / collector.BPS_DENOMINATOR();
            uint256 fee = collector.calculateFee(y);

            assertGe(fee, floorFee, "protocol should never receive less than floor fee");
            assertLe(fee, floorFee + 1, "ceiling fee should be at most one wei above floor");
        }
    }

    function test_collectFee_endToEndTreasuryReceivesCeilFee() public {
        uint256 yieldEarned = 11;
        uint256 expectedFee = 2;

        usdc.mint(address(this), expectedFee);
        usdc.approve(address(collector), type(uint256).max);

        vm.expectEmit(true, false, false, true);
        emit DivigentFeeCollector.FeeCollected(wallet, yieldEarned, expectedFee);

        uint256 returned = collector.collectFee(wallet, yieldEarned);

        assertEq(returned, expectedFee);
        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(address(collector)), 0);
    }
}
