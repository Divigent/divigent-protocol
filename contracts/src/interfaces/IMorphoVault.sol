// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMorphoVault
/// @notice Interface for MetaMorpho vaults (ERC-4626 compliant yield vaults on Base).
///         Morpho Steakhouse USDC and Morpho Re7 USDC are both MetaMorpho ERC-4626 vaults.
///         Full spec: https://eips.ethereum.org/EIPS/eip-4626
interface IMorphoVault {
    // ── ERC-4626 Core ─────────────────────────────────────────────────────────

    /// @notice The address of the underlying asset (USDC).
    function asset() external view returns (address);

    /// @notice Total USDC value of assets managed by this vault.
    function totalAssets() external view returns (uint256);

    /// @notice Total supply of vault shares.
    function totalSupply() external view returns (uint256);

    /// @notice Preview how many shares `assets` USDC would mint.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview how many USDC `shares` would redeem.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Convert `assets` USDC to equivalent shares (current exchange rate).
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Convert `shares` to equivalent USDC (current exchange rate).
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the share balance of `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns the maximum USDC that can be deposited.
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Returns the maximum shares that `owner` can redeem.
    function maxRedeem(address owner) external view returns (uint256);

    // ── ERC-4626 Mutative ────────────────────────────────────────────────────

    /// @notice Deposit `assets` USDC, minting shares to `receiver`.
    ///         Caller must have approved this contract for `assets` USDC.
    /// @return shares The number of vault shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Redeem `shares` for USDC, sending assets to `receiver`.
    ///         Caller must own or be approved for `shares`.
    /// @return assets The amount of USDC returned.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Withdraw exactly `assets` USDC to `receiver`, burning however many
    ///         shares are required. Implements ERC-4626 exact-asset withdrawal semantics.
    ///         Unlike `redeem`, this avoids rounding-down errors that leave dust in the
    ///         vault — the router receives exactly `assets` USDC (or the call reverts).
    ///         Caller must be `owner` or have an approved allowance of shares from `owner`.
    /// @param assets   Exact amount of USDC to withdraw (6 decimals).
    /// @param receiver Address to receive the USDC.
    /// @param owner    Address whose shares are burned.
    /// @return shares  Number of vault shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /// @notice Returns the maximum USDC that `owner` can withdraw from the vault in a
    ///         single call, accounting for liquidity constraints in the underlying markets.
    ///         Used by VaultRouter for amount-aware safety checks (_canAllocate).
    function maxWithdraw(address owner) external view returns (uint256);

    // ── ERC-20 Approval (needed for VaultRouter to redeem on behalf) ──────────

    /// @notice Approve `spender` to transfer `amount` shares on behalf of msg.sender.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Allowance of `spender` over `owner`'s shares.
    function allowance(address owner, address spender) external view returns (uint256);
}
