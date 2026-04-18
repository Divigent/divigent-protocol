// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  dvUSDC — Divigent USDC Receipt Token
/// @author Divigent Protocol
/// @notice Non-transferable ERC-20 receipt token representing a proportional share of
///         the Divigent protocol's pooled yield position. Minted 1:1 with USDC on the
///         initial deposit and thereafter at the current protocol exchange rate.
///         Price is monotonically non-decreasing as yield accrues in the underlying
///         Aave V3 / Morpho vaults.
///
/// @dev    Security properties:
///         - Mint and burn are gated exclusively to the immutable VAULT_ROUTER address.
///           No other address — including the deployer — can create or destroy dvUSDC.
///         - NON-TRANSFERABLE: dvUSDC cannot be transferred between wallets. This is a
///           deliberate design constraint that preserves the cost-basis accounting
///           invariant in VaultRouter: costBasisUSDC[wallet] tracks the USDC deposited
///           by that specific wallet. If dvUSDC could move freely, the per-wallet
///           principal record would diverge from the actual depositor, making fee
///           calculation incorrect and opening a principal-theft vector. Transfers are
///           only allowed from/to address(0) (mint and burn respectively).
///         - 6 decimals to match USDC, simplifying exchange-rate arithmetic in VaultRouter.
///         - ERC20Permit is intentionally omitted: permit + delegated-transfer could
///           circumvent the non-transferability constraint via a signed approval flow.
///
/// @custom:invariant totalSupply() * VaultRouter.pricePerShare() / 1e18 >= sum(costBasisUSDC) (enforced in VaultRouter)
contract DvUSDC is ERC20 {
    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice The sole address authorised to mint and burn dvUSDC.
    ///         Set at construction time and cannot be changed.
    address public immutable VAULT_ROUTER;

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @dev Reverts if any address other than VAULT_ROUTER calls mint or burn.
    ///      The expected router is the contract's immutable `VAULT_ROUTER`; callers
    ///      can query it directly, so the error only reports the offending caller.
    error OnlyVaultRouter(address caller);

    /// @dev Reverts on any transfer between two non-zero addresses.
    ///      dvUSDC is a position receipt bound to the depositing wallet; it cannot
    ///      be sold, transferred, or gifted. Only minting (from == 0) and burning
    ///      (to == 0) are permitted.
    error NonTransferable();

    /// @dev Reverts if the constructor is given the zero address for VAULT_ROUTER.
    error ZeroRouter();

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param vaultRouter The DivigentVaultRouter address. Immutable after deployment.
    constructor(address vaultRouter)
        ERC20("Divigent USDC", "dvUSDC")
    {
        if (vaultRouter == address(0)) revert ZeroRouter();
        VAULT_ROUTER = vaultRouter;
    }

    // ── Access Control ────────────────────────────────────────────────────────

    modifier onlyVaultRouter() {
        if (msg.sender != VAULT_ROUTER) revert OnlyVaultRouter(msg.sender);
        _;
    }

    // ── Non-Transferability ───────────────────────────────────────────────────

    /// @dev Override the OZ v5 internal `_update` hook to block peer-to-peer transfers.
    ///      All token movements flow through `_update(from, to, value)`:
    ///        - Mint:     from == address(0)   → allowed
    ///        - Burn:     to   == address(0)   → allowed
    ///        - Transfer: from != 0 && to != 0 → REVERTS with NonTransferable()
    ///      This override preserves the VaultRouter's costBasisUSDC[wallet] invariant
    ///      by ensuring dvUSDC can never leave its originating wallet.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }

    // ── Token Operations ──────────────────────────────────────────────────────

    /// @notice Mints `amount` dvUSDC to `to`.
    ///         Called by VaultRouter on every successful USDC deposit.
    /// @param to     Recipient of the minted dvUSDC (the agent wallet).
    /// @param amount Number of dvUSDC tokens to mint (6 decimals).
    function mint(address to, uint256 amount) external onlyVaultRouter {
        _mint(to, amount);
    }

    /// @notice Burns `amount` dvUSDC from `from`.
    ///         Called by VaultRouter on every withdrawal. Because dvUSDC is
    ///         non-transferable, VaultRouter burns directly from the wallet that
    ///         originated the deposit — no allowance mechanics required.
    /// @param from   Address whose dvUSDC is being burned (the agent wallet).
    /// @param amount Number of dvUSDC tokens to burn (6 decimals).
    function burn(address from, uint256 amount) external onlyVaultRouter {
        _burn(from, amount);
    }

    // ── ERC-20 Overrides ──────────────────────────────────────────────────────

    /// @dev dvUSDC uses 6 decimals to match USDC, keeping exchange-rate math clean.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
