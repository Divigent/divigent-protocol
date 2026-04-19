// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {DvUSDC} from "../../../src/dvUSDC.sol";

/// @title WithdrawHandler
/// @notice Performs bounded random withdrawals and tracks per-withdraw
///         realized yield + fees to enable exact fee-yield closure invariants.
contract WithdrawHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    DvUSDC public dvUsdc;
    IERC20 public usdc;
    address public treasury;
    address[] public actors;

    uint256 public totalWithdrawn;
    uint256 public totalFeesPaid;
    uint256 public withdrawCount;

    /// @dev Sum of realized yield across all withdraws — i.e. (returned + fee)
    ///      minus principalOut for each withdraw where the wallet was in profit.
    ///      Enables the exact closure check: treasury ≈ realizedYield × FEE_BPS / BPS_DENOM.
    uint256 public totalRealizedYield;

    constructor(
        DivigentVaultRouter router_,
        DvUSDC dvUsdc_,
        IERC20 usdc_,
        address treasury_,
        address[] memory actors_
    ) {
        router = router_;
        dvUsdc = dvUsdc_;
        usdc = usdc_;
        treasury = treasury_;
        actors = actors_;
    }

    function withdraw(uint256 actorSeed, uint256 sharePct) external {
        sharePct = bound(sharePct, 1, 100);
        address actor = actors[actorSeed % actors.length];

        uint256 shares = dvUsdc.balanceOf(actor);
        if (shares == 0) return; // nothing to withdraw

        uint256 toWithdraw = (shares * sharePct) / 100;
        if (toWithdraw == 0) return;

        // Snapshot state for realized-yield / fee accounting
        uint256 costBasisBefore = router.costBasisUSDC(actor);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(actor);
        try router.withdraw(toWithdraw, actor, 0) returns (uint256 returned) {
            totalWithdrawn += returned;
            withdrawCount++;

            uint256 costBasisAfter = router.costBasisUSDC(actor);
            uint256 principalOut = costBasisBefore - costBasisAfter;
            uint256 feePaid = usdc.balanceOf(treasury) - treasuryBefore;
            totalFeesPaid += feePaid;

            // Realized yield = gross paid out from vaults − principal redeemed.
            // Gross = user's USDC + fee paid to treasury.
            uint256 gross = returned + feePaid;
            if (gross > principalOut) {
                totalRealizedYield += gross - principalOut;
            }
        } catch {
            // Expected: insufficient liquidity or rounding
        }
    }
}
