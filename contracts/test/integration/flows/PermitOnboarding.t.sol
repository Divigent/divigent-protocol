// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Permit Onboarding End-to-End Flow
/// @notice Pins down the two signature-driven entry points used by SDKs and
///         sponsored-relay services:
///
///           - `initializeFor(wallet, deadline, sig)`: EIP-712 signature over
///             the router's `InitializeFor` type. Permissionless: anyone holding
///             a valid signature can submit, which is how sponsored onboarding
///             works on L2s.
///           - `depositWithPermit(amount, wallet, deadline, v, r, s, minSharesOut)`: EIP-2612
///             signature over USDC's `Permit` type. The router pulls USDC from
///             `wallet` without a prior `approve` tx. Caller must be the wallet
///             itself or a pre-approved operator (the permit authorises the
///             token pull, not the deposit).
///
///         Combined, a new user on an L2 signs both messages once off-chain,
///         the sponsor submits onboarding, then the wallet makes its first
///         deposit without an `approve` tx. That is the journey this file
///         tests end-to-end.
contract PermitOnboardingTest is Actions {
    /// @dev Mirrored from the router so `vm.expectEmit` matches on selector.
    event WalletAuthorised(address indexed wallet);

    // ═════════════════════════════════════════════════════════════════════════
    // 1. Sponsored onboarding + permit-deposit + withdraw
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice A new wallet signs both messages off-chain. A sponsor submits
    ///         onboarding on the wallet's behalf. Then the wallet makes its
    ///         first deposit using the same permit signature: no `approve`
    ///         tx anywhere in the journey.
    function test_permit_sponsoredOnboardingThenPermitDeposit_noApproveAnywhere() public {
        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_wallet");
        address sponsor = makeAddr("permit_sponsor");

        // Pre-conditions: wallet holds USDC, nothing else.
        fund(wallet, 100_000e6);
        assertFalse(router.authorizedWallets(wallet), "Pre: wallet not yet registered");
        assertEq(router.nonces(wallet), 0, "Pre: router onboarding nonce == 0");
        assertEq(usdc.nonces(wallet), 0, "Pre: USDC permit nonce == 0");
        assertEq(usdc.allowance(wallet, address(router)), 0, "Pre: no standing allowance");

        // --- Off-chain: wallet signs both messages in one session -----------

        uint256 deadline = block.timestamp + 1 hours;
        uint256 depositAmount = 50_000e6;

        bytes memory onboardSig = signInitializeFor(walletKey, wallet, deadline);
        (uint8 pv, bytes32 pr, bytes32 ps) = signPermit(walletKey, wallet, address(router), depositAmount, deadline);

        // --- On-chain: sponsor submits initializeFor ------------------------

        vm.expectEmit(true, true, true, true);
        emit WalletAuthorised(wallet);

        vm.prank(sponsor);
        router.initializeFor(wallet, deadline, onboardSig);

        assertTrue(router.authorizedWallets(wallet), "Onboard: wallet authorised");
        assertEq(router.nonces(wallet), 1, "Onboard: router nonce consumed");
        assertFalse(router.authorizedWallets(sponsor), "Onboard: sponsor never authorised");

        // --- On-chain: wallet submits depositWithPermit ---------------------
        // The permit signature substitutes for the `approve` tx; the wallet
        // still calls the deposit itself (onlyWalletOrOperator). This is the
        // standard production path: the permit's value is eliminating the
        // approve tx, not making the deposit gasless.

        useAaveRoute();

        uint256 walletUsdcBefore = usdc.balanceOf(wallet);
        uint256 walletDvUsdcBefore = dvUsdc.balanceOf(wallet);

        vm.prank(wallet);
        uint256 shares = router.depositWithPermit(depositAmount, wallet, deadline, pv, pr, ps, 0);

        // The permit granted and the deposit consumed the allowance in one tx.
        assertEq(usdc.balanceOf(wallet), walletUsdcBefore - depositAmount, "Deposit: wallet's USDC pulled via permit");
        assertEq(dvUsdc.balanceOf(wallet), walletDvUsdcBefore + shares, "Deposit: shares minted to wallet");
        assertGt(shares, 0, "Deposit: non-zero shares");

        // EIP-2612 is one-shot: allowance is granted AND spent in the same
        // transaction, so what's left over is zero.
        assertEq(usdc.allowance(wallet, address(router)), 0, "Deposit: allowance fully consumed");
        assertEq(usdc.nonces(wallet), 1, "Deposit: USDC permit nonce consumed");

        // Cost basis booked to the wallet.
        (uint256 costBasis,,) = router.getPosition(wallet);
        assertEq(costBasis, depositAmount, "Deposit: cost basis credited to wallet");

        // INV-4: router never retains USDC across a call.
        assertEq(usdc.balanceOf(address(router)), 0, "Deposit: router holds zero USDC (INV-4)");

        // Sponsor never receives any protocol token.
        assertEq(usdc.balanceOf(sponsor), 0, "Sponsor: no USDC");
        assertEq(dvUsdc.balanceOf(sponsor), 0, "Sponsor: no dvUSDC");

        // --- Later: wallet exits on its own ---------------------------------

        uint256 returned = userWithdraws(wallet, shares);
        assertEq(returned, depositAmount, "Exit: full round-trip returns principal (no yield)");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. Operator-submitted depositWithPermit (fully delegated variant)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Once a wallet has authorised an operator, the operator can
    ///         submit `depositWithPermit` for them. This is the path smart-
    ///         account wallets and agent frameworks take when doing scheduled
    ///         or automated deposits.
    function test_depositWithPermit_approvedOperatorSubmitsForWallet_usdcPulledFromWallet() public {
        (address wallet, uint256 walletKey) = makeAddrAndKey("permit_operator_wallet");
        address operator_ = makeAddr("permit_operator");
        fundAndRegister(wallet, 100_000e6);

        // Wallet authorises the operator (one-time setup).
        vm.prank(wallet);
        router.setOperator(operator_, true);

        useAaveRoute();

        uint256 amount = 40_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = signPermit(walletKey, wallet, address(router), amount, deadline);

        uint256 walletUsdcBefore = usdc.balanceOf(wallet);
        uint256 operatorUsdcBefore = usdc.balanceOf(operator_);

        vm.prank(operator_);
        uint256 shares = router.depositWithPermit(amount, wallet, deadline, v, r, s, 0);

        // USDC flows from WALLET (not operator), dvUSDC to WALLET (not operator).
        assertEq(usdc.balanceOf(wallet), walletUsdcBefore - amount, "USDC pulled from wallet");
        assertEq(usdc.balanceOf(operator_), operatorUsdcBefore, "Operator's USDC untouched");
        assertEq(dvUsdc.balanceOf(wallet), shares, "dvUSDC minted to wallet");
        assertEq(dvUsdc.balanceOf(operator_), 0, "Operator gets no shares");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. depositWithPermit after self-registration (minimal happy path)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice The simplest everyday path: wallet self-registered at some
    ///         earlier point, and now uses permit on each deposit to skip the
    ///         approve tx.
    function test_depositWithPermit_selfRegisteredWallet_depositsWithoutApprove() public {
        (address eve, uint256 eveKey) = makeAddrAndKey("eve_self_registered");
        fundAndRegister(eve, 100_000e6);

        useAaveRoute();

        uint256 amount = 30_000e6;
        uint256 deadline = block.timestamp + 30 minutes;
        (uint8 v, bytes32 r, bytes32 s) = signPermit(eveKey, eve, address(router), amount, deadline);

        // No prior approve tx.
        assertEq(usdc.allowance(eve, address(router)), 0, "Pre: no standing approval");

        vm.prank(eve);
        uint256 shares = router.depositWithPermit(amount, eve, deadline, v, r, s, 0);

        assertGt(shares, 0, "Shares minted");
        assertEq(dvUsdc.balanceOf(eve), shares, "dvUSDC credited to eve");
        assertEq(usdc.allowance(eve, address(router)), 0, "Allowance consumed by deposit");
        assertEq(usdc.nonces(eve), 1, "Permit nonce advanced once");
        assertEq(usdc.balanceOf(address(router)), 0, "Router retains no USDC (INV-4)");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. initializeFor: revert paths
    // ═════════════════════════════════════════════════════════════════════════

    function test_initializeFor_revertsWith_WalletAlreadyAuthorised_onSignatureReplay() public {
        (address eve, uint256 eveKey) = makeAddrAndKey("eve_replay_onboard");
        address relayer = makeAddr("relayer_replay_onboard");

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signInitializeFor(eveKey, eve, deadline);

        vm.prank(relayer);
        router.initializeFor(eve, deadline, sig);

        // WalletAlreadyAuthorised fires before signature recovery.
        vm.prank(relayer);
        vm.expectRevert(IDivigentVaultRouter.WalletAlreadyAuthorised.selector);
        router.initializeFor(eve, deadline, sig);
    }

    function test_initializeFor_revertsWith_InvalidSignature_whenSignerIsNotWallet() public {
        (, uint256 malloryKey) = makeAddrAndKey("mallory_bad_onboard");
        (address victim,) = makeAddrAndKey("victim_bad_onboard");

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory wrongSig = signInitializeFor(malloryKey, victim, deadline);

        vm.expectRevert(IDivigentVaultRouter.InvalidSignature.selector);
        router.initializeFor(victim, deadline, wrongSig);

        // The revert MUST roll back the pre-check nonce bump.
        assertFalse(router.authorizedWallets(victim), "Victim not authorised after failed sig");
        assertEq(router.nonces(victim), 0, "Victim's nonce preserved after revert");
    }

    function test_initializeFor_revertsWith_PermitExpired_whenDeadlineInPast() public {
        (address lateWallet, uint256 lateKey) = makeAddrAndKey("late_onboard");

        uint256 expired = block.timestamp - 1;
        bytes memory sig = signInitializeFor(lateKey, lateWallet, expired);

        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.initializeFor(lateWallet, expired, sig);

        assertFalse(router.authorizedWallets(lateWallet), "Expired sig did not authorise");
        assertEq(router.nonces(lateWallet), 0, "Expired sig did not consume nonce");
    }

    /// @dev Boundary: `deadline == block.timestamp` must SUCCEED. The router
    ///      checks `if (block.timestamp > deadline) revert PermitExpired` —
    ///      a regression flipping this to `>=` would silently reject every
    ///      permit submitted at the exact deadline second. Pins the inclusive
    ///      semantics.
    function test_initializeFor_succeedsWhenDeadlineEqualsNow() public {
        (address exact, uint256 exactKey) = makeAddrAndKey("exact_boundary_onboard");

        uint256 deadline = block.timestamp; // == not >
        bytes memory sig = signInitializeFor(exactKey, exact, deadline);

        router.initializeFor(exact, deadline, sig);

        assertTrue(router.authorizedWallets(exact), "deadline == now must authorise");
        assertEq(router.nonces(exact), 1, "nonce consumed on success");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5. depositWithPermit: revert paths
    //    (PermitExpired at the router layer is covered in DepositValidation.t.sol;
    //     this tests the USDC-layer signature checks.)
    // ═════════════════════════════════════════════════════════════════════════

    function test_depositWithPermit_revertsWhenSignerIsNotOwner() public {
        (address eve,) = makeAddrAndKey("eve_wrong_signer");
        (, uint256 malloryKey) = makeAddrAndKey("mallory_wrong_signer");
        fundAndRegister(eve, 100_000e6);

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        // Mallory signs a permit claiming to be eve.
        (uint8 v, bytes32 r, bytes32 s) = signPermit(malloryKey, eve, address(router), amount, deadline);

        vm.prank(eve);
        vm.expectRevert(MockERC20.PermitInvalidSigner.selector);
        router.depositWithPermit(amount, eve, deadline, v, r, s, 0);

        assertEq(usdc.nonces(eve), 0, "Eve's USDC nonce untouched by bad sig");
    }

    function test_depositWithPermit_revertsOnReplayOfSameSignature() public {
        (address eve, uint256 eveKey) = makeAddrAndKey("eve_permit_replay");
        fundAndRegister(eve, 100_000e6);

        useAaveRoute();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = signPermit(eveKey, eve, address(router), amount, deadline);

        // First call consumes the nonce.
        vm.prank(eve);
        router.depositWithPermit(amount, eve, deadline, v, r, s, 0);
        assertEq(usdc.nonces(eve), 1, "Nonce consumed by first use");

        // Replay: same (v, r, s) signs over nonce=0; USDC expects nonce=1 now.
        // The recovered signer won't match eve -> PermitInvalidSigner.
        vm.prank(eve);
        vm.expectRevert(MockERC20.PermitInvalidSigner.selector);
        router.depositWithPermit(amount, eve, deadline, v, r, s, 0);
    }

    function test_depositWithPermit_revertsOnAmountMismatchVsSignedValue() public {
        (address eve, uint256 eveKey) = makeAddrAndKey("eve_amount_mismatch");
        fundAndRegister(eve, 100_000e6);

        uint256 signedAmount = 10_000e6;
        uint256 calledAmount = 20_000e6; // attacker inflates the call
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = signPermit(eveKey, eve, address(router), signedAmount, deadline);

        // USDC.permit rebuilds the digest with `calledAmount` and recovers a
        // different address than eve -> revert.
        vm.prank(eve);
        vm.expectRevert(MockERC20.PermitInvalidSigner.selector);
        router.depositWithPermit(calledAmount, eve, deadline, v, r, s, 0);
    }
}
