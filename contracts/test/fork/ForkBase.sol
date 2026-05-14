// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DivigentVaultRouter} from "../../src/DivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../../src/DivigentYieldOracle.sol";
import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {DvUSDC} from "../../src/dvUSDC.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IMorphoVault} from "../../src/interfaces/IMorphoVault.sol";

import {BaseAddresses} from "./BaseAddresses.sol";

/// @title  ForkBase — Base Mainnet fork test foundation
/// @notice Deploys fresh Divigent contracts on top of a pinned Base mainnet fork.
///         All vault addresses point to REAL Aave V3 and Morpho Steakhouse contracts.
///         Test actors are funded via deal().
///
///         Pattern: deploy OUR code fresh, use THEIR code live.
abstract contract ForkBase is Test, BaseAddresses {
    // Pinned Base mainnet block for reproducibility (April 18, 2026).
    uint256 internal constant FORK_BLOCK = 44_870_973;

    // ── Divigent contracts (deployed fresh on the fork) ──────────────────────
    DivigentVaultRouter internal router;
    DivigentYieldOracle internal oracle;
    DivigentFeeCollector internal feeCollector;
    DvUSDC internal dvUsdc;

    // ── Live protocol references ─────────────────────────────────────────────
    IERC20 internal usdc;
    IERC20 internal aToken;
    IAaveV3Pool internal aavePool;
    IMorphoVault internal morphoVault;

    // ── Test actors ──────────────────────────────────────────────────────────
    address internal alice;
    address internal bob;
    address internal treasury;
    address internal multisig;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);

        // Bind live protocol contracts
        usdc = IERC20(BASE_USDC);
        aToken = IERC20(BASE_AAVE_ATOKEN_USDC);
        aavePool = IAaveV3Pool(BASE_AAVE_POOL);
        morphoVault = IMorphoVault(BASE_MORPHO_STEAKHOUSE);

        // Create test actors
        treasury = makeAddr("fork_treasury");
        multisig = makeAddr("fork_multisig");
        alice = makeAddr("fork_alice");
        bob = makeAddr("fork_bob");

        // Deploy Divigent stack pointing to real vaults
        _deployDivigent();

        // Fund actors via deal (Foundry patches USDC proxy storage)
        deal(BASE_USDC, alice, 500_000e6);
        deal(BASE_USDC, bob, 500_000e6);

        // Register wallets
        vm.prank(alice);
        router.initialize();
        vm.prank(bob);
        router.initialize();
    }

    function _deployDivigent() internal {
        // Deploy oracle against real Aave + Morpho
        oracle = new DivigentYieldOracle(
            BASE_AAVE_POOL,
            BASE_AAVE_ATOKEN_USDC,
            BASE_USDC,
            BASE_MORPHO_STEAKHOUSE,
            multisig,
            multisig
        );

        // Predict router address for circular references
        uint256 nonce = vm.getNonce(address(this));
        address expectedRouter = vm.computeCreateAddress(address(this), nonce + 2);

        feeCollector = new DivigentFeeCollector(BASE_USDC, treasury, expectedRouter);
        dvUsdc = new DvUSDC(expectedRouter);

        router = new DivigentVaultRouter(
            BASE_USDC,
            BASE_AAVE_POOL,
            BASE_AAVE_ATOKEN_USDC,
            BASE_MORPHO_STEAKHOUSE,
            address(oracle),
            address(feeCollector),
            address(dvUsdc),
            multisig
        );

        require(address(router) == expectedRouter, "Router address mismatch");
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(router), amount);
        shares = router.deposit(amount, user, 0);
        vm.stopPrank();
    }

    function _withdraw(address user, uint256 shares) internal returns (uint256 returned) {
        vm.prank(user);
        returned = router.withdraw(shares, user, 0);
    }

    function _withdrawAll(address user) internal returns (uint256 returned) {
        uint256 shares = dvUsdc.balanceOf(user);
        if (shares == 0) return 0;
        return _withdraw(user, shares);
    }

    function _seedOracle() internal {
        oracle.recordObservation();
        vm.warp(block.timestamp + 6 minutes);
        oracle.recordObservation();
    }
}
