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

    // ── Mutative ──────────────────────────────────────────────────────────────

    /// @notice Records a new rate observation if the minimum interval has elapsed.
    ///         Permissionless — anyone can call to update the TWAR.
    function recordObservation() external;
}
