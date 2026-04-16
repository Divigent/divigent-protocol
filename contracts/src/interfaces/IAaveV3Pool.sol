// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAaveV3Pool
/// @notice Minimal interface for the Aave V3 Pool on Base mainnet.
/// @dev    Full interface: https://github.com/aave/aave-v3-core/blob/master/contracts/interfaces/IPool.sol
///         Base mainnet Pool address: 0x18cd499E3d7ed42fEBFCbf98a1d306f4ccc4d934
interface IAaveV3Pool {
    // ── Supply ────────────────────────────────────────────────────────────────

    /// @notice Supplies `amount` of `asset` into the reserve on behalf of `onBehalfOf`.
    ///         The caller must have approved this contract to transfer `amount` of `asset`.
    ///         Mints aTokens to `onBehalfOf` at a 1:1 ratio.
    /// @param asset       The address of the underlying asset (USDC).
    /// @param amount      The amount to supply, in asset decimals.
    /// @param onBehalfOf  The address that will receive the aTokens.
    /// @param referralCode Protocol referral code (use 0).
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice EIP-2612 permit variant of supply — no separate approve tx required.
    function supplyWithPermit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external;

    // ── Withdraw ──────────────────────────────────────────────────────────────

    /// @notice Withdraws `amount` of `asset` from the reserve, burning the caller's aTokens.
    ///         The caller must hold or be approved for sufficient aTokens.
    /// @param asset   The underlying asset address.
    /// @param amount  Amount to withdraw (use type(uint256).max for full position).
    /// @param to      Address that receives the withdrawn USDC.
    /// @return        The actual amount withdrawn.
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    // ── View ──────────────────────────────────────────────────────────────────

    /// @notice Returns the normalised income of the reserve (liquidity index), in ray (1e27).
    function getReserveNormalizedIncome(address asset) external view returns (uint256);

    /// @notice Returns the aToken, stableDebtToken and variableDebtToken addresses for `asset`.
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,   // APY for suppliers, in ray (1e27)
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40  lastUpdateTimestamp,
            uint16  id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
}
