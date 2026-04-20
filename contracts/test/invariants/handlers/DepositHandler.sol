// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title DepositHandler
/// @notice Performs bounded random deposits from a pool of actors.
///         Handler is targeted by the fuzzer; it calls
///         protocol functions with constrained random inputs.
contract DepositHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    MockERC20 public usdc;
    address[] public actors;

    uint256 public totalDeposited;
    uint256 public depositCount;

    uint256 constant MIN_DEPOSIT = 10e6;
    uint256 constant MAX_DEPOSIT = 50_000e6;

    constructor(DivigentVaultRouter router_, MockERC20 usdc_, address[] memory actors_) {
        router = router_;
        usdc = usdc_;
        actors = actors_;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
        address actor = actors[actorSeed % actors.length];

        usdc.mint(actor, amount);

        vm.startPrank(actor);
        usdc.approve(address(router), amount);
        try router.deposit(amount, actor) {
            totalDeposited += amount;
            depositCount++;
        } catch {
            // Expected: paused, cap, or stale oracle
        }
        vm.stopPrank();
    }
}
