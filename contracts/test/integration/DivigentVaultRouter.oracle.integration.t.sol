// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";
import {RouterIntegrationBase} from "./RouterIntegrationBase.sol";

contract DivigentVaultRouterOracleIntegrationTest is RouterIntegrationBase {
    /// @dev Deposits should fall back to Morpho when the oracle prefers Aave but
    ///      Aave has insufficient immediate capacity for the requested amount.
    function test_deposit_fallsBackToMorphoWhenPreferredAaveHasNoCapacity() public {
        uint256 amount = 10_000e6;

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _setAaveAvailableLiquidity(0);

        uint256 shares = _deposit(alice, alice, amount);

        assertGt(shares, 0, "Fallback deposit should still mint shares");
        assertEq(aToken.balanceOf(address(router)), 0, "Aave should receive no assets on Morpho fallback");
        assertEq(morphoVault.totalAssets_(), amount, "Morpho should receive the full deposit on fallback");
    }

    /// @dev A stale oracle must block new deposits, but existing positions should
    ///      still be withdrawable.
    function test_staleOracle_blocksDepositButNotWithdraw() public {
        uint256 amount = 10_000e6;

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, amount);

        vm.warp(block.timestamp + 7201);
        oracle.setFresh(false);

        vm.startPrank(alice);
        usdc.approve(address(router), amount);
        vm.expectRevert(IDivigentVaultRouter.StaleOracle.selector);
        router.deposit(amount, alice, 0);
        vm.stopPrank();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);

        assertEq(returned, amount, "Stale oracle should not affect withdrawal of principal-only position");
        assertEq(usdc.balanceOf(alice), aliceBefore + amount, "Withdraw should still transfer USDC to Alice");
    }
}
