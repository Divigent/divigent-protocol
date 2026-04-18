// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DivigentVaultRouter} from "../../src/DivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../../src/DivigentYieldOracle.sol";
import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {DvUSDC} from "../../src/dvUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";

/// @title  Echidna Property Tests for DivigentVaultRouter
/// @notice Echidna/Medusa call random sequences of deposit/withdraw/yield
///         and assert properties hold after every action.
contract EchidnaVaultRouter {
    DivigentVaultRouter internal router;
    DivigentYieldOracle internal oracle;
    DivigentFeeCollector internal feeCollector;
    DvUSDC internal dvUsdc;

    MockERC20 internal usdc;
    MockERC20 internal aToken;
    MockAavePool internal aavePool;
    MockMorphoVault internal morphoVault;

    address internal treasury;
    address internal multisig;

    bool internal initialized;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(usdc), address(aToken));
        morphoVault = new MockMorphoVault(address(usdc));

        aavePool.setCurrentLiquidityRate(0.05e27);
        usdc.mint(address(aToken), 10_000_000e6);

        oracle = new DivigentYieldOracle(
            address(aavePool), address(aToken), address(usdc), address(morphoVault)
        );

        treasury = address(0x50000);
        multisig = address(0x60000);

        uint256 nonce = _getNonce();
        address expectedRouter = _computeCreate(nonce + 2);

        feeCollector = new DivigentFeeCollector(address(usdc), treasury, expectedRouter);
        dvUsdc = new DvUSDC(expectedRouter);
        router = new DivigentVaultRouter(
            address(usdc), address(aavePool), address(aToken), address(morphoVault),
            address(oracle), address(feeCollector), address(dvUsdc), multisig
        );

        usdc.mint(msg.sender, 10_000_000e6);
        usdc.mint(address(0x20000), 10_000_000e6);
        usdc.mint(address(0x30000), 10_000_000e6);
        usdc.mint(address(0x40000), 10_000_000e6);

        initialized = true;
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    function fuzz_deposit(uint256 amount) public {
        if (!initialized) return;
        amount = _bound(amount, 10e6, 50_000e6);

        if (!router.authorizedWallets(msg.sender)) {
            router.initialize();
        }

        usdc.approve(address(router), amount);
        try router.deposit(amount, msg.sender) {} catch {}

        _checkProperties();
    }

    function fuzz_withdraw(uint256 sharePct) public {
        if (!initialized) return;
        sharePct = _bound(sharePct, 1, 100);

        uint256 shares = dvUsdc.balanceOf(msg.sender);
        if (shares == 0) return;

        uint256 toWithdraw = (shares * sharePct) / 100;
        if (toWithdraw == 0) return;

        try router.withdraw(toWithdraw, msg.sender, 0) {} catch {}

        _checkProperties();
    }

    function fuzz_accrueYield(uint256 amount) public {
        if (!initialized) return;
        amount = _bound(amount, 1, 5_000e6);
        if (aToken.balanceOf(address(router)) == 0) return;
        aToken.mint(address(router), amount);

        _checkProperties();
    }

    // ── Properties ───────────────────────────────────────────────────────────

    function _checkProperties() internal view {
        _prop_statelessness();
        _prop_feeCollectorPassThrough();
        _prop_zeroSharesZeroCostBasis();
        _prop_nonzeroCostBasisNonzeroShares();
        _prop_vaultDecomposition();
        _prop_solvencyWithFees();
        _prop_feeConstants();
        _prop_principalPreservation();
        _prop_feeBound();
        _prop_shareAssetConsistency();
    }

    function _prop_statelessness() internal view {
        assert(usdc.balanceOf(address(router)) == 0);
    }

    function _prop_feeCollectorPassThrough() internal view {
        assert(usdc.balanceOf(address(feeCollector)) == 0);
    }

    function _prop_zeroSharesZeroCostBasis() internal view {
        address[3] memory actors = [msg.sender, address(0x20000), address(0x30000)];
        for (uint256 i = 0; i < 3; i++) {
            if (dvUsdc.balanceOf(actors[i]) == 0) {
                assert(router.costBasisUSDC(actors[i]) == 0);
            }
        }
    }

    function _prop_nonzeroCostBasisNonzeroShares() internal view {
        address[3] memory actors = [msg.sender, address(0x20000), address(0x30000)];
        for (uint256 i = 0; i < 3; i++) {
            if (router.costBasisUSDC(actors[i]) > 0) {
                assert(dvUsdc.balanceOf(actors[i]) > 0);
            }
        }
    }

    function _prop_vaultDecomposition() internal view {
        (uint256 aave, uint256 morpho) = router.getCurrentAllocation();
        assert(router.totalVaultAssets() == aave + morpho);
    }

    function _prop_solvencyWithFees() internal view {
        address[3] memory actors = [msg.sender, address(0x20000), address(0x30000)];
        uint256 sumCostBasis;
        for (uint256 i = 0; i < 3; i++) {
            sumCostBasis += router.costBasisUSDC(actors[i]);
        }
        uint256 totalFees = usdc.balanceOf(treasury);
        assert(router.totalVaultAssets() + totalFees >= sumCostBasis);
    }

    function _prop_feeConstants() internal view {
        assert(feeCollector.FEE_BPS() == 1_000);
        assert(feeCollector.BPS_DENOMINATOR() == 10_000);
    }

    function _prop_principalPreservation() internal view {
        assert(feeCollector.calculateFee(0) == 0);
    }

    function _prop_feeBound() internal view {
        uint256 fee = feeCollector.calculateFee(1_000e6);
        assert(fee <= (1_000e6 * 1_000) / 10_000);
    }

    function _prop_shareAssetConsistency() internal view {
        uint256 supply = dvUsdc.totalSupply();
        if (supply == 0) return;
        uint256 pps = router.pricePerShare();
        uint256 implied = (supply * pps) / 1e18;
        uint256 actual = router.totalVaultAssets();
        uint256 diff = implied > actual ? implied - actual : actual - implied;
        assert(diff <= 1e6);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x >= min && x <= max) return x;
        uint256 size = max - min + 1;
        return min + (x % size);
    }

    function _getNonce() internal view returns (uint256) {
        // Workaround: can't use vm.getNonce in echidna
        // Use a fixed offset since constructor deploys are sequential
        return 6; // feeCollector at nonce 6, dvUsdc at 7, router at 8
    }

    function _computeCreate(uint256 nonce) internal view returns (address) {
        bytes memory data;
        if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), uint8(nonce));
        } else {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), address(this), bytes1(0x81), uint8(nonce));
        }
        return address(uint160(uint256(keccak256(data))));
    }
}
