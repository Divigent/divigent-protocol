// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {DvUSDC} from "../src/dvUSDC.sol";

/// @notice Unit tests for dvUSDC — access control, non-transferability, mint/burn, metadata.
contract DvUSDCTest is Test {
    DvUSDC internal token;

    address internal vaultRouter = makeAddr("vaultRouter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new DvUSDC(vaultRouter);
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_revertsWhenRouterIsZero() public {
        vm.expectRevert(DvUSDC.ZeroRouter.selector);
        new DvUSDC(address(0));
    }

    function test_constructor_setsImmutableRouterAndMetadata() public view {
        assertEq(token.VAULT_ROUTER(), vaultRouter);
        assertEq(token.name(), "Divigent USDC");
        assertEq(token.symbol(), "dvUSDC");
        assertEq(token.decimals(), uint8(6));
    }

    // ── Mint / burn (only vault router) ───────────────────────────────────────

    function test_mint_revertsWhenCallerIsNotVaultRouter() public {
        vm.expectRevert(abi.encodeWithSelector(DvUSDC.OnlyVaultRouter.selector, alice));
        vm.prank(alice);
        token.mint(bob, 1e6);
    }

    function test_burn_revertsWhenCallerIsNotVaultRouter() public {
        vm.expectRevert(abi.encodeWithSelector(DvUSDC.OnlyVaultRouter.selector, alice));
        vm.prank(alice);
        token.burn(bob, 1e6);
    }

    function test_mint_fromVaultRouter_increasesBalanceAndTotalSupply() public {
        vm.prank(vaultRouter);
        token.mint(alice, 1_000_000);

        assertEq(token.balanceOf(alice), 1_000_000);
        assertEq(token.totalSupply(), 1_000_000);
    }

    function test_mint_fromVaultRouter_canMintToMultipleWallets() public {
        vm.startPrank(vaultRouter);
        token.mint(alice, 100e6);
        token.mint(bob, 250e6);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 100e6);
        assertEq(token.balanceOf(bob), 250e6);
        assertEq(token.totalSupply(), 350e6);
    }

    function test_mint_zeroAmount_isNoOpButAllowed() public {
        vm.prank(vaultRouter);
        token.mint(alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_burn_fromVaultRouter_reducesBalanceAndTotalSupply() public {
        vm.prank(vaultRouter);
        token.mint(alice, 500e6);

        vm.prank(vaultRouter);
        token.burn(alice, 200e6);

        assertEq(token.balanceOf(alice), 300e6);
        assertEq(token.totalSupply(), 300e6);
    }

    function test_burn_revertsWhenBalanceInsufficient() public {
        vm.prank(vaultRouter);
        token.mint(alice, 10e6);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e6, 11e6));
        vm.prank(vaultRouter);
        token.burn(alice, 11e6);
    }

    // ── Non-transferability (peer transfers always revert) ────────────────────

    function test_transfer_revertsBetweenTwoNonZeroAddresses() public {
        vm.prank(vaultRouter);
        token.mint(alice, 100e6);

        vm.expectRevert(DvUSDC.NonTransferable.selector);
        vm.prank(alice);
        token.transfer(bob, 50e6);
    }

    /// @dev Self-transfer is still `from != 0 && to != 0` — must revert (OZ allows same-address transfer path).
    function test_transfer_revertsOnSelfTransfer() public {
        vm.prank(vaultRouter);
        token.mint(alice, 100e6);

        vm.expectRevert(DvUSDC.NonTransferable.selector);
        vm.prank(alice);
        token.transfer(alice, 10e6);
    }

    function test_transferFrom_revertsBetweenTwoNonZeroAddressesEvenWithAllowance() public {
        vm.prank(vaultRouter);
        token.mint(alice, 100e6);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.expectRevert(DvUSDC.NonTransferable.selector);
        vm.prank(bob);
        token.transferFrom(alice, carol, 50e6);
    }

    function test_transfer_revertsWhenRecipientIsRouterButSenderIsNotMinting() public {
        vm.prank(vaultRouter);
        token.mint(alice, 100e6);

        vm.expectRevert(DvUSDC.NonTransferable.selector);
        vm.prank(alice);
        token.transfer(vaultRouter, 10e6);
    }

    // ── NEW: edge cases and invariants ──────────────────────────────────────

    function test_mint_toAddressZero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(vaultRouter);
        token.mint(address(0), 100e6);
    }

    function test_burn_fromAddressZero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(vaultRouter);
        token.burn(address(0), 100e6);
    }

    function test_burn_exactBalanceLeavesZero() public {
        vm.prank(vaultRouter);
        token.mint(alice, 500e6);

        vm.prank(vaultRouter);
        token.burn(alice, 500e6);

        assertEq(token.balanceOf(alice), 0, "Burning exact balance should leave zero");
        assertEq(token.totalSupply(), 0, "Total supply should be zero");
    }

    function test_burn_zeroBalanceReverts() public {
        // Bob has no tokens.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        vm.prank(vaultRouter);
        token.burn(bob, 1);
    }

    function test_approve_worksEvenThoughTransfersRevert() public {
        vm.prank(vaultRouter);
        token.mint(alice, 100e6);

        vm.prank(alice);
        token.approve(bob, 50e6);

        assertEq(token.allowance(alice, bob), 50e6, "Allowance should be set");

        // But using the allowance still reverts
        vm.expectRevert(DvUSDC.NonTransferable.selector);
        vm.prank(bob);
        token.transferFrom(alice, bob, 50e6);
    }

    function test_mint_nonRouterWithZeroAmount_stillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DvUSDC.OnlyVaultRouter.selector, alice));
        vm.prank(alice);
        token.mint(bob, 0);
    }

    function test_burn_nonRouterWithZeroAmount_stillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DvUSDC.OnlyVaultRouter.selector, alice));
        vm.prank(alice);
        token.burn(bob, 0);
    }

    function test_multipleMintsThenPartialBurn_tracksTotalSupply() public {
        vm.startPrank(vaultRouter);
        token.mint(alice, 100e6);
        token.mint(bob, 200e6);
        token.mint(carol, 300e6);
        assertEq(token.totalSupply(), 600e6, "Total supply after 3 mints");

        token.burn(bob, 150e6);
        assertEq(token.totalSupply(), 450e6, "Total supply after partial burn");
        assertEq(token.balanceOf(bob), 50e6, "Bob remaining balance");
        assertEq(token.balanceOf(alice), 100e6, "Alice unaffected");
        assertEq(token.balanceOf(carol), 300e6, "Carol unaffected");
        vm.stopPrank();
    }

    function test_decimals_returnsSix() public view {
        assertEq(token.decimals(), 6, "dvUSDC should have 6 decimals");
    }

    function test_nameAndSymbol() public view {
        assertEq(token.name(), "Divigent USDC");
        assertEq(token.symbol(), "dvUSDC");
    }

    // ── Fuzz: only router can move supply via mint/burn ───────────────────────

    function testFuzz_mintBurn_roundTripConservesSupplyInvariant(uint128 rawAmount) public {
        uint256 amount = uint256(rawAmount);
        vm.assume(amount > 0);

        vm.prank(vaultRouter);
        token.mint(alice, amount);

        vm.prank(vaultRouter);
        token.burn(alice, amount);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testFuzz_transfer_alwaysRevertsForPeerTransfer(uint128 rawAmt, address recipient) public {
        vm.assume(recipient != address(0));
        uint256 amt = uint256(rawAmt);
        vm.assume(amt > 0);

        vm.prank(vaultRouter);
        token.mint(alice, amt);

        vm.expectRevert(DvUSDC.NonTransferable.selector);
        vm.prank(alice);
        token.transfer(recipient, amt);
    }
}
