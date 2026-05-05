// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {DivigentVaultRouter} from "../../src/DivigentVaultRouter.sol";
import {DvUSDC} from "../../src/dvUSDC.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

contract RouterIntegrationBase is Test {
    DivigentVaultRouter internal router;
    DivigentFeeCollector internal feeCollector;
    DvUSDC internal dvUsdc;

    MockERC20 internal usdc;
    MockERC20 internal aToken;
    MockAavePool internal aavePool;
    MockMorphoVault internal morphoVault;
    MockOracle internal oracle;

    address internal treasury = makeAddr("treasury");
    address internal emergencyMultisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant INITIAL_USDC = 100_000e6;

    function setUp() public virtual {
        _createAssets();
        _createMocks();
        _seedMockState();
        _deployRouterStack();
        _fundActors();
        _initializeWallets();
    }

    function _createAssets() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave aUSDC", "aUSDC", 6);
    }

    function _createMocks() internal {
        aavePool = new MockAavePool(address(usdc), address(aToken));
        morphoVault = new MockMorphoVault(address(usdc));
        oracle = new MockOracle();
        oracle.setLastObservationTime(block.timestamp);
    }

    function _seedMockState() internal {
        usdc.mint(address(aToken), 10_000_000e6);
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
            address(oracle),
            address(feeCollector),
            address(dvUsdc),
            emergencyMultisig
        );

        assertEq(address(router), expectedRouterAddr, "Router address mismatch");
    }

    function _fundActors() internal {
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
    }

    function _initializeWallets() internal {
        vm.prank(alice);
        router.initialize();

        vm.prank(bob);
        router.initialize();
    }

    function _deposit(address caller, address wallet, uint256 amount) internal returns (uint256) {
        vm.prank(wallet);
        usdc.approve(address(router), amount);

        vm.prank(caller);
        return router.deposit(amount, wallet, 0);
    }

    function _setAaveAvailableLiquidity(uint256 availableUsdc) internal {
        usdc.setBalance(address(aToken), availableUsdc);
    }
}
