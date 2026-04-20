// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";

/// @title  Fork Gas Profile Tests
/// @notice Benchmarks gas costs of core operations against real Base mainnet
///         state AND enforces upper-bound budgets that catch regressions.
///
///         The budgets below are generous ceilings sized to current measured
///         gas plus ~40% headroom. They catch a material regression (e.g. a
///         refactor that doubles a hot-path's cost) without flagging routine
///         compiler / OZ-version drift.
///
///         To re-baseline: run `forge test --match-contract ForkGasProfileTest
///         --gas-report`, take the reported gas for each op, and update the
///         budget constants to `measured × 1.4` (rounded up to a readable
///         number).
///
///         Run with: forge test --match-contract ForkGasProfileTest --gas-report
contract ForkGasProfileTest is ForkBase {
    // ── Budgets (upper-bound regression detection) ───────────────────────────
    // Mutating ops include external calls to Aave/Morpho and state writes.
    uint256 internal constant GAS_BUDGET_FIRST_DEPOSIT       = 900_000;
    uint256 internal constant GAS_BUDGET_SECOND_DEPOSIT      = 700_000;
    uint256 internal constant GAS_BUDGET_FULL_WITHDRAW       = 900_000;
    uint256 internal constant GAS_BUDGET_PARTIAL_WITHDRAW    = 900_000;
    uint256 internal constant GAS_BUDGET_WITHDRAW_WITH_YIELD = 1_000_000;
    uint256 internal constant GAS_BUDGET_RECORD_OBSERVATION  = 400_000;

    // View calls — should be cheap regardless of TVL.
    uint256 internal constant GAS_BUDGET_PRICE_PER_SHARE     = 150_000;
    uint256 internal constant GAS_BUDGET_TOTAL_VAULT_ASSETS  = 150_000;
    uint256 internal constant GAS_BUDGET_GET_POSITION        = 150_000;

    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_gas_firstDeposit() public {
        uint256 g0 = gasleft();
        _deposit(alice, 50_000e6);
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_FIRST_DEPOSIT, "first deposit gas regression");
    }

    function testFork_gas_secondDeposit() public {
        _deposit(alice, 50_000e6);
        uint256 g0 = gasleft();
        _deposit(bob, 30_000e6);
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_SECOND_DEPOSIT, "second deposit gas regression");
    }

    function testFork_gas_fullWithdraw() public {
        _deposit(alice, 50_000e6);
        uint256 g0 = gasleft();
        _withdrawAll(alice);
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_FULL_WITHDRAW, "full withdraw gas regression");
    }

    function testFork_gas_partialWithdraw() public {
        _deposit(alice, 50_000e6);
        uint256 half = dvUsdc.balanceOf(alice) / 2;
        uint256 g0 = gasleft();
        _withdraw(alice, half);
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_PARTIAL_WITHDRAW, "partial withdraw gas regression");
    }

    function testFork_gas_withdrawWithYield() public {
        _deposit(alice, 50_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 302_400);
        _seedOracle();
        uint256 g0 = gasleft();
        _withdrawAll(alice);
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_WITHDRAW_WITH_YIELD, "withdraw-with-yield gas regression");
    }

    function testFork_gas_recordObservation() public {
        vm.warp(block.timestamp + 6 minutes);
        uint256 g0 = gasleft();
        oracle.recordObservation();
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_RECORD_OBSERVATION, "recordObservation gas regression");
    }

    function testFork_gas_pricePerShare() public view {
        uint256 g0 = gasleft();
        router.pricePerShare();
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_PRICE_PER_SHARE, "pricePerShare gas regression");
    }

    function testFork_gas_totalVaultAssets() public view {
        uint256 g0 = gasleft();
        router.totalVaultAssets();
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_TOTAL_VAULT_ASSETS, "totalVaultAssets gas regression");
    }

    function testFork_gas_getPosition() public {
        _deposit(alice, 50_000e6);
        uint256 g0 = gasleft();
        router.getPosition(alice);
        uint256 used = g0 - gasleft();
        assertLt(used, GAS_BUDGET_GET_POSITION, "getPosition gas regression");
    }
}
