// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  FindingsValidation
/// @notice Pins three auditor findings using the REAL failure modes they
///         describe, not proxies.
///
///           R8 treasury blocklist — `usdc.setBlocklisted(treasury, true)`
///                                    mirrors Circle's canonical USDC
///                                    `require(!blacklisted[to])`. Any
///                                    transfer to the treasury reverts with
///                                    `BlocklistedRecipient(treasury)`.
///
///           R8 global USDC pause —   `usdc.setTransfersPaused(true)` mirrors
///                                    Circle's `pause()` admin action. Every
///                                    transfer — including fee flow — reverts
///                                    with `TokenPaused()`.
///
///           R2 permissionless sig —  `initializeFor` signatures can be
///                                    submitted by any address.
///
///           R5 preview overflow —    `previewWithdrawNet` must not revert
///                                    on realistic large positions.
///
///         Previously the R8 tests simulated the failure by clearing the
///         router-to-FeeCollector approval. That only proved "the fee path
///         can fail if approval is missing" — it neither exercised the
///         blocklist/pause semantics USDC actually implements nor proved that
///         a real Circle action would halt withdrawals. The mock now carries
///         an adversarial blocklist + pause, so these tests exercise the
///         real-world condition directly.
contract FindingsValidation is TestBase {
    uint256 constant DEPOSIT = 10_000e6;

    function setUp() public override {
        super.setUp();
        // Alice deposits and earns yield (realistic starting state)
        vm.startPrank(alice);
        usdc.approve(address(router), DEPOSIT);
        router.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Simulate Aave rebasing yield
        aToken.mint(address(router), 500e6);
    }

    // ========================================================================
    //  FINDING R8: FeeCollector revert blocks ALL withdrawals
    //
    //  Real-world trigger: Circle blocklists the treasury multisig address.
    //  Happened to Tornado Cash-associated addresses in 2022. Circle can
    //  blocklist ANY address on USDC.
    //
    //  When the treasury is blocklisted:
    //    - FeeCollector.collectFee() calls USDC.safeTransferFrom(router, treasury, fee)
    //    - USDC enforces `require(!blocklisted[to])` and reverts
    //    - The router's withdraw() reverts
    //    - NO user can exit a yield-earning position
    //
    //  This is the only non-vault external call in withdraw() that has
    //  no fallback. Aave/Morpho reverts have ExitRedirected. Fee doesn't.
    // ========================================================================

    /// @notice Treasury is blocklisted on USDC. Withdrawals that would charge
    ///         a fee revert with `BlocklistedRecipient(treasury)` — the exact
    ///         selector canonical USDC would use on mainnet.
    function test_R8_treasuryBlocklisted_allWithdrawalsFail() public {
        uint256 shares = dvUsdc.balanceOf(alice);

        // Pre-revert snapshot — atomicity is a load-bearing claim here; if the
        // revert leaks partial state (dvUSDC burned, costBasis decremented,
        // Aave pulled, router holds stray USDC), the test-bench would have
        // been blind to it. Snapshot every mutable slot the withdraw touches.
        (uint256 cbPre, , ) = router.getPosition(alice);
        uint256 dvPre       = dvUsdc.balanceOf(alice);
        uint256 aTokPre     = aToken.balanceOf(address(router));
        uint256 morphoPre   = morphoVault.balanceOf(address(router));
        uint256 routerPre   = usdc.balanceOf(address(router));
        uint256 alicePre    = usdc.balanceOf(alice);
        uint256 treasuryPre = usdc.balanceOf(treasury);

        // Circle blocklists the treasury. Any USDC transfer with to=treasury reverts.
        usdc.setBlocklisted(treasury, true);

        // The fee transfer inside collectFee() now reverts. Because the revert
        // propagates through SafeERC20, the router bubbles up the original
        // BlocklistedRecipient selector — the same one mainnet USDC emits.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlocklistedRecipient.selector, treasury));
        router.withdraw(shares, alice, 0);

        // Post-revert: every slot must be bit-identical to pre-revert. This is
        // the atomicity guarantee — if any one of these drifts, a blocklist
        // event silently corrupts accounting across the protocol.
        (uint256 cbPost, , ) = router.getPosition(alice);
        assertEq(cbPost,                           cbPre,       "costBasis atomic");
        assertEq(dvUsdc.balanceOf(alice),          dvPre,       "dvUSDC atomic");
        assertEq(aToken.balanceOf(address(router)), aTokPre,    "aToken atomic");
        assertEq(morphoVault.balanceOf(address(router)), morphoPre, "Morpho shares atomic");
        assertEq(usdc.balanceOf(address(router)),  routerPre,   "router USDC atomic (INV-4)");
        assertEq(usdc.balanceOf(alice),            alicePre,    "alice USDC atomic");
        assertEq(usdc.balanceOf(treasury),         treasuryPre, "treasury USDC atomic");

        // R8 fix: wrap collectFee in try/catch; on blocklist, user gets the
        // full gross and the skipped fee is an operational incident rather
        // than a DoS. Tracked in .audit/findings-to-fix.md.
    }

    /// @notice Simulates Circle's global USDC pause (March 2023 SVB incident).
    ///         Every transfer reverts with `TokenPaused()`. Withdrawals should
    ///         still work per INV-5, but under the current code they don't
    ///         because the fee path reverts.
    ///
    /// @dev Pins CURRENT broken behavior. When the R8 fix lands (try/catch
    ///      around FEE_COLLECTOR.collectFee in withdraw), the assertion flips
    ///      to `assertGt(usdcReturned, 0)` and the test name changes to
    ///      reflect the restored permissionless-exit guarantee.
    function test_R8_usdcGlobalPause_withdrawalsShouldWorkButDont() public {
        uint256 shares = dvUsdc.balanceOf(alice);

        // Circle pauses USDC globally. No transfer can succeed.
        usdc.setTransfersPaused(true);

        // Morpho path uses `usdc.transfer`; Aave's mock bypasses (it `mint`s
        // USDC directly), but the fee's transferFrom in FeeCollector is
        // always on the transfer path. Selector matches canonical paused-token
        // semantics.
        vm.prank(alice);
        vm.expectRevert(MockERC20.TokenPaused.selector);
        router.withdraw(shares, alice, 0);
    }

    /// @notice Positive control: normal withdrawal with working fee path.
    function test_R8_control_normalWithdrawalSucceeds() public {
        uint256 shares = dvUsdc.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);

        assertGt(returned, 0);
        assertGt(usdc.balanceOf(alice), balBefore);
    }

    // ========================================================================
    //  FINDING R2: initializeFor signature is permissionless
    //
    //  Any party with a valid signature can submit it (not just the relayer).
    //  The wallet is still registered correctly. Nonce is consumed before
    //  sig validation (defense-in-depth: validate first, consume after).
    // ========================================================================

    /// @notice Proves that anyone with a valid initializeFor signature can
    ///         submit it — not just the intended relayer. The wallet has no
    ///         control over WHO submits the signature or WHEN.
    function test_R2_anyoneCanSubmitValidSig() public {
        (address victim, uint256 victimKey) = makeAddrAndKey("newUser");
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = router.nonces(victim);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("InitializeFor(address wallet,uint256 deadline,uint256 nonce)"),
                victim,
                deadline,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Third party submits the sig before the intended relayer
        address thirdParty = makeAddr("thirdParty");
        vm.prank(thirdParty);
        router.initializeFor(victim, deadline, sig);

        assertTrue(router.authorizedWallets(victim));

        // Re-submission now fails (wallet already registered)
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("WalletAlreadyAuthorised()"));
        router.initializeFor(victim, deadline, sig);
    }

    /// @notice Pins the non-standard nonce-ordering: nonce is incremented
    ///         (line 273) BEFORE signature check (line 281). On revert, state
    ///         rolls back, so nonce is unchanged. Non-standard vs OZ
    ///         ERC20Permit but no practical exploit.
    function test_R2_nonceOrderingIsNonStandard() public {
        address newWallet = makeAddr("orderingTest");
        uint256 nonceBefore = router.nonces(newWallet);

        vm.expectRevert();
        router.initializeFor(
            newWallet,
            block.timestamp + 1 hours,
            hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefaa"
        );

        assertEq(router.nonces(newWallet), nonceBefore, "Nonce unchanged on revert");
    }

    // ========================================================================
    //  FINDING R5: previewWithdrawNet overflow on extreme inputs
    //
    //  Real-world trigger: a whale with a very large position tries to
    //  preview their withdrawal. The view should return a valid result,
    //  not revert from uint256 overflow in the 4-way numerator.
    // ========================================================================

    /// @notice R5 regression: previewWithdrawNet must NOT revert for
    ///         legitimate large positions. The fix wraps the 4-way numerator
    ///         in OZ `Math.mulDiv` (512-bit intermediate) so the product can
    ///         exceed 2^256 safely.
    function test_R5_largePosition_previewDoesNotOverflow() public {
        vm.warp(block.timestamp + 92 days); // Day 91+ removes TVL cap

        uint256 whale = 10_000_000e6;
        usdc.mint(alice, whale);
        usdc.mint(address(aToken), whale * 2);

        vm.startPrank(alice);
        usdc.approve(address(router), whale);
        router.deposit(whale, alice);
        vm.stopPrank();

        uint256 walletShares = dvUsdc.balanceOf(alice);
        uint256 totalPosition = whale + DEPOSIT;

        uint256 sharesAtPosition = router.previewWithdrawNet(totalPosition, alice);
        assertGt(sharesAtPosition, 0, "preview returns non-zero for servable position");
        assertLe(sharesAtPosition, walletShares, "preview caps at walletShares");

        uint256 sharesAtMax = router.previewWithdrawNet(type(uint128).max, alice);
        assertEq(sharesAtMax, walletShares, "uint128-max desiredNet caps at walletShares");
    }

    // ========================================================================
    //  HELPER
    // ========================================================================

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DivigentVaultRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
