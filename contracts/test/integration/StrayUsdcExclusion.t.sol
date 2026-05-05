// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./helpers/Actions.sol";

/// @title  Stray USDC Exclusion
/// @notice Pins the delta-based `actualGross` semantics inside
///         `DivigentVaultRouter.withdraw`.
///
///         The router computes the withdraw's realised gross as:
///
///             uint256 balanceBefore = USDC.balanceOf(address(this));
///             ... vault redemptions ...
///             uint256 actualGross   = USDC.balanceOf(address(this)) - balanceBefore;
///
///         If some USDC was sitting in the router at the start of the call
///         (from an accidental transfer, a revert-during-withdraw residue,
///         or a hostile donation), `actualGross` correctly excludes it —
///         fee is charged ONLY on what the vaults actually paid out this
///         transaction.
///
///         Without the delta formulation, stray USDC would be double-counted:
///         the user would receive it as "yield" and the treasury would
///         collect 10% of it as fee. These tests make that guarantee
///         explicit.
contract StrayUsdcExclusionTest is Actions {
    uint256 internal constant DEPOSIT = 10_000e6;
    uint256 internal constant YIELD = 1_000e6;
    uint256 internal constant STRAY = 5_000e6;

    /// @notice Stray USDC sitting in the router BEFORE withdraw is excluded
    ///         from `actualGross`. Fee is 10% of the vault yield only.
    function test_strayUsdc_excludedFromFee() public {
        address user = makeActor("stray_user", DEPOSIT * 2);

        useAaveRoute();
        uint256 shares = userDeposits(user, DEPOSIT);

        // Accrue vault yield (actual protocol yield)
        fastForward(30 days);
        accrueAaveYield(YIELD);

        // Hostile donation / accidental transfer into the router
        usdc.mint(address(router), STRAY);
        assertEq(usdc.balanceOf(address(router)), STRAY, "stray USDC sits in router pre-withdraw");

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // User withdraws all. Helper asserts post-state BUT also enforces
        // `USDC.balanceOf(router) == 0` as INV-4 — so we must NOT use the
        // helper here (it would fail the invariant check despite the actual
        // behaviour being correct: STRAY legitimately remains). Call the
        // router directly.
        vm.prank(user);
        uint256 returned = router.withdraw(shares, user, 0);

        // Fee is exactly 10% of realised vault yield, NOT 10% of
        // (yield + stray). The delta-based `actualGross` absorbs stray, while
        // the virtual offset retains a small slice of the vault yield.
        uint256 feeCharged = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 actualGross = returned + feeCharged;
        uint256 realisedYield = actualGross - DEPOSIT;
        uint256 residualBound = (YIELD * 1e6) / (DEPOSIT + 1e6) + 4;

        assertLe(realisedYield, YIELD, "realised yield cannot include stray USDC");
        assertGe(realisedYield + residualBound, YIELD, "virtual residual is bounded");
        assertEq(feeCharged, expectedFee(realisedYield), "fee must be 10% of realised vault yield");

        // User receives: principal + 90% of vault yield only — the stray
        // USDC stays in the router.
        uint256 expectedNet = DEPOSIT + (realisedYield - feeCharged);
        assertEq(returned, expectedNet, "user nets principal + realised yield after fee");

        // The stray USDC REMAINS in the router. A follow-up rescue pathway
        // (governance, multisig) would be required to recover it — but it
        // is never silently credited to a user or the treasury.
        assertApproxEqAbs(usdc.balanceOf(address(router)), STRAY, 2, "stray USDC remains in router after withdraw");
    }

    /// @notice Even with zero vault yield, stray USDC in the router must not
    ///         cause a fee or inflate the user's net. `actualGross` would be
    ///         zero (or very small) and fee stays at zero.
    function test_strayUsdc_doesNotCreatePhantomYield() public {
        address user = makeActor("stray_no_yield", DEPOSIT * 2);

        useAaveRoute();
        uint256 shares = userDeposits(user, DEPOSIT);

        // No yield — just stray donation.
        usdc.mint(address(router), STRAY);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(user);
        uint256 returned = router.withdraw(shares, user, 0);

        // No fee because there's no realised yield.
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "no fee when there's no vault yield, despite stray");

        // User gets exactly their principal (no inflation from stray).
        assertApproxEqAbs(returned, DEPOSIT, 2, "user gets exactly principal, stray does not leak to user");

        assertApproxEqAbs(usdc.balanceOf(address(router)), STRAY, 2, "stray still sitting in router");
    }
}
