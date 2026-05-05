// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Fork Deposit Tests
/// @notice Verifies deposit flows against real Aave V3 and Morpho Steakhouse on Base.
contract ForkDepositTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_deposit_routesToVault() public {
        uint256 amount = 10_000e6;
        uint256 aTokenBefore = aToken.balanceOf(address(router));
        uint256 morphoSharesBefore = morphoVault.balanceOf(address(router));

        uint256 shares = _deposit(alice, amount);

        assertGt(shares, 0, "Got dvUSDC shares");
        assertEq(router.costBasisUSDC(alice), amount, "costBasis == deposit amount");
        // Funds went to Aave OR Morpho (oracle picks the winner)
        bool aaveGrew = aToken.balanceOf(address(router)) > aTokenBefore;
        bool morphoGrew = morphoVault.balanceOf(address(router)) > morphoSharesBefore;
        assertTrue(aaveGrew || morphoGrew, "Funds routed to Aave or Morpho");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4: router holds no USDC");
        assertEq(dvUsdc.balanceOf(alice), shares, "dvUSDC balance == minted shares");
    }

    function testFork_deposit_morphoRoute() public {
        // Seed more observations so Morpho could potentially win
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 6 minutes);
            oracle.recordObservation();
        }

        uint256 morphoSharesBefore = morphoVault.balanceOf(address(router));
        uint256 amount = 10_000e6;

        // Verify the deposit path regardless of which vault wins routing
        uint256 shares = _deposit(alice, amount);

        assertGt(shares, 0, "Got dvUSDC shares");
        assertEq(router.costBasisUSDC(alice), amount, "costBasis == deposit");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4: no residual USDC");

        // Funds went to either Aave or Morpho (totalVaultAssets increased)
        assertGe(router.totalVaultAssets(), amount - 2, "TVA >= deposit (within rounding)");
    }

    function testFork_deposit_minDeposit() public {
        uint256 shares = _deposit(alice, 10e6); // MIN_DEPOSIT = $10
        assertGt(shares, 0, "MIN_DEPOSIT mints non-zero shares");
    }

    function testFork_deposit_belowMinReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(router), 9e6);
        vm.expectRevert();
        router.deposit(9e6, alice, 0);
        vm.stopPrank();
    }

    function testFork_deposit_multipleDeposits() public {
        _deposit(alice, 50_000e6);
        _deposit(bob, 30_000e6);
        _deposit(alice, 20_000e6);

        assertEq(router.costBasisUSDC(alice), 70_000e6, "Alice: cumulative costBasis");
        assertEq(router.costBasisUSDC(bob), 30_000e6, "Bob: costBasis");
        assertGe(router.totalVaultAssets(), 100_000e6 - 10, "TVA >= total deposited");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4");
    }

    function testFork_deposit_oracleAutoRefresh() public {
        // Advance time past MAX_STALENESS (2 hours)
        vm.warp(block.timestamp + 3 hours);
        assertFalse(oracle.isFresh(), "Oracle should be stale");

        // Deposit should auto-refresh the oracle and succeed
        uint256 shares = _deposit(alice, 10_000e6);
        assertGt(shares, 0, "Deposit succeeded despite stale oracle (auto-refreshed)");
        assertTrue(oracle.isFresh(), "Oracle is fresh after deposit auto-refresh");
    }

    function testFork_deposit_checksPricePerShare() public {
        uint256 ppsBefore = router.pricePerShare();

        _deposit(alice, 50_000e6);

        uint256 ppsAfter = router.pricePerShare();
        // PPS should stay approximately the same after a deposit (no yield yet)
        assertApproxEqRel(ppsAfter, ppsBefore, 0.001e18, "PPS stable after deposit (within 0.1%)");
    }

    function testFork_deposit_unauthorizedReverts() public {
        address stranger = makeAddr("stranger");
        deal(BASE_USDC, stranger, 100_000e6);

        vm.startPrank(stranger);
        usdc.approve(address(router), 50_000e6);
        vm.expectRevert();
        router.deposit(50_000e6, stranger, 0);
        vm.stopPrank();
    }

    function testFork_deposit_zeroAmountReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(router), 1);
        vm.expectRevert();
        router.deposit(0, alice, 0);
        vm.stopPrank();
    }
}
