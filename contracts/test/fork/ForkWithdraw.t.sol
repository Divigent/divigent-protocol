// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";

/// @title  Fork Withdraw Tests
/// @notice Verifies withdrawal flows against real Aave V3 and Morpho on Base.
contract ForkWithdrawTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_withdraw_fullExit() public {
        uint256 depositAmt = 50_000e6;
        uint256 shares = _deposit(alice, depositAmt);

        uint256 balBefore = usdc.balanceOf(alice);
        uint256 returned = _withdraw(alice, shares);

        assertGt(returned, 0, "Got USDC back");
        assertGe(returned, depositAmt - 2, "Returned >= deposit - 2 (rounding)");
        assertLe(returned, depositAmt, "Returned <= deposit (no yield yet)");
        assertEq(dvUsdc.balanceOf(alice), 0, "All shares burned");
        assertEq(router.costBasisUSDC(alice), 0, "costBasis == 0 after full exit");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4: no residual USDC");
        assertEq(usdc.balanceOf(alice), balBefore + returned, "USDC arrived at alice");
    }

    function testFork_withdraw_partialExit() public {
        uint256 depositAmt = 50_000e6;
        uint256 shares = _deposit(alice, depositAmt);
        uint256 half = shares / 2;

        uint256 returned = _withdraw(alice, half);

        assertGt(returned, 0, "Partial withdraw returned USDC");
        assertGt(dvUsdc.balanceOf(alice), 0, "Still has remaining shares");
        assertGt(router.costBasisUSDC(alice), 0, "Still has costBasis");
        assertLt(router.costBasisUSDC(alice), depositAmt, "costBasis reduced");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4");
    }

    function testFork_withdraw_withYield() public {
        uint256 depositAmt = 50_000e6;
        uint256 shares = _deposit(alice, depositAmt);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // Advance 7 days for real Aave yield accrual
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 302_400); // ~7 days of Base blocks (2s each)

        uint256 returned = _withdraw(alice, shares);

        // With real Aave yield over 7 days (~4% APY), expect tiny yield
        // The key check: fee was charged if there was yield
        uint256 treasuryAfter = usdc.balanceOf(treasury);

        if (returned > depositAmt) {
            // Yield was earned — treasury should have received a fee
            assertGt(treasuryAfter, treasuryBefore, "Fee charged on real yield");
        }

        assertEq(dvUsdc.balanceOf(alice), 0, "All shares burned");
        assertEq(router.costBasisUSDC(alice), 0, "costBasis zeroed");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4");
    }

    function testFork_withdraw_slippageGuard() public {
        uint256 shares = _deposit(alice, 50_000e6);

        // Withdraw with reasonable slippage (should succeed)
        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 49_990e6);
        assertGt(returned, 0, "Withdraw with slippage succeeded");
    }

    function testFork_withdraw_slippageExceeded() public {
        uint256 shares = _deposit(alice, 50_000e6);

        // Withdraw with impossible slippage (should revert)
        vm.prank(alice);
        vm.expectRevert();
        router.withdraw(shares, alice, 100_000e6); // demanding more than deposited
    }

    function testFork_withdraw_multiUserIndependence() public {
        _deposit(alice, 50_000e6);
        uint256 bobShares = _deposit(bob, 30_000e6);

        // Alice fully exits
        _withdrawAll(alice);

        // Bob's position should be unaffected
        assertEq(dvUsdc.balanceOf(bob), bobShares, "Bob shares unchanged");
        assertEq(router.costBasisUSDC(bob), 30_000e6, "Bob costBasis unchanged");

        // Bob can also exit
        uint256 bobReturned = _withdrawAll(bob);
        assertGe(bobReturned, 30_000e6 - 2, "Bob gets his deposit back");
        assertEq(usdc.balanceOf(address(router)), 0, "INV-4 final");
    }

    function testFork_withdraw_insufficientSharesReverts() public {
        _deposit(alice, 10_000e6);
        uint256 shares = dvUsdc.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        router.withdraw(shares + 1, alice, 0);
    }

    function testFork_withdraw_zeroSharesReverts() public {
        _deposit(alice, 10_000e6);

        vm.prank(alice);
        vm.expectRevert();
        router.withdraw(0, alice, 0);
    }

    function testFork_withdraw_unauthorizedReverts() public {
        _deposit(alice, 10_000e6);
        uint256 shares = dvUsdc.balanceOf(alice);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        router.withdraw(shares, alice, 0);
    }

    function testFork_withdraw_costBasisZeroAfterFullExit() public {
        _deposit(alice, 50_000e6);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 302_400);

        _withdrawAll(alice);

        assertEq(router.costBasisUSDC(alice), 0, "costBasis exactly 0 after full exit");
        assertEq(dvUsdc.balanceOf(alice), 0, "zero shares");
    }
}
