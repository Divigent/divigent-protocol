// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./integration/helpers/Actions.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";

/// @title  depositWithPermit frontrun tolerance
/// @notice Pins OpenZeppelin's recommended permit pattern: `permit()` is
///         best-effort because anyone can submit a valid permit, and the
///         allowance after that attempt is the actual spending authority.
contract DivigentVaultRouterPermitFrontrunTest is Actions {
    uint256 internal constant DEPOSIT_AMOUNT = 10_000e6;

    function test_depositWithPermit_succeedsWhenPermitFrontrunWithoutPriorAllowance() public {
        useAaveRoute();

        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_frontrun_wallet");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        address searcher = makeAddr("permit_frontrunner");
        vm.prank(searcher);
        usdc.permit(wallet, address(router), DEPOSIT_AMOUNT, deadline, v, r, s);

        assertEq(usdc.nonces(wallet), 1, "permit nonce consumed by frontrunner");
        assertEq(usdc.allowance(wallet, address(router)), DEPOSIT_AMOUNT, "router allowance installed");

        vm.prank(wallet);
        uint256 minted = router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);

        assertGt(minted, 0, "deposit succeeds after frontrun permit");
        assertEq(dvUsdc.balanceOf(wallet), minted, "shares credited to wallet");
        assertEq(usdc.balanceOf(wallet), 0, "deposit pulled wallet USDC");
        assertEq(usdc.allowance(wallet, address(router)), 0, "allowance consumed by deposit");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no transient USDC");
    }

    function test_depositWithPermit_succeedsWhenPermitFailsButAllowanceAlreadySufficient() public {
        useAaveRoute();

        (address wallet,) = makeAddrAndKey("permit_allowance_wallet");
        (, uint256 wrongKey) = makeAddrAndKey("permit_allowance_wrong_key");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        vm.prank(wallet);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(wrongKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        uint256 minted = router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);

        assertGt(minted, 0, "pre-existing allowance authorizes deposit");
        assertEq(dvUsdc.balanceOf(wallet), minted, "shares minted");
        assertEq(usdc.nonces(wallet), 0, "failed permit does not consume nonce");
        assertEq(usdc.allowance(wallet, address(router)), 0, "allowance consumed by deposit");
    }

    function test_depositWithPermit_revertsWhenPermitFailsAndAllowanceInsufficient() public {
        useAaveRoute();

        (address wallet,) = makeAddrAndKey("permit_insufficient_wallet");
        (, uint256 wrongKey) = makeAddrAndKey("permit_insufficient_wrong_key");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(wrongKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.InsufficientPermitAllowance.selector,
                0,
                DEPOSIT_AMOUNT
            )
        );
        router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);
    }

    function test_depositWithPermit_revertsWhenPermitFailsAndAllowancePartial() public {
        useAaveRoute();

        (address wallet,) = makeAddrAndKey("permit_partial_wallet");
        (, uint256 wrongKey) = makeAddrAndKey("permit_partial_wrong_key");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 partialAllowance = DEPOSIT_AMOUNT / 2;
        vm.prank(wallet);
        usdc.approve(address(router), partialAllowance);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(wrongKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.InsufficientPermitAllowance.selector,
                partialAllowance,
                DEPOSIT_AMOUNT
            )
        );
        router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);

        assertEq(usdc.allowance(wallet, address(router)), partialAllowance, "partial allowance unchanged");
    }

    function test_depositWithPermit_normalPathUnchanged() public {
        useAaveRoute();

        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_normal_wallet");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        uint256 minted = router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);

        assertGt(minted, 0, "valid permit still deposits");
        assertEq(dvUsdc.balanceOf(wallet), minted, "shares minted");
        assertEq(usdc.nonces(wallet), 1, "permit nonce consumed once");
        assertEq(usdc.allowance(wallet, address(router)), 0, "allowance consumed by deposit");
    }

    function test_depositWithPermit_expiredDeadlineKeepsPermitExpiredRevert() public {
        useAaveRoute();

        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_expired_wallet");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.warp(deadline + 1);

        vm.prank(wallet);
        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);

        assertEq(usdc.nonces(wallet), 0, "expired path does not touch permit");
        assertEq(usdc.allowance(wallet, address(router)), 0, "expired path leaves allowance unchanged");
    }

    function test_depositWithPermit_revertLeavesWalletAndProtocolStateUnchanged() public {
        useAaveRoute();

        (address wallet,) = makeAddrAndKey("permit_revert_state_wallet");
        (, uint256 wrongKey) = makeAddrAndKey("permit_revert_state_wrong_key");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 walletUsdcBefore = usdc.balanceOf(wallet);
        uint256 walletSharesBefore = dvUsdc.balanceOf(wallet);
        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 totalAssetsBefore = router.totalVaultAssets();
        uint256 totalSupplyBefore = dvUsdc.totalSupply();
        uint256 nonceBefore = usdc.nonces(wallet);
        (uint256 costBasisBefore,,) = router.getPosition(wallet);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(wrongKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.InsufficientPermitAllowance.selector,
                0,
                DEPOSIT_AMOUNT
            )
        );
        router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, 0);

        assertEq(usdc.balanceOf(wallet), walletUsdcBefore, "wallet USDC unchanged");
        assertEq(dvUsdc.balanceOf(wallet), walletSharesBefore, "wallet shares unchanged");
        assertEq(usdc.balanceOf(address(router)), routerUsdcBefore, "router USDC unchanged");
        assertEq(router.totalVaultAssets(), totalAssetsBefore, "vault assets unchanged");
        assertEq(dvUsdc.totalSupply(), totalSupplyBefore, "share supply unchanged");
        assertEq(usdc.nonces(wallet), nonceBefore, "bad permit does not consume nonce");
        assertEq(usdc.allowance(wallet, address(router)), 0, "allowance remains zero");
        (uint256 costBasisAfter,,) = router.getPosition(wallet);
        assertEq(costBasisAfter, costBasisBefore, "cost basis unchanged");
    }

    function test_depositWithPermit_frontrunPermitStillHonorsMinSharesOut() public {
        useAaveRoute();

        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_slippage_frontrun_wallet");
        fundAndRegister(wallet, DEPOSIT_AMOUNT);

        uint256 minSharesOut = router.previewDeposit(DEPOSIT_AMOUNT) + 1;
        uint256 actualMint = router.previewDeposit(DEPOSIT_AMOUNT);
        assertLt(actualMint, minSharesOut, "precondition: minimum is too high");

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, wallet, address(router), DEPOSIT_AMOUNT, deadline);

        address searcher = makeAddr("permit_slippage_frontrunner");
        vm.prank(searcher);
        usdc.permit(wallet, address(router), DEPOSIT_AMOUNT, deadline, v, r, s);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.SlippageExceeded.selector,
                actualMint,
                minSharesOut
            )
        );
        router.depositWithPermit(DEPOSIT_AMOUNT, wallet, deadline, v, r, s, minSharesOut);

        assertEq(usdc.allowance(wallet, address(router)), DEPOSIT_AMOUNT, "frontrun allowance remains after revert");
        assertEq(dvUsdc.balanceOf(wallet), 0, "no shares minted on slippage revert");
    }
}
