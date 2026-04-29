// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {DvUSDC} from "../../../src/dvUSDC.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title OperatorHandler
/// @notice Fuzzes operator grant/revoke and operator-delegated deposits/withdrawals.
contract OperatorHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    DvUSDC public dvUsdc;
    MockERC20 public usdc;
    address[] public actors;
    address public operator;

    uint256 public operatorDepositCount;
    uint256 public operatorWithdrawCount;
    uint256 public totalOperatorDeposited;
    uint256 public totalOperatorWithdrawn;
    /// @dev Sum of realized yield across operator-triggered withdrawals. Feeds
    ///      the exact fee-yield closure invariant alongside WithdrawHandler's
    ///      equivalent counter for direct-user withdrawals.
    uint256 public totalOperatorRealizedYield;

    /// @notice USDC minted to the operator at construction. Pinned by the
    ///         `Operator-A` invariant: the operator must never accumulate
    ///         USDC beyond this baseline. Wallets receive all yield / principal
    ///         via the router; operators merely authorise calls on behalf of
    ///         wallets and never see the flow.
    uint256 public constant INITIAL_OPERATOR_BALANCE = 10_000_000e6;

    address public treasury;

    constructor(
        DivigentVaultRouter router_,
        DvUSDC dvUsdc_,
        MockERC20 usdc_,
        address treasury_,
        address[] memory actors_
    ) {
        router = router_;
        dvUsdc = dvUsdc_;
        usdc = usdc_;
        treasury = treasury_;
        actors = actors_;
        operator = address(0x70000);
        usdc.mint(operator, INITIAL_OPERATOR_BALANCE);
    }

    function grantOperator(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        router.setOperator(operator, true);
    }

    function revokeOperator(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        router.setOperator(operator, false);
    }

    function operatorDeposit(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 10e6, 50_000e6);
        address actor = actors[actorSeed % actors.length];

        if (!router.isOperator(actor, operator)) return;

        usdc.mint(actor, amount);
        vm.prank(actor);
        usdc.approve(address(router), amount);

        vm.prank(operator);
        try router.deposit(amount, actor, 0) {
            totalOperatorDeposited += amount;
            operatorDepositCount++;
        } catch {}
    }

    function operatorWithdraw(uint256 actorSeed, uint256 sharePct) external {
        sharePct = bound(sharePct, 1, 100);
        address actor = actors[actorSeed % actors.length];

        if (!router.isOperator(actor, operator)) return;

        uint256 shares = dvUsdc.balanceOf(actor);
        if (shares == 0) return;

        uint256 toWithdraw = (shares * sharePct) / 100;
        if (toWithdraw == 0) return;

        // Snapshot state for realized-yield accounting (mirrors WithdrawHandler).
        uint256 costBasisBefore = router.costBasisUSDC(actor);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(operator);
        try router.withdraw(toWithdraw, actor, 0) returns (uint256 returned) {
            totalOperatorWithdrawn += returned;
            operatorWithdrawCount++;

            uint256 costBasisAfter = router.costBasisUSDC(actor);
            uint256 principalOut = costBasisBefore - costBasisAfter;
            uint256 feePaid = usdc.balanceOf(treasury) - treasuryBefore;

            uint256 gross = returned + feePaid;
            if (gross > principalOut) {
                totalOperatorRealizedYield += gross - principalOut;
            }
        } catch {}
    }
}
