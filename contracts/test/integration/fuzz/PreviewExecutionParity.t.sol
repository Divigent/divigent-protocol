// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Preview / Execute Parity Fuzz
/// @notice Proves the router's preview views never mislead a caller — neither
///         under-delivering nor over-estimating — across the regimes the
///         invariant suite reaches: mixed Aave/Morpho positions, positive
///         yield, and realised loss.
///
///         Three properties, one per preview:
///
///           1. `previewDeposit(x)` equals the share count actually minted
///              by the next `deposit(x)` when no state changes between them.
///
///           2. `previewRedeem(s, wallet)` equals the USDC actually delivered
///              by `withdraw(s, wallet, 0)` within tight rounding tolerance.
///              The tolerance absorbs Morpho's exact-asset share flooring.
///
///           3. `previewWithdrawNet(d, wallet)` returns a `shares` value such
///              that `withdraw(shares, wallet, 0) >= d`. The "≥" is the
///              contract's load-bearing guarantee — the whole point of the
///              view is that a client can ask "how many shares do I need to
///              net exactly d USDC?" and have the router round shares UP so
///              the realised gross covers `d` plus any fee.
///
///         A violation in any of these would propagate as user-facing drift
///         across every UI, agent, and integrator that quotes a preview
///         before executing.
contract PreviewExecutionParityTest is Actions {
    uint256 internal constant MIN_AMOUNT = 10e6;
    uint256 internal constant MAX_DEPOSIT = 400_000e6;
    uint256 internal constant MAX_YIELD = 50_000e6;
    uint256 internal constant ACTOR_FUNDING = MAX_DEPOSIT * 3;

    // ═══════════════════════════════════════════════════════════════════════
    // previewDeposit parity (expected: strict equality)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice `previewDeposit` must equal the share count actually minted for
    ///         the same pre-state. The deposit path reads `totalAssetsBefore`
    ///         with the same formula the view uses, so the two agree exactly —
    ///         including across yield-inflated and mixed-vault states.
    function test_previewDeposit_fuzz_parityOnEmptyPool(uint128 amount_) public {
        uint256 amount = bound(uint256(amount_), MIN_AMOUNT, MAX_DEPOSIT);
        address subject = makeActor("pd_empty", ACTOR_FUNDING);

        useAaveRoute();
        uint256 predicted = router.previewDeposit(amount);

        vm.prank(subject);
        usdc.approve(address(router), amount);
        vm.prank(subject);
        uint256 actualMinted = router.deposit(amount, subject);

        assertEq(actualMinted, predicted, "previewDeposit (empty pool) != actual mint");
    }

    function test_previewDeposit_fuzz_parityAfterYield(uint128 seed_, uint128 amount_, uint96 yield_) public {
        uint256 seed = bound(uint256(seed_), 1_000e6, MAX_DEPOSIT / 2);
        uint256 amount = bound(uint256(amount_), MIN_AMOUNT, MAX_DEPOSIT / 2);
        uint256 yld = bound(uint256(yield_), 0, MAX_YIELD);

        address seeder = makeActor("pd_seed", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(seeder, seed);
        if (yld > 0) accrueAaveYield(yld);

        address subject = makeActor("pd_subject", ACTOR_FUNDING);
        uint256 predicted = router.previewDeposit(amount);

        vm.prank(subject);
        usdc.approve(address(router), amount);
        vm.prank(subject);
        uint256 actualMinted = router.deposit(amount, subject);

        assertEq(actualMinted, predicted, "previewDeposit (with yield) != actual mint");
    }

    function test_previewDeposit_fuzz_parityOnMixedVault(uint128 aaveDep_, uint128 morphoDep_, uint128 amount_) public {
        uint256 aaveDep = bound(uint256(aaveDep_), MIN_AMOUNT, MAX_DEPOSIT / 3);
        uint256 morphoDep = bound(uint256(morphoDep_), MIN_AMOUNT, MAX_DEPOSIT / 3);
        uint256 amount = bound(uint256(amount_), MIN_AMOUNT, MAX_DEPOSIT / 3);

        address seeder = makeActor("pd_mixed_seed", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(seeder, aaveDep);
        useMorphoRoute();
        userDeposits(seeder, morphoDep);

        address subject = makeActor("pd_mixed_subject", ACTOR_FUNDING);
        uint256 predicted = router.previewDeposit(amount);

        vm.prank(subject);
        usdc.approve(address(router), amount);
        vm.prank(subject);
        uint256 actualMinted = router.deposit(amount, subject);

        assertEq(actualMinted, predicted, "previewDeposit (mixed vault) != actual mint");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // previewRedeem parity (expected: equality within 2 wei tolerance)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice `previewRedeem` must equal the net USDC actually delivered on
    ///         withdraw, within the rounding envelope of one vault redemption
    ///         (Morpho's exact-asset `withdraw` can lose up to 1 wei to share
    ///         flooring; the fee-calc floors another).
    function test_previewRedeem_fuzz_parityAaveOnlyWithYield(uint128 deposit_, uint96 yield_, uint256 sharePct_)
        public
    {
        uint256 dep = bound(uint256(deposit_), 10_000e6, MAX_DEPOSIT);
        uint256 yld = bound(uint256(yield_), 0, MAX_YIELD);
        uint256 pct = bound(sharePct_, 1, 100);

        address user = makeActor("pr_aave_yield", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, dep);
        if (yld > 0) {
            fastForward(30 days);
            accrueAaveYield(yld);
        }

        uint256 shares = (dvUsdc.balanceOf(user) * pct) / 100;
        if (shares == 0) return;

        uint256 predicted = router.previewRedeem(shares, user);
        vm.prank(user);
        uint256 actualOut = router.withdraw(shares, user, 0);

        assertApproxEqAbs(actualOut, predicted, 2, "previewRedeem (Aave) != actual withdraw");
    }

    function test_previewRedeem_fuzz_parityMixedVaultWithYield(
        uint128 aaveDep_,
        uint128 morphoDep_,
        uint96 yield_,
        uint256 sharePct_
    ) public {
        uint256 aaveDep = bound(uint256(aaveDep_), 10_000e6, MAX_DEPOSIT / 2);
        uint256 morphoDep = bound(uint256(morphoDep_), 10_000e6, MAX_DEPOSIT / 2);
        uint256 yld = bound(uint256(yield_), 0, MAX_YIELD);
        uint256 pct = bound(sharePct_, 1, 100);

        address user = makeActor("pr_mixed_yield", ACTOR_FUNDING);
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

        uint256 predicted = router.previewRedeem(shares, user);
        vm.prank(user);
        uint256 actualOut = router.withdraw(shares, user, 0);

        // Mixed-vault proportional split + Morpho exact-asset rounding can
        // accumulate 1–2 wei drift per leg; 4 wei absorbs worst case.
        assertApproxEqAbs(actualOut, predicted, 4, "previewRedeem (mixed) != actual withdraw");
    }

    function test_previewRedeem_fuzz_parityUnderLoss(uint128 deposit_, uint128 loss_, uint256 sharePct_) public {
        uint256 dep = bound(uint256(deposit_), 50_000e6, MAX_DEPOSIT);
        uint256 lossAmt = bound(uint256(loss_), 1_000e6, dep / 2);
        uint256 pct = bound(sharePct_, 1, 100);

        address user = makeActor("pr_loss", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, dep);
        // Induce loss by dropping aToken balance directly.
        aToken.setBalance(address(router), dep - lossAmt);

        uint256 shares = (dvUsdc.balanceOf(user) * pct) / 100;
        if (shares == 0) return;

        uint256 predicted = router.previewRedeem(shares, user);
        vm.prank(user);
        uint256 actualOut = router.withdraw(shares, user, 0);

        assertApproxEqAbs(actualOut, predicted, 2, "previewRedeem (loss) != actual withdraw");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // previewWithdrawNet — the core guarantee: actual out ≥ desired net
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice `previewWithdrawNet(d)` rounds shares UP so that executing the
    ///         same `d` against the same state delivers ≥ `d` net USDC. A
    ///         single violation of this ordering breaks every "withdraw a
    ///         fixed USDC amount" flow.
    function test_previewWithdrawNet_fuzz_doesNotUnderDeliver_profitBranch(
        uint128 deposit_,
        uint96 yield_,
        uint256 desiredBps_
    ) public {
        uint256 dep = bound(uint256(deposit_), 50_000e6, MAX_DEPOSIT);
        uint256 yld = bound(uint256(yield_), 1_000e6, MAX_YIELD);
        uint256 bps = bound(desiredBps_, 100, 9_500);

        address user = makeActor("pwn_profit", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, dep);
        fastForward(30 days);
        accrueAaveYield(yld);

        uint256 allShares = dvUsdc.balanceOf(user);
        uint256 maxGross = router.previewRedeem(allShares, user);
        if (maxGross < 1e6) return; // dust

        uint256 desired = (maxGross * bps) / 10_000;
        if (desired == 0) return;

        uint256 sharesNeeded = router.previewWithdrawNet(desired, user);
        if (sharesNeeded == 0) return; // preview signals unserviceable

        vm.prank(user);
        uint256 actualOut = router.withdraw(sharesNeeded, user, 0);

        assertGe(actualOut, desired, "previewWithdrawNet (profit) under-delivered");
    }

    function test_previewWithdrawNet_fuzz_doesNotUnderDeliver_lossBranch(
        uint128 deposit_,
        uint128 loss_,
        uint256 desiredBps_
    ) public {
        uint256 dep = bound(uint256(deposit_), 50_000e6, MAX_DEPOSIT);
        uint256 lossAmt = bound(uint256(loss_), dep / 10, dep - MIN_AMOUNT);
        uint256 bps = bound(desiredBps_, 100, 9_500);

        address user = makeActor("pwn_loss", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, dep);
        aToken.setBalance(address(router), dep - lossAmt);

        uint256 allShares = dvUsdc.balanceOf(user);
        uint256 maxGross = router.previewRedeem(allShares, user);
        if (maxGross < 1e6) return;

        uint256 desired = (maxGross * bps) / 10_000;
        if (desired == 0) return;

        uint256 sharesNeeded = router.previewWithdrawNet(desired, user);
        if (sharesNeeded == 0) return;

        vm.prank(user);
        uint256 actualOut = router.withdraw(sharesNeeded, user, 0);

        assertGe(actualOut, desired, "previewWithdrawNet (loss) under-delivered");
    }

    function test_previewWithdrawNet_fuzz_doesNotUnderDeliver_mixedVault(
        uint128 aaveDep_,
        uint128 morphoDep_,
        uint96 yield_,
        uint256 desiredBps_
    ) public {
        uint256 aaveDep = bound(uint256(aaveDep_), 30_000e6, MAX_DEPOSIT / 2);
        uint256 morphoDep = bound(uint256(morphoDep_), 30_000e6, MAX_DEPOSIT / 2);
        uint256 yld = bound(uint256(yield_), 0, MAX_YIELD);
        uint256 bps = bound(desiredBps_, 100, 9_000);

        address user = makeActor("pwn_mixed", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, aaveDep);
        useMorphoRoute();
        userDeposits(user, morphoDep);
        if (yld > 0) {
            fastForward(30 days);
            accrueAaveYield(yld / 2);
            accrueMorphoYield(yld / 2);
        }

        uint256 allShares = dvUsdc.balanceOf(user);
        uint256 maxGross = router.previewRedeem(allShares, user);
        if (maxGross < 1e6) return;

        uint256 desired = (maxGross * bps) / 10_000;
        if (desired == 0) return;

        uint256 sharesNeeded = router.previewWithdrawNet(desired, user);
        if (sharesNeeded == 0) return;

        vm.prank(user);
        uint256 actualOut = router.withdraw(sharesNeeded, user, 0);

        assertGe(actualOut, desired, "previewWithdrawNet (mixed) under-delivered");
    }
}
