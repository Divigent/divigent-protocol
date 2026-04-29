// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RouterIntegrationBase} from "./integration/RouterIntegrationBase.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";
import {IDivigentYieldOracle} from "../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Preview/execution parity
/// @notice Pins the F-10 view guarantees: pricePerShare uses the same
///         virtual-offset ratio as execution math, and previewWithdrawNet
///         either returns a serviceable quote or reverts with a typed reason.
contract DivigentVaultRouterPreviewParityTest is RouterIntegrationBase {
    uint256 internal constant VIRTUAL_OFFSET = 1e6;

    function test_pricePerShare_emptyVaultReturnsOne() public view {
        assertEq(router.pricePerShare(), 1e18, "empty vault starts at one-to-one");
    }

    function test_pricePerShare_usesOffsetFormulaPostYield() public {
        uint256 depositAmount = 100_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        aToken.mint(address(router), 10_000e6);

        uint256 expected =
            ((router.totalVaultAssets() + VIRTUAL_OFFSET) * 1e18) / (dvUsdc.totalSupply() + VIRTUAL_OFFSET);
        assertEq(router.pricePerShare(), expected, "PPS follows offset-adjusted ratio");
    }

    function test_pricePerShare_deepLossStillUsesOffsetFormula() public {
        uint256 depositAmount = 100_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, depositAmount);

        aToken.burn(address(router), depositAmount - 1e6);

        uint256 expected =
            ((router.totalVaultAssets() + VIRTUAL_OFFSET) * 1e18) / (dvUsdc.totalSupply() + VIRTUAL_OFFSET);
        assertEq(router.pricePerShare(), expected, "PPS remains formula-consistent under loss");
        assertLe(router.convertToAssets(shares), router.totalVaultAssets(), "execution quote caps at physical assets");
    }

    function test_previewWithdrawNet_revertsZeroAmount() public {
        _deposit(alice, alice, 10_000e6);

        vm.expectRevert(IDivigentVaultRouter.ZeroAmount.selector);
        router.previewWithdrawNet(0, alice);
    }

    function test_previewWithdrawNet_revertsNoPositionToWithdraw() public {
        address emptyWallet = makeAddr("empty_preview_wallet");

        vm.expectRevert(IDivigentVaultRouter.NoPositionToWithdraw.selector);
        router.previewWithdrawNet(1e6, emptyWallet);
    }

    function test_previewWithdrawNet_revertsPositionRoundsToZero() public {
        vm.prank(address(router));
        dvUsdc.mint(alice, 1);

        vm.expectRevert(IDivigentVaultRouter.PositionRoundsToZero.selector);
        router.previewWithdrawNet(1, alice);
    }

    function test_previewWithdrawNet_revertsUnserviceableNetWithMaxDeliverable() public {
        uint256 depositAmount = 10_000e6;
        uint256 desiredNet = 1_000_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        aToken.mint(address(router), 1_000e6);

        uint256 maxDeliverable = router.previewRedeem(dvUsdc.balanceOf(alice), alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDivigentVaultRouter.UnserviceableNet.selector, desiredNet, maxDeliverable)
        );
        router.previewWithdrawNet(desiredNet, alice);
    }

    function test_previewWithdrawNet_thenWithdrawSucceedsAtExactMinOut_profit() public {
        uint256 depositAmount = 50_000e6;
        uint256 desiredNet = 51_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        aToken.mint(address(router), 2_000e6);

        uint256 shares = router.previewWithdrawNet(desiredNet, alice);
        assertGe(router.previewRedeem(shares, alice), desiredNet, "previewed shares service desired net");

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, desiredNet);
        assertGe(returned, desiredNet, "withdraw honors exact minOut from preview");
    }

    function test_previewWithdrawNet_exactMaxDeliverableReturnsWalletShares_profit() public {
        uint256 depositAmount = 50_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        aToken.mint(address(router), 2_000e6);

        uint256 walletShares = dvUsdc.balanceOf(alice);
        uint256 maxDeliverable = router.previewRedeem(walletShares, alice);
        uint256 shares = router.previewWithdrawNet(maxDeliverable, alice);
        assertEq(shares, walletShares, "exact max deliverable should quote full wallet shares");

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, maxDeliverable);
        assertGe(returned, maxDeliverable, "full withdrawal honors exact max minOut");
    }

    function test_previewWithdrawNet_thenWithdrawSucceedsAtExactMinOut_loss() public {
        uint256 depositAmount = 100_000e6;
        uint256 desiredNet = 10_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        aToken.burn(address(router), 20_000e6);

        uint256 shares = router.previewWithdrawNet(desiredNet, alice);
        assertGe(router.previewRedeem(shares, alice), desiredNet, "loss preview services desired net");

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, desiredNet);
        assertGe(returned, desiredNet, "loss withdraw honors exact minOut from preview");
    }
}
