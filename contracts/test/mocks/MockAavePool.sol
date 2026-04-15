// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

contract MockAavePool {
    MockERC20 public usdc;
    MockERC20 public aToken;

    uint128 public currentLiquidityRate;
    uint256 public reserveNormalizedIncome = 1e27;

    constructor(address usdc_, address aToken_) {
        usdc = MockERC20(usdc_);
        aToken = MockERC20(aToken_);
    }

    function setCurrentLiquidityRate(uint128 newRate) external {
        currentLiquidityRate = newRate;
    }

    function setReserveNormalizedIncome(uint256 newIncome) external {
        reserveNormalizedIncome = newIncome;
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        usdc.burn(msg.sender, amount);
        aToken.mint(onBehalfOf, amount);
    }

    function supplyWithPermit(address, uint256 amount, address onBehalfOf, uint16, uint256, uint8, bytes32, bytes32)
        external
    {
        usdc.burn(msg.sender, amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        aToken.burn(msg.sender, amount);
        usdc.mint(to, amount);
        return amount;
    }

    function getReserveNormalizedIncome(address) external view returns (uint256) {
        return reserveNormalizedIncome;
    }

    function getReserveData(address)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate_,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        )
    {
        return (
            0,
            0,
            currentLiquidityRate,
            0,
            0,
            0,
            uint40(block.timestamp),
            0,
            address(aToken),
            address(0),
            address(0),
            address(0),
            0,
            0,
            0
        );
    }
}
