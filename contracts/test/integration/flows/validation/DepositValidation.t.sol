// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Deposit — Validation Suite
/// @notice Systematically enumerates every revert path for `deposit` and
///         `depositWithPermit` one file per operation, one test
///         per revert reason, named `test_<fn>_revertsWith_<Error>_when_<cause>`.
///
///         Purpose: any new reviewer (or audit firm) can open this file and see,
///         in one place, every way the deposit surface can fail — matched 1:1 to
///         the router's revert statements. Coverage gaps jump out immediately.
///
///         Revert map (per `DivigentVaultRouter.deposit` + `depositWithPermit`):
///           • `DepositsPausedError`       — pause bit set.
///           • `NotAuthorised`             — caller neither wallet nor operator.
///           • `NotAuthorised`             — wallet not registered.
///           • `InvalidAmount`             — amount below `MIN_DEPOSIT`.
///           • `TVLCapExceeded`            — deposit would push TVL past current cap.
///           • `StaleOracle`               — oracle not fresh after try-to-record.
///           • `NoSafeRoute`               — neither vault can allocate the amount.
///           • `ZeroAmount`                — share math rounds `dvUsdcMinted` to 0.
///           • `PermitExpired`             — (depositWithPermit) deadline passed.
contract DepositValidationTest is Actions {
    // ─────────────────────────────────────────────────────────────────────────
    // Authorization
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWith_NotAuthorised_whenWalletIsNotRegistered() public {
        address unregistered = makeAddr("unregistered");
        fund(unregistered, 10_000e6);

        vm.prank(unregistered);
        usdc.approve(address(router), 1_000e6);

        vm.prank(unregistered);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(1_000e6, unregistered);
    }

    function test_deposit_revertsWith_NotAuthorised_whenCallerIsNeitherWalletNorOperator() public {
        address stranger = makeAddr("stranger");
        fund(stranger, 10_000e6);

        // alice is registered (by RouterIntegrationBase); stranger is not her operator.
        vm.prank(alice);
        usdc.approve(address(router), 1_000e6);

        vm.prank(stranger);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(1_000e6, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pause
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWith_DepositsPausedError_whenDepositsPaused() public {
        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        vm.prank(alice);
        usdc.approve(address(router), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.DepositsPausedError.selector);
        router.deposit(1_000e6, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Amount bounds
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWith_InvalidAmount_whenAmountBelowMinDeposit() public {
        uint256 tooSmall = router.MIN_DEPOSIT() - 1;

        vm.prank(alice);
        usdc.approve(address(router), tooSmall);

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.InvalidAmount.selector);
        router.deposit(tooSmall, alice);
    }

    function test_deposit_revertsWith_TVLCapExceeded_whenDepositExceedsCap() public {
        useAaveRoute();

        // Fill TVL up to the cap.
        fund(alice, 5_000_000e6);
        userDeposits(alice, 500_000e6); // initial cap

        // The smallest amount that clears the MIN_DEPOSIT gate is MIN_DEPOSIT
        // itself. Any such deposit now pushes TVL past the cap -> must revert
        // with TVLCapExceeded(requested=minDeposit, cap=500_000e6).
        uint256 minDeposit = router.MIN_DEPOSIT();
        uint256 cap = router.currentTVLCap();
        vm.prank(alice);
        usdc.approve(address(router), minDeposit);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.TVLCapExceeded.selector, minDeposit, cap));
        router.deposit(minDeposit, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Oracle freshness
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWith_StaleOracle_whenOracleNotFresh() public {
        oracle.setFresh(false);

        vm.prank(alice);
        usdc.approve(address(router), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.StaleOracle.selector);
        router.deposit(1_000e6, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Routing capacity
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWith_NoSafeRoute_whenBothVaultsRefuse() public {
        // Drain Aave's idle cash and cap Morpho at 0.
        usdc.setBalance(address(aToken), 0);
        morphoVault.setMaxDeposit(0);

        uint256 amount = 10_000e6;
        vm.prank(alice);
        usdc.approve(address(router), amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.NoSafeRoute.selector, amount));
        router.deposit(amount, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Share-math rounding
    // ─────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWith_ZeroAmount_whenShareMathRoundsToZero() public {
        // Precondition for `dvUsdcMinted == 0`:
        //   amount * (totalSupply + offset) < (totalAssets + offset)
        // With the larger virtual offset this requires an extreme donated
        // balance, so warp past day 91 to remove the cap before building the
        // mechanical zero-share validation state.

        fastForward(92 days);
        assertEq(router.currentTVLCap(), type(uint256).max, "cap removed post day-91");

        // Seed a small position so totalSupply > 0.
        useAaveRoute();
        address seedUser = makeActor("zero_shares_seed", 100_000_000e6);
        userDeposits(seedUser, router.MIN_DEPOSIT());

        // Inflate aToken balance enough to collapse share math to zero.
        aToken.mint(address(router), 1_000_000_000e6);

        // Fresh victim attempts MIN_DEPOSIT. Cache the value so `vm.expectRevert`
        // matches `router.deposit` directly (not the inline MIN_DEPOSIT view call).
        address victim = makeActor("zero_shares_victim", 1_000e6);
        uint256 minDeposit = router.MIN_DEPOSIT();

        vm.prank(victim);
        usdc.approve(address(router), minDeposit);

        vm.prank(victim);
        vm.expectRevert(IDivigentVaultRouter.ZeroAmount.selector);
        router.deposit(minDeposit, victim);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // depositWithPermit — deadline
    // ─────────────────────────────────────────────────────────────────────────

    function test_depositWithPermit_revertsWith_PermitExpired_whenDeadlineInPast() public {
        // The PermitExpired check is the first line of depositWithPermit,
        // before the USDC.permit call. No need for a real signature here —
        // only the deadline branch should fire.
        uint256 expiredDeadline = block.timestamp - 1;

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.depositWithPermit(1_000e6, alice, expiredDeadline, 0, bytes32(0), bytes32(0));
    }
}
