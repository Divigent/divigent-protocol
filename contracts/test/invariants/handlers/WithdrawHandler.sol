// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {DvUSDC} from "../../../src/dvUSDC.sol";

/// @title WithdrawHandler
/// @notice Performs bounded random withdrawals from actors with positions.
contract WithdrawHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    DvUSDC public dvUsdc;
    address[] public actors;

    uint256 public totalWithdrawn;
    uint256 public totalFeesPaid;
    uint256 public withdrawCount;

    constructor(DivigentVaultRouter router_, DvUSDC dvUsdc_, address[] memory actors_) {
        router = router_;
        dvUsdc = dvUsdc_;
        actors = actors_;
    }

    function withdraw(uint256 actorSeed, uint256 sharePct) external {
        sharePct = bound(sharePct, 1, 100);
        address actor = actors[actorSeed % actors.length];

        uint256 shares = dvUsdc.balanceOf(actor);
        if (shares == 0) return; // nothing to withdraw

        uint256 toWithdraw = (shares * sharePct) / 100;
        if (toWithdraw == 0) return;

        vm.prank(actor);
        try router.withdraw(toWithdraw, actor, 0) returns (uint256 returned) {
            totalWithdrawn += returned;
            withdrawCount++;
        } catch {
            // Expected: insufficient liquidity or rounding
        }
    }
}
