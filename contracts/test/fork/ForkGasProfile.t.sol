// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";

/// @title  Fork Gas Profile Tests
/// @notice Benchmarks gas costs of core operations against real Base mainnet state.
///         Run with: forge test --match-contract ForkGasProfileTest --gas-report
contract ForkGasProfileTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_gas_firstDeposit() public {
        _deposit(alice, 50_000e6);
    }

    function testFork_gas_secondDeposit() public {
        _deposit(alice, 50_000e6);
        _deposit(bob, 30_000e6);
    }

    function testFork_gas_fullWithdraw() public {
        _deposit(alice, 50_000e6);
        _withdrawAll(alice);
    }

    function testFork_gas_partialWithdraw() public {
        _deposit(alice, 50_000e6);
        uint256 half = dvUsdc.balanceOf(alice) / 2;
        _withdraw(alice, half);
    }

    function testFork_gas_withdrawWithYield() public {
        _deposit(alice, 50_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 302_400);
        _seedOracle();
        _withdrawAll(alice);
    }

    function testFork_gas_recordObservation() public {
        vm.warp(block.timestamp + 6 minutes);
        oracle.recordObservation();
    }

    function testFork_gas_pricePerShare() public view {
        router.pricePerShare();
    }

    function testFork_gas_totalVaultAssets() public view {
        router.totalVaultAssets();
    }

    function testFork_gas_getPosition() public {
        _deposit(alice, 50_000e6);
        router.getPosition(alice);
    }
}
