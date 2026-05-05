// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./integration/helpers/Actions.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Deposit min-shares slippage guard
/// @notice Pins the deposit-side equivalent of withdraw's `minUsdcOut` guard:
///         callers must be able to reject deposits that would mint fewer
///         dvUSDC shares than their quoted minimum.
contract DivigentVaultRouterDepositSlippageTest is Actions {
    uint256 internal constant DEPOSIT_AMOUNT = 10_000e6;
    uint256 internal constant DONATION_AMOUNT = 1_000e6;

    function test_deposit_revertsWhenMintBelowMinSharesOut() public {
        useAaveRoute();

        uint256 minSharesOut = router.previewDeposit(DEPOSIT_AMOUNT);
        _donateAaveAssets(DONATION_AMOUNT);
        uint256 dilutedMint = router.previewDeposit(DEPOSIT_AMOUNT);
        assertLt(dilutedMint, minSharesOut, "donation must reduce shares minted");
        _approve(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.SlippageExceeded.selector,
                dilutedMint,
                minSharesOut
            )
        );
        router.deposit(DEPOSIT_AMOUNT, alice, minSharesOut);
    }

    function test_deposit_succeedsAtMinSharesOutBoundary() public {
        useAaveRoute();

        _donateAaveAssets(DONATION_AMOUNT);
        uint256 minSharesOut = router.previewDeposit(DEPOSIT_AMOUNT);
        assertGt(minSharesOut, 0, "precondition: deposit still mints shares");
        _approve(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 minted = router.deposit(DEPOSIT_AMOUNT, alice, minSharesOut);

        assertEq(minted, minSharesOut, "strictly below minimum reverts; equality succeeds");
        assertEq(dvUsdc.balanceOf(alice), minted, "minted shares credited to wallet");
    }

    function test_deposit_zeroMinSharesOutAcceptsAnyPositiveMint() public {
        useAaveRoute();

        _donateAaveAssets(DONATION_AMOUNT);
        uint256 expectedMint = router.previewDeposit(DEPOSIT_AMOUNT);
        assertGt(expectedMint, 0, "precondition: positive mint");
        _approve(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        uint256 minted = router.deposit(DEPOSIT_AMOUNT, alice, 0);

        assertEq(minted, expectedMint, "zero minimum explicitly accepts the computed mint");
    }

    function test_deposit_revertLeavesWalletAndProtocolStateUnchanged() public {
        useAaveRoute();

        uint256 minSharesOut = router.previewDeposit(DEPOSIT_AMOUNT);
        _donateAaveAssets(DONATION_AMOUNT);
        uint256 dilutedMint = router.previewDeposit(DEPOSIT_AMOUNT);
        assertLt(dilutedMint, minSharesOut, "precondition: slippage path");
        _approve(alice, DEPOSIT_AMOUNT);

        uint256 walletUsdcBefore = usdc.balanceOf(alice);
        uint256 walletSharesBefore = dvUsdc.balanceOf(alice);
        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 totalAssetsBefore = router.totalVaultAssets();
        uint256 totalSupplyBefore = dvUsdc.totalSupply();
        uint256 costBasisBefore;
        (costBasisBefore,,) = router.getPosition(alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.SlippageExceeded.selector,
                dilutedMint,
                minSharesOut
            )
        );
        router.deposit(DEPOSIT_AMOUNT, alice, minSharesOut);

        assertEq(usdc.balanceOf(alice), walletUsdcBefore, "wallet USDC unchanged");
        assertEq(dvUsdc.balanceOf(alice), walletSharesBefore, "wallet shares unchanged");
        assertEq(usdc.balanceOf(address(router)), routerUsdcBefore, "router keeps no transient USDC");
        assertEq(router.totalVaultAssets(), totalAssetsBefore, "vault assets unchanged");
        assertEq(dvUsdc.totalSupply(), totalSupplyBefore, "share supply unchanged");
        (uint256 costBasisAfter,,) = router.getPosition(alice);
        assertEq(costBasisAfter, costBasisBefore, "cost basis unchanged");
    }

    function test_depositWithPermit_revertsWhenMintBelowMinSharesOut() public {
        useAaveRoute();

        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_slippage_wallet");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 minSharesOut = router.previewDeposit(DEPOSIT_AMOUNT);
        _donateAaveAssets(DONATION_AMOUNT);
        uint256 dilutedMint = router.previewDeposit(DEPOSIT_AMOUNT);
        assertLt(dilutedMint, minSharesOut, "donation must reduce shares minted");

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.SlippageExceeded.selector,
                dilutedMint,
                minSharesOut
            )
        );
        router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, minSharesOut);

        assertEq(usdc.nonces(wallet), 0, "reverted permit-deposit must not consume nonce");
        assertEq(usdc.allowance(wallet, address(router)), 0, "reverted permit-deposit leaves no allowance");
        assertEq(dvUsdc.balanceOf(wallet), 0, "reverted permit-deposit mints no shares");
    }

    function test_depositWithPermit_succeedsAtMinSharesOutBoundary() public {
        useAaveRoute();

        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_boundary_wallet");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        _donateAaveAssets(DONATION_AMOUNT);
        uint256 minSharesOut = router.previewDeposit(DEPOSIT_AMOUNT);
        assertGt(minSharesOut, 0, "precondition: deposit still mints shares");

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        uint256 minted = router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, minSharesOut);

        assertEq(minted, minSharesOut, "permit deposit honors inclusive minimum");
        assertEq(dvUsdc.balanceOf(wallet), minted, "shares credited to wallet");
        assertEq(usdc.nonces(wallet), 1, "permit nonce consumed on success");
        assertEq(usdc.allowance(wallet, address(router)), 0, "allowance consumed by deposit");
    }

    function _approve(address wallet, uint256 amount) internal {
        vm.prank(wallet);
        usdc.approve(address(router), amount);
    }

    function _donateAaveAssets(uint256 amount) internal {
        aToken.mint(address(router), amount);
    }
}
