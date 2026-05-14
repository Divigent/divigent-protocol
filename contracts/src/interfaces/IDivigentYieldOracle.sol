// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDivigentYieldOracle
/// @notice Interface for DivigentYieldOracle — reads time-weighted average rates from
///         Aave V3 and Morpho vaults and returns the optimal routing destination.
interface IDivigentYieldOracle {
    // ── Types ─────────────────────────────────────────────────────────────────

    enum VaultType { AAVE, MORPHO }

    struct VaultRate {
        address vault;
        VaultType vaultType;
        uint256 spotRate;   // Current rate in ray (1e27), annualised
        uint256 twarRate;   // 4-hour TWAR in ray (1e27), annualised
        bool    isSafe;     // Utilisation < UTILISATION_THRESHOLD
    }

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new rate observation is recorded.
    event ObservationRecorded(
        uint256 indexed timestamp,
        uint256 aaveRate,
        uint256 morphoRate
    );

    /// @notice Emitted when ORACLE_ADMIN updates the routing differential threshold.
    event MinDifferentialRayUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when ORACLE_ADMIN schedules a routing differential threshold.
    event MinDifferentialRayUpdateScheduled(uint256 oldValue, uint256 newValue, uint256 effectiveAt);

    /// @notice Emitted when ORACLE_ADMIN cancels a pending routing differential threshold.
    event MinDifferentialRayUpdateCancelled(uint256 pendingValue, uint256 effectiveAt);

    /// @notice Emitted when the emergency owner schedules an oracle-admin rotation.
    event OracleAdminRotationProposed(
        address indexed currentAdmin,
        address indexed pendingAdmin,
        uint256 effectiveAt
    );

    /// @notice Emitted when the emergency owner cancels a pending oracle-admin rotation.
    event OracleAdminRotationCancelled(address indexed cancelledPendingAdmin);

    /// @notice Emitted when the oracle-admin rotation executes.
    event OracleAdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // ── View ──────────────────────────────────────────────────────────────────

    /// @notice Returns the optimal vault for new deposits, using TWAR rates.
    ///         Falls back to Aave V3 only when Aave also passes its safety check.
    ///         Reverts if neither supported vault is currently safe.
    /// @return vault     Address of the recommended vault (Aave Pool or Morpho vault).
    /// @return vaultType Enum indicating AAVE or MORPHO.
    /// @return twarRate  The TWAR APY of the recommended vault, in ray (1e27).
    function getOptimalVault()
        external
        view
        returns (address vault, VaultType vaultType, uint256 twarRate);

    /// @notice Returns rate data for all supported vaults.
    function getAllRates() external view returns (VaultRate[] memory rates);

    /// @notice Returns true if `vaultType` passes its safety heuristic.
    ///         Aave: utilisation below 90%. Morpho: share price >= 1 USDC (not underwater).
    function isVaultSafe(VaultType vaultType) external view returns (bool);

    /// @notice Current operational admin allowed to tune minDifferentialRay.
    function ORACLE_ADMIN() external view returns (address);

    // ── Freshness ─────────────────────────────────────────────────────────────

    /// @notice Timestamp of the most recent successfully recorded observation.
    ///         Exposed so callers (e.g. VaultRouter) can assess oracle staleness.
    function lastObservationTime() external view returns (uint256);

    /// @notice Returns true if the last observation is within MAX_STALENESS (2 hours).
    ///         VaultRouter reverts with StaleOracle() if this returns false on deposit.
    function isFresh() external view returns (bool);

    /// @notice Returns the number of seconds since the last recorded observation.
    ///         Useful for off-chain monitoring and keeper alerting.
    function lastGoodObservationAge() external view returns (uint256);

    /// @notice Minimum APY differential, in ray, required for Morpho to beat Aave.
    function minDifferentialRay() external view returns (uint256);

    /// @notice Default minDifferentialRay value used at deployment.
    function DEFAULT_MIN_DIFFERENTIAL_RAY() external view returns (uint256);

    /// @notice Lowest allowed minDifferentialRay value.
    function MIN_DIFFERENTIAL_RAY_LOWER_BOUND() external view returns (uint256);

    /// @notice Highest allowed minDifferentialRay value.
    function MIN_DIFFERENTIAL_RAY_UPPER_BOUND() external view returns (uint256);

    /// @notice Delay before a pending minDifferentialRay value can be executed.
    function MIN_DIFFERENTIAL_RAY_CHANGE_DELAY() external view returns (uint256);

    /// @notice Pending minDifferentialRay value awaiting timelock execution.
    function pendingMinDifferentialRay() external view returns (uint256);

    /// @notice Timestamp when pendingMinDifferentialRay can be executed.
    function pendingMinDifferentialRayEffectiveAt() external view returns (uint256);

    /// @notice Delay before a pending oracle-admin rotation can be executed.
    function ORACLE_ADMIN_ROTATION_DELAY() external view returns (uint256);

    /// @notice Grace window after the delay during which an oracle-admin rotation can execute.
    function ORACLE_ADMIN_ROTATION_GRACE_PERIOD() external view returns (uint256);

    /// @notice Pending replacement oracle admin, or address(0) if none is pending.
    function pendingOracleAdmin() external view returns (address);

    /// @notice Timestamp when pendingOracleAdmin can be executed.
    function oracleAdminRotationEffectiveAt() external view returns (uint256);

    // ── Mutative ──────────────────────────────────────────────────────────────

    /// @notice Records a new rate observation if the minimum interval has elapsed.
    ///         Permissionless — anyone can call to update the TWAR.
    function recordObservation() external;

    /// @notice Schedules a minimum differential threshold update within fixed bounds.
    ///         Rescheduling a value cancels the old pending value and restarts the delay.
    function setMinDifferentialRay(uint256 newValue) external;

    /// @notice Executes a pending minDifferentialRay after its timelock.
    /// @dev Permissionless by design: execution only applies a bounded change
    ///      already scheduled by ORACLE_ADMIN. Admin can cancel before execution.
    function executeMinDifferentialRay() external;

    /// @notice Cancels the pending minDifferentialRay update.
    function cancelPendingMinDifferentialRay() external;

    /// @notice Proposes rotating ORACLE_ADMIN to `newAdmin` after a timelock.
    /// @dev Restricted to owner(), expected to be the emergency multisig.
    function proposeOracleAdminRotation(address newAdmin) external;

    /// @notice Executes a pending oracle-admin rotation after its timelock.
    /// @dev Permissionless by design: execution only applies a rotation already
    ///      scheduled by owner(). Owner can cancel before execution.
    function executeOracleAdminRotation() external;

    /// @notice Cancels the pending oracle-admin rotation.
    /// @dev Restricted to owner(), expected to be the emergency multisig.
    function cancelOracleAdminRotation() external;

}
