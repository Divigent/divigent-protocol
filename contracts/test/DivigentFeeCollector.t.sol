// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm, stdError} from "forge-std/Test.sol";

import {DivigentFeeCollector} from "../src/DivigentFeeCollector.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests for DivigentFeeCollector — constructor guards, fee math, collectFee.
contract DivigentFeeCollectorTest is Test {
    DivigentFeeCollector internal collector;

    MockERC20 internal usdc;
    address internal treasury = makeAddr("treasury");
    address internal wallet = makeAddr("wallet");

    /// @dev This test contract is deployed as `address(this)` and used as VAULT_ROUTER.
    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        collector = new DivigentFeeCollector(address(usdc), treasury, address(this));
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_revertsWhenUsdcIsZero() public {
        vm.expectRevert(DivigentFeeCollector.ZeroUsdc.selector);
        new DivigentFeeCollector(address(0), treasury, address(this));
    }

    function test_constructor_revertsWhenTreasuryIsZero() public {
        vm.expectRevert(DivigentFeeCollector.ZeroTreasury.selector);
        new DivigentFeeCollector(address(usdc), address(0), address(this));
    }

    function test_constructor_revertsWhenRouterIsZero() public {
        vm.expectRevert(DivigentFeeCollector.ZeroRouter.selector);
        new DivigentFeeCollector(address(usdc), treasury, address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(collector.USDC()), address(usdc));
        assertEq(collector.TREASURY(), treasury);
        assertEq(collector.VAULT_ROUTER(), address(this));
        assertEq(collector.FEE_BPS(), 1_000);
        assertEq(collector.BPS_DENOMINATOR(), 10_000);
    }

    // ── calculateFee (pure) ───────────────────────────────────────────────────

    function test_calculateFee_zeroYield_returnsZero() public view {
        assertEq(collector.calculateFee(0), 0);
    }

    function test_calculateFee_roundsDownToNearestMicroUsdc() public view {
        // 1 wei yield → 1000/10000 = 0
        assertEq(collector.calculateFee(1), 0);
        // 9 → still 0
        assertEq(collector.calculateFee(9), 0);
        // 10 → 10000/10000 = 1
        assertEq(collector.calculateFee(10), 1);
    }

    function test_calculateFee_tenPercentExamples() public view {
        assertEq(collector.calculateFee(100e6), 10e6);
        assertEq(collector.calculateFee(1_000_000), 100_000);
    }

    function testFuzz_calculateFee_neverExceedsTenPercent(uint128 yieldRaw) public view {
        uint256 y = uint256(yieldRaw);
        uint256 fee = collector.calculateFee(y);
        assertLe(fee * collector.BPS_DENOMINATOR(), y * collector.FEE_BPS());
        assertLe(fee, y);
    }

    function testFuzz_calculateFee_matchesFloorProduct(uint128 yieldRaw) public view {
        uint256 y = uint256(yieldRaw);
        uint256 expected = (y * collector.FEE_BPS()) / collector.BPS_DENOMINATOR();
        assertEq(collector.calculateFee(y), expected);
    }

    // ── collectFee access control ─────────────────────────────────────────────

    function test_collectFee_revertsWhenCallerIsNotVaultRouter() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert(abi.encodeWithSelector(DivigentFeeCollector.OnlyVaultRouter.selector, attacker));
        vm.prank(attacker);
        collector.collectFee(wallet, 100e6);
    }

    // ── collectFee yield == 0 ─────────────────────────────────────────────────

    function test_collectFee_zeroYield_returnsZeroWithoutTransfer() public {
        uint256 fee = collector.collectFee(wallet, 0);
        assertEq(fee, 0);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(this)), 0);
    }

    // ── collectFee yield > 0 but fee floors to 0 ──────────────────────────────

    function test_collectFee_positiveYieldButFlooredFee_returnsZeroWithoutTransfer() public {
        // yield 5 → fee = 5000/10000 = 0
        uint256 fee = collector.collectFee(wallet, 5);
        assertEq(fee, 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ── collectFee happy path ─────────────────────────────────────────────────

    function test_collectFee_pullsFromRouterAndCreditsTreasury_emitsEvent() public {
        uint256 yieldEarned = 1_000e6;
        uint256 expectedFee = 100e6;

        usdc.mint(address(this), expectedFee);
        usdc.approve(address(collector), type(uint256).max);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.expectEmit(true, true, true, true);
        emit DivigentFeeCollector.FeeCollected(wallet, yieldEarned, expectedFee);

        uint256 returned = collector.collectFee(wallet, yieldEarned);

        assertEq(returned, expectedFee);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + expectedFee);
        assertEq(usdc.balanceOf(address(collector)), 0);
    }

    function test_collectFee_routerBalanceCanExceedExactFee_pullsOnlyFee() public {
        uint256 yieldEarned = 100e6;
        uint256 expectedFee = 10e6;

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(collector), type(uint256).max);

        uint256 selfBefore = usdc.balanceOf(address(this));
        collector.collectFee(wallet, yieldEarned);

        assertEq(usdc.balanceOf(address(this)), selfBefore - expectedFee);
        assertEq(usdc.balanceOf(treasury), expectedFee);
    }

    function test_collectFee_sequentialCalls_accumulateTreasury() public {
        usdc.mint(address(this), 500e6);
        usdc.approve(address(collector), type(uint256).max);

        collector.collectFee(wallet, 100e6);
        collector.collectFee(makeAddr("other"), 200e6);

        assertEq(usdc.balanceOf(treasury), 10e6 + 20e6);
        assertEq(usdc.balanceOf(address(collector)), 0);
    }

    function test_collectFee_revertsWhenRouterInsufficientBalance() public {
        // No USDC on router, approval irrelevant. MockERC20.transferFrom decrements
        // balanceOf[from] with checked math -> arithmetic underflow panic (0x11).
        usdc.approve(address(collector), type(uint256).max);

        vm.expectRevert(stdError.arithmeticError);
        collector.collectFee(wallet, 100e6);
    }

    function test_collectFee_revertsWhenRouterInsufficientAllowance() public {
        // Router holds USDC but allowance is 0 -> allowance -= amount underflows
        // on the checked-math path -> arithmetic panic (0x11).
        usdc.mint(address(this), 100e6);
        usdc.approve(address(collector), 0);

        vm.expectRevert(stdError.arithmeticError);
        collector.collectFee(wallet, 100e6);
    }

    // ── NEW: edge cases and invariants ──────────────────────────────────────

    function test_calculateFee_maxUint128_doesNotOverflow() public view {
        uint256 maxYield = type(uint128).max;
        uint256 fee = collector.calculateFee(maxYield);
        // FEE_BPS = 1000, BPS_DENOMINATOR = 10000
        // fee = maxYield * 1000 / 10000 = maxYield / 10
        assertEq(fee, maxYield / 10, "Max uint128 yield should compute without overflow");
        assertLe(fee, maxYield, "Fee should never exceed yield");
    }

    // NOTE: `test_calculateFee_isDeterministic` was removed — calling a
    // `pure` function twice and comparing results tests the EVM, not the
    // contract. Integration-level fee correctness (routed through the
    // real router withdraw path, against realised vault yield) is covered
    // by `test/integration/fuzz/PropertyFuzz.t.sol:test_fee_fuzz_exactlyTenPercentOfRealisedYield`
    // — the canonical "fee matches realised yield end-to-end" test.

    function test_collectFee_returnMatchesCalculateFee() public {
        uint256 yieldEarned = 777e6;
        uint256 expectedFee = collector.calculateFee(yieldEarned);

        usdc.mint(address(this), expectedFee);
        usdc.approve(address(collector), type(uint256).max);

        uint256 returned = collector.collectFee(wallet, yieldEarned);
        assertEq(returned, expectedFee, "collectFee return should match calculateFee");
    }

    function test_collectFee_collectorHoldsZeroUsdcAfterCall() public {
        usdc.mint(address(this), 100e6);
        usdc.approve(address(collector), type(uint256).max);

        collector.collectFee(wallet, 1_000e6);

        assertEq(usdc.balanceOf(address(collector)), 0, "Collector should hold zero USDC after collectFee");
    }

    function test_collectFee_walletAddressZero_stillWorks() public {
        usdc.mint(address(this), 10e6);
        usdc.approve(address(collector), type(uint256).max);

        // wallet param is only for event indexing, not functional
        uint256 fee = collector.collectFee(address(0), 100e6);
        assertEq(fee, 10e6, "Zero wallet address should still compute fee");
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    function test_collectFee_doesNotEmitEventWhenYieldIsZero() public {
        vm.recordLogs();
        collector.collectFee(wallet, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "No event should be emitted for zero yield");
    }

    function test_collectFee_doesNotEmitEventWhenFeeFloorsToZero() public {
        vm.recordLogs();
        collector.collectFee(wallet, 5); // fee = 5 * 1000 / 10000 = 0

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "No event should be emitted when floored fee is zero");
    }

    /// @dev SafeERC20 should surface transferFrom failure — mock reverts on underflow if needed.
    function test_collectFee_exactAllowance_succeeds() public {
        uint256 yieldEarned = 50e6;
        uint256 feeNeeded = 5e6;

        usdc.mint(address(this), feeNeeded);
        usdc.approve(address(collector), feeNeeded);

        uint256 ret = collector.collectFee(wallet, yieldEarned);
        assertEq(ret, feeNeeded);
        assertEq(usdc.balanceOf(treasury), feeNeeded);
    }
}
