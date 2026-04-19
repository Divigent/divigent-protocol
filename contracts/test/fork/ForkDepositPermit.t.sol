// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.sol";
import {DivigentVaultRouter} from "../../src/DivigentVaultRouter.sol";
import {DvUSDC} from "../../src/dvUSDC.sol";
import {DivigentYieldOracle} from "../../src/DivigentYieldOracle.sol";
import {DivigentFeeCollector} from "../../src/DivigentFeeCollector.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  ForkDepositPermit — EIP-2612 depositWithPermit against real Base USDC
/// @notice Circle-native USDC on Base supports EIP-2612. Exercises the full
///         permit→deposit round-trip with a live-signed signature against the
///         real USDC contract at 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913.
///
///         Unit tests (test/integration/flows/PermitOnboarding.t.sol) cover
///         the router's control flow with a MockERC20-permit. This file adds
///         the live-integration gate: if Circle's permit typehash or domain
///         separator format ever diverges from what our router expects,
///         these tests catch it before mainnet.
contract ForkDepositPermitTest is ForkBase {
    // EIP-2612 canonical typehash
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // Signer with known private key
    address internal carol;
    uint256 internal carolKey;

    function setUp() public override {
        super.setUp();
        (carol, carolKey) = makeAddrAndKey("fork_carol_permit");
        deal(BASE_USDC, carol, 500_000e6);

        vm.prank(carol);
        router.initialize();

        // Oracle warm-up so deposit doesn't hit StaleOracle
        _seedOracle();
    }

    /// @dev Happy path: sign a permit against live Base USDC, then deposit.
    ///      No prior approve() from the wallet. The permit grants allowance
    ///      atomically inside depositWithPermit; the router then pulls USDC.
    function testFork_depositWithPermit_happyPath() public {
        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(carolKey, carol, address(router), amount, deadline);

        // Sanity: no prior allowance from carol to router.
        assertEq(IERC20(BASE_USDC).allowance(carol, address(router)), 0, "no pre-approval");

        uint256 usdcBefore = IERC20(BASE_USDC).balanceOf(carol);
        uint256 sharesBefore = dvUsdc.balanceOf(carol);

        vm.prank(carol);
        uint256 minted = router.depositWithPermit(amount, carol, deadline, v, r, s);

        assertGt(minted, 0, "shares minted");
        assertEq(dvUsdc.balanceOf(carol), sharesBefore + minted, "carol receives dvUSDC");
        assertEq(IERC20(BASE_USDC).balanceOf(carol), usdcBefore - amount, "USDC pulled from carol");
    }

    /// @dev Expired deadline must revert with PermitExpired from the router's
    ///      own gate at DivigentVaultRouter.sol:329 (before the USDC call).
    function testFork_depositWithPermit_expiredDeadline_reverts() public {
        uint256 amount = 5_000e6;
        uint256 deadline = block.timestamp + 10; // sign for a valid deadline
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(carolKey, carol, address(router), amount, deadline);

        // Advance past the deadline
        vm.warp(deadline + 1);

        vm.prank(carol);
        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.depositWithPermit(amount, carol, deadline, v, r, s);
    }

    /// @dev Replay: the same signature must only work once. Second use
    ///      reverts because the nonce has been consumed (USDC's own check).
    function testFork_depositWithPermit_replayRejected() public {
        uint256 amount = 1_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(carolKey, carol, address(router), amount, deadline);

        // First use succeeds
        vm.prank(carol);
        router.depositWithPermit(amount, carol, deadline, v, r, s);

        // Second use must revert — USDC's permit enforces nonce monotonicity.
        // Circle's USDC reverts with a require-string; match any revert from USDC's call.
        vm.prank(carol);
        vm.expectRevert(); // intentionally broad — USDC's error is string-based
        router.depositWithPermit(amount, carol, deadline, v, r, s);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Sign an EIP-2612 permit against live USDC using its own DOMAIN_SEPARATOR.
    function _signPermit(uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        // Query USDC's live nonce for this owner
        (bool ok1, bytes memory n) =
            BASE_USDC.staticcall(abi.encodeWithSignature("nonces(address)", owner));
        require(ok1, "USDC nonces() call failed");
        uint256 nonce = abi.decode(n, (uint256));

        // Query USDC's live DOMAIN_SEPARATOR (it may depend on chainid / version)
        (bool ok2, bytes memory d) = BASE_USDC.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok2, "USDC DOMAIN_SEPARATOR() call failed");
        bytes32 domainSep = abi.decode(d, (bytes32));

        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (v, r, s) = vm.sign(pk, digest);
    }
}
