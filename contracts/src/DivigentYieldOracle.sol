// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {IDivigentYieldOracle} from "./interfaces/IDivigentYieldOracle.sol";

/// @title  DivigentYieldOracle
/// @author Divigent Protocol
/// @notice Reads on-chain APY data from Aave V3 and a MetaMorpho vault, maintains
///         a 4-hour Time-Weighted Average Rate (TWAR) for each, and returns the
///         optimal routing destination for new USDC deposits.
///
/// @dev    Why TWAR instead of spot rates?
///         Spot rates can be temporarily inflated by flash loans that distort pool
///         utilisation within a single block. A 4-hour TWAR makes it economically
///         infeasible to sustain a manipulated rate long enough to influence routing:
///         the attacker must hold the manipulated rate for hours at massive capital cost.
///
///         TWAR implementation (Uniswap V2 style, adapted for rates):
///         - Each `recordObservation()` call accumulates `rate * elapsed_seconds` into
///           running cumulative accumulators for each vault.
///         - A circular buffer stores the last BUFFER_SIZE checkpoints.
///         - `getOptimalVault()` finds the oldest checkpoint within the TWAR_WINDOW
///           and computes: TWAR = (cumulative_now - cumulative_then) / (now - then).
///         - No single flashloan-able event can meaningfully shift a 4-hour average.
///
///         Morpho rate methodology (share-price snapshot):
///         - Rate is derived from two consecutive share-price observations separated by
///           at least MIN_OBSERVATION_INTERVAL seconds. Using a single snapshot and
///           comparing to a fixed base would confuse total accrued yield with
///           the period rate, producing wildly inaccurate annualised figures.
///         - `lastMorphoSharePrice` stores the baseline for positive price movement.
///         - intervalRate = (currentPrice - baseline) / baseline * (SECONDS_PER_YEAR / elapsed)
///         - Flat or downward observations keep the prior baseline and produce a zero Morpho rate.
///
///         Vault safety (oracle advisory):
///         - Aave: utilisation check via available USDC vs. total aToken supply (<90%).
///         - Morpho: share price peg check (sampled share price at or above peg).
///         - getOptimalVault() excludes unsafe vaults from deposit routing.
///           VaultRouter then enforces amount-aware capacity checks via _canAllocate().
///
///         Oracle freshness:
///         - MAX_STALENESS = 2 hours. If no observation has been recorded within 2 hours,
///           isFresh() returns false and VaultRouter rejects new deposits with StaleOracle().
///         - Permissionless observation means any keeper, the router itself, or the SDK
///           can call recordObservation() to prevent staleness.
///
///         Warm-up and partial-window behavior:
///         - TWAR_WINDOW is 4 hours and the buffer holds 48 checkpoints at the
///           5-minute MIN_OBSERVATION_INTERVAL. Until recorded checkpoints span
///           the full window, _computeTWAR() returns spot rates when there are no
///           usable checkpoints, or averages over the shorter available interval.
///         - isFresh() is only a recency check against MAX_STALENESS. It does not
///           certify that the checkpoint buffer spans the full TWAR_WINDOW.
///         - During warm-up, returned rates are real on-chain rates but are less
///           smoothed, and therefore less resistant to short-term rate movement,
///           than a mature 4-hour TWAR. Keepers should call recordObservation()
///           at the 5-minute cadence from deployment; integrators that require a
///           fully mature window should wait until observations cover TWAR_WINDOW.
///
///         Minimum re-routing differential (50 bps = 0.50%):
///         - Prevents unnecessary vault switches due to rate noise.
///         - Routing only changes when the challenger's TWAR exceeds the current
///           vault's TWAR by at least MIN_DIFFERENTIAL_BPS basis points (annualised).
///
/// @custom:security-contact security@divigent.xyz
contract DivigentYieldOracle is IDivigentYieldOracle {

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice TWAR window: 4 hours in seconds.
    uint256 public constant TWAR_WINDOW = 4 hours;

    /// @notice Minimum interval between consecutive observations (5 minutes).
    ///         Prevents spam updates while maintaining ~48 data points per window.
    uint256 public constant MIN_OBSERVATION_INTERVAL = 5 minutes;

    /// @notice Number of checkpoints in the circular buffer.
    ///         48 slots × 5-min minimum interval covers exactly 4 hours.
    uint8 public constant BUFFER_SIZE = 48;

    /// @notice Aave V3 ray precision (1e27).
    uint256 public constant RAY = 1e27;

    /// @notice Annualisation factor in seconds (365.25 days).
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice Safety threshold: maximum utilisation before a vault is excluded.
    ///         Stored as a fraction of BPS_DENOMINATOR.
    uint256 public constant UTILISATION_THRESHOLD_BPS = 9_000; // 90%
    uint256 public constant BPS_DENOMINATOR           = 10_000;

    /// @notice Minimum APY differential (annualised, in RAY) to trigger a vault switch.
    ///         0.50% × 1e27 (expressed in ray terms for comparison with TWAR rates).
    uint256 public constant MIN_DIFFERENTIAL_RAY = 5e24; // 0.5% in ray

    /// @notice Morpho share amount used for share-price sampling.
    /// @dev Uses a larger probe size to reduce USDC 6-decimal quantization in
    ///      per-interval rate calculations.
    uint256 public constant SHARE_UNIT = 1e24;

    /// @dev One full share is 1e18 shares and 1 USDC is 1e6 assets, so
    ///      convertToAssets(SHARE_UNIT) should be at least SHARE_UNIT * 1e6 / 1e18.
    ///      At SHARE_UNIT = 1e24, this evaluates to 1e12.
    uint256 public constant MORPHO_PEG_ASSETS = SHARE_UNIT / 1e12;

    /// @notice Maximum age of the last observation before the oracle is considered stale.
    ///         VaultRouter rejects deposits when isFresh() returns false.
    uint256 public constant MAX_STALENESS = 2 hours;

    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice Aave V3 Pool on Base mainnet.
    IAaveV3Pool  public immutable AAVE_POOL;

    /// @notice aUSDC token address (used to read Aave utilisation).
    IERC20       public immutable A_TOKEN;

    /// @notice USDC token address on Base mainnet.
    IERC20       public immutable USDC;

    /// @notice MetaMorpho vault (ERC-4626) for Morpho Steakhouse / Prime USDC.
    IMorphoVault public immutable MORPHO_VAULT;

    // ── TWAR State ────────────────────────────────────────────────────────────

    /// @dev A single checkpoint stores cumulative rate accumulators at a timestamp,
    ///      plus the Morpho share price recorded at that moment for auditability.
    ///      Cumulatives are truncated to uint224 — overflow is intentional and safe
    ///      because only the *difference* between two checkpoints is used (like Uniswap V2).
    struct Checkpoint {
        uint32  timestamp;
        uint64  morphoSharePrice;  // convertToAssets(SHARE_UNIT), sampled USDC assets
        uint224 aaveCumulative;    // Σ aaveRate × Δt (in RAY·seconds), truncated
        uint224 morphoCumulative;  // Σ morphoRate × Δt (in RAY·seconds), truncated
    }

    /// @dev Circular buffer of TWAR checkpoints.
    Checkpoint[48] private _checkpoints; // fixed-size for gas efficiency
    uint8  private _head;   // index of the next slot to write
    uint8  private _count;  // number of populated slots (0..BUFFER_SIZE)

    /// @notice Running cumulative accumulators (full uint256, no truncation).
    uint256 public aaveCumulative;
    uint256 public morphoCumulative;

    /// @notice Current spot rates (RAY), updated on each observation.
    uint256 public aaveSpotRate;
    uint256 public morphoSpotRate;

    /// @inheritdoc IDivigentYieldOracle
    uint256 public lastObservationTime;

    /// @notice Morpho share-price baseline used for the next positive-rate interval.
    ///         Preserved across flat or downward observations.
    ///         Advances only on strict positive share-price movement.
    ///         Initialised in the constructor with the vault's current share price.
    uint256 public lastMorphoSharePrice;

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @dev Constructor-side zero-address errors. One per dependency so the
    ///      revert reason pinpoints the misconfigured argument.
    error ZeroAavePool();
    error ZeroAToken();
    error ZeroUsdc();
    error ZeroMorphoVault();

    /// @notice Reverts when neither supported vault passes the oracle safety check.
    error NoSafeVault();

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param aavePool    Aave V3 Pool address on Base.
    /// @param aToken      aUSDC address on Base.
    /// @param usdc        USDC address on Base.
    /// @param morphoVault MetaMorpho USDC vault address on Base.
    constructor(
        address aavePool,
        address aToken,
        address usdc,
        address morphoVault
    ) {
        if (aavePool    == address(0)) revert ZeroAavePool();
        if (aToken      == address(0)) revert ZeroAToken();
        if (usdc        == address(0)) revert ZeroUsdc();
        if (morphoVault == address(0)) revert ZeroMorphoVault();

        AAVE_POOL    = IAaveV3Pool(aavePool);
        A_TOKEN      = IERC20(aToken);
        USDC         = IERC20(usdc);
        MORPHO_VAULT = IMorphoVault(morphoVault);

        // Seed Aave rate from on-chain data
        aaveSpotRate = _readAaveSpotRate();

        // Seed Morpho share price — no rate yet (need two snapshots for a valid rate)
        lastMorphoSharePrice = MORPHO_VAULT.convertToAssets(SHARE_UNIT);
        morphoSpotRate       = 0; // conservative: wait for first observation interval

        lastObservationTime  = block.timestamp;
    }

    // ── External: IDivigentYieldOracle ────────────────────────────────────────

    /// @inheritdoc IDivigentYieldOracle
    function getOptimalVault()
        external
        view
        override
        returns (address vault, VaultType vaultType, uint256 twarRate)
    {
        (uint256 aaveTWAR, uint256 morphoTWAR) = _computeTWAR();

        bool aaveSafe   = _isVaultSafe(VaultType.AAVE);
        bool morphoSafe = _isVaultSafe(VaultType.MORPHO);

        if (!aaveSafe && !morphoSafe) revert NoSafeVault();

        // Morpho wins only if: safe AND its TWAR exceeds Aave's by MIN_DIFFERENTIAL_RAY
        bool morphoWins = morphoSafe
            && (morphoTWAR > aaveTWAR)
            && (morphoTWAR - aaveTWAR >= MIN_DIFFERENTIAL_RAY);

        if (morphoWins || !aaveSafe) {
            return (address(MORPHO_VAULT), VaultType.MORPHO, morphoTWAR);
        }

        // Fallback: Aave V3 only while it passes its own safety check.
        // VaultRouter performs its own _canAllocate() check and can revert
        // with NoSafeRoute if neither vault can accommodate the deposit amount.
        return (address(AAVE_POOL), VaultType.AAVE, aaveTWAR);
    }

    /// @inheritdoc IDivigentYieldOracle
    function getAllRates()
        external
        view
        override
        returns (VaultRate[] memory rates)
    {
        (uint256 aaveTWAR, uint256 morphoTWAR) = _computeTWAR();

        rates = new VaultRate[](2);

        rates[0] = VaultRate({
            vault:     address(AAVE_POOL),
            vaultType: VaultType.AAVE,
            spotRate:  aaveSpotRate,
            twarRate:  aaveTWAR,
            isSafe:    _isVaultSafe(VaultType.AAVE)
        });

        rates[1] = VaultRate({
            vault:     address(MORPHO_VAULT),
            vaultType: VaultType.MORPHO,
            spotRate:  morphoSpotRate,
            twarRate:  morphoTWAR,
            isSafe:    _isVaultSafe(VaultType.MORPHO)
        });
    }

    /// @inheritdoc IDivigentYieldOracle
    function isVaultSafe(VaultType vaultType)
        external
        view
        override
        returns (bool)
    {
        return _isVaultSafe(vaultType);
    }

    /// @inheritdoc IDivigentYieldOracle
    /// @dev Pure recency check on the last observation. Does not certify that the
    ///      checkpoint buffer spans the full TWAR_WINDOW; see the contract-level
    ///      warm-up notes for partial-window fallback behavior.
    function isFresh() external view override returns (bool) {
        return block.timestamp - lastObservationTime <= MAX_STALENESS;
    }

    /// @inheritdoc IDivigentYieldOracle
    function lastGoodObservationAge() external view override returns (uint256) {
        return block.timestamp - lastObservationTime;
    }

    /// @inheritdoc IDivigentYieldOracle
    /// @dev Permissionless — anyone can call. No state is changed if the minimum
    ///      interval has not elapsed. This design prevents a single actor from
    ///      withholding oracle updates to manipulate routing decisions.
    function recordObservation() external override {
        uint256 elapsed = block.timestamp - lastObservationTime;

        // Rate-limit to avoid gas-spam; do nothing if called too frequently
        if (elapsed < MIN_OBSERVATION_INTERVAL) return;

        // ── Step 1: Accumulate using the PREVIOUS observation's spot rates ────
        // Uniswap V2 accumulator pattern: record the area
        // under the rate curve for the interval [lastObservation, now].
        aaveCumulative   += aaveSpotRate   * elapsed;
        morphoCumulative += morphoSpotRate * elapsed;

        // ── Step 2: Read new Aave spot rate ───────────────────────────────────
        uint256 newAaveRate = _readAaveSpotRate();

        // ── Step 3: Compute new Morpho rate from share-price snapshots ────────
        // Uses two consecutive share-price readings to derive the true interval APY.
        // intervalRate = (currentPrice - lastPrice) / lastPrice * (SECONDS_PER_YEAR / elapsed)
        // This avoids the "compare to a fixed base" flaw which conflates total accrued yield
        // with the current period rate, producing wildly inaccurate annualised figures.
        uint256 currentSharePrice = MORPHO_VAULT.convertToAssets(SHARE_UNIT);
        uint256 newMorphoRate     = 0;
        uint256 morphoBaseline    = lastMorphoSharePrice;

        if (morphoBaseline == 0) {
            morphoBaseline = currentSharePrice;
        } else if (currentSharePrice > morphoBaseline) {
            // Annualised rate in ray:
            // rate = (priceDelta / baseline) * (SECONDS_PER_YEAR / elapsed) * RAY
            newMorphoRate = (currentSharePrice - morphoBaseline)
                * SECONDS_PER_YEAR
                * RAY
                / morphoBaseline
                / elapsed;
            morphoBaseline = currentSharePrice;
        }
        // Flat or downward observations keep the prior baseline. Recoveries back
        // to that baseline are not counted as positive yield.

        // ── Step 4: Store checkpoint in circular buffer ───────────────────────
        _checkpoints[_head % BUFFER_SIZE] = Checkpoint({
            timestamp:        uint32(block.timestamp),
            morphoSharePrice: uint64(currentSharePrice),
            aaveCumulative:   uint224(aaveCumulative),    // intentional truncation
            morphoCumulative: uint224(morphoCumulative)   // intentional truncation
        });

        // Advance head with explicit modulo against BUFFER_SIZE.
        // Do NOT rely on uint8 overflow: uint8 wraps at 256, and 256 % BUFFER_SIZE
        // (48) = 16, which would silently desync the ring index from _head and
        // break the chronological-order assumption inside _computeTWAR's walk.
        _head = uint8((uint256(_head) + 1) % BUFFER_SIZE);
        if (_count < BUFFER_SIZE) _count++;

        // ── Step 5: Update state variables ────────────────────────────────────
        aaveSpotRate         = newAaveRate;
        morphoSpotRate       = newMorphoRate;
        lastMorphoSharePrice = morphoBaseline;
        lastObservationTime  = block.timestamp;

        emit ObservationRecorded(block.timestamp, newAaveRate, newMorphoRate);
    }

    // ── Internal: Rate Reading ────────────────────────────────────────────────

    /// @dev Reads the current Aave V3 liquidity supply rate for USDC in ray (1e27).
    ///      `currentLiquidityRate` is already annualised by Aave's interest rate model.
    function _readAaveSpotRate() internal view returns (uint256 aaveRate) {
        (
            ,            // configuration
            ,            // liquidityIndex
            uint128 currentLiquidityRate,
            ,            // variableBorrowIndex
            ,            // currentVariableBorrowRate
            ,            // currentStableBorrowRate
            ,            // lastUpdateTimestamp
            ,            // id
            ,            // aTokenAddress
            ,            // stableDebtTokenAddress
            ,            // variableDebtTokenAddress
            ,            // interestRateStrategyAddress
            ,            // accruedToTreasury
            ,            // unbacked
                         // isolationModeTotalDebt
        ) = AAVE_POOL.getReserveData(address(USDC));

        aaveRate = uint256(currentLiquidityRate);
    }

    // ── Internal: TWAR Computation ────────────────────────────────────────────

    /// @dev Computes the 4-hour TWAR for each vault.
    ///      Finds the oldest checkpoint within the TWAR_WINDOW, then:
    ///        TWAR = (cumulativeNow - cumulativeThen) / (now - then)
    ///      where cumulativeNow is derived by extending the last stored checkpoint
    ///      with the current spot rate × elapsed time since last observation.
    ///
    ///      If recorded history does not span TWAR_WINDOW yet, this uses the
    ///      oldest available checkpoint as the lower bound. With no usable
    ///      checkpoint, or when the elapsed interval is zero, it falls back to
    ///      current spot rates.
    function _computeTWAR()
        internal
        view
        returns (uint256 aaveTWAR, uint256 morphoTWAR)
    {
        // Extend accumulators to current timestamp using the latest spot rates
        uint256 elapsed      = block.timestamp - lastObservationTime;
        uint256 aaveCumNow   = aaveCumulative   + (aaveSpotRate   * elapsed);
        uint256 morphoCumNow = morphoCumulative + (morphoSpotRate * elapsed);
        uint256 timestampNow = block.timestamp;

        // Need at least one checkpoint to compute a differential
        if (_count == 0) {
            return (aaveSpotRate, morphoSpotRate);
        }

        uint256 windowStart = timestampNow > TWAR_WINDOW
            ? timestampNow - TWAR_WINDOW
            : 0;

        // Walk the circular buffer from oldest to newest, find the oldest checkpoint
        // within or just before the windowStart boundary.
        // Buffer is ordered oldest→newest starting at (_head - _count) mod BUFFER_SIZE.
        uint8 startIdx = _count == BUFFER_SIZE
            ? _head                           // full buffer: oldest is at _head
            : 0;                              // partial buffer: oldest is at index 0

        Checkpoint memory bestCheckpoint;
        bool found = false;

        for (uint8 i = 0; i < _count; i++) {
            uint8 idx = uint8((startIdx + i) % BUFFER_SIZE);
            Checkpoint memory cp = _checkpoints[idx];

            if (cp.timestamp <= windowStart) {
                bestCheckpoint = cp;
                found = true;
                // continue: find the NEWEST checkpoint that is still <= windowStart
            } else if (!found) {
                // All checkpoints are newer than windowStart — use oldest available
                bestCheckpoint = cp;
                found = true;
                break;
            } else {
                // cp.timestamp > windowStart and a valid bestCheckpoint exists
                break;
            }
        }

        if (!found) {
            return (aaveSpotRate, morphoSpotRate);
        }

        uint256 dt = timestampNow - uint256(bestCheckpoint.timestamp);
        if (dt == 0) {
            return (aaveSpotRate, morphoSpotRate);
        }

        // Compute TWAR from cumulative delta. Cumulatives are stored as uint224
        // and intentionally overflow (Uniswap V2 pattern). The subtraction must
        // be unchecked so Solidity 0.8.x wraps instead of reverting on underflow.
        uint256 aaveDelta;
        uint256 morphoDelta;
        unchecked {
            aaveDelta   = uint256(uint224(aaveCumNow)   - bestCheckpoint.aaveCumulative);
            morphoDelta = uint256(uint224(morphoCumNow) - bestCheckpoint.morphoCumulative);
        }

        aaveTWAR   = aaveDelta   / dt;
        morphoTWAR = morphoDelta / dt;
    }

    // ── Internal: Safety Check ────────────────────────────────────────────────

    /// @dev Oracle-advisory safety checks for each vault.
    ///      These are qualitative signals; VaultRouter enforces amount-specific
    ///      capacity via _canAllocate() before routing any deposit.
    ///
    ///      IMPORTANT: neither check is a protocol-native safety guarantee.
    ///      Both are heuristics derived from observable on-chain state; they do not
    ///      represent commitments from Aave or Morpho about future vault behaviour,
    ///      market stress resilience, or withdrawal capacity under adverse conditions.
    ///
    ///      Aave utilisation (heuristic):
    ///        Computed as 1 - (USDC.balanceOf(aToken) / A_TOKEN.totalSupply()).
    ///        This uses the aToken contract's current idle USDC cash as a proxy for
    ///        liquidity depth. It is a balance-based heuristic, not a protocol-native
    ///        Aave capacity interface. It does not guarantee future withdrawal capacity,
    ///        does not account for pending borrows, and does not reflect Aave's internal
    ///        risk parameters. Safe if computed utilisation < 90% at query time.
    ///
    ///      Morpho share-price peg (heuristic):
    ///        Safe if convertToAssets(SHARE_UNIT) is at or above par — i.e., the vault has
    ///        not gone underwater. This is a narrow bad-debt/peg check, not a liquidity
    ///        or market-stress check. A healthy share price does not guarantee the vault
    ///        can service a large redemption without delay or slippage.
    function _isVaultSafe(VaultType vaultType) internal view returns (bool) {
        if (vaultType == VaultType.AAVE) {
            uint256 totalAToken = A_TOKEN.totalSupply();
            if (totalAToken == 0) return true; // empty pool is trivially safe

            // Available USDC cash sitting in the aToken contract
            uint256 available = USDC.balanceOf(address(A_TOKEN));

            // Safe if utilisation < UTILISATION_THRESHOLD_BPS
            // available / totalAToken > (10000 - threshold) / 10000
            // => available * 10000 > totalAToken * (10000 - threshold)
            uint256 minAvailable = (totalAToken * (BPS_DENOMINATOR - UTILISATION_THRESHOLD_BPS))
                / BPS_DENOMINATOR;

            return available >= minAvailable;
        } else {
            // Morpho MetaMorpho vault (18-decimal shares, 6-decimal USDC).
            // The peg threshold is scaled to the oracle's probe size.
            uint256 sharePrice = MORPHO_VAULT.convertToAssets(SHARE_UNIT);
            return sharePrice >= MORPHO_PEG_ASSETS;
        }
    }
}
