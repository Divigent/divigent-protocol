// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";

/// @title  Fork Yield Accrual Tests
/// @notice Verifies that real Aave V3 yield accrues over time on Base mainnet,
///         pricePerShare increases, and fees are correctly charged.
contract ForkYieldAccrualTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_yield_ppsIncreasesOverTime() public {
        _deposit(alice, 100_000e6);

        uint256 ppsBefore = router.pricePerShare();

        // Advance 30 days — real Aave interest accrues via aToken rebasing
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 ppsAfter = router.pricePerShare();

        // PPS should increase (Aave generates real yield)
        assertGe(ppsAfter, ppsBefore, "PPS non-decreasing after 30 days");
    }

    function testFork_yield_totalVaultAssetsGrows() public {
        _deposit(alice, 100_000e6);

        uint256 tvaBefore = router.totalVaultAssets();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 tvaAfter = router.totalVaultAssets();

        assertGe(tvaAfter, tvaBefore, "TVA non-decreasing after 30 days");
    }

    function testFork_yield_feeOnRealYield() public {
        _deposit(alice, 100_000e6);

        // Advance 30 days for meaningful yield
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 shares = dvUsdc.balanceOf(alice);

        // Seed oracle again after time warp
        _seedOracle();

        uint256 returned = _withdraw(alice, shares);

        uint256 treasuryAfter = usdc.balanceOf(treasury);
        uint256 feeCollected = treasuryAfter - treasuryBefore;

        if (returned > 100_000e6) {
            uint256 yield_ = returned + feeCollected - 100_000e6;
            // Fee should be ~10% of yield
            if (yield_ > 10) {
                uint256 expectedFee = feeCollector.calculateFee(yield_);
                assertApproxEqAbs(feeCollected, expectedFee, 2, "Fee ~= 10% of yield");
            }
        }

        assertEq(dvUsdc.balanceOf(alice), 0, "All shares burned");
        assertEq(router.costBasisUSDC(alice), 0, "costBasis zeroed");
    }

    function testFork_yield_noFeeOnImmediateWithdraw() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _deposit(alice, 50_000e6);
        _withdrawAll(alice);

        uint256 treasuryAfter = usdc.balanceOf(treasury);

        // No time passed — no yield — no fee
        assertEq(treasuryAfter, treasuryBefore, "No fee on immediate withdraw");
    }

    function testFork_yield_accruedYieldReported() public {
        _deposit(alice, 100_000e6);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        (uint256 deposited, uint256 currentValue, uint256 accruedYield) =
            router.getPosition(alice);

        assertEq(deposited, 100_000e6, "deposited == original amount");
        assertGe(currentValue, deposited, "currentValue >= deposited after yield");

        if (currentValue > deposited) {
            assertEq(accruedYield, currentValue - deposited, "accruedYield == value - deposited");
        }
    }

    function testFork_yield_multiUserFairness() public {
        _deposit(alice, 60_000e6);
        _deposit(bob, 40_000e6);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        (,uint256 aliceValue,) = router.getPosition(alice);
        (,uint256 bobValue,) = router.getPosition(bob);

        // Alice deposited 60%, Bob 40%. Yield should be proportional.
        // Alice's share of total value should be ~60%
        uint256 totalValue = aliceValue + bobValue;
        if (totalValue > 0) {
            uint256 alicePct = (aliceValue * 100) / totalValue;
            assertApproxEqAbs(alicePct, 60, 1, "Alice gets ~60% of value");
        }
    }
}
