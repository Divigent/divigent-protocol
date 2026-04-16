// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  DivigentFeeCollector
/// @author Divigent Protocol
/// @notice Handles the 10% protocol fee on yield earned by Divigent agents.
///         Fee is deducted at the moment of withdrawal and ONLY from yield —
///         the deposited principal is never touched under any circumstance.
///
/// @dev    Security properties:
///         - Only VAULT_ROUTER may call collectFee(). No other address can
///           trigger fee collection or move USDC out of this contract.
///         - TREASURY is immutable — no admin key can redirect fees.
///         - Fee arithmetic uses checked math (Solidity 0.8.x) and is bounded
///           by the FEE_BPS constant (1000 bps = 10.00%). The fee can never
///           exceed 10% of the yield amount passed by VaultRouter.
///         - If yieldEarned is 0 (principal-only withdrawal), fee is exactly 0.
///
/// @custom:invariant fee <= FEE_BPS * yieldEarned / BPS_DENOMINATOR (always)
/// @custom:invariant USDC.balanceOf(address(this)) == 0 after every collectFee() call
contract DivigentFeeCollector {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Fee rate: 1000 basis points = 10.00%.
    uint256 public constant FEE_BPS = 1_000;

    /// @notice Denominator for basis-point arithmetic.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice USDC token on Base mainnet (6 decimals).
    IERC20 public immutable USDC;

    /// @notice The protocol treasury — a 2-of-3 Gnosis Safe multisig on Base.
    ///         Immutable: no admin key can redirect fees post-deployment.
    address public immutable TREASURY;

    /// @notice The only address authorised to call collectFee().
    address public immutable VAULT_ROUTER;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful fee collection.
    /// @param wallet      The agent wallet from which the fee was derived.
    /// @param yieldEarned The gross yield earned by the agent (before fee).
    /// @param feeAmount   The fee amount transferred to TREASURY.
    event FeeCollected(
        address indexed wallet,
        uint256 yieldEarned,
        uint256 feeAmount
    );

    // ── Errors ────────────────────────────────────────────────────────────────

    error OnlyVaultRouter(address caller);
    error ZeroTreasury();
    error ZeroRouter();
    error ZeroUsdc();

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param usdc        USDC token address on Base (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).
    /// @param treasury    The 2-of-3 multisig treasury address.
    /// @param vaultRouter The DivigentVaultRouter address.
    constructor(address usdc, address treasury, address vaultRouter) {
        if (usdc == address(0))        revert ZeroUsdc();
        if (treasury == address(0))    revert ZeroTreasury();
        if (vaultRouter == address(0)) revert ZeroRouter();

        USDC         = IERC20(usdc);
        TREASURY     = treasury;
        VAULT_ROUTER = vaultRouter;
    }

    // ── Access Control ────────────────────────────────────────────────────────

    modifier onlyVaultRouter() {
        if (msg.sender != VAULT_ROUTER) revert OnlyVaultRouter(msg.sender);
        _;
    }

    // ── Fee Logic ─────────────────────────────────────────────────────────────

    /// @notice Calculates the protocol fee on `yieldEarned` without side effects.
    ///         Useful for off-chain simulation and SDK preview calls.
    /// @param yieldEarned Gross yield earned in USDC (6 decimals).
    /// @return fee        Protocol fee in USDC (always <= 10% of yieldEarned).
    function calculateFee(uint256 yieldEarned)
        public
        pure
        returns (uint256 fee)
    {
        // Solidity 0.8.x checked arithmetic — no overflow possible with 6-decimal USDC
        fee = (yieldEarned * FEE_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Collects the protocol fee from a completed withdrawal.
    ///         Called exclusively by DivigentVaultRouter after it has received the
    ///         full USDC withdrawal from Aave/Morpho and measured the actual gross.
    ///
    ///         Flow:
    ///         1. VaultRouter redeems from Aave/Morpho → USDC arrives in VaultRouter
    ///         2. VaultRouter measures actualGross = USDC.balanceOf(address(this))
    ///         3. VaultRouter computes actualYield = actualGross - principalOut (floor 0)
    ///         4. VaultRouter calls collectFee(wallet, actualYield) with the realised yield
    ///         5. FeeCollector pulls feeAmount directly from VaultRouter to TREASURY
    ///         6. VaultRouter forwards remainder (principal + 90% actualYield) to agent
    ///
    ///         Using actualYield (measured after redemption) rather than a pre-estimated
    ///         gross ensures the fee is always computed on true realised yield. Any rounding
    ///         differences from Morpho's exact-asset withdrawal are absorbed before the fee
    ///         calculation, so the principal is never inadvertently charged a fee.
    ///
    /// @dev    The FeeCollector holds USDC only transiently during this call.
    ///         After execution, USDC.balanceOf(address(this)) returns to 0.
    ///
    /// @param wallet      The agent wallet (for event indexing).
    /// @param yieldEarned The actual realised yield on which the fee is calculated.
    /// @return feeAmount  The amount transferred to TREASURY.
    function collectFee(address wallet, uint256 yieldEarned)
        external
        onlyVaultRouter
        returns (uint256 feeAmount)
    {
        // If no yield was earned (principal-only withdrawal), fee is zero.
        // This guard is also the primary invariant enforcement: principal is never touched.
        if (yieldEarned == 0) return 0;

        feeAmount = calculateFee(yieldEarned);
        if (feeAmount == 0) return 0;

        // Pull the fee from VaultRouter (VaultRouter must have approved this contract)
        USDC.safeTransferFrom(VAULT_ROUTER, TREASURY, feeAmount);

        emit FeeCollected(wallet, yieldEarned, feeAmount);
    }
}
