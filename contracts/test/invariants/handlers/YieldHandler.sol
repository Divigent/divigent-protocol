// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockMorphoVault} from "../../mocks/MockMorphoVault.sol";

/// @title YieldHandler
/// @notice Simulates yield accrual AND loss on both Aave and Morpho vaults.
///         Aave gains: mint aTokens to the router (mirrors rebasing).
///         Aave losses: burn aTokens from the router.
///         Morpho gains: accrueYield on the mock (inflates share price).
///         Morpho losses: setTotalAssets on the mock (deflates share price).
///
///         Including losses unlocks invariant exploration of the loss regimes —
///         PPS-decrease paths, fee-clamp-at-zero, and the previewWithdrawNet
///         loss branch. Without loss events, the entire drawdown class is
///         invisible to the invariant fuzzer.
contract YieldHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    MockERC20 public aToken;
    MockMorphoVault public morphoVault;

    uint256 public totalYieldAccrued;
    uint256 public totalLossAccrued;
    uint256 public yieldCount;
    uint256 public lossCount;

    uint256 constant MAX_YIELD = 5_000e6;
    // Loss capped to a small fraction of current holdings to keep invariants
    // tractable; extreme losses are covered by dedicated targeted tests.
    uint256 constant MAX_LOSS_BPS = 2_500; // 25 % of current holdings per event

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

    /// @dev Simulate a loss on the Aave leg by burning aTokens from the router.
    ///      Bounded to ≤25% of current holdings per event.
    function accrueLoss(uint256 bps) external {
        uint256 balance = aToken.balanceOf(address(router));
        if (balance == 0) return;

        bps = bound(bps, 1, MAX_LOSS_BPS);
        uint256 loss = (balance * bps) / 10_000;
        if (loss == 0) return;

        aToken.burn(address(router), loss);
        totalLossAccrued += loss;
        lossCount++;
    }

    /// @dev Simulate a loss on the Morpho leg by deflating the mock's totalAssets.
    ///      Bounded to ≤25% of current assets per event.
    function accrueMorphoLoss(uint256 bps) external {
        if (morphoVault.balanceOf(address(router)) == 0) return;

        uint256 currentAssets = morphoVault.totalAssets();
        if (currentAssets == 0) return;

        bps = bound(bps, 1, MAX_LOSS_BPS);
        uint256 loss = (currentAssets * bps) / 10_000;
        if (loss == 0) return;

        morphoVault.setTotalAssets(currentAssets - loss);
        totalLossAccrued += loss;
        lossCount++;
    }
}
