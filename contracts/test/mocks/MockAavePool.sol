// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

contract MockAavePool {
    uint256 internal constant ACTIVE_MASK = 1 << 56;
    uint256 internal constant FROZEN_MASK = 1 << 57;
    uint256 internal constant PAUSED_MASK = 1 << 60;

    MockERC20 public usdc;
    MockERC20 public aToken;

    uint128 public currentLiquidityRate;
    uint256 public reserveNormalizedIncome = 1e27;
    uint256 public configuration = ACTIVE_MASK;
    bool public silentFailWithdraw;
    bool public revertConfiguration;
    bool public revertReserveData;
    address public reentranceTarget;
    address public reentranceWallet;

    function setSilentFailWithdraw(bool fail) external { silentFailWithdraw = fail; }
    function setRevertConfiguration(bool fail) external { revertConfiguration = fail; }
    function setRevertReserveData(bool fail) external { revertReserveData = fail; }
    function setReserveActive(bool active_) external { _setConfigBit(ACTIVE_MASK, active_); }
    function setReserveFrozen(bool frozen_) external { _setConfigBit(FROZEN_MASK, frozen_); }
    function setReservePaused(bool paused_) external { _setConfigBit(PAUSED_MASK, paused_); }

    function setReentranceTarget(address target, address wallet) external {
        reentranceTarget = target;
        reentranceWallet = wallet;
    }

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
        require(_supplyEnabled(), "MockAavePool: supply disabled");
        usdc.burn(msg.sender, amount);
        aToken.mint(onBehalfOf, amount);
    }

    function supplyWithPermit(address, uint256 amount, address onBehalfOf, uint16, uint256, uint8, bytes32, bytes32)
        external
    {
        require(_supplyEnabled(), "MockAavePool: supply disabled");
        usdc.burn(msg.sender, amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        require(_withdrawEnabled(), "MockAavePool: withdraw disabled");
        if (silentFailWithdraw) {
            aToken.burn(msg.sender, amount);
            return 0;
        }
        if (reentranceTarget != address(0)) {
            address target = reentranceTarget;
            address wallet = reentranceWallet;
            reentranceTarget = address(0);
            IDivigentVaultRouter(target).withdraw(1, wallet, 0);
            revert("MockAavePool: reentrance was NOT blocked");
        }
        aToken.burn(msg.sender, amount);
        usdc.mint(to, amount);
        return amount;
    }

    function getReserveNormalizedIncome(address) external view returns (uint256) {
        return reserveNormalizedIncome;
    }

    function getConfiguration(address) external view returns (uint256 configuration_) {
        if (revertConfiguration) revert("MockAavePool: configuration disabled");
        return configuration;
    }

    function getReserveData(address)
        external
        view
        returns (
            uint256 configuration_,
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
        if (revertReserveData) revert("MockAavePool: reserve data disabled");

        return (
            configuration,
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

    function _setConfigBit(uint256 mask, bool enabled) internal {
        if (enabled) {
            configuration |= mask;
        } else {
            configuration &= ~mask;
        }
    }

    function _supplyEnabled() internal view returns (bool) {
        return (configuration & ACTIVE_MASK) != 0
            && (configuration & FROZEN_MASK) == 0
            && (configuration & PAUSED_MASK) == 0;
    }

    function _withdrawEnabled() internal view returns (bool) {
        return (configuration & ACTIVE_MASK) != 0
            && (configuration & PAUSED_MASK) == 0;
    }
}
