// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title  Fork Permit Replay & Frontrun
/// @notice Exercises `depositWithPermit` against REAL Base USDC, not the
///         mock. The unit suite covers this via `MockERC20.permit`, but the
///         canonical USDC on Base (Circle's FiatTokenProxy →
///         FiatTokenV2_2 implementation) has its own EIP-2612 domain,
///         nonce layout, and signer recovery. Any drift between the
///         router's permit call and the live USDC implementation would
///         surface here — especially around domain separator caching,
///         chain-id handling, and nonce semantics.
///
///         Tests:
///           1. Third-party relayer submits a valid permit — the permit
///              grants allowance to the router, the router executes the
///              deposit for the signer's wallet, USDC lands correctly and
///              dvUSDC is minted to the signer (not the relayer).
///           2. Replay is blocked: re-using the same (v, r, s) after the
///              nonce advances reverts because the recovered signer no
///              longer matches the owner.
///
///         Requires `BASE_RPC_URL`. Skippable locally via
///         `forge test --no-match-path "test/fork/*"`.
contract ForkPermitReplayTest is ForkBase {
    // Test-only keyed actor, funded after fork setup.
    address internal keyedSigner;
    uint256 internal keyedKey;

    function setUp() public override {
        super.setUp();
        (keyedSigner, keyedKey) = makeAddrAndKey("fork_permit_signer");
        deal(BASE_USDC, keyedSigner, 500_000e6);
        vm.prank(keyedSigner);
        router.initialize();
    }

    /// @notice Third-party relay submits a valid permit signed by `keyedSigner`.
    ///         USDC allowance goes to the router, the router pulls the USDC
    ///         from `keyedSigner` (NOT the relay), and dvUSDC lands in
    ///         `keyedSigner`'s wallet.
    function testFork_permit_thirdPartyRelaySucceeds() public {
        _seedOracle();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signBasePermit(keyedKey, keyedSigner, address(router), amount, deadline);

        address relay = makeAddr("fork_relay");
        uint256 signerUsdcBefore = usdc.balanceOf(keyedSigner);
        uint256 relayUsdcBefore = usdc.balanceOf(relay);

        vm.prank(relay);
        uint256 shares = router.depositWithPermit(amount, keyedSigner, deadline, v, r, s, 0);

        assertGt(shares, 0, "dvUSDC minted");
        assertEq(dvUsdc.balanceOf(keyedSigner), shares, "shares to signer, not relay");
        assertEq(dvUsdc.balanceOf(relay), 0, "relay gets no shares");
        assertEq(usdc.balanceOf(keyedSigner), signerUsdcBefore - amount, "USDC pulled from signer");
        assertEq(usdc.balanceOf(relay), relayUsdcBefore, "relay USDC untouched");
    }

    /// @notice A replayed permit — same (v, r, s), same (owner, spender,
    ///         value, deadline) — must fail. Real Base USDC consumes the
    ///         nonce on first use; the second call's signature recovers a
    ///         different address (the nonce has moved), causing the live
    ///         USDC `permit` to revert.
    function testFork_permit_replayBlocked() public {
        _seedOracle();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signBasePermit(keyedKey, keyedSigner, address(router), amount, deadline);

        address relay = makeAddr("fork_relay_replay");

        // 1st submission — succeeds
        vm.prank(relay);
        router.depositWithPermit(amount, keyedSigner, deadline, v, r, s, 0);

        // 2nd submission — replay. The nonce advanced on the first call,
        // so this signature no longer recovers to `keyedSigner`. The router
        // swallows the permit failure, then fails its allowance check.
        // We don't pin the specific selector (Circle's implementation can
        // evolve), just that the call fails.
        vm.prank(relay);
        vm.expectRevert();
        router.depositWithPermit(amount, keyedSigner, deadline, v, r, s, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Live-USDC EIP-712 digest builder — READS the USDC contract's domain
    // separator at runtime rather than reconstructing it. Real USDC's
    // DOMAIN_SEPARATOR is version-locked and chain-locked; we just fetch it.
    // ─────────────────────────────────────────────────────────────────────────

    function _signBasePermit(uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        uint256 nonce = IERC20Permit(address(usdc)).nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 domainSep = IERC20Permit(address(usdc)).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (v, r, s) = vm.sign(pk, digest);
    }
}
