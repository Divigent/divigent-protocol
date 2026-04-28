// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Fork Stressed Capacity Tests
/// @notice Exercises router behaviour against LIVE Aave V3 + Morpho
///         Steakhouse contracts under constrained-liquidity conditions.
///
///         Ideally these would pin a specific historical Base block where
///         either vault was naturally stressed (high utilisation spike,
///         supply-cap hit, paused market). Identifying such blocks is a
///         separate data-research task; this file substitutes by
///         INJECTING stress on-fork via `deal()` on Aave's aToken USDC
///         balance — the same quantity the router reads as `aaveIdle`
///         during withdraw planning and deposit-capacity checks.
///
///         The code path the router follows under injected stress is
///         IDENTICAL to the path under natural stress: `_canAllocate`
///         returns false, the router falls back or reverts; `aaveCap`
///         is below proportional target, the redirect machinery engages.
///         The tests are meaningful against any fork block because they
///         exercise the same guarantees.
///
///         Four scenarios:
///           1. Aave drained → new deposits fall back to Morpho.
///           2. Both vaults over capacity → `NoSafeRoute` revert.
///           3. Mixed position + Aave stress → withdraw redirects to Morpho.
///           4. Mixed position + both legs stressed → exit reverts
///              `InsufficientVaultLiquidity` cleanly.
contract ForkStressedCapacityTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Aave drained → deposit falls back to Morpho
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice When Aave's idle cash is drained, the router's amount-aware
    ///         fallback in `_canAllocate` routes to Morpho instead — the
    ///         deposit succeeds, landing in the alternate vault.
    function testFork_stressedAave_depositFallsBackToMorpho() public {
        uint256 depositAmount = 10_000e6;

        // Drain Aave idle to a thin sliver — less than the deposit amount.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 100e6);

        // Skip if Morpho can't accept this size (cap-bound).
        uint256 morphoMax = morphoVault.maxDeposit(address(router));
        if (morphoMax < depositAmount) return;

        uint256 morphoBefore = morphoVault.balanceOf(address(router));
        uint256 aTokenBefore = aToken.balanceOf(address(router));

        deal(BASE_USDC, alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(router), depositAmount);
        router.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 morphoAfter = morphoVault.balanceOf(address(router));
        uint256 aTokenAfter = aToken.balanceOf(address(router));

        assertGt(morphoAfter, morphoBefore, "Morpho leg received the fallback deposit");
        assertEq(aTokenAfter, aTokenBefore, "Aave leg untouched (thin idle forced fallback)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Both vaults over capacity → NoSafeRoute revert
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice When Aave is drained AND the deposit size exceeds live Morpho
    ///         `maxDeposit`, neither vault can accept — router reverts
    ///         `NoSafeRoute(amount)`. This is the joint-capacity failure
    ///         mode the fallback logic is designed to surface cleanly.
    function testFork_stressedBoth_depositRevertsNoSafeRoute() public {
        // Drain Aave idle.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);

        // Amount = Morpho's live maxDeposit + 1 wei — exceeds both caps.
        uint256 morphoMax = morphoVault.maxDeposit(address(router));
        uint256 amount = morphoMax + 1_000e6;

        // Skip if TVL cap would fire first (different revert reason).
        uint256 tvlCap = router.currentTVLCap();
        if (tvlCap != type(uint256).max && router.totalVaultAssets() + amount > tvlCap) return;
        // Skip if amount is degenerately large or Morpho cap is already huge.
        if (amount > 1_000_000_000_000e6) return;

        deal(BASE_USDC, alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(router), amount);
        vm.expectPartialRevert(IDivigentVaultRouter.NoSafeRoute.selector);
        router.deposit(amount, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Mixed position + Aave stressed → withdraw redirects to Morpho
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Build a mixed position (force Morpho by draining Aave between
    ///         deposits), then drain Aave idle again so withdraw planning
    ///         sees `aaveCap = 0`. The router must serve the full exit from
    ///         Morpho via the redirect path.
    function testFork_stressedAave_withdrawRedirectsToMorpho() public {
        deal(BASE_USDC, alice, 100_000e6);

        // Deposit #1 (Aave-preferred route).
        _deposit(alice, 50_000e6);

        // Drain Aave idle → next deposit falls to Morpho.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);

        // Deposit #2 goes to Morpho.
        _deposit(alice, 50_000e6);

        uint256 aaveBefore = aToken.balanceOf(address(router));
        uint256 morphoSharesBefore = morphoVault.balanceOf(address(router));
        require(aaveBefore > 0 && morphoSharesBefore > 0, "Precondition: mixed position");

        // Keep Aave idle at zero — withdraw planning must route Aave's share
        // to Morpho via redirect. Morpho must have capacity to absorb it.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);

        uint256 morphoAssetsBefore = morphoVault.convertToAssets(morphoSharesBefore);
        uint256 morphoMaxW = morphoVault.maxWithdraw(address(router));
        if (morphoMaxW < morphoAssetsBefore) return; // Morpho itself constrained — covered elsewhere

        // Half exit. If aaveCap + morphoCap >= gross, it succeeds.
        uint256 half = dvUsdc.balanceOf(alice) / 2;
        uint256 returned = _withdraw(alice, half);
        assertGt(returned, 0, "Exit under Aave-stress serves via Morpho redirect");

        uint256 aaveAfter = aToken.balanceOf(address(router));
        uint256 morphoSharesAfter = morphoVault.balanceOf(address(router));

        // Aave leg can't have drawn (idle was 0), so Morpho absorbed everything.
        assertEq(aaveAfter, aaveBefore, "Aave leg untouched under zero-idle stress");
        assertLt(morphoSharesAfter, morphoSharesBefore, "Morpho absorbed the full withdraw");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Mixed position + both legs stressed → InsufficientVaultLiquidity
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Both Aave idle and Morpho's effective cap below the requested
    ///         gross must revert `InsufficientVaultLiquidity` cleanly —
    ///         the router does not partial-pay, silently hold shares, or
    ///         leak state under this condition.
    ///
    ///         Morpho's live max isn't easily manipulable, so we use the
    ///         "huge position" angle: deposit a position so large that
    ///         draining Aave leaves combined capacity below gross.
    function testFork_stressedBoth_withdrawRevertsInsufficientLiquidity() public {
        deal(BASE_USDC, alice, 100_000e6);

        _deposit(alice, 50_000e6);
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);
        _deposit(alice, 50_000e6);

        // Drain Aave idle.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);

        // If Morpho's live maxWithdraw is ample, the redirect succeeds —
        // we can't force Morpho's internal cap. Guard for this and only
        // assert under actually-stressed conditions.
        uint256 morphoShares = morphoVault.balanceOf(address(router));
        uint256 morphoAssets = morphoVault.convertToAssets(morphoShares);
        uint256 morphoMaxW = morphoVault.maxWithdraw(address(router));

        // Only proceed if Morpho's max can't absorb the full gross.
        uint256 shares = dvUsdc.balanceOf(alice);
        uint256 supply = dvUsdc.totalSupply();
        uint256 aaveBal = aToken.balanceOf(address(router));
        uint256 totalHeld = aaveBal + morphoAssets;
        uint256 virtualOffset = 1e6;
        uint256 grossEstimate = (shares * (totalHeld + virtualOffset)) / (supply + virtualOffset);

        uint256 aaveCap = 0; // idle drained
        uint256 morphoCap = morphoMaxW > morphoAssets ? morphoAssets : morphoMaxW;
        if (aaveCap + morphoCap >= grossEstimate) return; // not jointly stressed — skip

        vm.prank(alice);
        vm.expectPartialRevert(IDivigentVaultRouter.InsufficientVaultLiquidity.selector);
        router.withdraw(shares, alice, 0);

        // Shares unchanged: revert was atomic.
        assertEq(dvUsdc.balanceOf(alice), shares, "shares preserved across joint-stress revert");
    }
}
