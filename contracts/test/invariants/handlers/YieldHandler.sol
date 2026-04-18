// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockMorphoVault} from "../../mocks/MockMorphoVault.sol";

/// @title YieldHandler
/// @notice Simulates yield accrual on BOTH Aave and Morpho vaults.
///         Aave: mints aTokens to the router (mirrors rebasing).
///         Morpho: calls accrueYield on the mock (inflates share price).
contract YieldHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    MockERC20 public aToken;
    MockMorphoVault public morphoVault;

    uint256 public totalYieldAccrued;
    uint256 public yieldCount;

    uint256 constant MAX_YIELD = 5_000e6;

    constructor(DivigentVaultRouter router_, MockERC20 aToken_, MockMorphoVault morphoVault_) {
        router = router_;
        aToken = aToken_;
        morphoVault = morphoVault_;
    }

    function accrueYield(uint256 amount) external {
        amount = bound(amount, 1, MAX_YIELD);

        if (aToken.balanceOf(address(router)) == 0) return;

        aToken.mint(address(router), amount);
        totalYieldAccrued += amount;
        yieldCount++;
    }

    function accrueMorphoYield(uint256 amount) external {
        amount = bound(amount, 1, MAX_YIELD);

        if (morphoVault.balanceOf(address(router)) == 0) return;

        morphoVault.accrueYield(amount);
        totalYieldAccrued += amount;
        yieldCount++;
    }
}
