// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Fork Mixed Vault Tests
/// @notice Previously these tests hoped the oracle would route some deposits
///         to Morpho and some to Aave, then asserted "both legs drained" —
///         but on any fork block where the oracle prefers one vault, the
///         assertion became a tautology (the untouched leg was already 0).
///
///         This rewrite FORCES a mixed position by draining Aave's live
///         idle USDC mid-test, guaranteeing the second deposit falls back
///         to Morpho via the router's amount-aware fallback. The partial-
///         withdraw test then proves BOTH vault legs decrease — a claim
///         the old version could not make.
contract ForkMixedVaultTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: force a mixed position by draining Aave idle between deposits
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deposit first with whatever the oracle recommends (usually Aave),
    ///      then zero out Aave's live idle USDC balance so the second deposit
    ///      must fall through to Morpho via `_canAllocate`. Returns the Aave
    ///      and Morpho asset balances held by the router after both deposits.
    function _forceMixedPosition(address user, uint256 perLeg)
        internal
        returns (uint256 aaveBal, uint256 morphoBal)
    {
        _deposit(user, perLeg);

        // Drain live Aave idle cash. This makes `_canAllocate(AAVE, perLeg)`
        // return false inside the router, forcing fallback to Morpho.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);

        _deposit(user, perLeg);

        aaveBal = aToken.balanceOf(address(router));
        morphoBal = morphoVault.balanceOf(address(router));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Decomposition — sum of legs equals totalVaultAssets
    // ─────────────────────────────────────────────────────────────────────────

    function testFork_mixed_totalVaultAssetsDecomposition() public {
        (uint256 aaveBal, uint256 morphoBal) = _forceMixedPosition(alice, 50_000e6);
        // Both legs must be populated — this is the whole point of the rewrite.
        assertGt(aaveBal, 0, "Aave leg populated");
        assertGt(morphoBal, 0, "Morpho leg populated");

        (uint256 aaveAssets, uint256 morphoAssets) = router.getCurrentAllocation();
        uint256 tva = router.totalVaultAssets();

        assertEq(tva, aaveAssets + morphoAssets, "TVA == aave + morpho");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Partial withdraw TOUCHES BOTH LEGS — the load-bearing claim
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice With a deliberately mixed position and both legs capable of
    ///         serving, a partial withdraw must pull from BOTH proportionally.
    ///         The previous version of this test could pass vacuously when
    ///         the oracle picked one leg — this one cannot.
    ///
    ///         Before asserting, we restore Aave idle so Aave can actually
    ///         serve its proportional share (we zero'd it above to force
    ///         the mixed position).
    function testFork_mixed_partialWithdraw_touchesBothLegsProvably() public {
        (uint256 aaveBefore, uint256 morphoSharesBefore) = _forceMixedPosition(alice, 50_000e6);

        // Restore Aave idle so withdraw can pull from it.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 10_000_000e6);

        uint256 morphoAssetsBefore = morphoVault.convertToAssets(morphoSharesBefore);

        uint256 half = dvUsdc.balanceOf(alice) / 2;
        _withdraw(alice, half);

        uint256 aaveAfter = aToken.balanceOf(address(router));
        uint256 morphoSharesAfter = morphoVault.balanceOf(address(router));
        uint256 morphoAssetsAfter = morphoVault.convertToAssets(morphoSharesAfter);

        // THE assertion the old test could not make:
        assertLt(aaveAfter, aaveBefore, "Aave leg decreased - proves it was touched");
        assertLt(morphoSharesAfter, morphoSharesBefore, "Morpho leg decreased - proves it was touched");

        // Magnitudes: both drops are roughly proportional (each ~25k of the 50k total).
        uint256 aaveDrop = aaveBefore - aaveAfter;
        uint256 morphoDrop = morphoAssetsBefore - morphoAssetsAfter;
        // At least 10% of the total drop comes from each leg — neither can be dust.
        uint256 totalDrop = aaveDrop + morphoDrop;
        assertGt(aaveDrop * 10, totalDrop, "Aave leg drop is meaningful (gt 10 pct of total)");
        assertGt(morphoDrop * 10, totalDrop, "Morpho leg drop is meaningful (gt 10 pct of total)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Full withdraw drains both legs to near-zero
    // ─────────────────────────────────────────────────────────────────────────

    function testFork_mixed_withdrawAll_drainsBothLegs() public {
        _forceMixedPosition(alice, 50_000e6);

        // Restore Aave idle for the withdraw to succeed.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 10_000_000e6);

        uint256 returned = _withdrawAll(alice);
        assertGe(returned, 100_000e6 - 10, "Full exit returns ~100k");

        (uint256 aaveAfter, uint256 morphoAfter) = router.getCurrentAllocation();
        assertLe(aaveAfter, 4, "Aave position cleared within dust");
        assertLe(morphoAfter, 4, "Morpho position cleared within dust");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Two actors sharing a mixed vault — individual positions sum to TVA
    // ─────────────────────────────────────────────────────────────────────────

    function testFork_mixed_getPositionConsistency() public {
        _forceMixedPosition(alice, 30_000e6);
        // Restore idle for Bob's deposit routing flexibility.
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 10_000_000e6);
        _deposit(bob, 40_000e6);

        (, uint256 aliceVal,) = router.getPosition(alice);
        (, uint256 bobVal,) = router.getPosition(bob);

        uint256 tva = router.totalVaultAssets();
        assertApproxEqAbs(aliceVal + bobVal, tva, 10, "Sum of positions matches TVA");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Morpho maxWithdraw sanity
    // ─────────────────────────────────────────────────────────────────────────

    function testFork_mixed_morphoMaxWithdraw() public {
        assertEq(morphoVault.maxWithdraw(address(router)), 0, "maxWithdraw = 0 with no shares");

        _forceMixedPosition(alice, 50_000e6);

        // Now the router holds Morpho shares — maxWithdraw should be positive.
        assertGt(
            morphoVault.maxWithdraw(address(router)),
            0,
            "maxWithdraw > 0 after Morpho position opened"
        );
    }
}
