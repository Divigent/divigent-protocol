// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DivigentFeeCollector} from "../src/DivigentFeeCollector.sol";
import {DivigentVaultRouter} from "../src/DivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../src/DivigentYieldOracle.sol";
import {DvUSDC} from "../src/dvUSDC.sol";

import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorphoVault} from "./mocks/MockMorphoVault.sol";

contract TestBase is Test {
    DivigentVaultRouter internal router;
    DivigentYieldOracle internal yieldOracle;
    DivigentFeeCollector internal feeCollector;
    DvUSDC internal dvUsdc;

    MockERC20 internal usdc;
    MockERC20 internal aToken;
    MockAavePool internal aavePool;
    MockMorphoVault internal morphoVault;

    address internal treasury = makeAddr("treasury");
    address internal emergencyMultisig = makeAddr("multisig");
    address internal alice;
    uint256 internal aliceKey;
    address internal bob = makeAddr("bob");
    address internal operator_ = makeAddr("operator");

    uint256 internal constant INITIAL_USDC = 100_000e6;
    uint128 internal constant DEFAULT_AAVE_LIQUIDITY_RATE = 0.05e27;
    uint256 internal constant DEFAULT_AAVE_AVAILABLE_USDC = 10_000_000e6;

    function setUp() public virtual {
        _createAccounts();
        _createAssets();
        _createMocks();
        _seedMockState();
        _deployYieldOracle();
        _deployRouterStack();
        _fundActors();
        _initializeWallets();
    }

    function _createAccounts() internal {
        (alice, aliceKey) = makeAddrAndKey("alice");
    }

    function _createAssets() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave aUSDC", "aUSDC", 6);
    }

    function _createMocks() internal {
        aavePool = new MockAavePool(address(usdc), address(aToken));
        morphoVault = new MockMorphoVault(address(usdc));
    }

    function _seedMockState() internal {
        aavePool.setCurrentLiquidityRate(DEFAULT_AAVE_LIQUIDITY_RATE);
        usdc.mint(address(aToken), DEFAULT_AAVE_AVAILABLE_USDC);
    }

    function _deployYieldOracle() internal {
        yieldOracle = new DivigentYieldOracle(address(aavePool), address(aToken), address(usdc), address(morphoVault));
    }

    function _deployRouterStack() internal {
        uint256 currentNonce = vm.getNonce(address(this));
        address expectedRouterAddr = vm.computeCreateAddress(address(this), currentNonce + 2);

        feeCollector = new DivigentFeeCollector(address(usdc), treasury, expectedRouterAddr);

        dvUsdc = new DvUSDC(expectedRouterAddr);

        router = new DivigentVaultRouter(
            address(usdc),
            address(aavePool),
            address(aToken),
            address(morphoVault),
            address(yieldOracle),
            address(feeCollector),
            address(dvUsdc),
            emergencyMultisig
        );

        assertEq(address(router), expectedRouterAddr, "Router address mismatch");
    }

    function _fundActors() internal {
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
        usdc.mint(operator_, INITIAL_USDC);
    }

    function _initializeWallets() internal {
        vm.prank(alice);
        router.initialize();

        vm.prank(bob);
        router.initialize();
    }
}
