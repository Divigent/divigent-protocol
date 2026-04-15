// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {DivigentFeeCollector} from "../../../src/DivigentFeeCollector.sol";
import {DvUSDC} from "../../../src/dvUSDC.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";
import {IDivigentYieldOracle} from "../../../src/interfaces/IDivigentYieldOracle.sol";

import {MockAavePool} from "../../mocks/MockAavePool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";

/// @title  Reentrancy Resistance -- End-to-End Flow
/// @notice The router applies `nonReentrant` to `deposit` and `withdraw`. With the
///         current trusted dependencies (canonical USDC, audited Aave, audited
///         Morpho), no real reentry vector exists in production. But the modifier
///         is defensive coverage for any future integration with a less-trusted
///         vault. This test deploys a deliberately hostile MetaMorpho-shaped vault
///         that, on `withdraw`, attempts to reenter `router.withdraw`, and asserts
///         the guard fires.
///
///         Note: this test is fully self-contained -- it deploys a fresh router
///         stack pointing at the hostile vault. It does NOT inherit from
///         RouterIntegrationBase because the shared base wires in MockMorphoVault.
contract ReentrancyFlowTest is Test {
    DivigentVaultRouter internal router;
    DivigentFeeCollector internal feeCollector;
    DvUSDC internal dvUsdc;

    MockERC20 internal usdc;
    MockERC20 internal aToken;
    MockAavePool internal aavePool;
    HostileMorpho internal hostile;
    MockOracle internal oracle;

    address internal treasury = makeAddr("treasury_re");
    address internal multisig = makeAddr("multisig_re");
    address internal alice = makeAddr("alice_re");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(usdc), address(aToken));
        hostile = new HostileMorpho(address(usdc));
        oracle = new MockOracle();

        // Aave seed liquidity so _canAllocate always passes for the Aave route.
        usdc.mint(address(aToken), 1_000_000e6);

        oracle.setLastObservationTime(block.timestamp);
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);

        // Three-way circular deploy: precompute router address.
        uint256 n = vm.getNonce(address(this));
        address routerAddr = vm.computeCreateAddress(address(this), n + 2);
        feeCollector = new DivigentFeeCollector(address(usdc), treasury, routerAddr);
        dvUsdc = new DvUSDC(routerAddr);
        router = new DivigentVaultRouter(
            address(usdc),
            address(aavePool),
            address(aToken),
            address(hostile),
            address(oracle),
            address(feeCollector),
            address(dvUsdc),
            multisig
        );
        require(address(router) == routerAddr, "addr mismatch");

        hostile.setRouter(address(router));
        usdc.mint(alice, 1_000_000e6);

        vm.prank(alice);
        router.initialize();
    }

    /// @notice The hostile Morpho's `withdraw` attempts to reenter `router.withdraw`.
    ///         The router's `nonReentrant` modifier must fire on the inner call,
    ///         making the inner call revert. That revert bubbles up and aborts the
    ///         outer withdraw. Funds are not lost; the user simply cannot exit
    ///         while the hostile vault is in place (the vault would need replacing).
    function test_reentrancy_hostileMorphoCallbackIsBlocked() public {
        // Alice deposits via Morpho route -> her USDC goes into the hostile vault.
        vm.prank(alice);
        usdc.approve(address(router), 50_000e6);
        vm.prank(alice);
        router.deposit(50_000e6, alice);

        assertEq(hostile.balanceOf(address(router)), 50_000e6, "router holds hostile-vault shares");

        // Arm the hostile callback. The next withdraw will reenter.
        hostile.armReentrance();

        // Outer withdraw triggers Morpho.withdraw -> reentry -> nonReentrant guard fires.
        // OZ v5 reverts with ReentrancyGuardReentrantCall(); assert that exact selector.
        uint256 aliceShares = dvUsdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.withdraw(aliceShares, alice, 0);

        // Confirm: alice's position is unchanged (the failed tx rolled back fully).
        assertEq(dvUsdc.balanceOf(alice), aliceShares, "shares unchanged after blocked attempt");
        assertEq(hostile.balanceOf(address(router)), 50_000e6, "hostile shares unchanged after blocked attempt");
    }
}

/// @dev MetaMorpho-shaped vault whose `withdraw` deliberately attempts to reenter
///      the router. Used only by ReentrancyFlowTest. Implements just enough of the
///      ERC-4626/IMorphoVault surface that the router calls.
contract HostileMorpho {
    MockERC20 public immutable usdc;
    address public router;
    bool public reentranceArmed;

    mapping(address => uint256) public balanceOf;
    uint256 public totalShares;
    uint256 public totalAssets_;

    constructor(address _usdc) {
        usdc = MockERC20(_usdc);
    }

    function setRouter(address _router) external {
        router = _router;
    }

    function armReentrance() external {
        reentranceArmed = true;
    }

    // ----- 4626 view surface ---------------------------------------------

    function asset() external view returns (address) {
        return address(usdc);
    }

    function totalAssets() external view returns (uint256) {
        return totalAssets_;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    function previewDeposit(uint256 a) external pure returns (uint256) {
        return a;
    }

    function previewRedeem(uint256 s) external pure returns (uint256) {
        return s;
    }

    function convertToShares(uint256 a) external view returns (uint256) {
        if (totalAssets_ == 0) return a;
        return (a * totalShares) / totalAssets_;
    }

    function convertToAssets(uint256 s) external view returns (uint256) {
        if (totalShares == 0) return s;
        return (s * totalAssets_) / totalShares;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address a) external view returns (uint256) {
        return balanceOf[a];
    }

    function maxWithdraw(address) external view returns (uint256) {
        return totalAssets_;
    }

    // ----- 4626 mutative surface -----------------------------------------

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        usdc.burn(msg.sender, assets);
        shares = (totalShares == 0) ? assets : (assets * totalShares) / totalAssets_;
        totalAssets_ += assets;
        totalShares += shares;
        balanceOf[receiver] += shares;
    }

    /// @dev The hostile bit: when armed, attempt to reenter router.withdraw.
    ///      The router's `nonReentrant` should make the inner call revert.
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        if (reentranceArmed) {
            reentranceArmed = false; // only attempt once
            // Try to reenter the router during its own withdraw.
            // This call should revert with OZ v5's ReentrancyGuardReentrantCall.
            DivigentVaultRouter(router).withdraw(1, owner_, 0);
            // If we ever get here, reentrance succeeded -- fail loudly.
            revert("HostileMorpho: reentrance was NOT blocked");
        }
        shares = (assets * totalShares + totalAssets_ - 1) / totalAssets_;
        balanceOf[owner_] -= shares;
        totalShares -= shares;
        totalAssets_ -= assets;
        usdc.mint(receiver, assets);
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}
