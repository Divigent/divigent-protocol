// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";

/// @title  Fork Round-Trip Tests
/// @notice Verifies deposit->withdraw conservation on real Aave V3 and Morpho.
///         The core question: does money come back?
contract ForkRoundTripTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_roundTrip_immediate() public {
        uint256 amount = 50_000e6;
        uint256 balBefore = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, amount);
        uint256 returned = _withdraw(alice, shares);

        uint256 balAfter = usdc.balanceOf(alice);

        // Round-trip should return within 2 wei (virtual offset)
        assertGe(balAfter, balBefore - 2, "Round-trip loss <= 2 wei");
        assertLe(balAfter, balBefore, "No USDC created from nothing");
        assertEq(dvUsdc.balanceOf(alice), 0, "All shares burned");
        assertEq(router.costBasisUSDC(alice), 0, "costBasis zeroed");
    }

    function testFork_roundTrip_multiUser() public {
        uint256 aliceAmt = 60_000e6;
        uint256 bobAmt = 40_000e6;

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        _deposit(alice, aliceAmt);
        _deposit(bob, bobAmt);

        // Alice exits first
        _withdrawAll(alice);

        // Bob exits after
        _withdrawAll(bob);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 bobAfter = usdc.balanceOf(bob);

        assertGe(aliceAfter, aliceBefore - 2, "Alice: round-trip loss <= 2 wei");
        assertGe(bobAfter, bobBefore - 2, "Bob: round-trip loss <= 2 wei");
        assertLe(aliceAfter, aliceBefore, "Alice: no USDC from nothing");
        assertLe(bobAfter, bobBefore, "Bob: no USDC from nothing");
    }

    function testFork_roundTrip_conservation() public {
        uint256 a1 = 30_000e6;
        uint256 a2 = 20_000e6;
        uint256 b1 = 50_000e6;

        uint256 totalIn = a1 + a2 + b1;

        _deposit(alice, a1);
        _deposit(bob, b1);
        _deposit(alice, a2);

        uint256 aliceReturned = _withdrawAll(alice);
        uint256 bobReturned = _withdrawAll(bob);
        uint256 totalOut = aliceReturned + bobReturned;
        uint256 fees = usdc.balanceOf(treasury);

        // Conservation: totalOut + fees <= totalIn (no yield in same block)
        assertLe(totalOut + fees, totalIn, "Conservation: out + fees <= in");
        // totalOut should be very close to totalIn (within rounding)
        assertGe(totalOut, totalIn - 10, "Conservation: out >= in - 10 (rounding)");
    }

    function testFork_roundTrip_withYieldConservation() public {
        _deposit(alice, 50_000e6);
        _deposit(bob, 50_000e6);

        // Let real yield accrue
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 tvaBefore = router.totalVaultAssets();
        uint256 aliceReturned = _withdrawAll(alice);
        uint256 bobReturned = _withdrawAll(bob);
        uint256 fees = usdc.balanceOf(treasury);

        uint256 totalOut = aliceReturned + bobReturned + fees;

        // Conservation: everything that left the vault is accounted for
        assertApproxEqAbs(
            totalOut, tvaBefore, 10_000,
            "Conservation: user returns + fees == pre-withdrawal TVA"
        );

        // Both users should have gotten back at least their deposit
        assertGe(aliceReturned, 50_000e6 - 2, "Alice got at least principal");
        assertGe(bobReturned, 50_000e6 - 2, "Bob got at least principal");
    }

    function testFork_roundTrip_smallAmount() public {
        uint256 amount = 10e6; // MIN_DEPOSIT = $10
        uint256 balBefore = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, amount);
        _withdraw(alice, shares);

        uint256 balAfter = usdc.balanceOf(alice);
        assertGe(balAfter, balBefore - 2, "Small round-trip loss <= 2 wei");
    }

    function testFork_roundTrip_largeAmount() public {
        uint256 amount = 400_000e6; // $400k (near TVL cap)
        uint256 balBefore = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, amount);
        _withdraw(alice, shares);

        uint256 balAfter = usdc.balanceOf(alice);
        assertGe(balAfter, balBefore - 2, "Large round-trip loss <= 2 wei");
    }
}
