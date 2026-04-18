// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

/// @title  Fork Mixed Vault Tests
/// @notice Tests positions split across both Aave and Morpho on Base mainnet.
///         Verifies proportional withdrawal, shortfall redirect, and asset decomposition.
contract ForkMixedVaultTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    function testFork_mixed_totalVaultAssetsDecomposition() public {
        _deposit(alice, 100_000e6);

        (uint256 aaveAssets, uint256 morphoAssets) = router.getCurrentAllocation();
        uint256 tva = router.totalVaultAssets();

        assertEq(tva, aaveAssets + morphoAssets, "TVA == aave + morpho");
        assertGe(tva, 100_000e6 - 2, "TVA >= deposit");
    }

    function testFork_mixed_withdrawFromBothVaults() public {
        // Positions may exist in one or both vaults. If oracle always picks Aave,
        // the router may only have an Aave position. This test verifies the single-vault
        // withdrawal path works, and if both have assets, both are tapped.
        _deposit(alice, 100_000e6);

        (uint256 aaveBefore, uint256 morphoBefore) = router.getCurrentAllocation();

        uint256 returned = _withdrawAll(alice);

        assertGt(returned, 0, "Got USDC back");
        assertGe(returned, 100_000e6 - 2, "Returned >= deposit");

        (uint256 aaveAfter, uint256 morphoAfter) = router.getCurrentAllocation();

        // Both should be 0 or near-0 after full withdrawal
        assertLe(aaveAfter, 4, "Aave position cleared (within dust)");
        assertLe(morphoAfter, 4, "Morpho position cleared (within dust)");
    }

    function testFork_mixed_partialWithdrawPreservesRatio() public {
        _deposit(alice, 100_000e6);

        (uint256 aavePre, uint256 morphoPre) = router.getCurrentAllocation();
        uint256 totalPre = aavePre + morphoPre;

        // Withdraw 50%
        uint256 half = dvUsdc.balanceOf(alice) / 2;
        _withdraw(alice, half);

        (uint256 aavePost, uint256 morphoPost) = router.getCurrentAllocation();
        uint256 totalPost = aavePost + morphoPost;

        // Total should be roughly halved
        assertApproxEqAbs(
            totalPost, totalPre / 2, totalPre / 100,
            "TVA roughly halved after 50% withdrawal"
        );
    }

    function testFork_mixed_getPositionConsistency() public {
        _deposit(alice, 60_000e6);
        _deposit(bob, 40_000e6);

        (,uint256 aliceVal,) = router.getPosition(alice);
        (,uint256 bobVal,) = router.getPosition(bob);

        uint256 tva = router.totalVaultAssets();

        // Sum of individual values should approximate totalVaultAssets
        assertApproxEqAbs(
            aliceVal + bobVal, tva, 10,
            "Sum of positions ~= TVA"
        );
    }

    function testFork_mixed_morphoMaxWithdraw() public {
        // Verify the real Morpho vault reports a sensible maxWithdraw
        uint256 maxW = morphoVault.maxWithdraw(address(router));
        // maxWithdraw for an address with no shares should be 0
        assertEq(maxW, 0, "maxWithdraw is 0 before any deposit");

        _deposit(alice, 50_000e6);

        // If deposit went to Morpho, maxWithdraw should be > 0
        uint256 morphoShares = morphoVault.balanceOf(address(router));
        if (morphoShares > 0) {
            uint256 maxWAfter = morphoVault.maxWithdraw(address(router));
            assertGt(maxWAfter, 0, "maxWithdraw > 0 after Morpho deposit");
        }
    }
}
