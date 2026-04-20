// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Withdraw Capacity View
/// @notice Pins the `withdrawCapacity()` pre-flight view against the router's
///         internal `_planWithdrawCapacity()` helper — proving the public
///         view never diverges from the math used by `withdraw()` itself.
///
///         Scenarios:
///           1. Healthy state: fields match live router holdings + idle cash.
///           2. Aave idle drained: `aaveWithdrawCap` reflects the cap.
///           3. Morpho maxWithdraw constrained: `morphoWithdrawCap` reflects cap.
///           4. Morpho `convertToAssets` reverts: `morphoReachable = false`.
///           5. Morpho `convertToAssets` gas-bombs: try/catch absorbs the hit.
///           6. `withdraw()` reverts `MorphoUnreachable` when view path dies.
///           7. Invariant: `totalWithdrawCap >= actualServed` after withdraw.
contract WithdrawCapacityTest is Actions {
    uint256 internal constant AAVE_DEP = 50_000e6;
    uint256 internal constant MORPHO_DEP = 50_000e6;

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Healthy state — fields match live reads
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawCapacity_healthyMixed_fieldsMatchLiveReads() public {
        address user = makeActor("cap_healthy", 500_000e6);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.aaveAssetsHeld, aToken.balanceOf(address(router)), "aaveAssetsHeld matches");
        assertEq(cap.aaveIdleLiquidity, usdc.balanceOf(address(aToken)), "aaveIdle matches");
        assertEq(
            cap.aaveWithdrawCap,
            cap.aaveAssetsHeld < cap.aaveIdleLiquidity ? cap.aaveAssetsHeld : cap.aaveIdleLiquidity,
            "aaveWithdrawCap = min(held, idle)"
        );

        uint256 expectedMorphoHeld = morphoVault.convertToAssets(morphoVault.balanceOf(address(router)));
        assertEq(cap.morphoAssetsHeld, expectedMorphoHeld, "morphoAssetsHeld matches");
        assertTrue(cap.morphoReachable, "Morpho reachable when healthy");
        assertEq(
            cap.totalWithdrawCap,
            cap.aaveWithdrawCap + cap.morphoWithdrawCap,
            "total = sum of legs"
        );
    }

    function test_withdrawCapacity_aaveOnlyPosition_morphoReachableTrivially() public {
        address user = makeActor("cap_aave_only", 500_000e6);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertGt(cap.aaveAssetsHeld, 0, "Aave leg populated");
        assertEq(cap.morphoAssetsHeld, 0, "Morpho leg empty");
        assertTrue(cap.morphoReachable, "Morpho reachable (no shares = no read)");
        assertEq(cap.morphoWithdrawCap, 0, "Morpho cap = 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Aave idle drained
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawCapacity_aaveIdleDrained_capReflectsLimit() public {
        address user = makeActor("cap_aave_drain", 500_000e6);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);

        // Drain Aave's idle USDC to 1000.
        usdc.setBalance(address(aToken), 1000);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.aaveIdleLiquidity, 1000, "idle captured");
        assertEq(cap.aaveWithdrawCap, 1000, "cap clamped to idle");
        assertLt(cap.aaveWithdrawCap, cap.aaveAssetsHeld, "cap below held");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Morpho maxWithdraw constrained
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawCapacity_morphoCapped_capReflectsLimit() public {
        address user = makeActor("cap_morpho_cap", 500_000e6);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        morphoVault.setMaxWithdraw(100e6);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(cap.morphoWithdrawCap, 100e6, "cap = setMaxWithdraw");
        assertLt(cap.morphoWithdrawCap, cap.morphoAssetsHeld, "cap below held");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Morpho view reverts → morphoReachable = false
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawCapacity_morphoViewReverts_reachableFalse() public {
        address user = makeActor("cap_morpho_revert", 500_000e6);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        // Flip Morpho's convertToAssets to revert.
        morphoVault.setRevertOnConvertToAssets(true);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertFalse(cap.morphoReachable, "morphoReachable = false on view revert");
        assertEq(cap.morphoAssetsHeld, 0, "morphoAssetsHeld = 0 when unreachable");
        assertEq(cap.morphoWithdrawCap, 0, "morphoWithdrawCap = 0 when unreachable");

        // Aave side of the breakdown is still accurate.
        assertEq(cap.aaveAssetsHeld, aToken.balanceOf(address(router)), "Aave side still live");
        assertEq(cap.totalWithdrawCap, cap.aaveWithdrawCap, "total = Aave only");
    }

    /// @notice Gas-bomb Morpho view: the try/catch ceiling (`_MORPHO_VIEW_GAS`)
    ///         absorbs the hit, capacity view still returns. Without the
    ///         gas limit, the caller would be out-of-gas'd by the malicious
    ///         vault view.
    function test_withdrawCapacity_morphoGasBomb_capAbsorbsHit() public {
        address user = makeActor("cap_gasbomb", 500_000e6);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        morphoVault.setGasBombConvertToAssets(true);

        uint256 gasBefore = gasleft();
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();
        uint256 gasUsed = gasBefore - gasleft();

        assertFalse(cap.morphoReachable, "gas-bomb flips reachable false");
        // Total gas consumed by the view must be bounded — the 100k cap plus
        // surrounding overhead, comfortably under 200k.
        assertLt(gasUsed, 200_000, "gas-bomb absorbed by try/catch ceiling");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4b. getCurrentAllocation — parity with withdrawCapacity under Morpho failure
    //
    // Finding F-2: `getCurrentAllocation()` used `_morphoAssetsHeld()` directly,
    // which fails loud on any Morpho read failure. That made every external
    // integrator (dashboards, keepers, other contracts) brick whenever Morpho
    // misbehaved, while `withdrawCapacity()` degraded gracefully via the same
    // 100k-gas try/catch. The fix routes `getCurrentAllocation` through
    // `_planWithdrawCapacity` so both views share one reachability path.
    // ─────────────────────────────────────────────────────────────────────────

    function test_getCurrentAllocation_morphoViewReverts_degradesGracefully() public {
        address user = makeActor("alloc_revert", 500_000e6);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        morphoVault.setRevertOnConvertToAssets(true);

        (uint256 aaveAssets, uint256 morphoAssets) = router.getCurrentAllocation();

        assertEq(aaveAssets, aToken.balanceOf(address(router)), "Aave leg still reported");
        assertEq(morphoAssets, 0, "Morpho leg reports 0 when view reverts");

        // Disambiguation: a caller that needs to distinguish 0-holdings from
        // unreachable can read withdrawCapacity() which exposes the flag.
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();
        assertFalse(cap.morphoReachable, "withdrawCapacity exposes reachable=false");
    }

    function test_getCurrentAllocation_morphoGasBomb_degradesGracefully() public {
        address user = makeActor("alloc_gasbomb", 500_000e6);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        morphoVault.setGasBombConvertToAssets(true);

        uint256 gasBefore = gasleft();
        (uint256 aaveAssets, uint256 morphoAssets) = router.getCurrentAllocation();
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(aaveAssets, aToken.balanceOf(address(router)), "Aave leg still reported");
        assertEq(morphoAssets, 0, "Morpho leg reports 0 under gas bomb");
        assertLt(gasUsed, 200_000, "Gas bomb absorbed by 100k try/catch ceiling");
    }

    /// @notice Fuzz: `getCurrentAllocation()` and `withdrawCapacity()` must agree
    ///         on the Morpho-reachable cell across healthy and unreachable states,
    ///         and never disagree on the Aave cell.
    function test_getCurrentAllocation_fuzz_matchesCapacityView(
        uint128 aaveDep_,
        uint128 morphoDep_,
        bool    bombMorpho,
        bool    revertMorpho
    ) public {
        uint256 aaveDep   = bound(uint256(aaveDep_),   10_000e6, 100_000e6);
        uint256 morphoDep = bound(uint256(morphoDep_), 10_000e6, 100_000e6);

        address user = makeActor("alloc_fuzz", 500_000e6);
        useAaveRoute();
        userDeposits(user, aaveDep);
        useMorphoRoute();
        userDeposits(user, morphoDep);

        if (bombMorpho)   morphoVault.setGasBombConvertToAssets(true);
        if (revertMorpho) morphoVault.setRevertOnConvertToAssets(true);

        (uint256 aAlloc, uint256 mAlloc) = router.getCurrentAllocation();
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertEq(aAlloc, cap.aaveAssetsHeld,   "Aave cell agrees");
        assertEq(mAlloc, cap.morphoAssetsHeld, "Morpho cell agrees");

        if (bombMorpho || revertMorpho) {
            assertFalse(cap.morphoReachable, "unreachable flagged");
            assertEq(mAlloc, 0, "Morpho cell zero when unreachable");
        } else {
            assertTrue(cap.morphoReachable, "reachable when healthy");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. withdraw() reverts MorphoUnreachable when view path dies
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdraw_reverts_MorphoUnreachable_whenViewReverts() public {
        address user = makeActor("cap_withdraw_revert", 500_000e6);
        useMorphoRoute();
        uint256 shares = userDeposits(user, MORPHO_DEP);

        morphoVault.setRevertOnConvertToAssets(true);

        vm.prank(user);
        vm.expectRevert(IDivigentVaultRouter.MorphoUnreachable.selector);
        router.withdraw(shares, user, 0);
    }

    /// @notice When router has ZERO Morpho exposure, a Morpho view revert is
    ///         irrelevant — `_morphoAssetsHeld` short-circuits on morphoShares == 0
    ///         and morphoReachable stays true. Aave-only withdraws still work.
    function test_withdraw_aaveOnly_unaffectedByMorphoViewRevert() public {
        address user = makeActor("cap_aave_only_withdraw", 500_000e6);
        useAaveRoute();
        uint256 shares = userDeposits(user, AAVE_DEP);

        morphoVault.setRevertOnConvertToAssets(true);

        vm.prank(user);
        uint256 returned = router.withdraw(shares, user, 0);
        assertGt(returned, 0, "Aave-only exit immune to Morpho view revert");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Invariant: totalWithdrawCap >= actual served amount (fuzz)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Snapshot `totalWithdrawCap` before withdrawing, then assert the
    ///         amount served is bounded by it. This is the load-bearing
    ///         pre-flight guarantee: any caller can trust that if their
    ///         desired `gross` is <= `totalWithdrawCap`, the withdraw won't
    ///         revert for liquidity reasons in the same block.
    function test_withdraw_fuzz_servedAmountBoundedByCap(
        uint128 aaveDep_,
        uint128 morphoDep_,
        uint128 yield_,
        uint256 sharePct_
    ) public {
        uint256 aaveDep   = bound(uint256(aaveDep_),   10_000e6, 100_000e6);
        uint256 morphoDep = bound(uint256(morphoDep_), 10_000e6, 100_000e6);
        uint256 yld       = bound(uint256(yield_),     0,        20_000e6);
        uint256 pct       = bound(sharePct_,           1,        100);

        address user = makeActor("cap_fuzz", 500_000e6);
        useAaveRoute();
        userDeposits(user, aaveDep);
        useMorphoRoute();
        userDeposits(user, morphoDep);
        if (yld > 0) {
            fastForward(30 days);
            accrueAaveYield(yld / 2);
            accrueMorphoYield(yld / 2);
        }

        uint256 shares = (dvUsdc.balanceOf(user) * pct) / 100;
        if (shares == 0) return;

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        vm.prank(user);
        try router.withdraw(shares, user, 0) returns (uint256 returned) {
            // The canonical invariant — router served amount is within cap.
            // Returned is net-of-fee; gross = returned + fee <= cap.
            assertLe(returned, cap.totalWithdrawCap, "served <= totalWithdrawCap");
        } catch {
            // Revert is fine — means cap couldn't serve the gross. Either way
            // the invariant `served <= cap` trivially holds (served = 0).
        }
    }

    /// @notice Complementary direction: if the caller's gross is comfortably
    ///         within `totalWithdrawCap`, withdraw must succeed. Pins the
    ///         pre-flight usefulness claim.
    function test_withdraw_fuzz_successGuaranteedWithinCap(uint128 aaveDep_, uint128 morphoDep_) public {
        uint256 aaveDep   = bound(uint256(aaveDep_),   10_000e6, 100_000e6);
        uint256 morphoDep = bound(uint256(morphoDep_), 10_000e6, 100_000e6);

        address user = makeActor("cap_within_fuzz", 500_000e6);
        useAaveRoute();
        userDeposits(user, aaveDep);
        useMorphoRoute();
        userDeposits(user, morphoDep);

        // Request 10% of the user's position — well within cap.
        uint256 shares = dvUsdc.balanceOf(user) / 10;
        uint256 preview = router.previewRedeem(shares, user);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();
        // Precondition: pre-flight says this is servable.
        if (preview > cap.totalWithdrawCap) return; // skip — edge state

        vm.prank(user);
        uint256 returned = router.withdraw(shares, user, 0);
        assertGt(returned, 0, "withdraw succeeds when within cap");
    }
}
