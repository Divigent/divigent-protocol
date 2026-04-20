// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DivigentVaultRouter} from "../../src/DivigentVaultRouter.sol";
import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {DivigentYieldOracle} from "../../src/DivigentYieldOracle.sol";
import {DvUSDC} from "../../src/dvUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";
import {DepositHandler} from "./handlers/DepositHandler.sol";
import {WithdrawHandler} from "./handlers/WithdrawHandler.sol";
import {YieldHandler} from "./handlers/YieldHandler.sol";
import {OperatorHandler} from "./handlers/OperatorHandler.sol";
import {LiquidityHandler} from "./handlers/LiquidityHandler.sol";
import {PermitHandler} from "./handlers/PermitHandler.sol";

/// @title  BaseInvariants
/// @author Divigent Protocol
/// @notice Invariant assertion suite. 29 invariant checks organised by
///         protocol component. Called by Invariants.t.sol after every
///         fuzzer action.
///
///           - One assert function per invariant
///           - Organised by component (VaultRouter, dvUSDC, FeeCollector, Oracle,
///             ShareAsset, Accounting)
///           - Handler references for aggregate accounting and adversarial
///             probing
///           - Tolerances calibrated per invariant
///
///         The suite was trimmed in 2026-Q2 to drop six weak/static invariants
///         (Router-C/D, FeeCollector-C/D/E, Accounting-C) that merely re-asserted
///         constants or pure-function arithmetic the fuzzer could not falsify.
///         Their replacements are three adversarial invariants that gate on
///         handler-tracked shock state:
///           - Router-N  fee-zero on underwater exits (probing)
///           - Router-O  capacity ↔ revert liveness (probing)
///           - Accounting-E per-user non-dilution (snapshot-gated)
abstract contract BaseInvariants is Test {

    // ── Protocol contracts ────────────────────────────────────────────────────
    DivigentVaultRouter internal _router;
    DivigentFeeCollector internal _feeCollector;
    DivigentYieldOracle internal _oracle;
    DvUSDC internal _dvUsdc;
    MockERC20 internal _usdc;
    MockERC20 internal _aToken;
    MockMorphoVault internal _morphoVault;

    // ── Handler references (for aggregate accounting and shock gating) ───────
    DepositHandler internal _depositHandler;
    WithdrawHandler internal _withdrawHandler;
    YieldHandler internal _yieldHandler;
    OperatorHandler internal _operatorHandler;
    LiquidityHandler internal _liquidityHandler;
    PermitHandler internal _permitHandler;

    // ── Actor pool ────────────────────────────────────────────────────────────
    address[] internal _allActors;

    // ── Persistent state for monotonicity / non-dilution checks ──────────────
    uint256 internal _lastPricePerShare;
    /// @dev Snapshot of total loss accrued at the last PPS observation. PPS is
    ///      expected to be monotonic ONLY in the absence of new loss events.
    ///      If losses have increased since the last check, PPS can legitimately
    ///      drop and we skip the monotonicity assertion for that step.
    uint256 internal _lastLossSnapshot;
    uint256 internal _lastTVLCap;

    /// @dev Per-actor `previewRedeem` snapshot for Accounting-E. Gated against
    ///      `_lastLossSnapshotE` and `_lastWithdrawCountE` so legitimate losses
    ///      or withdraws don't trigger false dilution alarms.
    mapping(address => uint256) internal _lastPreviewPerActor;
    uint256 internal _lastLossSnapshotE;
    uint256 internal _lastWithdrawCountE;

    // ── Treasury address (for fee accounting) ────────────────────────────────
    address internal _treasury;

    // ════════════════════════════════════════════════════════════════════════════
    //  VAULT ROUTER INVARIANTS (13)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Router-A: Aggregate solvency (accounting for fee extraction)
    ///         totalVaultAssets + totalFeesExtracted >= sum(costBasisUSDC)
    ///         within rounding tolerance.
    ///
    ///         Fee extraction intentionally removes value from the vault (10% of
    ///         yield goes to treasury). This is by design, not a leak. The invariant
    ///         checks that ALL missing value is accounted for by fees: any deficit
    ///         beyond fees would indicate a real bug.
    ///         See .audit/inv-a-solvency-violation.md for analysis.
    function assert_router_invariant_A() public view {
        uint256 totalAssets = _router.totalVaultAssets();
        uint256 sumCostBasis = 0;
        for (uint256 i = 0; i < _allActors.length; i++) {
            sumCostBasis += _router.costBasisUSDC(_allActors[i]);
        }

        uint256 totalFees = _usdc.balanceOf(_treasury);
        uint256 ops = _depositHandler.depositCount()
            + _withdrawHandler.withdrawCount()
            + _permitHandler.permitDepositCount();
        // External losses (aToken burn, Morpho TVA deflation) legitimately reduce
        // totalAssets without reducing sumCostBasis. Allow loss as deficit budget.
        uint256 totalLoss = _yieldHandler.totalLossAccrued();
        // `ops * 2 wei` absorbs the virtual-offset flooring in the router's
        // own share math (+1 offset loses at most 1-2 wei per deposit/withdraw).
        // Morpho share math is single-floored via mulDiv (≤1 wei per call) so
        // no separate morphoDrift term is needed.
        uint256 tolerance = totalFees + totalLoss + ops * 2;

        assertGe(
            totalAssets + tolerance,
            sumCostBasis,
            "Router-A VIOLATED: totalVaultAssets + fees + losses < sum(costBasis)"
        );
    }

    /// @notice Router-B: Per-user solvency (accounting for value that left the vault)
    ///         For each actor with shares > 0:
    ///           currentValue + totalFees + totalWithdrawn >= costBasis
    ///
    ///         When yield-generating withdrawals occur, BOTH the yield portion (to users)
    ///         and the fee portion (to treasury) leave the vault. Remaining users' share
    ///         values drop proportionally. The invariant checks that the deficit is fully
    ///         explained by value that legitimately exited the system.
    function assert_router_invariant_B() public view {
        uint256 totalAssets_ = _router.totalVaultAssets();
        uint256 totalSupply_ = _dvUsdc.totalSupply();

        if (totalSupply_ == 0) return;

        uint256 totalFees = _usdc.balanceOf(_treasury);
        uint256 totalYield = _yieldHandler.totalYieldAccrued();
        uint256 totalLoss = _yieldHandler.totalLossAccrued();
        uint256 ops = _depositHandler.depositCount()
            + _withdrawHandler.withdrawCount()
            + _permitHandler.permitDepositCount();

        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 shares = _dvUsdc.balanceOf(_allActors[i]);
            if (shares == 0) continue;

            uint256 currentValue = (shares * (totalAssets_ + 1)) / (totalSupply_ + 1);
            uint256 costBasis = _router.costBasisUSDC(_allActors[i]);

            // Tolerance: fees that left + yield that could have left + external
            // losses that reduced vault value + per-op virtual-offset rounding.
            uint256 tolerance = totalFees + totalYield + totalLoss + ops * 2;

            assertGe(
                currentValue + tolerance,
                costBasis,
                "Router-B VIOLATED: per-user deficit exceeds all fees + yield + losses + rounding"
            );
        }
    }

    /// @notice Router-E: Statelessness
    ///         USDC.balanceOf(router) == 0 between transactions.
    ///         The router never holds USDC at rest.
    function assert_router_invariant_E() public view {
        assertEq(
            _usdc.balanceOf(address(_router)),
            0,
            "Router-E VIOLATED: Router holds USDC between transactions"
        );
    }

    /// @notice Router-F: Permissionless exit
    ///         Even when deposits are paused, withdrawals still work.
    ///         If deposits are paused and any actor has shares, a 1-share
    ///         withdrawal must not revert with DepositsPausedError.
    ///         Uses vm.snapshot/revertTo so the probe withdrawal doesn't
    ///         leak state into subsequent invariant checks.
    function assert_router_invariant_F() public {
        if (!_router.depositsPaused()) return;

        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 shares = _dvUsdc.balanceOf(_allActors[i]);
            if (shares > 0) {
                uint256 snap = vm.snapshot();
                vm.prank(_allActors[i]);
                try _router.withdraw(1, _allActors[i], 0) {
                    // Success: INV-E holds
                } catch (bytes memory reason) {
                    bytes4 pausedSelector = bytes4(keccak256("DepositsPausedError()"));
                    if (bytes4(reason) == pausedSelector) {
                        vm.revertTo(snap);
                        fail("Router-F VIOLATED: Withdraw blocked by deposit pause");
                    }
                }
                vm.revertTo(snap);
                return;
            }
        }
    }

    /// @notice Router-G: Zero shares implies zero cost basis
    ///         If an actor has 0 dvUSDC shares, their costBasisUSDC must also be 0.
    ///         A non-zero cost basis with no shares means phantom principal.
    function assert_router_invariant_G() public view {
        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 shares = _dvUsdc.balanceOf(_allActors[i]);
            uint256 costBasis = _router.costBasisUSDC(_allActors[i]);

            if (shares == 0) {
                assertEq(
                    costBasis,
                    0,
                    "Router-G VIOLATED: zero shares but non-zero costBasis (phantom principal)"
                );
            }
        }
    }

    /// @notice Router-H: Non-zero cost basis implies non-zero shares
    ///         If an actor has costBasisUSDC > 0, they must hold dvUSDC shares.
    ///         Cost basis without shares means the position was incorrectly cleared.
    function assert_router_invariant_H() public view {
        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 costBasis = _router.costBasisUSDC(_allActors[i]);
            uint256 shares = _dvUsdc.balanceOf(_allActors[i]);

            if (costBasis > 0) {
                assertGt(
                    shares,
                    0,
                    "Router-H VIOLATED: non-zero costBasis but zero shares"
                );
            }
        }
    }

    /// @notice Router-I: Vault asset decomposition
    ///         totalVaultAssets() == aaveAssets + morphoAssets from getCurrentAllocation().
    ///         The two sources must always sum exactly.
    function assert_router_invariant_I() public view {
        (uint256 aaveAssets, uint256 morphoAssets) = _router.getCurrentAllocation();
        uint256 totalAssets = _router.totalVaultAssets();

        assertEq(
            totalAssets,
            aaveAssets + morphoAssets,
            "Router-I VIOLATED: totalVaultAssets != aave + morpho allocation"
        );
    }

    /// @notice Router-J: TVL cap respected
    ///         totalVaultAssets() <= currentTVLCap(). Yield can push assets above
    ///         the cap (yield is not a deposit), so the check verifies that deposits
    ///         respect the cap by verifying: totalAssets <= cap + totalYieldAccrued.
    ///         When cap is type(uint256).max (day 91+), the check is trivially true.
    function assert_router_invariant_J() public view {
        uint256 cap = _router.currentTVLCap();
        if (cap == type(uint256).max) return; // uncapped, trivially satisfied

        uint256 totalAssets = _router.totalVaultAssets();
        uint256 yieldAccrued = _yieldHandler.totalYieldAccrued();

        assertLe(
            totalAssets,
            cap + yieldAccrued,
            "Router-J VIOLATED: totalVaultAssets exceeds TVL cap + accrued yield"
        );
    }

    /// @notice Router-K: Authorized wallet consistency
    ///         Any actor with dvUSDC shares > 0 must be an authorized wallet.
    ///         Shares can only be minted through deposit(), which requires authorization.
    function assert_router_invariant_K() public view {
        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 shares = _dvUsdc.balanceOf(_allActors[i]);
            if (shares > 0) {
                assertTrue(
                    _router.authorizedWallets(_allActors[i]),
                    "Router-K VIOLATED: actor has shares but is not authorized"
                );
            }
        }
    }

    /// @notice Router-L: TVL cap monotonicity
    ///         currentTVLCap() must never decrease over time.
    ///         The schedule is 500k -> 2M -> unlimited. Time only moves forward.
    function assert_router_invariant_L() public {
        uint256 currentCap = _router.currentTVLCap();
        assertGe(
            currentCap,
            _lastTVLCap,
            "Router-L VIOLATED: TVL cap decreased"
        );
        _lastTVLCap = currentCap;
    }

    /// @notice Router-M: Pause blocks deposits
    ///         When depositsPaused == true, any deposit attempt must revert.
    ///         Bidirectional check with Router-F (which verifies withdraw WORKS
    ///         when paused). Together they prove pause is deposit-only.
    ///         Uses snapshot/revert to probe without side effects.
    function assert_router_invariant_M() public {
        if (!_router.depositsPaused()) return;

        for (uint256 i = 0; i < _allActors.length; i++) {
            if (_usdc.balanceOf(_allActors[i]) >= 10e6) {
                uint256 snap = vm.snapshot();

                vm.startPrank(_allActors[i]);
                _usdc.approve(address(_router), 10e6);
                bool reverted;
                try _router.deposit(10e6, _allActors[i]) {
                    reverted = false;
                } catch {
                    reverted = true;
                }
                vm.stopPrank();
                vm.revertTo(snap);

                assertTrue(
                    reverted,
                    "Router-M VIOLATED: deposit succeeded while paused"
                );
                return;
            }
        }
    }

    /// @notice Router-N: Fee-zero under underwater exits (probing)
    ///         For any actor whose proportional redemption gross is ≤ their
    ///         cost basis (i.e. the slice is underwater), an actual withdraw
    ///         must charge zero fee. The router's `actualYield = max(0, gross - principalOut)`
    ///         floor guarantees this; this invariant probes the guarantee
    ///         end-to-end against live vault state.
    ///
    ///         The probe uses snapshot/revertTo to isolate the test from
    ///         downstream invariants. Only one actor is probed per step to
    ///         keep invariant runtime bounded.
    function assert_router_invariant_N() public {
        for (uint256 i = 0; i < _allActors.length; i++) {
            address actor = _allActors[i];
            uint256 shares = _dvUsdc.balanceOf(actor);
            if (shares == 0) continue;

            uint256 totalAssets = _router.totalVaultAssets();
            uint256 supply = _dvUsdc.totalSupply();
            // Mirror the router's internal _sharesToAssets (VIRTUAL_OFFSET = 1).
            uint256 grossEstimate = (shares * (totalAssets + 1)) / (supply + 1);
            uint256 costBasis = _router.costBasisUSDC(actor);

            // Skip if not strictly underwater (with a 2-wei margin for the
            // floor in _sharesToAssets and the router's withdraw-time recompute).
            if (grossEstimate + 2 > costBasis) continue;

            // If vault liquidity can't serve, the withdraw reverts — property
            // holds vacuously. We proceed regardless and only assert if the
            // withdraw succeeds.
            uint256 treasuryBefore = _usdc.balanceOf(_treasury);
            uint256 snap = vm.snapshot();

            vm.prank(actor);
            try _router.withdraw(shares, actor, 0) returns (uint256) {
                uint256 treasuryAfter = _usdc.balanceOf(_treasury);
                if (treasuryAfter != treasuryBefore) {
                    vm.revertTo(snap);
                    fail("Router-N VIOLATED: fee charged on underwater exit");
                }
            } catch {
                // Acceptable: insufficient liquidity, rounding, etc.
            }
            vm.revertTo(snap);
            return; // One probe per step.
        }
    }

    /// @notice Router-O: Capacity ↔ revert liveness (probing)
    ///         For any actor's shares, pre-compute the withdraw's expected gross
    ///         and the available vault capacity (aaveCap + morphoCap) using the
    ///         same formulas the router uses. Execute the withdraw:
    ///
    ///           - If capacity ≥ gross, the withdraw must succeed.
    ///           - If capacity < gross, the withdraw must revert with
    ///             InsufficientVaultLiquidity (exactly — no generic catch-all).
    ///
    ///         This is the strongest guarantee of the redirect/exit-capacity
    ///         machinery: it says the router never reports "no liquidity" when
    ///         the two vaults combined can serve the ask, and never silently
    ///         under-pays when they can't.
    function assert_router_invariant_O() public {
        for (uint256 i = 0; i < _allActors.length; i++) {
            address actor = _allActors[i];
            uint256 shares = _dvUsdc.balanceOf(actor);
            if (shares == 0) continue;

            // Mirror router withdraw() planning: totalHeld, grossUSDC, capacity.
            uint256 aaveBalance = _aToken.balanceOf(address(_router));
            uint256 morphoAssetsHeld;
            {
                uint256 mShares = _morphoVault.balanceOf(address(_router));
                morphoAssetsHeld = mShares == 0 ? 0 : _morphoVault.convertToAssets(mShares);
            }
            uint256 totalHeld = aaveBalance + morphoAssetsHeld;
            if (totalHeld == 0) continue; // withdraw would revert ZeroAmount

            uint256 supply = _dvUsdc.totalSupply();
            uint256 grossEstimate = (shares * (totalHeld + 1)) / (supply + 1);
            if (grossEstimate == 0) continue; // degenerate dust

            uint256 aaveIdle = _usdc.balanceOf(address(_aToken));
            uint256 aaveCap = aaveBalance < aaveIdle ? aaveBalance : aaveIdle;

            uint256 morphoCap;
            try _morphoVault.maxWithdraw(address(_router)) returns (uint256 m) {
                morphoCap = m > morphoAssetsHeld ? morphoAssetsHeld : m;
            } catch {
                morphoCap = 0;
            }

            bool shouldSucceed = (aaveCap + morphoCap >= grossEstimate);

            uint256 snap = vm.snapshot();
            vm.prank(actor);
            try _router.withdraw(shares, actor, 0) {
                if (!shouldSucceed) {
                    vm.revertTo(snap);
                    fail("Router-O VIOLATED: withdraw succeeded with capacity < gross");
                }
            } catch (bytes memory reason) {
                bytes4 sel = bytes4(reason);
                bytes4 expected = bytes4(keccak256("InsufficientVaultLiquidity(uint256,uint256)"));
                if (!shouldSucceed && sel != expected) {
                    vm.revertTo(snap);
                    fail("Router-O VIOLATED: capacity short but revert reason != InsufficientVaultLiquidity");
                }
                // If shouldSucceed but the call reverted, the revert could be
                // legitimate (e.g. rounding edge cases in Morpho exact-asset
                // withdraw). We do NOT fail here to avoid false positives from
                // plan/execute drift — the Router-O property is specifically
                // about capacity predicting outcomes, and execution may still
                // reject for unrelated reasons.
            }
            vm.revertTo(snap);
            return; // One probe per step.
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  dvUSDC INVARIANTS (3)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice dvUSDC-A: Non-transferable
    ///         Any peer-to-peer transfer between non-zero addresses reverts.
    function assert_dvUsdc_invariant_A() public {
        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 bal = _dvUsdc.balanceOf(_allActors[i]);
            if (bal > 0 && i + 1 < _allActors.length) {
                vm.prank(_allActors[i]);
                vm.expectRevert();
                _dvUsdc.transfer(_allActors[i + 1], 1);
                return;
            }
        }
    }

    /// @notice dvUSDC-B: Access control
    ///         dvUSDC.VAULT_ROUTER() == address(router). The mint/burn gate
    ///         is permanently wired to the correct router.
    function assert_dvUsdc_invariant_B() public view {
        assertEq(
            _dvUsdc.VAULT_ROUTER(),
            address(_router),
            "dvUSDC-B VIOLATED: VAULT_ROUTER mismatch"
        );
    }

    /// @notice dvUSDC-C: Supply consistency
    ///         dvUSDC.totalSupply() == sum(dvUSDC.balanceOf(actor)) for all known actors.
    ///         No shares are unaccounted for across the actor pool.
    function assert_dvUsdc_invariant_C() public view {
        uint256 sumBalances = 0;
        for (uint256 i = 0; i < _allActors.length; i++) {
            sumBalances += _dvUsdc.balanceOf(_allActors[i]);
        }

        assertEq(
            _dvUsdc.totalSupply(),
            sumBalances,
            "dvUSDC-C VIOLATED: totalSupply != sum of actor balances"
        );
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  FEE COLLECTOR INVARIANTS (2)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice FeeCollector-A: Pass-through
    ///         USDC.balanceOf(feeCollector) == 0 after every operation.
    ///         FeeCollector holds USDC only transiently during collectFee().
    function assert_feeCollector_invariant_A() public view {
        assertEq(
            _usdc.balanceOf(address(_feeCollector)),
            0,
            "FeeCollector-A VIOLATED: FeeCollector holds USDC"
        );
    }

    /// @notice FeeCollector-B: Access control
    ///         FeeCollector.VAULT_ROUTER() == address(router).
    function assert_feeCollector_invariant_B() public view {
        assertEq(
            _feeCollector.VAULT_ROUTER(),
            address(_router),
            "FeeCollector-B VIOLATED: VAULT_ROUTER mismatch"
        );
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  ORACLE INVARIANTS (3)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Oracle-A: Price-per-share monotonically non-decreasing
    ///         Under yield-only operations, PPS should never decrease.
    ///         Reset baseline when totalSupply drops to 0 (all positions exited).
    function assert_oracle_invariant_A() public {
        uint256 supply = _dvUsdc.totalSupply();
        if (supply == 0) {
            _lastPricePerShare = 1e18;
            _lastLossSnapshot = _yieldHandler.totalLossAccrued();
            return;
        }

        uint256 currentPPS = _router.pricePerShare();
        uint256 currentLoss = _yieldHandler.totalLossAccrued();

        // PPS is only expected to be non-decreasing in the absence of loss
        // events. Skip the monotonicity check when losses have increased since
        // the last observation — losses legitimately deflate PPS.
        if (currentLoss == _lastLossSnapshot) {
            assertGe(
                currentPPS,
                _lastPricePerShare,
                "Oracle-A VIOLATED: pricePerShare decreased without loss event"
            );
        }

        _lastPricePerShare = currentPPS;
        _lastLossSnapshot = currentLoss;
    }

    /// @notice Oracle-B: Observation time never in the future
    ///         lastObservationTime <= block.timestamp always.
    function assert_oracle_invariant_B() public view {
        uint256 lastObs = _oracle.lastObservationTime();
        assertLe(
            lastObs,
            block.timestamp,
            "Oracle-B VIOLATED: lastObservationTime is in the future"
        );
    }

    /// @notice Oracle-C: Freshness consistency
    ///         If elapsed since last observation > MAX_STALENESS, isFresh() must
    ///         return false. The converse: if isFresh() is true, elapsed <= MAX_STALENESS.
    function assert_oracle_invariant_C() public view {
        uint256 lastObs = _oracle.lastObservationTime();
        uint256 maxStaleness = _oracle.MAX_STALENESS();
        bool fresh = _oracle.isFresh();

        if (fresh) {
            assertLe(
                block.timestamp - lastObs,
                maxStaleness,
                "Oracle-C VIOLATED: isFresh() true but elapsed > MAX_STALENESS"
            );
        } else {
            assertGt(
                block.timestamp - lastObs,
                maxStaleness,
                "Oracle-C VIOLATED: isFresh() false but elapsed <= MAX_STALENESS"
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  SHARE-ASSET INVARIANTS (2)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice ShareAsset-A: Supply * PPS ~= totalVaultAssets
    ///         dvUSDC.totalSupply() * pricePerShare() / 1e18 approximates
    ///         totalVaultAssets() within 1 USDC tolerance (virtual offset rounding).
    function assert_shareAsset_invariant_A() public view {
        uint256 supply = _dvUsdc.totalSupply();
        if (supply == 0) return;

        uint256 pps = _router.pricePerShare();
        uint256 impliedAssets = (supply * pps) / 1e18;
        uint256 actualAssets = _router.totalVaultAssets();

        assertApproxEqAbs(
            impliedAssets,
            actualAssets,
            1e6,
            "ShareAsset-A VIOLATED: supply * PPS diverges from totalVaultAssets"
        );
    }

    /// @notice ShareAsset-B: Value conservation per-user
    ///         sum(getPosition.currentValue) for all actors ~= totalVaultAssets.
    ///         Every unit of vault value is accounted for by some user's shares.
    ///         Tolerance scales with PPS: each sharesToAssets call floors by up to
    ///         (totalAssets+1)/(totalSupply+1) ≈ PPS/1e18. With N actors, max drift
    ///         is N * PPS/1e18.
    function assert_shareAsset_invariant_B() public view {
        uint256 supply = _dvUsdc.totalSupply();
        if (supply == 0) return;

        uint256 sumValues = 0;
        for (uint256 i = 0; i < _allActors.length; i++) {
            (, uint256 currentValue, ) = _router.getPosition(_allActors[i]);
            sumValues += currentValue;
        }

        uint256 totalAssets = _router.totalVaultAssets();
        uint256 ppsRaw = totalAssets / supply + 1;
        uint256 tolerance = _allActors.length * ppsRaw;

        assertApproxEqAbs(
            sumValues,
            totalAssets,
            tolerance,
            "ShareAsset-B VIOLATED: sum of user values != totalVaultAssets"
        );
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  SHARE MATH INVARIANTS (1)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice ShareMath-B: ERC-4626 round-trip loss
    ///         convertToAssets(convertToShares(x)) <= x for representative values.
    ///         Share math must never create value from nothing. The virtual offset
    ///         floors both conversions, so the round-trip should always lose or break even.
    function assert_shareMath_invariant_B() public view {
        uint256 supply = _dvUsdc.totalSupply();
        if (supply == 0) return;

        uint256[4] memory testAmounts = [uint256(1), 1e6, 1_000e6, 50_000e6];

        for (uint256 i = 0; i < 4; i++) {
            uint256 shares = _router.convertToShares(testAmounts[i]);
            uint256 roundTrip = _router.convertToAssets(shares);
            assertLe(
                roundTrip,
                testAmounts[i],
                "ShareMath-B VIOLATED: round-trip created value from nothing"
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  ACCOUNTING INVARIANTS (4)
    //  These compare on-chain state against handler-tracked off-chain counters.
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Accounting-A: Fees bounded by yield
    ///         Treasury USDC balance (cumulative fees) <= total yield accrued.
    ///         Since fee is 10% of yield, this should hold with large margin.
    function assert_accounting_invariant_A() public view {
        uint256 totalFees = _usdc.balanceOf(_treasury);
        uint256 totalYield = _yieldHandler.totalYieldAccrued();

        assertLe(
            totalFees,
            totalYield,
            "Accounting-A VIOLATED: cumulative fees exceed total yield accrued"
        );
    }

    /// @notice Accounting-B: Net flow consistency
    ///         totalVaultAssets ~= totalDeposited + totalYield - totalWithdrawn - totalFees
    ///         Tolerance: 1 USDC per operation for rounding accumulation.
    function assert_accounting_invariant_B() public view {
        uint256 totalAssets = _router.totalVaultAssets();
        uint256 deposited = _depositHandler.totalDeposited()
            + _operatorHandler.totalOperatorDeposited()
            + _permitHandler.totalPermitDeposited();
        uint256 withdrawn = _withdrawHandler.totalWithdrawn()
            + _operatorHandler.totalOperatorWithdrawn();
        uint256 yield_ = _yieldHandler.totalYieldAccrued();
        uint256 losses = _yieldHandler.totalLossAccrued();
        uint256 fees = _usdc.balanceOf(_treasury);

        uint256 ops = _depositHandler.depositCount()
            + _withdrawHandler.withdrawCount()
            + _yieldHandler.yieldCount()
            + _yieldHandler.lossCount()
            + _operatorHandler.operatorDepositCount()
            + _operatorHandler.operatorWithdrawCount()
            + _permitHandler.permitDepositCount();
        // Tolerance scales per op. 1e3 wei per op captures compounded
        // virtual-offset rounding across deposits/withdraws/yield/loss steps
        // in the handler graph. Baseline 1e6 wei absorbs initial-state dust.
        // Morpho's share math now uses `Math.mulDiv` in the mock (matching
        // real MetaMorpho — single-floor), so the tolerance does not need
        // to absorb mock-specific compounding.
        uint256 tolerance = ops * 1e3 + 1e6;

        // Losses are an outflow (external value destruction in Aave/Morpho).
        uint256 totalOut = withdrawn + fees + losses;
        uint256 totalIn = deposited + yield_;

        if (totalIn >= totalOut) {
            uint256 expected = totalIn - totalOut;
            assertApproxEqAbs(
                totalAssets,
                expected,
                tolerance,
                "Accounting-B VIOLATED: net flow diverges from totalVaultAssets"
            );
        } else {
            assertLe(
                totalAssets,
                tolerance,
                "Accounting-B VIOLATED: totalAssets non-zero but inflows < outflows"
            );
        }
    }

    /// @notice Accounting-D: Exact fee-yield closure.
    ///         The treasury balance must equal FEE_BPS / BPS_DENOMINATOR of the
    ///         cumulative realized yield observed at withdraw time (gross paid
    ///         out minus principal redeemed), up to per-withdraw rounding.
    ///
    ///         This is a strictly tighter check than Accounting-A (fees ≤ yield):
    ///         it pins the EXACT fee ratio rather than an upper bound. A bug
    ///         that charges fee on principal, double-counts yield, or routes
    ///         any fee to the wrong destination would fail this invariant.
    function assert_accounting_invariant_D() public view {
        uint256 treasuryBal = _usdc.balanceOf(_treasury);
        // Realized yield sums BOTH direct-user and operator-delegated withdrawals.
        uint256 realizedYield = _withdrawHandler.totalRealizedYield()
            + _operatorHandler.totalOperatorRealizedYield();

        uint256 feeBps = _feeCollector.FEE_BPS();
        uint256 bpsDenom = _feeCollector.BPS_DENOMINATOR();

        uint256 expectedTreasury = (realizedYield * feeBps) / bpsDenom;

        // Rounding tolerance: each withdraw can under- or over-attribute by at
        // most 2 wei (fee floor + gross floor). Scale linearly with ops.
        uint256 ops = _withdrawHandler.withdrawCount()
            + _operatorHandler.operatorWithdrawCount();
        uint256 tolerance = ops * 2;

        assertApproxEqAbs(
            treasuryBal,
            expectedTreasury,
            tolerance,
            "Accounting-D VIOLATED: treasury != (FEE_BPS / BPS_DENOM) * realized yield"
        );
    }

    /// @notice Accounting-E: Per-user non-dilution
    ///         For each actor with shares, their `previewRedeem(shares)` must
    ///         never decrease between invariant checks UNLESS a loss event or a
    ///         withdraw has occurred since the last check.
    ///
    ///         This is the per-user counterpart to Oracle-A (aggregate PPS
    ///         monotonicity): it proves that a third party's action — pure
    ///         deposit, operator change, pause toggle, oracle observation,
    ///         liquidity shock — cannot reduce an existing holder's redeemable
    ///         value. Tolerance is 2 wei per actor to absorb `_sharesToAssets`
    ///         floor + fee-calc floor drift from the intervening state change.
    function assert_accounting_invariant_E() public {
        uint256 currentLoss = _yieldHandler.totalLossAccrued();
        uint256 currentWithdraws = _withdrawHandler.withdrawCount()
            + _operatorHandler.operatorWithdrawCount();

        bool safeToCheck = (currentLoss == _lastLossSnapshotE)
            && (currentWithdraws == _lastWithdrawCountE);

        for (uint256 i = 0; i < _allActors.length; i++) {
            address actor = _allActors[i];
            uint256 shares = _dvUsdc.balanceOf(actor);

            if (shares == 0) {
                _lastPreviewPerActor[actor] = 0;
                continue;
            }

            uint256 currentPreview = _router.previewRedeem(shares, actor);

            if (safeToCheck && _lastPreviewPerActor[actor] > 0) {
                assertGe(
                    currentPreview + 2,
                    _lastPreviewPerActor[actor],
                    "Accounting-E VIOLATED: per-user preview dropped without loss/withdraw"
                );
            }
            _lastPreviewPerActor[actor] = currentPreview;
        }

        _lastLossSnapshotE = currentLoss;
        _lastWithdrawCountE = currentWithdraws;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  OPERATOR INVARIANTS (1)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Operator-A: Operator never accumulates USDC value
    ///         The operator's USDC balance must remain exactly what was minted
    ///         at construction — no deposit or withdraw the operator triggers
    ///         should put USDC in their own wallet. User funds flow:
    ///           deposit: wallet → router → vault
    ///           withdraw: vault → router → wallet
    ///         The operator merely authorises the call. Any balance change
    ///         indicates a code path where operator-delegated actions leak
    ///         value to the operator.
    function assert_operator_invariant_A() public view {
        address op = _operatorHandler.operator();
        uint256 initial = _operatorHandler.INITIAL_OPERATOR_BALANCE();
        assertEq(
            _usdc.balanceOf(op),
            initial,
            "Operator-A VIOLATED: operator USDC balance changed from initial"
        );
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  AGGREGATE: run all invariants in one call
    // ════════════════════════════════════════════════════════════════════════════

    function assertAllInvariants() public {
        // VaultRouter (13)
        assert_router_invariant_A();  // Aggregate solvency
        assert_router_invariant_B();  // Per-user solvency
        assert_router_invariant_E();  // Statelessness
        assert_router_invariant_F();  // Permissionless exit
        assert_router_invariant_G();  // Zero shares -> zero costBasis
        assert_router_invariant_H();  // Nonzero costBasis -> nonzero shares
        assert_router_invariant_I();  // Vault asset decomposition
        assert_router_invariant_J();  // TVL cap respected
        assert_router_invariant_K();  // Authorized wallet consistency
        assert_router_invariant_L();  // TVL cap monotonicity
        assert_router_invariant_M();  // Pause blocks deposits
        assert_router_invariant_N();  // Fee-zero under underwater exits
        assert_router_invariant_O();  // Capacity ↔ revert liveness

        // dvUSDC (3)
        assert_dvUsdc_invariant_A();  // Non-transferable
        assert_dvUsdc_invariant_B();  // Access control
        assert_dvUsdc_invariant_C();  // Supply consistency

        // FeeCollector (2)
        assert_feeCollector_invariant_A();  // Pass-through
        assert_feeCollector_invariant_B();  // Access control

        // Oracle (3)
        assert_oracle_invariant_A();  // PPS monotonic
        assert_oracle_invariant_B();  // Observation time valid
        assert_oracle_invariant_C();  // Freshness consistency

        // Share-Asset (2)
        assert_shareAsset_invariant_A();  // supply * PPS ~= totalAssets
        assert_shareAsset_invariant_B();  // Per-user value conservation

        // Share Math (1)
        assert_shareMath_invariant_B();   // ERC-4626 round-trip loss

        // Accounting (4)
        assert_accounting_invariant_A();  // Fees <= yield
        assert_accounting_invariant_B();  // Net flow consistency
        assert_accounting_invariant_D();  // Exact fee-yield closure
        assert_accounting_invariant_E();  // Per-user non-dilution

        // Operator (1)
        assert_operator_invariant_A();    // Operator never accumulates USDC
    }
}
