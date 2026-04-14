// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

contract MockMorphoVault {
    uint256 private constant SHARE_UNIT = 1e6;

    MockERC20 public usdc;
    uint256 public totalShares;
    uint256 public totalAssets_;
    uint256 public maxDepositAmount = type(uint256).max;
    uint256 public maxWithdrawAmount = type(uint256).max;
    uint256 public manualSharePrice = SHARE_UNIT;
    bool    public useManualSharePrice;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address usdc_) {
        usdc = MockERC20(usdc_);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function totalAssets() external view returns (uint256) {
        return _currentTotalAssets();
    }

    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        return _assetsToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        return _sharesToAssets(shares);
    }

    function convertToShares(uint256 assets) external view returns (uint256 shares) {
        return _assetsToShares(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        return _sharesToAssets(shares);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function maxDeposit(address) external view returns (uint256) {
        return maxDepositAmount;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _assetsToShares(assets);
        usdc.burn(msg.sender, assets);
        totalAssets_ += assets;
        totalShares += shares;
        _balances[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= shares;
        }

        assets = _sharesToAssets(shares);
        _balances[owner] -= shares;
        totalShares -= shares;
        totalAssets_ -= assets;
        usdc.mint(receiver, assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = _assetsToSharesRoundUp(assets);

        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= shares;
        }

        _balances[owner] -= shares;
        totalShares -= shares;
        totalAssets_ -= assets;
        usdc.mint(receiver, assets);
    }

    function maxWithdraw(address) external view returns (uint256) {
        return maxWithdrawAmount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function accrueYield(uint256 extraAssets) external {
        totalAssets_ += extraAssets;
    }

    function setMaxDeposit(uint256 cap) external {
        maxDepositAmount = cap;
    }

    function setMaxWithdraw(uint256 cap) external {
        maxWithdrawAmount = cap;
    }

    function setSharePrice(uint256 newSharePrice) external {
        manualSharePrice = newSharePrice;
        useManualSharePrice = true;
    }

    function clearManualSharePrice() external {
        useManualSharePrice = false;
    }

    function setTotalAssets(uint256 newTotalAssets) external {
        totalAssets_ = newTotalAssets;
    }

    function setTotalShares(uint256 newTotalShares) external {
        totalShares = newTotalShares;
    }

    function setBalance(address account, uint256 shares) external {
        _balances[account] = shares;
    }

    function _currentSharePrice() internal view returns (uint256) {
        if (useManualSharePrice) return manualSharePrice;
        if (totalShares == 0) return SHARE_UNIT;
        return (totalAssets_ * SHARE_UNIT) / totalShares;
    }

    function _currentTotalAssets() internal view returns (uint256) {
        if (useManualSharePrice) {
            if (totalShares == 0) return manualSharePrice;
            return (totalShares * manualSharePrice) / SHARE_UNIT;
        }
        return totalAssets_;
    }

    function _assetsToShares(uint256 assets) internal view returns (uint256 shares) {
        uint256 sharePrice = _currentSharePrice();
        shares = (assets * SHARE_UNIT) / sharePrice;
    }

    function _assetsToSharesRoundUp(uint256 assets) internal view returns (uint256 shares) {
        uint256 sharePrice = _currentSharePrice();
        shares = (assets * SHARE_UNIT + sharePrice - 1) / sharePrice;
    }

    function _sharesToAssets(uint256 shares) internal view returns (uint256 assets) {
        assets = (shares * _currentSharePrice()) / SHARE_UNIT;
    }
}
