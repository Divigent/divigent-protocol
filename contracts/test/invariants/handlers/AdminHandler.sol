// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../../../src/DivigentYieldOracle.sol";

/// @title AdminHandler
/// @notice Simulates time progression and oracle updates.
contract AdminHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    DivigentYieldOracle public oracle;
    address public multisig;

    uint256 public warpCount;

    constructor(DivigentVaultRouter router_, DivigentYieldOracle oracle_, address multisig_) {
        router = router_;
        oracle = oracle_;
        multisig = multisig_;
    }

    /// @notice Advance time by a bounded random amount (1 min to 6 hours)
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 60, 6 hours);
        vm.warp(block.timestamp + seconds_);
        warpCount++;
    }

    /// @notice Advance time by a large bounded amount (1 day to 100 days).
    ///         Enables the fuzzer to reach TVL cap transitions at day 31 and day 91.
    function warpTimeLong(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 days, 100 days);
        vm.warp(block.timestamp + seconds_);
        warpCount++;
    }

    /// @notice Record an oracle observation (permissionless, anyone can call)
    function recordObservation() external {
        try oracle.recordObservation() {} catch {}
    }

    /// @notice Toggle deposit pause (multisig only)
    function togglePause(bool shouldPause) external {
        vm.prank(multisig);
        if (shouldPause) {
            try router.pauseDeposits() {} catch {}
        } else {
            try router.unpauseDeposits() {} catch {}
        }
    }
}
