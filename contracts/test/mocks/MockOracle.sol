// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";

contract MockOracle {
    IDivigentYieldOracle.VaultType public optimalVault = IDivigentYieldOracle.VaultType.AAVE;
    bool public fresh_ = true;
    uint256 public lastObservationTime_;

    function getOptimalVault()
        external
        view
        returns (
            uint256 aaveRate,
            IDivigentYieldOracle.VaultType vaultType,
            uint256 morphoRate
        )
    {
        return (0, optimalVault, 0);
    }

    function isFresh() external view returns (bool) {
        return fresh_;
    }

    function lastObservationTime() external view returns (uint256) {
        return lastObservationTime_;
    }

    function lastGoodObservationAge() external view returns (uint256) {
        return block.timestamp - lastObservationTime_;
    }

    function recordObservation() external {}

    function setOptimalVault(IDivigentYieldOracle.VaultType vaultType_) external {
        optimalVault = vaultType_;
    }

    function setFresh(bool fresh__) external {
        fresh_ = fresh__;
    }

    function setLastObservationTime(uint256 timestamp) external {
        lastObservationTime_ = timestamp;
    }
}
