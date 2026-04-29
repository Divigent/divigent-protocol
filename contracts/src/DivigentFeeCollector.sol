// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title  DivigentFeeCollector
/// @author Divigent Protocol
/// @notice Handles the 10% protocol fee on yield earned by Divigent agents.
///         Fee is deducted at the moment of withdrawal and ONLY from yield —
///         the deposited principal is never touched under any circumstance.
///
/// @dev    Security properties:
///         - Only VAULT_ROUTER may call external functions. No other address
///           can trigger fee collection or treasury rotation.
///         - `treasury` is rotatable via a 7-day timelock gated by
///           EMERGENCY_MULTISIG (through the router). Recovers from USDC
///           blocklist against the treasury.
///         - Fee arithmetic uses checked math (Solidity 0.8.x) bounded by
///           FEE_BPS. Fee is exactly 0 when yieldEarned is 0, otherwise
///           ceiling-rounded in the protocol's favour.
///         - All functions follow CEI: checks → effects → event; `collectFee`
///           has no state mutations, only an external token transfer.
///
/// @custom:invariant fee == ceil(FEE_BPS * yieldEarned / BPS_DENOMINATOR)
/// @custom:invariant USDC.balanceOf(address(this)) == 0 always
contract DivigentFeeCollector {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Fee rate: 1000 basis points = 10.00%.
    uint256 public constant FEE_BPS = 1_000;

    /// @notice Denominator for basis-point arithmetic.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Delay between proposing and executing a treasury rotation.
    uint256 public constant TREASURY_ROTATION_DELAY = 7 days;

    /// @notice Window after the delay elapses during which a pending rotation
    ///         can still be executed; past this window the proposal expires.
    uint256 public constant TREASURY_ROTATION_GRACE_PERIOD = 14 days;

    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice USDC token on Base mainnet (6 decimals).
    IERC20 public immutable USDC;

    /// @notice The only address authorised to call external functions.
    address public immutable VAULT_ROUTER;

    // ── Mutable state ────────────────────────────────────────────────────────

    /// @notice Current protocol treasury. Rotatable under the timelock.
    address public treasury;

    /// @notice Proposed replacement treasury; `address(0)` when no rotation is
    ///         pending. Packs with `treasuryRotationEffectiveAt` into one slot.
    address public pendingTreasury;

    /// @notice Earliest timestamp at which `executeTreasuryRotation` succeeds
    ///         for the current `pendingTreasury`. Zero when none is pending.
    ///         uint96 fits any realistic block.timestamp for the next ~10^21 years.
    uint96 public treasuryRotationEffectiveAt;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful fee collection.
    event FeeCollected(
        address indexed wallet,
        uint256 yieldEarned,
        uint256 feeAmount
    );

    /// @notice Emitted when a treasury rotation is proposed. Indexers watch
    ///         this to detect pending rotations before they take effect.
    event TreasuryRotationProposed(
        address indexed currentTreasury,
        address indexed pendingTreasury,
        uint256 effectiveAt
    );

    /// @notice Emitted when a pending rotation is cancelled before execution.
    event TreasuryRotationCancelled(address indexed cancelledPendingTreasury);

    /// @notice Emitted when a rotation executes and the treasury address changes.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ── Errors ────────────────────────────────────────────────────────────────

    error OnlyVaultRouter(address caller);
    error ZeroTreasury();
    error ZeroRouter();
    error ZeroUsdc();
    error RotationNotProposed();
    error RotationNotReady(uint256 currentTime, uint256 effectiveAt);
    error RotationExpired(uint256 currentTime, uint256 expiredAt);
    error InvalidNewTreasury();
    error RotationAlreadyPending(address pendingTreasury);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param usdc         USDC token address on Base.
    /// @param treasury_    Initial 2-of-3 multisig treasury address.
    /// @param vaultRouter  The DivigentVaultRouter address.
    constructor(address usdc, address treasury_, address vaultRouter) {
        if (usdc == address(0))        revert ZeroUsdc();
        if (treasury_ == address(0))   revert ZeroTreasury();
        if (vaultRouter == address(0)) revert ZeroRouter();

        USDC         = IERC20(usdc);
        treasury     = treasury_;
        VAULT_ROUTER = vaultRouter;
    }

    // ── Access Control ────────────────────────────────────────────────────────

    modifier onlyVaultRouter() {
        if (msg.sender != VAULT_ROUTER) revert OnlyVaultRouter(msg.sender);
        _;
    }

    // ── Fee Logic ─────────────────────────────────────────────────────────────

    /// @notice Calculates the protocol fee on `yieldEarned` without side effects.
    /// @param yieldEarned Gross yield earned in USDC (6 decimals).
    /// @return fee        Ceiling-rounded protocol fee in USDC.
    function calculateFee(uint256 yieldEarned)
        public
        pure
        returns (uint256 fee)
    {
        fee = Math.mulDiv(yieldEarned, FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @notice Collects the protocol fee from a completed withdrawal.
    ///         Pulls `feeAmount` directly from VaultRouter to `treasury` via
    ///         `safeTransferFrom`; FeeCollector never holds USDC itself.
    /// @param wallet      The agent wallet (for event indexing).
    /// @param yieldEarned The actual realised yield to fee against.
    /// @return feeAmount  The amount transferred to `treasury`.
    function collectFee(address wallet, uint256 yieldEarned)
        external
        onlyVaultRouter
        returns (uint256 feeAmount)
    {
        // CEI: checks
        if (yieldEarned == 0) return 0;
        feeAmount = calculateFee(yieldEarned);
        if (feeAmount == 0) return 0;

        // CEI: interaction (no effects — treasury is read-only here)
        USDC.safeTransferFrom(VAULT_ROUTER, treasury, feeAmount);

        emit FeeCollected(wallet, yieldEarned, feeAmount);
    }

    // ── Treasury Rotation ─────────────────────────────────────────────────────

    /// @notice Propose rotating `treasury` to `newTreasury`. Starts a 7-day
    ///         timelock. Caller must be VAULT_ROUTER; router enforces
    ///         EMERGENCY_MULTISIG gating.
    function proposeTreasuryRotation(address newTreasury) external onlyVaultRouter {
        // CEI: checks
        if (newTreasury == address(0))     revert ZeroTreasury();
        if (newTreasury == treasury)       revert InvalidNewTreasury();
        if (pendingTreasury != address(0)) revert RotationAlreadyPending(pendingTreasury);

        // CEI: effects
        pendingTreasury = newTreasury;
        treasuryRotationEffectiveAt = (block.timestamp + TREASURY_ROTATION_DELAY).toUint96();

        // CEI: event (no external calls)
        emit TreasuryRotationProposed(treasury, newTreasury, treasuryRotationEffectiveAt);
    }

    /// @notice Finalise a proposed rotation. Reverts unless the delay has
    ///         elapsed and the grace period has not yet expired.
    function executeTreasuryRotation() external onlyVaultRouter {
        // CEI: checks
        if (pendingTreasury == address(0)) revert RotationNotProposed();
        if (block.timestamp < treasuryRotationEffectiveAt) {
            revert RotationNotReady(block.timestamp, treasuryRotationEffectiveAt);
        }
        uint256 expiredAt = treasuryRotationEffectiveAt + TREASURY_ROTATION_GRACE_PERIOD;
        if (block.timestamp > expiredAt) {
            revert RotationExpired(block.timestamp, expiredAt);
        }

        // CEI: effects
        address oldTreasury = treasury;
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        treasuryRotationEffectiveAt = 0;

        // CEI: event
        emit TreasuryUpdated(oldTreasury, treasury);
    }

    /// @notice Cancel a pending rotation. Does not affect the current `treasury`.
    function cancelTreasuryRotation() external onlyVaultRouter {
        // CEI: checks
        if (pendingTreasury == address(0)) revert RotationNotProposed();

        // CEI: effects
        address cancelled = pendingTreasury;
        pendingTreasury = address(0);
        treasuryRotationEffectiveAt = 0;

        // CEI: event
        emit TreasuryRotationCancelled(cancelled);
    }
}
