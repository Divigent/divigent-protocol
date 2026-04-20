// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Test.sol";

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Exit Redirect — Adversarial Coverage
/// @notice `ExitRedirect.t.sol` pins the core redirect scenarios (one-leg-short
///         -> redirect, both-short -> revert, healthy -> no-event). This file
///         extends that to the full adversarial product space the invariant
///         suite exercises stochastically but doesn't pin deterministically:
///
///           - fuzzed cap fractions crossed with fuzzed withdraw sizes
///           - redirect under positive yield (fee paid on realised gain)
///           - redirect under realised loss (fee clamped to zero)
///           - exact boundary (`cap == target`) -- no redirect, no event
///           - operator-triggered redirect (wallet still gets the USDC)
///           - sequential redirects with the constraint flipping between legs
///
///         Fuzz bounds are chosen so every run reaches the "redirect fires
///         AND gross is servable" regime. Cases that fall outside (capacity
///         insufficient or cap above proportional target) are pinned as
///         targeted scenarios elsewhere; here we stress the redirect math
///         with varied but always-servable state.
contract ExitRedirectAdversarialTest is Actions {
    /// @dev Mirrored from the interface for event decoding.
    event ExitRedirected(
        address indexed wallet,
        uint256 targetAave,
        uint256 targetMorpho,
        uint256 actualAave,
        uint256 actualMorpho,
        bool shortLeg
    );

    bytes32 internal constant REDIRECT_TOPIC =
        keccak256("ExitRedirected(address,uint256,uint256,uint256,uint256,bool)");

    uint256 internal constant AAVE_DEP = 50_000e6;
    uint256 internal constant MORPHO_DEP = 50_000e6;
    uint256 internal constant ACTOR_FUNDING = 500_000e6;

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz: Morpho capped tightly below target, redirect to Aave
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Fuzz the Morpho cap in [0, 20%] and withdraw pct in [30%, 50%].
    ///         At these bounds: proportional Morpho target exceeds cap, so
    ///         redirect fires; Aave alone has capacity for the full gross
    ///         (50k >= 50k max gross); so the exit is always servable.
    ///
    ///         Asserts: redirect event fires, shortLeg flag correct, actual
    ///         draws reconcile with vault deltas, net out matches preview.
    function test_redirect_fuzz_morphoCappedBelowTarget(uint256 morphoCapBps_, uint256 withdrawPct_) public {
        uint256 morphoCapBps = bound(morphoCapBps_, 0, 2_000);
        uint256 withdrawPct = bound(withdrawPct_, 30, 50);

        address user = makeActor("era_m", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        uint256 morphoCap = (MORPHO_DEP * morphoCapBps) / 10_000;
        morphoVault.setMaxWithdraw(morphoCap);

        uint256 shares = (dvUsdc.balanceOf(user) * withdrawPct) / 100;
        if (shares == 0) return;

        uint256 aaveBefore = aToken.balanceOf(address(router));
        uint256 expectedNet = router.previewRedeem(shares, user);

        vm.recordLogs();
        uint256 returned = userWithdraws(user, shares);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertApproxEqAbs(returned, expectedNet, 4, "returned close to preview");

        (bool found,,, uint256 actualAave, uint256 actualMorpho, bool shortLeg) = _findRedirect(logs);
        assertTrue(found, "ExitRedirected must fire when Morpho capped below target");
        assertTrue(shortLeg, "shortLeg=true marks Morpho as constrained");

        uint256 aaveDrop = aaveBefore - aToken.balanceOf(address(router));
        assertEq(aaveDrop, actualAave, "aToken delta matches event.actualAave");
        assertLe(actualMorpho, morphoCap, "actual Morpho draw respects cap");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz: Aave idle capped tightly below target, redirect to Morpho
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Mirror of the above, with Aave as the constrained leg. The
    ///         router reads `usdc.balanceOf(aToken)` as `aaveIdle`; setting
    ///         that balance low constrains the Aave leg without touching the
    ///         router's aToken holdings.
    function test_redirect_fuzz_aaveCappedBelowTarget(uint256 aaveIdleBps_, uint256 withdrawPct_) public {
        uint256 aaveIdleBps = bound(aaveIdleBps_, 0, 2_000);
        uint256 withdrawPct = bound(withdrawPct_, 30, 50);

        address user = makeActor("era_a", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        // Drive aaveIdle down. Router reads USDC.balanceOf(aToken).
        uint256 aaveIdleCap = (AAVE_DEP * aaveIdleBps) / 10_000;
        usdc.setBalance(address(aToken), aaveIdleCap);

        uint256 shares = (dvUsdc.balanceOf(user) * withdrawPct) / 100;
        if (shares == 0) return;

        uint256 morphoBefore = morphoVault.balanceOf(address(router));
        uint256 expectedNet = router.previewRedeem(shares, user);

        vm.recordLogs();
        uint256 returned = userWithdraws(user, shares);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertApproxEqAbs(returned, expectedNet, 4, "returned close to preview");

        (bool found,,, uint256 actualAave,, bool shortLeg) = _findRedirect(logs);
        assertTrue(found, "ExitRedirected must fire when Aave capped below target");
        assertFalse(shortLeg, "shortLeg=false marks Aave as constrained");
        assertLe(actualAave, aaveIdleCap, "actual Aave draw respects idle cap");
        assertLt(morphoVault.balanceOf(address(router)), morphoBefore, "Morpho absorbed shortfall");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Redirect + positive yield: fee is exactly 10% of realised gain
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Under realised yield, the redirect preserves the fee invariant:
    ///         treasury receives exactly 10% of (actualGross - principalOut).
    ///         The withdraw pulls at most 40% of total holdings so Aave alone
    ///         can serve the full gross — the constraint forces redirect but
    ///         doesn't exceed capacity.
    function test_redirect_fuzz_underPositiveYield(uint96 aaveYield_, uint256 morphoCapBps_) public {
        uint256 yld = bound(uint256(aaveYield_), 500e6, 10_000e6);
        uint256 morphoCapBps = bound(morphoCapBps_, 0, 1_000);

        address user = makeActor("era_y", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        fastForward(30 days);
        accrueAaveYield(yld);

        morphoVault.setMaxWithdraw((MORPHO_DEP * morphoCapBps) / 10_000);

        // Withdraw 40% — gross ≤ 40% * (100k + yld) ≤ 44k ≤ Aave balance (50k + yld),
        // so Aave alone can cover even after redirect.
        uint256 shares = (dvUsdc.balanceOf(user) * 40) / 100;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 expectedNet = router.previewRedeem(shares, user);

        uint256 returned = userWithdraws(user, shares);
        uint256 feeCharged = usdc.balanceOf(treasury) - treasuryBefore;

        assertApproxEqAbs(returned, expectedNet, 4, "net returned close to previewed");

        // Realised yield for 40% withdraw = 40% of total yield (yld).
        uint256 expectedFee = (yld * 40) / 100 / 10; // 10% fee on realised yield slice
        assertApproxEqAbs(feeCharged, expectedFee, 4, "fee == 10% of realised yield, post-redirect");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Redirect + loss: fee clamped to zero
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Under a realised loss that puts the position underwater, the
    ///         fee is exactly zero — even when the exit uses the redirect
    ///         path. Treasury delta must be 0.
    function test_redirect_fuzz_underRealisedLoss(uint128 lossAmt_, uint256 morphoCapBps_) public {
        uint256 loss = bound(uint256(lossAmt_), AAVE_DEP / 10, AAVE_DEP / 2);
        uint256 morphoCapBps = bound(morphoCapBps_, 0, 1_000);

        address user = makeActor("era_l", ACTOR_FUNDING);
        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        aToken.setBalance(address(router), AAVE_DEP - loss);
        morphoVault.setMaxWithdraw((MORPHO_DEP * morphoCapBps) / 10_000);

        // Withdraw 20% — with max loss of 25k, remaining Aave is 25k, and
        // 20% of the 75k-100k post-loss position is 15-20k, so Aave alone
        // can cover even after redirect.
        uint256 shares = (dvUsdc.balanceOf(user) * 20) / 100;
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        userWithdraws(user, shares);
        uint256 feeCharged = usdc.balanceOf(treasury) - treasuryBefore;

        assertEq(feeCharged, 0, "fee must be zero on underwater exit, even with redirect");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Exact boundary: cap == target → no redirect, no event
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice When Morpho's cap exactly equals the proportional target, the
    ///         router does not redirect — the proportional plan covers it.
    function test_redirect_exactBoundary_noRedirectNoEvent() public {
        address user = makeActor("era_boundary", ACTOR_FUNDING);

        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        // 50% withdraw → proportional target is 25k each.
        // Set Morpho cap to 25k exactly: no redirect.
        uint256 half = dvUsdc.balanceOf(user) / 2;
        morphoVault.setMaxWithdraw(25_000e6);

        vm.recordLogs();
        userWithdraws(user, half);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found,,,,,) = _findRedirect(logs);
        assertFalse(found, "exact-boundary exit must not emit ExitRedirected");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Operator-triggered redirect
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Operator submits the withdraw; redirect fires; USDC lands in
    ///         the wallet (not the operator). Operator's own balance is
    ///         unchanged.
    function test_redirect_operatorTriggered_walletGetsUsdc() public {
        address user = makeActor("era_op", ACTOR_FUNDING);
        address op_ = makeAddr("era_op_submitter");
        usdc.mint(op_, 1_000e6);

        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        vm.prank(user);
        router.setOperator(op_, true);

        morphoVault.setMaxWithdraw(0);

        uint256 shares = dvUsdc.balanceOf(user) / 2;
        uint256 opBalBefore = usdc.balanceOf(op_);
        uint256 userBalBefore = usdc.balanceOf(user);

        vm.prank(op_);
        uint256 returned = router.withdraw(shares, user, 0);

        assertEq(usdc.balanceOf(user) - userBalBefore, returned, "USDC lands in wallet");
        assertEq(usdc.balanceOf(op_), opBalBefore, "operator balance untouched");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no USDC post-withdraw");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sequential redirects: constraint flips between legs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Two sequential withdraws with the constraint on different legs
    ///         each time. Each withdraw reads fresh capacity — planning is
    ///         stateless.
    function test_redirect_sequentialWithdraws_constraintFlips() public {
        address user = makeActor("era_seq", ACTOR_FUNDING);

        useAaveRoute();
        userDeposits(user, AAVE_DEP);
        useMorphoRoute();
        userDeposits(user, MORPHO_DEP);

        // 1st: Morpho constrained → Aave absorbs
        morphoVault.setMaxWithdraw(0);
        uint256 q1 = dvUsdc.balanceOf(user) / 3;
        uint256 aave1 = aToken.balanceOf(address(router));
        userWithdraws(user, q1);
        assertLt(aToken.balanceOf(address(router)), aave1, "Aave side absorbed 1st redirect");

        // Restore Morpho, drain Aave idle → Aave constrained
        morphoVault.setMaxWithdraw(type(uint256).max);
        usdc.setBalance(address(aToken), 0);

        // 2nd: Aave constrained → Morpho absorbs
        uint256 q2 = dvUsdc.balanceOf(user) / 2;
        uint256 morpho2 = morphoVault.balanceOf(address(router));
        userWithdraws(user, q2);
        assertLt(morphoVault.balanceOf(address(router)), morpho2, "Morpho side absorbed 2nd redirect");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: decode ExitRedirected event from recorded logs
    // ─────────────────────────────────────────────────────────────────────────

    function _findRedirect(Vm.Log[] memory logs)
        internal
        pure
        returns (
            bool found,
            uint256 targetAave,
            uint256 targetMorpho,
            uint256 actualAave,
            uint256 actualMorpho,
            bool shortLeg
        )
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != REDIRECT_TOPIC) continue;
            (targetAave, targetMorpho, actualAave, actualMorpho, shortLeg) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bool));
            found = true;
            return (found, targetAave, targetMorpho, actualAave, actualMorpho, shortLeg);
        }
    }
}
