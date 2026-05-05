// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Permit / Operator Sequence Fuzz
/// @notice Adversarial fuzz coverage for the two delegation surfaces:
///
///           1. `initializeFor(wallet, deadline, sig)` — gasless wallet
///              onboarding via EIP-712 signature.
///
///           2. `setOperator(op, approved)` — per-wallet operator grant/revoke
///              with `deposit` / `withdraw` delegation rights.
///
///         Each property asserts a cross-wallet or cross-time safety
///         guarantee that the unit suite pins only in single-scenario form:
///
///           - initializeFor signatures are single-use (nonce-protected replay)
///           - initializeFor requires the signer to be the wallet itself
///             (no delegation of signing authority)
///           - third-party submission is allowed (permissionless relay) but
///             wallet ownership is unaffected
///           - expired deadlines revert, regardless of signature validity
///           - operator revocation is immediately effective: grant → deposit →
///             revoke → deposit reverts with NotAuthorised
///           - operator for wallet A cannot touch wallet B's position
///           - USDC permit surface (wrong signer, expired, replay) cleanly
///             reports router-level permit and allowance failures
contract PermitOperatorFuzzTest is Actions {
    uint256 internal constant MIN_DEPOSIT = 10e6;
    uint256 internal constant MAX_DEPOSIT = 100_000e6;
    uint256 internal constant ACTOR_FUNDING = MAX_DEPOSIT * 3;

    // ═══════════════════════════════════════════════════════════════════════
    // initializeFor — signature lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice An `initializeFor` signature is single-use. Re-submitting the
    ///         same valid sig after the wallet is registered reverts with
    ///         `WalletAlreadyAuthorised` — the nonce has been consumed and
    ///         the wallet-registered guard catches the duplicate.
    function test_initializeFor_fuzz_singleUse(uint256 deadlineOffset_) public {
        uint256 offset = bound(deadlineOffset_, 60, 30 days);
        (address w, uint256 wKey) = makeAddrAndKey("initF_singleUse");
        uint256 deadline = block.timestamp + offset;
        bytes memory sig = signInitializeFor(wKey, w, deadline);

        address relay1 = makeAddr("initF_relay1");
        vm.prank(relay1);
        router.initializeFor(w, deadline, sig);
        assertTrue(router.authorizedWallets(w));

        // Same sig again — any submitter — reverts with WalletAlreadyAuthorised.
        address relay2 = makeAddr("initF_relay2");
        vm.prank(relay2);
        vm.expectRevert(IDivigentVaultRouter.WalletAlreadyAuthorised.selector);
        router.initializeFor(w, deadline, sig);
    }

    /// @notice The signer of an `initializeFor` signature must be the wallet
    ///         itself. A signature produced by any other key reverts with
    ///         `InvalidSignature` — no key can delegate ownership.
    function test_initializeFor_fuzz_wrongSignerReverts(uint256 deadlineOffset_) public {
        uint256 offset = bound(deadlineOffset_, 60, 30 days);
        (address wallet, ) = makeAddrAndKey("initF_wrongSigner_wallet");
        (, uint256 attackerKey) = makeAddrAndKey("initF_wrongSigner_attacker");

        uint256 deadline = block.timestamp + offset;

        // Sign the wallet's initialization struct with the attacker's key.
        bytes memory sig = signInitializeFor(attackerKey, wallet, deadline);

        address relay = makeAddr("initF_wrongSigner_relay");
        vm.prank(relay);
        vm.expectRevert(IDivigentVaultRouter.InvalidSignature.selector);
        router.initializeFor(wallet, deadline, sig);

        assertFalse(router.authorizedWallets(wallet), "wallet remains unregistered after failed sig");
    }

    /// @notice A permissionless relay may submit a valid signature. The
    ///         wallet is registered correctly regardless of who submits,
    ///         and the wallet itself remains the unique authority.
    function test_initializeFor_fuzz_anyRelayAllowed(uint256 deadlineOffset_, uint256 relaySeed_) public {
        uint256 offset = bound(deadlineOffset_, 60, 30 days);
        (address wallet, uint256 walletKey) = makeAddrAndKey("initF_anyRelay_wallet");
        uint256 deadline = block.timestamp + offset;
        bytes memory sig = signInitializeFor(walletKey, wallet, deadline);

        // Pick an arbitrary relay address (not the wallet itself).
        address relay = address(uint160(uint256(keccak256(abi.encode(relaySeed_, "relay")))));
        vm.assume(relay != address(0) && relay != wallet);

        vm.prank(relay);
        router.initializeFor(wallet, deadline, sig);

        assertTrue(router.authorizedWallets(wallet), "registered by any relay");
    }

    /// @notice Expired deadlines revert with `PermitExpired` regardless of
    ///         signature validity. The deadline check fires before any
    ///         state mutation.
    function test_initializeFor_fuzz_expiredDeadlineReverts(uint256 expiredBy_) public {
        uint256 expiredBy = bound(expiredBy_, 1, 30 days);

        (address wallet, uint256 walletKey) = makeAddrAndKey("initF_expired_wallet");

        vm.warp(block.timestamp + 60 days);
        uint256 deadline = block.timestamp - expiredBy;

        bytes memory sig = signInitializeFor(walletKey, wallet, deadline);

        address relay = makeAddr("initF_expired_relay");
        vm.prank(relay);
        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.initializeFor(wallet, deadline, sig);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Operator lifecycle: grant → deposit → revoke → deposit must fail
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Operator revocation is immediately effective. The sequence
    ///         `grant → operatorDeposit → revoke → operatorDeposit` must
    ///         end with the second operatorDeposit reverting `NotAuthorised`.
    ///         The wallet's shares from the first deposit remain intact.
    function test_operator_fuzz_revocationMidSequence(uint128 firstDeposit_, uint128 secondDeposit_) public {
        uint256 d1 = bound(uint256(firstDeposit_), MIN_DEPOSIT, MAX_DEPOSIT / 2);
        uint256 d2 = bound(uint256(secondDeposit_), MIN_DEPOSIT, MAX_DEPOSIT / 2);

        address user = makeActor("op_revoke_user", ACTOR_FUNDING);
        address op_ = makeAddr("op_revoke_op");

        useAaveRoute();

        // Grant operator and have them make a legitimate deposit.
        vm.prank(user);
        router.setOperator(op_, true);

        uint256 sharesBeforeRevoke;
        {
            sharesBeforeRevoke = operatorDeposits(op_, user, d1);
        }
        assertGt(sharesBeforeRevoke, 0, "first operator deposit succeeded");

        // Revoke, then any operator-initiated action must revert NotAuthorised.
        vm.prank(user);
        router.setOperator(op_, false);

        // Wallet re-approves for the attempted second deposit. Even with
        // fresh approval, the operator cannot call deposit for a wallet
        // they no longer operate.
        vm.prank(user);
        usdc.approve(address(router), d2);

        vm.prank(op_);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(d2, user, 0);

        // Wallet's share balance is exactly what the first deposit minted —
        // no accidental revert-side-effect on the wallet.
        assertEq(dvUsdc.balanceOf(user), sharesBeforeRevoke, "shares preserved across revocation");
    }

    /// @notice Operator for wallet A cannot act on wallet B's position.
    ///         Tests cross-wallet isolation: the `isOperator[wallet][operator]`
    ///         mapping is keyed on BOTH dimensions and a grant from A does
    ///         not leak to any other wallet.
    function test_operator_fuzz_crossWalletIsolation(uint128 depA_, uint128 depB_) public {
        uint256 depA = bound(uint256(depA_), MIN_DEPOSIT, MAX_DEPOSIT / 2);
        uint256 depB = bound(uint256(depB_), MIN_DEPOSIT, MAX_DEPOSIT / 2);

        address userA = makeActor("op_iso_A", ACTOR_FUNDING);
        address userB = makeActor("op_iso_B", ACTOR_FUNDING);
        address opA = makeAddr("op_iso_opA");

        useAaveRoute();

        // A grants opA, B does not.
        vm.prank(userA);
        router.setOperator(opA, true);

        // opA can deposit for userA.
        operatorDeposits(opA, userA, depA);

        // opA tries to deposit for userB — should revert NotAuthorised.
        vm.prank(userB);
        usdc.approve(address(router), depB);

        vm.prank(opA);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(depB, userB, 0);

        // And opA cannot withdraw from userB either.
        // (Even if userB had shares, which they don't here — belt-and-suspenders.)
        uint256 userAShares = dvUsdc.balanceOf(userA);
        vm.prank(opA);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.withdraw(userAShares / 2, userB, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // USDC permit surface — exposed via depositWithPermit
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice `depositWithPermit` with an expired deadline reverts with
    ///         `PermitExpired`, before any state change. No USDC is pulled.
    function test_depositWithPermit_fuzz_expiredDeadlineReverts(uint128 amount_, uint256 expiredBy_) public {
        uint256 amount = bound(uint256(amount_), MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 expiredBy = bound(expiredBy_, 1, 30 days);

        address walletAddr;
        uint256 walletKey;
        (walletAddr, walletKey) = makeAddrAndKey("permit_expired_wallet");
        fundAndRegister(walletAddr, amount);

        useAaveRoute();

        vm.warp(block.timestamp + 60 days);
        uint256 deadline = block.timestamp - expiredBy;

        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, walletAddr, address(router), amount, deadline);

        uint256 balBefore = usdc.balanceOf(walletAddr);
        vm.prank(walletAddr);
        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.depositWithPermit(amount, walletAddr, deadline, v, r, s, 0);

        assertEq(usdc.balanceOf(walletAddr), balBefore, "USDC not pulled on expired-permit revert");
    }

    /// @notice A permit signed by a key other than `wallet` fails with the
    ///         the router-level insufficient-allowance error — the router never
    ///         reaches the `_deposit` path.
    function test_depositWithPermit_fuzz_wrongSignerReverts(uint128 amount_) public {
        uint256 amount = bound(uint256(amount_), MIN_DEPOSIT, MAX_DEPOSIT);

        (address walletAddr, ) = makeAddrAndKey("permit_wrongSigner_wallet");
        (, uint256 attackerKey) = makeAddrAndKey("permit_wrongSigner_attacker");
        fundAndRegister(walletAddr, amount);

        useAaveRoute();
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(attackerKey, walletAddr, address(router), amount, deadline);

        vm.prank(walletAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.InsufficientPermitAllowance.selector,
                0,
                amount
            )
        );
        router.depositWithPermit(amount, walletAddr, deadline, v, r, s, 0);
    }

    /// @notice A permit signature can be replayed by third parties only
    ///         until its nonce is consumed. First use succeeds; the second
    ///         use with the same (v, r, s) reverts — the nonce has moved.
    function test_depositWithPermit_fuzz_replayFails(uint128 amount_) public {
        uint256 amount = bound(uint256(amount_), MIN_DEPOSIT, MAX_DEPOSIT / 2);

        (address walletAddr, uint256 walletKey) = makeAddrAndKey("permit_replay_wallet");
        fundAndRegister(walletAddr, amount * 2); // fund for both attempted deposits

        useAaveRoute();
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            signPermit(walletKey, walletAddr, address(router), amount, deadline);

        // First use succeeds.
        vm.prank(walletAddr);
        router.depositWithPermit(amount, walletAddr, deadline, v, r, s, 0);

        // Second use of the same (v, r, s) — nonce has advanced, signature
        // no longer recovers to `walletAddr`; allowance was consumed by the
        // first deposit, so the router reports insufficient allowance.
        vm.prank(walletAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.InsufficientPermitAllowance.selector,
                0,
                amount
            )
        );
        router.depositWithPermit(amount, walletAddr, deadline, v, r, s, 0);
    }
}
