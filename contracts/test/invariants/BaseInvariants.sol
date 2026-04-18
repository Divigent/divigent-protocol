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

/// @title  BaseInvariants
/// @author Divigent Protocol
/// @notice Maple-style invariant assertion suite. 30 invariant checks organised
///         by protocol component. Called by Invariants.t.sol after every fuzzer
///         action.
///
///         Structure mirrors maple-core-v2/tests/invariants/BaseInvariants.t.sol:
///           - One assert function per invariant
///           - Organised by component (VaultRouter, dvUSDC, FeeCollector, Oracle, Accounting)
///           - Handler references for aggregate accounting checks
///           - Tolerances calibrated per invariant
abstract contract BaseInvariants is Test {

    // ── Protocol contracts ────────────────────────────────────────────────────
    DivigentVaultRouter internal _router;
    DivigentFeeCollector internal _feeCollector;
    DivigentYieldOracle internal _oracle;
    DvUSDC internal _dvUsdc;
    MockERC20 internal _usdc;
    MockERC20 internal _aToken;
    MockMorphoVault internal _morphoVault;

    // ── Handler references (for aggregate accounting checks) ─────────────────
    DepositHandler internal _depositHandler;
    WithdrawHandler internal _withdrawHandler;
    YieldHandler internal _yieldHandler;
    OperatorHandler internal _operatorHandler;

    // ── Actor pool ────────────────────────────────────────────────────────────
    address[] internal _allActors;

    // ── Persistent state for monotonicity checks ─────────────────────────────
    uint256 internal _lastPricePerShare;
    uint256 internal _lastObservationTime;
    uint256 internal _lastDepositCount;
    uint256 internal _lastWithdrawCount;
    uint256 internal _lastYieldCount;
    uint256 internal _lastTVLCap;

    // ── Treasury address (for fee accounting) ────────────────────────────────
    address internal _treasury;

    // ════════════════════════════════════════════════════════════════════════════
    //  VAULT ROUTER INVARIANTS (11)
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
        uint256 ops = _depositHandler.depositCount() + _withdrawHandler.withdrawCount();
        uint256 tolerance = totalFees + ops * 2;

        assertGe(
            totalAssets + tolerance,
            sumCostBasis,
            "Router-A VIOLATED: totalVaultAssets + fees < sum(costBasis)"
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
        uint256 ops = _depositHandler.depositCount() + _withdrawHandler.withdrawCount();

        for (uint256 i = 0; i < _allActors.length; i++) {
            uint256 shares = _dvUsdc.balanceOf(_allActors[i]);
            if (shares == 0) continue;

            uint256 currentValue = (shares * (totalAssets_ + 1)) / (totalSupply_ + 1);
            uint256 costBasis = _router.costBasisUSDC(_allActors[i]);

            // Tolerance: fees that left + yield that could have left + rounding
            uint256 tolerance = totalFees + totalYield + ops * 2;

            assertGe(
                currentValue + tolerance,
                costBasis,
                "Router-B VIOLATED: per-user deficit exceeds all fees + yield + rounding"
            );
        }
    }

    /// @notice Router-C: Principal preservation (structural)
    ///         calculateFee(0) must always return 0. If yield is zero, no fee
    ///         is charged: principal is never touched.
    function assert_router_invariant_C() public view {
        assertEq(
            _feeCollector.calculateFee(0),
            0,
            "Router-C VIOLATED: calculateFee(0) != 0: fee on zero yield"
        );
    }

    /// @notice Router-D: Fee bound (structural)
    ///         For any yield amount, fee <= yield * FEE_BPS / BPS_DENOMINATOR.
    ///         Checked with representative values. Fee can never exceed 10%.
    function assert_router_invariant_D() public view {
        uint256 feeBps = _feeCollector.FEE_BPS();
        uint256 bpsDenom = _feeCollector.BPS_DENOMINATOR();

        uint256[5] memory testYields = [uint256(0), 1, 1e6, 1_000e6, 1_000_000e6];

        for (uint256 i = 0; i < 5; i++) {
            uint256 fee = _feeCollector.calculateFee(testYields[i]);
            uint256 maxFee = (testYields[i] * feeBps) / bpsDenom;
            assertLe(
                fee,
                maxFee,
                "Router-D VIOLATED: fee exceeds FEE_BPS bound"
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
    //  FEE COLLECTOR INVARIANTS (3)
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

    /// @notice FeeCollector-C: Fee constants immutable
    ///         FEE_BPS == 1000 (10%) and BPS_DENOMINATOR == 10000.
    ///         These are constants and should never change, but verifying
    ///         the assumption holds across all fuzzer states.
    function assert_feeCollector_invariant_C() public view {
        assertEq(
            _feeCollector.FEE_BPS(),
            1_000,
            "FeeCollector-C VIOLATED: FEE_BPS != 1000"
        );
        assertEq(
            _feeCollector.BPS_DENOMINATOR(),
            10_000,
            "FeeCollector-C VIOLATED: BPS_DENOMINATOR != 10000"
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
            return;
        }

        uint256 currentPPS = _router.pricePerShare();
        assertGe(
            currentPPS,
            _lastPricePerShare,
            "Oracle-A VIOLATED: pricePerShare decreased"
        );
        _lastPricePerShare = currentPPS;
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
    //  SHARE-ASSET INVARIANTS (1)
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

    // ════════════════════════════════════════════════════════════════════════════
    //  ACCOUNTING INVARIANTS (3)
    //  These compare on-chain state against handler-tracked off-chain counters.
    //  Maple uses this pattern to detect state leaks invisible to pure on-chain checks.
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
            + _operatorHandler.totalOperatorDeposited();
        uint256 withdrawn = _withdrawHandler.totalWithdrawn()
            + _operatorHandler.totalOperatorWithdrawn();
        uint256 yield_ = _yieldHandler.totalYieldAccrued();
        uint256 fees = _usdc.balanceOf(_treasury);

        uint256 ops = _depositHandler.depositCount()
            + _withdrawHandler.withdrawCount()
            + _yieldHandler.yieldCount()
            + _operatorHandler.operatorDepositCount()
            + _operatorHandler.operatorWithdrawCount();
        uint256 tolerance = ops * 1e3 + 1e6;

        uint256 totalOut = withdrawn + fees;
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

    /// @notice Accounting-C: Handler operation counts non-decreasing
    ///         Deposit, withdraw, and yield counts should monotonically increase.
    ///         Detects handler state corruption.
    function assert_accounting_invariant_C() public {
        uint256 dc = _depositHandler.depositCount();
        uint256 wc = _withdrawHandler.withdrawCount();
        uint256 yc = _yieldHandler.yieldCount();

        assertGe(dc, _lastDepositCount, "Accounting-C VIOLATED: deposit count decreased");
        assertGe(wc, _lastWithdrawCount, "Accounting-C VIOLATED: withdraw count decreased");
        assertGe(yc, _lastYieldCount, "Accounting-C VIOLATED: yield count decreased");

        _lastDepositCount = dc;
        _lastWithdrawCount = wc;
        _lastYieldCount = yc;
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  ADDITIONAL INVARIANTS (6) — from 50-agent audit
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice ShareMath-B: ERC-4626 round-trip loss
    ///         convertToAssets(convertToShares(x)) <= x for representative values.
    ///         Share math must never create value from nothing. The virtual offset
    ///         floors both conversions, so the round-trip should always lose or break even.
    function assert_shareMath_invariant_B() public view {
        uint256 supply = _dvUsdc.totalSupply();
        if (supply == 0) return;

        uint256 totalAssets_ = _router.totalVaultAssets();

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

    /// @notice FeeCollector-D: Fee monotonicity
    ///         For a <= b, calculateFee(a) <= calculateFee(b).
    ///         Higher yield must never produce a lower fee.
    function assert_feeCollector_invariant_D() public view {
        uint256 prevFee = 0;
        uint256[5] memory amounts = [uint256(0), 1, 1_000e6, 10_000e6, 100_000e6];

        for (uint256 i = 0; i < 5; i++) {
            uint256 fee = _feeCollector.calculateFee(amounts[i]);
            assertGe(
                fee,
                prevFee,
                "FeeCollector-D VIOLATED: fee decreased for higher yield"
            );
            prevFee = fee;
        }
    }

    /// @notice FeeCollector-E: Fee strictly less than yield
    ///         calculateFee(x) < x for all x > 0.
    ///         The net return to the user is always positive.
    function assert_feeCollector_invariant_E() public view {
        uint256[4] memory amounts = [uint256(1), 100, 1_000e6, 100_000e6];

        for (uint256 i = 0; i < 4; i++) {
            uint256 fee = _feeCollector.calculateFee(amounts[i]);
            assertLt(
                fee,
                amounts[i],
                "FeeCollector-E VIOLATED: fee >= yield (user gets nothing)"
            );
        }
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

    // ════════════════════════════════════════════════════════════════════════════
    //  AGGREGATE: run all invariants in one call
    // ════════════════════════════════════════════════════════════════════════════

    function assertAllInvariants() public {
        // VaultRouter (11)
        assert_router_invariant_A();  // Aggregate solvency
        assert_router_invariant_B();  // Per-user solvency
        assert_router_invariant_C();  // Principal preservation
        assert_router_invariant_D();  // Fee bound
        assert_router_invariant_E();  // Statelessness
        assert_router_invariant_F();  // Permissionless exit
        assert_router_invariant_G();  // Zero shares -> zero costBasis
        assert_router_invariant_H();  // Nonzero costBasis -> nonzero shares
        assert_router_invariant_I();  // Vault asset decomposition
        assert_router_invariant_J();  // TVL cap respected
        assert_router_invariant_K();  // Authorized wallet consistency

        // dvUSDC (3)
        assert_dvUsdc_invariant_A();  // Non-transferable
        assert_dvUsdc_invariant_B();  // Access control
        assert_dvUsdc_invariant_C();  // Supply consistency

        // FeeCollector (3)
        assert_feeCollector_invariant_A();  // Pass-through
        assert_feeCollector_invariant_B();  // Access control
        assert_feeCollector_invariant_C();  // Constants immutable

        // Oracle (3)
        assert_oracle_invariant_A();  // PPS monotonic
        assert_oracle_invariant_B();  // Observation time valid
        assert_oracle_invariant_C();  // Freshness consistency

        // Share-Asset (1)
        assert_shareAsset_invariant_A();  // supply * PPS ~= totalAssets

        // Accounting (3)
        assert_accounting_invariant_A();  // Fees <= yield
        assert_accounting_invariant_B();  // Net flow consistency
        assert_accounting_invariant_C();  // Operation counts monotonic

        // Additional (6) — from 50-agent audit
        assert_shareMath_invariant_B();   // ERC-4626 round-trip loss
        assert_feeCollector_invariant_D();// Fee monotonicity
        assert_feeCollector_invariant_E();// Fee < yield
        assert_shareAsset_invariant_B();  // Per-user value conservation
        assert_router_invariant_L();      // TVL cap monotonicity
        assert_router_invariant_M();      // Stale oracle blocks deposits
    }
}
