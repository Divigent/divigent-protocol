// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestBase} from "../TestBase.sol";

import {BaseInvariants} from "./BaseInvariants.sol";
import {DepositHandler} from "./handlers/DepositHandler.sol";
import {WithdrawHandler} from "./handlers/WithdrawHandler.sol";
import {YieldHandler} from "./handlers/YieldHandler.sol";
import {AdminHandler} from "./handlers/AdminHandler.sol";
import {OperatorHandler} from "./handlers/OperatorHandler.sol";
import {LiquidityHandler} from "./handlers/LiquidityHandler.sol";
import {PermitHandler} from "./handlers/PermitHandler.sol";

/// @title  InvariantTest
/// @notice Handler-based invariant suite. 29 invariants across 8 components,
///         asserted after every random fuzzer action.
///
///         Run:  forge test --match-contract InvariantTest -vv
///         Deep: forge test --match-contract InvariantTest -vvvv --fuzz-runs 10000
contract InvariantTest is TestBase, BaseInvariants {
    AdminHandler internal adminHandler;

    function setUp() public override {
        super.setUp();

        // ── Wire BaseInvariants to deployed contracts ─────────────────────────
        _router = router;
        _feeCollector = feeCollector;
        _oracle = yieldOracle;
        _dvUsdc = dvUsdc;
        _usdc = usdc;
        _aToken = aToken;
        _treasury = treasury;
        _morphoVault = morphoVault;
        _lastPricePerShare = 1e18;
        _lastTVLCap = router.currentTVLCap();

        // ── Actor pool: 5 keyed actors ────────────────────────────────────────
        // `makeAddrAndKey` derives the address from the hashed name. `makeAddr`
        // (used for bob/etc. in TestBase) uses the same derivation, so the
        // addresses agree. Collecting keys here lets PermitHandler sign on
        // behalf of the same actors the deposit/withdraw handlers target.
        (address charlie, uint256 charlieKey) = makeAddrAndKey("charlie");
        (address dave, uint256 daveKey) = makeAddrAndKey("dave");
        (address eve, uint256 eveKey) = makeAddrAndKey("eve");
        (, uint256 bobKey) = makeAddrAndKey("bob"); // bob already from TestBase

        vm.prank(charlie);
        router.initialize();
        vm.prank(dave);
        router.initialize();
        vm.prank(eve);
        router.initialize();

        _allActors = new address[](5);
        _allActors[0] = alice;
        _allActors[1] = bob;
        _allActors[2] = charlie;
        _allActors[3] = dave;
        _allActors[4] = eve;

        uint256[] memory actorKeys = new uint256[](5);
        actorKeys[0] = aliceKey;
        actorKeys[1] = bobKey;
        actorKeys[2] = charlieKey;
        actorKeys[3] = daveKey;
        actorKeys[4] = eveKey;

        // ── Deploy handlers ──────────────────────────────────────────────────
        DepositHandler dh = new DepositHandler(router, usdc, _allActors);
        WithdrawHandler wh = new WithdrawHandler(router, dvUsdc, IERC20(address(usdc)), treasury, _allActors);
        YieldHandler yh = new YieldHandler(router, aToken, morphoVault);
        adminHandler = new AdminHandler(router, yieldOracle, emergencyMultisig);
        OperatorHandler oh = new OperatorHandler(router, dvUsdc, usdc, treasury, _allActors);
        LiquidityHandler lh = new LiquidityHandler(usdc, aToken, morphoVault);
        PermitHandler ph = new PermitHandler(router, usdc, _allActors, actorKeys);

        // Wire handler refs into BaseInvariants for accounting checks
        _depositHandler = dh;
        _withdrawHandler = wh;
        _yieldHandler = yh;
        _operatorHandler = oh;
        _liquidityHandler = lh;
        _permitHandler = ph;

        // ── Target handlers for the fuzzer ───────────────────────────────────
        targetContract(address(dh));
        targetContract(address(wh));
        targetContract(address(yh));
        targetContract(address(adminHandler));
        targetContract(address(oh));
        targetContract(address(lh));
        targetContract(address(ph));

        // ── Restrict fuzzer to handler entry points ──────────────────────────
        bytes4[] memory depositSelectors = new bytes4[](1);
        depositSelectors[0] = DepositHandler.deposit.selector;
        targetSelector(FuzzSelector(address(dh), depositSelectors));

        bytes4[] memory withdrawSelectors = new bytes4[](1);
        withdrawSelectors[0] = WithdrawHandler.withdraw.selector;
        targetSelector(FuzzSelector(address(wh), withdrawSelectors));

        bytes4[] memory yieldSelectors = new bytes4[](4);
        yieldSelectors[0] = YieldHandler.accrueYield.selector;
        yieldSelectors[1] = YieldHandler.accrueMorphoYield.selector;
        yieldSelectors[2] = YieldHandler.accrueLoss.selector;
        yieldSelectors[3] = YieldHandler.accrueMorphoLoss.selector;
        targetSelector(FuzzSelector(address(yh), yieldSelectors));

        bytes4[] memory adminSelectors = new bytes4[](4);
        adminSelectors[0] = AdminHandler.warpTime.selector;
        adminSelectors[1] = AdminHandler.recordObservation.selector;
        adminSelectors[2] = AdminHandler.togglePause.selector;
        adminSelectors[3] = AdminHandler.warpTimeLong.selector;
        targetSelector(FuzzSelector(address(adminHandler), adminSelectors));

        bytes4[] memory operatorSelectors = new bytes4[](4);
        operatorSelectors[0] = OperatorHandler.grantOperator.selector;
        operatorSelectors[1] = OperatorHandler.revokeOperator.selector;
        operatorSelectors[2] = OperatorHandler.operatorDeposit.selector;
        operatorSelectors[3] = OperatorHandler.operatorWithdraw.selector;
        targetSelector(FuzzSelector(address(oh), operatorSelectors));

        bytes4[] memory liquiditySelectors = new bytes4[](4);
        liquiditySelectors[0] = LiquidityHandler.shockAaveIdle.selector;
        liquiditySelectors[1] = LiquidityHandler.restoreAaveIdle.selector;
        liquiditySelectors[2] = LiquidityHandler.shockMorphoMaxWithdraw.selector;
        liquiditySelectors[3] = LiquidityHandler.restoreMorphoMaxWithdraw.selector;
        targetSelector(FuzzSelector(address(lh), liquiditySelectors));

        bytes4[] memory permitSelectors = new bytes4[](1);
        permitSelectors[0] = PermitHandler.permitDeposit.selector;
        targetSelector(FuzzSelector(address(ph), permitSelectors));
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  VAULT ROUTER (13 invariants)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_router_A_aggregateSolvency() public view {
        assert_router_invariant_A();
    }

    function invariant_router_B_perUserSolvency() public view {
        assert_router_invariant_B();
    }

    function invariant_router_E_statelessness() public view {
        assert_router_invariant_E();
    }

    function invariant_router_F_permissionlessExit() public {
        assert_router_invariant_F();
    }

    function invariant_router_G_zeroSharesZeroCostBasis() public view {
        assert_router_invariant_G();
    }

    function invariant_router_H_nonzeroCostBasisNonzeroShares() public view {
        assert_router_invariant_H();
    }

    function invariant_router_I_vaultAssetDecomposition() public view {
        assert_router_invariant_I();
    }

    function invariant_router_J_tvlCapRespected() public view {
        assert_router_invariant_J();
    }

    function invariant_router_K_authorizedWalletConsistency() public view {
        assert_router_invariant_K();
    }

    function invariant_router_L_tvlCapMonotonic() public {
        assert_router_invariant_L();
    }

    function invariant_router_M_staleOracleBlocksDeposit() public {
        assert_router_invariant_M();
    }

    function invariant_router_N_feeZeroUnderwaterExit() public {
        assert_router_invariant_N();
    }

    function invariant_router_O_capacityMatchesRevert() public {
        assert_router_invariant_O();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  dvUSDC (3 invariants)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_dvUsdc_A_nonTransferable() public {
        assert_dvUsdc_invariant_A();
    }

    function invariant_dvUsdc_B_accessControl() public view {
        assert_dvUsdc_invariant_B();
    }

    function invariant_dvUsdc_C_supplyConsistency() public view {
        assert_dvUsdc_invariant_C();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  FEE COLLECTOR (2 invariants)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_feeCollector_A_passThrough() public view {
        assert_feeCollector_invariant_A();
    }

    function invariant_feeCollector_B_accessControl() public view {
        assert_feeCollector_invariant_B();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  ORACLE (3 invariants)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_oracle_A_ppsMonotonic() public {
        assert_oracle_invariant_A();
    }

    function invariant_oracle_B_observationTimeValid() public view {
        assert_oracle_invariant_B();
    }

    function invariant_oracle_C_freshnessConsistency() public view {
        assert_oracle_invariant_C();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  SHARE-ASSET (2 invariants)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_shareAsset_A_supplyTimePps() public view {
        assert_shareAsset_invariant_A();
    }

    function invariant_shareAsset_B_perUserValueConservation() public view {
        assert_shareAsset_invariant_B();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  SHARE MATH (1 invariant)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_shareMath_B_roundTripLoss() public view {
        assert_shareMath_invariant_B();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  ACCOUNTING (4 invariants)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_accounting_A_feesBoundedByYield() public view {
        assert_accounting_invariant_A();
    }

    function invariant_accounting_B_netFlowConsistency() public view {
        assert_accounting_invariant_B();
    }

    function invariant_accounting_D_exactFeeClosure() public view {
        assert_accounting_invariant_D();
    }

    function invariant_accounting_E_perUserNonDilution() public {
        assert_accounting_invariant_E();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  OPERATOR (1 invariant)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_operator_A_neverAccumulatesUsdc() public view {
        assert_operator_invariant_A();
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  AGGREGATE: all 29 invariants in one call (for gas-efficient single run)
    // ════════════════════════════════════════════════════════════════════════════

    function invariant_ALL() public {
        assertAllInvariants();
    }
}
