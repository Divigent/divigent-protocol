// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "../TestBase.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

/// @title SilentFailureTest
/// @notice Tests for slither findings F-4: what happens when Aave or Morpho
///         silently return 0 instead of reverting on withdraw/deposit.
///
///         These test the EXACT scenarios flagged by the slither report:
///         1. AAVE_POOL.withdraw() returns 0 without reverting → user's
///            dvUSDC is burned but no USDC is delivered.
///         2. MORPHO_VAULT.withdraw() returns 0 without reverting → same.
///         3. MORPHO_VAULT.deposit() returns 0 shares without reverting →
///            dvUSDC is minted but backed by nothing.
///
/// @dev    Uses modified mocks that can toggle "silent failure" mode.
///         In real Aave V3 and MetaMorpho, these functions revert on failure.
///         These tests prove that IF they didn't revert, the router would
///         be vulnerable - confirming the slither finding is a genuine
///         assumption dependency, not a false positive.
contract SilentFailureTest is TestBase {
    uint256 constant DEPOSIT = 1_000e6;

    function setUp() public override {
        super.setUp();
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    // ─── Test 1: Aave withdraw returns 0, no revert ────────────────────────
    //
    // Scenario: user withdraws, Aave's withdraw() silently returns 0
    // (doesn't transfer USDC, doesn't revert). The router burns dvUSDC
    // and measures actualGross = USDC.balanceOf(this). If Aave returned
    // nothing, actualGross = 0 (or just the Morpho leg). The user gets
    // less USDC than expected, potentially 0.

    function test_aaveWithdrawSilentZero_nowReverts() public {
        aavePool.setSilentFailWithdraw(true);

        uint256 shares = dvUsdc.balanceOf(alice);

        vm.prank(alice);
        // AFTER FIX: the router checks actualGross > 0 and reverts with
        // InsufficientVaultLiquidity when vault redemptions return nothing.
        // dvUSDC is NOT burned, user funds are safe.
        vm.expectPartialRevert(IDivigentVaultRouter.InsufficientVaultLiquidity.selector);
        router.withdraw(shares, alice, 0);

        // Verify dvUSDC was NOT burned (tx reverted, state rolled back)
        assertEq(dvUsdc.balanceOf(alice), shares, "dvUSDC should NOT be burned on revert");
    }

    // ─── Test 2: Morpho withdraw returns 0 shares, no revert ───────────────
    //
    // Same scenario but for Morpho leg.

    function test_morphoWithdrawSilentZero_userLosesFunds() public {
        // First, do a deposit that routes to Morpho
        // (need oracle to pick Morpho - set higher rate)
        _routeToMorpho();

        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Enable silent failure on Morpho
        morphoVault.setSilentFailWithdraw(true);

        uint256 shares = dvUsdc.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);

        uint256 received = usdc.balanceOf(alice) - aliceUsdcBefore;

        // With silent fail on Morpho, only Aave leg delivers
        assertLt(received, DEPOSIT * 2, "User should receive less than full position");
    }

    // ─── Test 3: Morpho deposit returns 0 shares, no revert ────────────────
    //
    // Scenario: router deposits to Morpho, vault accepts USDC but returns
    // 0 shares. dvUSDC is minted to user, costBasis recorded, but the
    // router holds 0 Morpho shares - the position is backed by nothing.

    function test_morphoDepositSilentZero_dvUsdcBackedByNothing() public {
        _routeToMorpho();

        morphoVault.setSilentFailDeposit(true);

        uint256 dvUsdcBefore = dvUsdc.totalSupply();

        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        uint256 minted = router.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // dvUSDC was minted
        assertGt(minted, 0, "dvUSDC should be minted");
        assertGt(dvUsdc.totalSupply(), dvUsdcBefore, "Total dvUSDC supply increased");

        // Morpho returned 0 shares despite accepting USDC
        uint256 morphoShares = morphoVault.balanceOf(address(router));
        assertEq(morphoShares, 0, "Router has 0 Morpho shares");

        assertEq(router.costBasisUSDC(alice), DEPOSIT * 2, "Cost basis increased (from setUp + this deposit)");
    }

    // ─── Test 4: Positive control (mocks revert without silent-fail flag) ──
    //
    // Without the silent failure flag enabled, mocks revert on insufficient
    // liquidity. This validates the mock setup, not the router.

    function test_aaveWithdraw_revertsOnInsufficientLiquidity() public {
        // Drain Aave liquidity
        uint256 aaveBalance = usdc.balanceOf(address(aToken));
        usdc.setBalance(address(aToken), 0);

        uint256 shares = dvUsdc.balanceOf(alice);

        vm.prank(alice);
        // Aave USDC liquidity drained → aaveCap = 0, morphoCap = 0 → combined
        // capacity is less than the gross target → InsufficientVaultLiquidity.
        vm.expectPartialRevert(IDivigentVaultRouter.InsufficientVaultLiquidity.selector);
        router.withdraw(shares, alice, 0);
    }

    function test_morphoDeposit_maxDepositZero_doesNotRevert() public {
        _routeToMorpho();

        // Set Morpho max deposit to 0 — the router's _canAllocate checks
        // maxDeposit but routes to the alternate vault if the primary can't
        // accept. This is correct behaviour (not a bug) — the router falls
        // back to Aave when Morpho's maxDeposit is 0.
        morphoVault.setMaxDeposit(0);

        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        // Should NOT revert — routes to Aave instead
        uint256 minted = router.deposit(DEPOSIT, alice);
        vm.stopPrank();

        assertGt(minted, 0, "Deposit should succeed via Aave fallback");
    }

    // ─── Helper ─────────────────────────────────────────────────────────────

    function _routeToMorpho() internal {
        // Bump Morpho share price + record observations so oracle picks Morpho
        morphoVault.setSharePrice(1_050_000); // 5% above par
        vm.warp(block.timestamp + 301); // past MIN_OBSERVATION_INTERVAL
        yieldOracle.recordObservation();
        vm.warp(block.timestamp + 301);
        morphoVault.setSharePrice(1_100_000); // another jump
        yieldOracle.recordObservation();
    }
}
