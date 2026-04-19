// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockMorphoVault} from "../../mocks/MockMorphoVault.sol";

/// @title  LiquidityHandler
/// @notice Mutates vault *serviceability* — the dimensions that drive the
///         `InsufficientVaultLiquidity` and exit-redirect paths in
///         `DivigentVaultRouter.withdraw()` — without touching vault value.
///
///         - Aave idle cash:    `USDC.balanceOf(aToken)` bounds `aaveCap` during
///                              withdraw planning. Shocking down simulates a pool
///                              drained by other borrowers; restoring simulates
///                              repayments or fresh supply from elsewhere.
///         - Morpho maxWithdraw: `MORPHO_VAULT.maxWithdraw(router)` bounds
///                               `morphoCap`. Shocking simulates a vault with
///                               tight allocator limits or paused markets.
///
///         The counters exist so invariants can gate on "did a shock happen
///         since the last step" — mirroring how Oracle-A uses `_lastLossSnapshot`
///         to avoid false monotonicity failures across legitimate loss events.
///         Shock mutations are not themselves value-destructive (aToken claims
///         persist, Morpho totalAssets persists), so they do not feed the
///         accounting tolerance counters.
contract LiquidityHandler is CommonBase, StdUtils {
    MockERC20 public usdc;
    MockERC20 public aToken;
    MockMorphoVault public morphoVault;

    uint256 public aaveShockCount;
    uint256 public aaveRestoreCount;
    uint256 public morphoShockCount;
    uint256 public morphoRestoreCount;

    /// @dev Cap on the per-call restoration mint. Keeps the fuzzer from
    ///      ballooning `USDC.balanceOf(aToken)` to absurd values that
    ///      trivially satisfy every capacity check.
    uint256 internal constant MAX_RESTORE_AMOUNT = 100_000e6;

    constructor(MockERC20 usdc_, MockERC20 aToken_, MockMorphoVault morphoVault_) {
        usdc = usdc_;
        aToken = aToken_;
        morphoVault = morphoVault_;
    }

    /// @dev Drain a fraction of Aave's idle USDC cash. Router reads this cash
    ///      as `aaveIdle` during withdraw planning — low idle + full aToken
    ///      balance is the canonical "pool-liquidity-constrained" regime that
    ///      forces exit redirection to Morpho.
    function shockAaveIdle(uint256 bps) external {
        uint256 idle = usdc.balanceOf(address(aToken));
        if (idle == 0) return;

        bps = bound(bps, 1, 10_000);
        uint256 drain = (idle * bps) / 10_000;
        if (drain == 0) return;

        usdc.burn(address(aToken), drain);
        aaveShockCount++;
    }

    /// @dev Mint USDC into the aToken contract. Simulates borrower repayments
    ///      or fresh supply from other users filling the pool back up.
    function restoreAaveIdle(uint256 amount) external {
        amount = bound(amount, 1, MAX_RESTORE_AMOUNT);
        usdc.mint(address(aToken), amount);
        aaveRestoreCount++;
    }

    /// @dev Tighten Morpho's `maxWithdraw` cap to a fraction of current assets.
    ///      The mock enforces `assets <= maxWithdrawAmount` inside withdraw(),
    ///      so this directly constrains the router's `morphoCap`.
    function shockMorphoMaxWithdraw(uint256 bps) external {
        uint256 assets = morphoVault.totalAssets();
        if (assets == 0) return;

        bps = bound(bps, 1, 10_000);
        uint256 newCap = (assets * (10_000 - bps)) / 10_000;

        morphoVault.setMaxWithdraw(newCap);
        morphoShockCount++;
    }

    /// @dev Lift the Morpho cap back to unbounded.
    function restoreMorphoMaxWithdraw() external {
        morphoVault.setMaxWithdraw(type(uint256).max);
        morphoRestoreCount++;
    }

    /// @dev Aggregate counter for any serviceability mutation since last read.
    ///      Invariants that must skip when a shock happened mid-sequence use
    ///      this as a single gate rather than tracking four counters.
    function totalShockEvents() external view returns (uint256) {
        return aaveShockCount + aaveRestoreCount + morphoShockCount + morphoRestoreCount;
    }
}
