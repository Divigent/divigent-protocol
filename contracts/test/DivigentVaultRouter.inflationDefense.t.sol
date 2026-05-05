// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "test/TestBase.sol";

/// @title Donation Inflation Defense Regression Tests
/// @notice Pins the early-supply donation scenarios from the audit. Directly
///         donated vault tokens must not make normal deposits zero-mint or
///         create cheap floor-loss griefing against later depositors.
contract DivigentVaultRouterInflationDefenseTest is TestBase {
    uint256 internal constant MAX_DUST_LOSS = 1e6; // 1 USDC

    function test_donationInflation_emptyRouterSmallDepositMintsRecoverableShares() public {
        uint256 donation = 1_001e6;
        uint256 victimDeposit = 1_000e6;

        _donateAavePosition(bob, donation);

        uint256 preview = router.previewDeposit(victimDeposit);
        assertGt(preview, 0, "preview must not quote a zero-share mint");

        uint256 shares = _depositFor(alice, victimDeposit);

        assertEq(shares, preview, "actual shares must match preview in unchanged state");
        assertGt(shares, 0, "victim must receive shares after donation");

        (, uint256 currentValue,) = router.getPosition(alice);
        assertGe(currentValue, victimDeposit - MAX_DUST_LOSS, "victim donation loss must stay below 1 USDC");
    }

    function test_donationInflation_auditGriefingScenarioDoesNotCaptureVictimValue() public {
        uint256 bobDonation = 500e6;
        uint256 bobDeposit = 50_100e6;
        uint256 aliceDeposit = 1_000e6;

        _donateAavePosition(bob, bobDonation);

        uint256 bobShares = _depositFor(bob, bobDeposit);
        assertGt(bobShares, 0, "bob should receive shares for his deposit");

        uint256 aliceShares = _depositFor(alice, aliceDeposit);
        assertGt(aliceShares, 0, "alice should receive shares for her deposit");

        (, uint256 aliceValue,) = router.getPosition(alice);
        assertGe(aliceValue, aliceDeposit - MAX_DUST_LOSS, "alice floor loss must stay below 1 USDC");

        (, uint256 bobValue,) = router.getPosition(bob);
        uint256 recoveredDonation = bobValue > bobDeposit ? bobValue - bobDeposit : 0;
        assertLe(recoveredDonation, MAX_DUST_LOSS, "bob must not recover a meaningful part of the donation");
    }

    function test_donationInflation_millionUsdcDonationCannotZeroMintStandardDeposit() public {
        uint256 donation = 1_000_000e6;
        uint256 victimDeposit = 1_000e6;

        usdc.mint(bob, donation);
        _donateAavePosition(bob, donation);

        uint256 preview = router.previewDeposit(victimDeposit);
        assertGt(preview, 0, "1M USDC donation must not zero-mint a 1000 USDC deposit");
    }

    function test_donationInflation_firstDepositorStillMintsOneToOne() public {
        uint256 amount = 1_000e6;

        uint256 preview = router.previewDeposit(amount);
        uint256 shares = _depositFor(alice, amount);

        assertEq(preview, amount, "empty-pool preview should stay 1:1");
        assertEq(shares, amount, "first deposit should stay 1:1");
        assertEq(router.pricePerShare(), 1e18, "first deposit should keep 1 USDC per dvUSDC");
    }

    function _donateAavePosition(address donor, uint256 amount) internal {
        usdc.burn(donor, amount);
        aToken.mint(address(router), amount);
    }

    function _depositFor(address wallet, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(wallet);
        usdc.approve(address(router), amount);
        shares = router.deposit(amount, wallet, 0);
        vm.stopPrank();
    }
}
