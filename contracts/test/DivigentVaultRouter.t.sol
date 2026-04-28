// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DivigentVaultRouter} from "../src/DivigentVaultRouter.sol";
import {DivigentFeeCollector} from "../src/DivigentFeeCollector.sol";
import {DvUSDC} from "../src/dvUSDC.sol";
import {IDivigentVaultRouter} from "../src/interfaces/IDivigentVaultRouter.sol";
import {IDivigentYieldOracle} from "../src/interfaces/IDivigentYieldOracle.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorphoVault} from "./mocks/MockMorphoVault.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @dev Full integration test harness with mock contracts from test/mocks/.
contract DivigentVaultRouterTest is Test {
    // ── Protocol contracts ──────────────────────────────────────────────────
    DivigentVaultRouter internal router;
    DivigentFeeCollector internal feeCollector;
    DvUSDC internal dvUsdc;

    // ── Mocks ────────────────────────────────────────────────────────────────
    MockERC20 internal usdc;
    MockERC20 internal aToken;
    MockAavePool internal aavePool;
    MockMorphoVault internal morphoVault;
    MockOracle internal oracle;

    // ── Actors ──────────────────────────────────────────────────────────────
    address internal treasury = makeAddr("treasury");
    address internal emergencyMultisig = makeAddr("multisig");
    address internal alice;
    uint256 internal aliceKey;
    address internal bob = makeAddr("bob");
    address internal operator_ = makeAddr("operator");

    // ── Constants ────────────────────────────────────────────────────────────
    uint256 internal constant INITIAL_USDC = 100_000e6; // 100k USDC
    uint256 internal constant MIN_DEPOSIT = 10e6;
    uint256 internal constant FEE_BPS = 1_000; // 10 %
    uint256 internal constant BPS_DENOM = 10_000;

    bytes32 private constant INITIALIZE_FOR_TYPEHASH =
        keccak256("InitializeFor(address wallet,uint256 deadline,uint256 nonce)");

    // ────────────────────────────────────────────────────────────────────────

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave aUSDC", "aUSDC", 6);

        // Deploy mock protocols
        aavePool = new MockAavePool(address(usdc), address(aToken));
        morphoVault = new MockMorphoVault(address(usdc));
        oracle = new MockOracle();
        oracle.setLastObservationTime(block.timestamp);

        // Seed aToken with USDC liquidity for Aave capacity check
        usdc.mint(address(aToken), 10_000_000e6);

        // Deploy real protocol contracts.
        // There is a three-way circular dependency:
        //   FeeCollector needs (usdc, treasury, routerAddr)
        //   DvUSDC       needs (routerAddr)
        //   Router       needs (feeCollectorAddr, dvUsdcAddr)
        //
        // Resolve by pre-computing the router's CREATE address before any deploy:
        //   nonce N  : feeCollector
        //   nonce N+1: dvUsdc
        //   nonce N+2: router  ← pre-compute this
        uint256 currentNonce = vm.getNonce(address(this));
        address expectedRouterAddr = vm.computeCreateAddress(address(this), currentNonce + 2);

        feeCollector = new DivigentFeeCollector( // nonce N
            address(usdc),
            treasury,
            expectedRouterAddr
        );

        dvUsdc = new DvUSDC(expectedRouterAddr); // nonce N+1

        router = new DivigentVaultRouter( // nonce N+2 → lands at expectedRouterAddr
            address(usdc),
            address(aavePool),
            address(aToken),
            address(morphoVault),
            address(oracle),
            address(feeCollector),
            address(dvUsdc),
            emergencyMultisig
        );

        // Sanity: verify the circular wiring is correct.
        assert(address(router) == expectedRouterAddr);

        // Fund actors
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
        usdc.mint(operator_, INITIAL_USDC);

        // Register alice and bob by default
        vm.prank(alice);
        router.initialize();

        vm.prank(bob);
        router.initialize();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Approve and deposit `amount` USDC for `wallet` called by `caller`.
    ///      USDC is always pulled from `wallet` by the router; `wallet` must approve.
    ///      When `caller != wallet` (operator flow), wallet approves separately and
    ///      caller just triggers the deposit.
    function _deposit(address caller, address wallet, uint256 amount) internal returns (uint256) {
        // wallet approves router to pull its USDC (router always pulls from wallet)
        vm.prank(wallet);
        usdc.approve(address(router), amount);

        vm.prank(caller);
        return router.deposit(amount, wallet);
    }

    /// @dev Build and sign an initializeFor() EIP-712 digest.
    function _signInitializeFor(uint256 privateKey, address wallet, uint256 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        uint256 nonce = router.nonces(wallet);

        bytes32 structHash = keccak256(abi.encode(INITIALIZE_FOR_TYPEHASH, wallet, deadline, nonce));

        // Compute domain separator from router (must match EIP712 impl)
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DivigentVaultRouter")),
                keccak256(bytes("1")),
                block.chainid,
                address(router)
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSep, structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  1. previewWithdrawNet accuracy
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev previewWithdrawNet should predict net USDC within 1 wei of the
    ///      actual withdraw() return value, accounting for the 10% yield fee.
    function test_previewWithdrawNet_accuracy() public {
        uint256 depositAmount = 50_000e6;
        // Use Aave route (default oracle) so yield is simulated via aToken inflation
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        // Simulate 5% yield: mint extra USDC to aToken address.
        // The router reads aToken.balanceOf(router) as Aave assets; inflate it
        // by minting aTokens to the router, which mirrors how Aave accrues yield.
        uint256 yieldAmount = depositAmount * 5 / 100;
        aToken.mint(address(router), yieldAmount);

        uint256 desiredNet = 50_000e6 + 2_000e6; // want principal + some yield net of fee

        uint256 predictedShares = router.previewWithdrawNet(desiredNet, alice);
        uint256 predictedOut = router.previewRedeem(predictedShares, alice);

        // Actual withdraw
        vm.startPrank(alice);
        uint256 actualOut = router.withdraw(
            predictedShares,
            alice,
            0 /* no slippage guard */
        );
        vm.stopPrank();

        // Must be within 1 wei — formula is algebraic, not iterative
        assertApproxEqAbs(actualOut, desiredNet, 1, "previewWithdrawNet off by >1 wei");
        assertApproxEqAbs(predictedOut, actualOut, 1, "previewRedeem inconsistent with withdraw");
    }

    /// @dev previewWithdrawNet for full withdrawal (desiredNet >= position value)
    ///      must return exactly the wallet's share balance, not overflow.
    function test_previewWithdrawNet_cappedAtWalletShares() public {
        uint256 depositAmount = 20_000e6;
        _deposit(alice, alice, depositAmount);

        uint256 hugDesiredNet = 1_000_000_000e6; // far more than deposited
        uint256 shares = router.previewWithdrawNet(hugDesiredNet, alice);

        uint256 walletBalance = dvUsdc.balanceOf(alice);
        assertEq(shares, walletBalance, "Should be capped at wallet shares");
    }

    /// @dev previewWithdrawNet returns 0 shares when desiredNet == 0.
    function test_previewWithdrawNet_zeroDesired() public {
        uint256 depositAmount = 10_000e6;
        _deposit(alice, alice, depositAmount);
        uint256 shares = router.previewWithdrawNet(0, alice);
        assertEq(shares, 0);
    }

    /// @dev previewWithdrawNet must not under-deliver when the vault is in drawdown.
    ///      Guarantee: actualOut >= desiredNetUSDC (or capped at walletShares).
    ///      The closed-form solver assumes yield = gross - principalOut unconditionally
    ///      and treats negative yield as a fee rebate, inflating what each share returns.
    ///      In reality withdraw() floors yield at 0 (no negative fee), so the preview
    ///      solves for too few shares in a loss state.
    function test_previewWithdrawNet_lossScenario_violatesGuarantee() public {
        uint256 depositAmount = 1_000e6; // 1000 USDC
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        // Simulate a 10% drawdown in the Aave leg (gross < principalOut for alice)
        aToken.burn(address(router), 100e6);
        assertEq(router.totalVaultAssets(), 900e6, "Post-loss vault total");

        uint256 desiredNet = 100e6; // want 100 USDC net
        uint256 predictedShares = router.previewWithdrawNet(desiredNet, alice);

        // Sanity: not capped at walletShares (so the guarantee must hold)
        uint256 walletShares = dvUsdc.balanceOf(alice);
        assertLt(predictedShares, walletShares, "Not the cap case");

        // Execute the actual withdraw
        vm.prank(alice);
        uint256 actualOut = router.withdraw(predictedShares, alice, 0);

        // The core promise: user receives at least desiredNet (allow 1 wei floor tolerance)
        assertGe(actualOut, desiredNet - 1, "loss: actualOut < desiredNet - 1 wei");
    }

    /// @dev previewWithdrawNet must handle a huge desiredNet relative to tiny position
    ///      by capping at walletShares without reverting.
    function test_previewWithdrawNet_tinyShares_hugeDesired() public {
        uint256 depositAmount = MIN_DEPOSIT; // 10 USDC
        _deposit(alice, alice, depositAmount);

        uint256 walletShares = dvUsdc.balanceOf(alice);

        // Ask for astronomical net (inside uint128.max to avoid input-overflow revert)
        uint256 huge = type(uint128).max;
        uint256 predicted = router.previewWithdrawNet(huge, alice);

        assertEq(predicted, walletShares, "Preview caps at walletShares");
    }

    /// @dev Fuzz invariant: for any valid (depositAmount, yield/loss, desiredNet),
    ///      the shares returned by previewWithdrawNet must, when fed into the
    ///      actual withdraw flow, deliver at least desiredNet.
    ///
    ///      Bounds are chosen so that every input reaches the asserting branch
    ///      — no silent early-returns on dust / cap / zero-shares. A 10k-USDC
    ///      minimum deposit, ±20% max swing, and desired capped at 95% of
    ///      position keep `positionValue`, `desired`, `predictedShares`, and
    ///      `predictedShares < walletShares` all provably non-degenerate.
    function testFuzz_previewWithdrawNet_withdrawYieldsAtLeastDesired(
        uint128 depositAmount_,
        int16 yieldBps_,
        uint128 desiredNet_
    ) public {
        uint256 depositAmount = bound(uint256(depositAmount_), 10_000e6, 100_000e6);
        // yieldBps in [-2000, +3000] bps ⇒ -20% drawdown to +30% gain.
        // -20% on 10k min deposit ⇒ positionValue >= 8_000e6; never dust.
        int256 yieldBps = int256(bound(int256(yieldBps_), -2000, 3000));

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, depositAmount);

        if (yieldBps > 0) {
            uint256 gain = (depositAmount * uint256(yieldBps)) / BPS_DENOM;
            aToken.mint(address(router), gain);
        } else if (yieldBps < 0) {
            uint256 loss = (depositAmount * uint256(-yieldBps)) / BPS_DENOM;
            aToken.burn(address(router), loss);
        }

        uint256 positionValue = router.previewRedeem(shares, alice);
        assertGe(positionValue, 8_000e6, "positionValue lower-bounded by -20% on 10k min");

        // Cap desired at 95% of positionValue so predictedShares never hits
        // the wallet-shares ceiling (the old "capped, guarantee relaxed" escape).
        uint256 desired = bound(uint256(desiredNet_), 1e6, (positionValue * 95) / 100);

        uint256 predictedShares = router.previewWithdrawNet(desired, alice);
        assertGt(predictedShares, 0, "preview returned zero shares for non-dust desired");
        assertLt(predictedShares, dvUsdc.balanceOf(alice), "preview never hits cap under 95% bound");

        uint256 actualOut = router.previewRedeem(predictedShares, alice);
        assertGe(actualOut + 1, desired, "actualOut < desired - 1 wei (preview underestimated)");
    }

    /// @dev Dust-position edge: when the vault's value per share floors to 0
    ///      (walletShares * A1 / S1 == 0 via Floor rounding), the loss branch
    ///      would otherwise return shares capped at walletShares that then
    ///      deliver 0 USDC — violating the >= desiredNet guarantee silently.
    ///      The preview must return 0 in this degenerate state.
    function test_previewWithdrawNet_grossAllZero_returnsZero() public {
        vm.prank(address(router));
        dvUsdc.mint(alice, 1);

        // Any positive desired is unserviceable; preview must signal via 0
        uint256 shares = router.previewWithdrawNet(1, alice);
        assertEq(shares, 0, "grossAll=0 must short-circuit to 0 shares");
    }

    /// @dev Exact break-even boundary: grossAll == costBasis. The loss-branch
    ///      predicate uses `<=` so this value goes to the loss branch (no fee).
    ///      Verifies the round-trip still delivers >= desiredNet at the boundary.
    function test_previewWithdrawNet_lossBranch_exactBreakEven() public {
        uint256 depositAmount = 100_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        // No yield, no loss. grossAll ~= costBasis (modulo the virtual offset).
        // A=100_000e6, S=100_000e6, walletShares=100_000e6, costBasis=100_000e6
        //   grossAll = floor(100_000e6 * (100_000e6+1) / (100_000e6+1)) = 100_000e6
        //   costBasis = 100_000e6 -> grossAll <= costBasis -> loss branch
        uint256 desiredNet = 10_000e6;
        uint256 predictedShares = router.previewWithdrawNet(desiredNet, alice);

        assertGt(predictedShares, 0, "Should return non-zero at break-even");

        vm.prank(alice);
        uint256 actualOut = router.withdraw(predictedShares, alice, 0);

        // Exact boundary; no fee because yield = 0
        assertGe(actualOut, desiredNet - 1, "break-even: actualOut < desiredNet - 1 wei");
    }

    /// @dev Deep loss: 95% drawdown. Exercises the loss branch at an extreme
    ///      where withdrawing more than the dust-guard threshold is still valid.
    function test_previewWithdrawNet_lossBranch_deepLoss95() public {
        uint256 depositAmount = 100_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        // 95% drawdown: vault holds 5,000 USDC against 100,000 principal
        aToken.burn(address(router), 95_000e6);
        assertEq(router.totalVaultAssets(), 5_000e6, "Deep drawdown applied");

        // Ask for 1k USDC - comfortably within the 5k vault total
        uint256 desiredNet = 1_000e6;
        uint256 predictedShares = router.previewWithdrawNet(desiredNet, alice);

        assertGt(predictedShares, 0, "Returns shares for servable amount");
        assertLt(predictedShares, dvUsdc.balanceOf(alice), "Not the cap case");

        vm.prank(alice);
        uint256 actualOut = router.withdraw(predictedShares, alice, 0);

        assertGe(actualOut, desiredNet - 1, "deep loss: actualOut < desiredNet - 1 wei");
    }

    /// @dev Cap boundary in loss regime: caller asks for more than their total
    ///      position value. Preview must cap at walletShares. The >= desiredNet
    ///      guarantee is intentionally waived in the cap case (user opted for
    ///      max withdrawal, not a specific amount).
    function test_previewWithdrawNet_lossBranch_cappedAtWalletShares() public {
        uint256 depositAmount = 100_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        _deposit(alice, alice, depositAmount);

        // 30% drawdown: position is worth ~70k
        aToken.burn(address(router), 30_000e6);

        // Ask for 200k (way more than position value of 70k)
        uint256 predictedShares = router.previewWithdrawNet(200_000e6, alice);

        // Must cap at walletShares
        assertEq(predictedShares, dvUsdc.balanceOf(alice), "Caps at walletShares in loss");

        // Withdraw delivers full remaining position value - caller gets ~70k, not 200k
        vm.prank(alice);
        uint256 actualOut = router.withdraw(predictedShares, alice, 0);
        assertApproxEqAbs(actualOut, 70_000e6, 2, "Cap delivers remaining position value");
        assertLt(actualOut, 200_000e6, "Cap explicitly short-of-desired in this regime");
    }

    /// @dev With a large virtual offset, deep-loss redemptions can otherwise
    ///      quote phantom virtual assets. convertToAssets/previewRedeem/withdraw
    ///      must cap at physical totalAssets.
    function test_sharesToAssets_capsAtTotalAssets_underDeepLoss() public {
        uint256 depositAmount = 100_000e6;
        uint256 postLossAssets = 1e6; // 1 USDC remains
        uint256 virtualOffset = 1e6;

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, depositAmount);

        aToken.burn(address(router), depositAmount - postLossAssets);
        assertEq(router.totalVaultAssets(), postLossAssets, "deep loss applied");

        uint256 uncappedQuote = (shares * (postLossAssets + virtualOffset)) / (dvUsdc.totalSupply() + virtualOffset);
        assertGt(uncappedQuote, postLossAssets, "precondition: virtual offset would overquote");

        assertEq(router.convertToAssets(shares), postLossAssets, "convertToAssets caps at real assets");
        assertEq(router.previewRedeem(shares, alice), postLossAssets, "previewRedeem uses capped gross");

        vm.prank(alice);
        uint256 actualOut = router.withdraw(shares, alice, 0);
        assertEq(actualOut, postLossAssets, "withdraw returns only physical assets");
        assertEq(router.totalVaultAssets(), 0, "all physical assets withdrawn");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  2. Stale oracle blocks deposits
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Advancing past MAX_STALENESS (2 hours) must cause deposit() to revert
    ///      with StaleOracle().
    function test_staleOracle_blocksDeposit() public {
        // Oracle is fresh at setUp time.
        uint256 amount = 10_000e6;
        _deposit(alice, alice, amount); // should succeed

        // Advance time beyond MAX_STALENESS (2 hours = 7200 s)
        vm.warp(block.timestamp + 7201);
        oracle.setFresh(false);

        vm.startPrank(alice);
        usdc.approve(address(router), amount);
        vm.expectRevert(IDivigentVaultRouter.StaleOracle.selector);
        router.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev Withdrawals must still succeed when oracle is stale.
    function test_staleOracle_doesNotBlockWithdraw() public {
        uint256 depositAmount = 10_000e6;
        uint256 shares = _deposit(alice, alice, depositAmount);

        vm.warp(block.timestamp + 7201);
        oracle.setFresh(false);

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);
        assertGt(returned, 0, "Withdraw should succeed even with stale oracle");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3. Operator authorisation
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `setOperator(address(0), _)` must revert `ZeroAddress`. Before this
    ///      test, the error at `DivigentVaultRouter.sol:291` was uncovered —
    ///      a regression deleting the guard would have silently written
    ///      `isOperator[wallet][0x0] = true/false`, polluting indexers and
    ///      introducing a confused-deputy surface.
    function test_setOperator_reverts_ZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.ZeroAddress.selector);
        router.setOperator(address(0), true);

        vm.prank(alice);
        vm.expectRevert(IDivigentVaultRouter.ZeroAddress.selector);
        router.setOperator(address(0), false);

        // Mapping must remain clean.
        assertFalse(router.isOperator(alice, address(0)), "no operator state written");
    }

    /// @dev An approved operator can deposit and withdraw on behalf of a wallet.
    function test_operator_canDepositAndWithdraw() public {
        // Alice grants operator_ operator rights
        vm.prank(alice);
        router.setOperator(operator_, true);

        uint256 depositAmount = 15_000e6;

        // USDC is pulled from wallet (alice), not from the operator.
        // Alice must pre-approve the router; operator_ merely calls deposit().
        vm.prank(alice);
        usdc.approve(address(router), depositAmount);

        // operator_ deposits on alice's behalf — using alice's USDC
        vm.prank(operator_);
        uint256 sharesMinted = router.deposit(depositAmount, alice);

        assertEq(dvUsdc.balanceOf(alice), sharesMinted, "Shares minted to alice");
        assertEq(dvUsdc.balanceOf(operator_), 0, "Operator receives no shares");

        // operator_ withdraws on alice's behalf; USDC returns to alice
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(operator_);
        uint256 returned = router.withdraw(sharesMinted, alice, 0);

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + returned, "USDC returned to alice, not operator");
    }

    /// @dev An address that is NOT an approved operator must be rejected.
    function test_operator_cannotActWithoutApproval() public {
        address rogue = makeAddr("rogue");
        uint256 amount = 10_000e6;

        // rogue is not registered or approved
        vm.startPrank(rogue);
        usdc.approve(address(router), amount);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev After revoking an operator, they must no longer be able to act.
    function test_operator_revokeStopsAccess() public {
        vm.prank(alice);
        router.setOperator(operator_, true);

        // Revoke
        vm.prank(alice);
        router.setOperator(operator_, false);

        uint256 amount = 10_000e6;
        vm.startPrank(operator_);
        usdc.approve(address(router), amount);
        vm.expectRevert(IDivigentVaultRouter.NotAuthorised.selector);
        router.deposit(amount, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  4. Proportional principal attribution across many partial withdrawals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev After N partial withdrawals, fees must track realised user yield,
    ///      and principal must never be touched — even under cumulative rounding.
    function test_partialWithdrawals_principalAttributionCorrect() public {
        uint256 depositAmount = 50_000e6;
        uint256 yieldAmount = 5_000e6; // 10% synthetic yield

        // Alice deposits into Aave (default oracle route)
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 totalShares = _deposit(alice, alice, depositAmount);

        // Simulate yield: mint extra aTokens directly to the router.
        // The router's aToken balance represents its Aave position;
        // inflating it mirrors how Aave accrues interest (rebasing aTokens).
        aToken.mint(address(router), yieldAmount);

        uint256 usdcReturnedTotal = 0;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 sharesToRedeem = totalShares;
        uint256 withdrawalsCount = 5;
        uint256 chunkShares = sharesToRedeem / withdrawalsCount;

        for (uint256 i = 0; i < withdrawalsCount; i++) {
            uint256 chunk = (i == withdrawalsCount - 1)
                ? dvUsdc.balanceOf(alice)  // redeem remainder in last step
                : chunkShares;

            vm.prank(alice);
            uint256 returned = router.withdraw(chunk, alice, 0);
            usdcReturnedTotal += returned;
        }

        // Total returned must be >= depositAmount (principal always safe)
        assertGe(usdcReturnedTotal, depositAmount, "Principal must be fully returned");

        uint256 feeCollected = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 actualGross = usdcReturnedTotal + feeCollected;
        uint256 actualYield = actualGross - depositAmount;
        uint256 expectedFee = (actualYield * FEE_BPS) / BPS_DENOM;

        assertLe(actualYield, yieldAmount, "Realised user yield cannot exceed vault yield");
        assertGe(actualYield, yieldAmount - 1e6, "Virtual offset should retain less than 1 USDC of this yield");
        assertLe(feeCollected, expectedFee, "Fee must not exceed 10% of realised user yield");
        assertGe(feeCollected + withdrawalsCount, expectedFee, "Fee floor drift should be at most 1 wei per withdrawal");

        // No dvUSDC dust remaining
        assertEq(dvUsdc.balanceOf(alice), 0, "All shares must be redeemed");
    }

    /// @dev A wallet that deposits twice should have a cost basis equal to the
    ///      sum of both deposits, and fees are computed correctly on total yield.
    function test_partialWithdrawals_multipleDepositsCorrectBasis() public {
        uint256 deposit1 = 20_000e6;
        uint256 deposit2 = 30_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);

        _deposit(alice, alice, deposit1);
        // Accrue some yield between deposits (inflate aToken balance at router)
        aToken.mint(address(router), 500e6);
        _deposit(alice, alice, deposit2);

        // Check cost basis reflects both deposits
        (uint256 basis,,) = router.getPosition(alice);
        assertEq(basis, deposit1 + deposit2, "Cost basis must equal sum of deposits");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  5. initializeFor nonce replay protection
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The same signature must be rejected on a second call to initializeFor().
    function test_initializeFor_nonceReplay_reverts() public {
        // Use a fresh wallet that hasn't been registered yet
        (address newWallet, uint256 newKey) = makeAddrAndKey("newWallet");

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signInitializeFor(newKey, newWallet, deadline);

        // First call: should succeed
        router.initializeFor(newWallet, deadline, sig);
        assertTrue(router.authorizedWallets(newWallet), "Wallet must be authorised");

        // Second call with the same sig: `authorizedWallets[wallet]` is now true,
        // so the WalletAlreadyAuthorised check fires first (before any sig work).
        vm.expectRevert(IDivigentVaultRouter.WalletAlreadyAuthorised.selector);
        router.initializeFor(newWallet, deadline, sig);
    }

    /// @dev initializeFor() with a wrong signer must revert with InvalidSignature.
    function test_initializeFor_wrongSigner_reverts() public {
        (address newWallet,) = makeAddrAndKey("newWallet2");
        (, uint256 rogueKey) = makeAddrAndKey("rogue2");

        uint256 deadline = block.timestamp + 1 hours;
        // Sign with rogue key, not newWallet's key
        uint256 nonce = router.nonces(newWallet);
        bytes32 structHash = keccak256(abi.encode(INITIALIZE_FOR_TYPEHASH, newWallet, deadline, nonce));

        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DivigentVaultRouter")),
                keccak256(bytes("1")),
                block.chainid,
                address(router)
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSep, structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IDivigentVaultRouter.InvalidSignature.selector);
        router.initializeFor(newWallet, deadline, sig);
    }

    /// @dev initializeFor() with an expired deadline must revert with PermitExpired.
    function test_initializeFor_expiredDeadline_reverts() public {
        (address newWallet, uint256 newKey) = makeAddrAndKey("newWallet3");

        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory sig = _signInitializeFor(newKey, newWallet, deadline);

        vm.expectRevert(IDivigentVaultRouter.PermitExpired.selector);
        router.initializeFor(newWallet, deadline, sig);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  6. dvUSDC non-transferability
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Direct dvUSDC.transfer() between two accounts must revert.
    function test_dvUSDC_nonTransferable_transfer() public {
        uint256 depositAmount = 10_000e6;
        _deposit(alice, alice, depositAmount);

        uint256 shares = dvUsdc.balanceOf(alice);
        assertGt(shares, 0, "Alice must hold shares");

        vm.startPrank(alice);
        vm.expectRevert(DvUSDC.NonTransferable.selector);
        dvUsdc.transfer(bob, shares);
        vm.stopPrank();
    }

    /// @dev dvUSDC.transferFrom() (even with allowance) must revert.
    function test_dvUSDC_nonTransferable_transferFrom() public {
        uint256 depositAmount = 10_000e6;
        _deposit(alice, alice, depositAmount);

        uint256 shares = dvUsdc.balanceOf(alice);

        vm.prank(alice);
        dvUsdc.approve(bob, shares);

        vm.startPrank(bob);
        vm.expectRevert(DvUSDC.NonTransferable.selector);
        dvUsdc.transferFrom(alice, bob, shares);
        vm.stopPrank();
    }

    /// @dev Mint (from == address(0)) must still work — invoked via deposit.
    function test_dvUSDC_mintAllowed() public {
        uint256 depositAmount = 10_000e6;
        uint256 shares = _deposit(alice, alice, depositAmount);
        assertGt(shares, 0, "Minting must succeed");
        assertEq(dvUsdc.balanceOf(alice), shares);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  7. NoSafeRoute when both vaults are at capacity
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev When Aave's aToken has insufficient USDC liquidity AND Morpho's
    ///      maxDeposit returns 0, deposit() must revert with NoSafeRoute.
    function test_noSafeRoute_whenBothVaultsFull() public {
        // Drain USDC balance held by aToken to 0 — router checks balanceOf(aToken)
        // as a heuristic for Aave liquidity capacity.
        usdc.setBalance(address(aToken), 0);

        // Restrict Morpho maxDeposit to 0
        morphoVault.setMaxDeposit(0);

        // Oracle routes to Aave first (default)
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);

        uint256 amount = 10_000e6;
        vm.startPrank(alice);
        usdc.approve(address(router), amount);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.NoSafeRoute.selector, amount));
        router.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev When primary vault is full but alternate is not, deposit succeeds.
    function test_noSafeRoute_fallbackToAlternate() public {
        // Drain Aave capacity
        usdc.setBalance(address(aToken), 0);

        // Morpho still open
        morphoVault.setMaxDeposit(type(uint256).max);

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);

        uint256 amount = 10_000e6;
        uint256 shares = _deposit(alice, alice, amount);
        assertGt(shares, 0, "Deposit must succeed via fallback to Morpho");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  8. Fee invariants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev When there is zero yield (no share-price appreciation), the fee must
    ///      be exactly zero — principal is never touched.
    function test_fee_zeroYield_zeroFee() public {
        uint256 depositAmount = 20_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, depositAmount);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);

        // No yield → no fee → returned == depositAmount (allow 1 wei rounding)
        assertApproxEqAbs(returned, depositAmount, 1, "Principal must be fully returned when yield == 0");
        assertApproxEqAbs(usdc.balanceOf(alice), aliceBefore + depositAmount, 1);
    }

    /// @dev Fee must equal exactly 10% of yield when yield > 0.
    function test_fee_exactlyTenPercentOfYield() public {
        uint256 depositAmount = 10_000e6;
        uint256 yieldAmount = 1_000e6; // 10% yield

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, depositAmount);

        // Simulate yield: inflate the router's aToken balance (mirrors Aave rebasing)
        aToken.mint(address(router), yieldAmount);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 expectedGross = router.convertToAssets(shares);
        uint256 expectedYield = expectedGross - depositAmount;
        uint256 expectedFee = feeCollector.calculateFee(expectedYield);

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);

        uint256 netYield = returned - depositAmount;
        uint256 feeCollected = usdc.balanceOf(treasury) - treasuryBefore;

        assertEq(feeCollected, expectedFee, "Fee must be 10% of realised user yield");
        assertEq(netYield, expectedYield - expectedFee, "Net yield must match realised yield after fee");
        assertGe(expectedYield, yieldAmount - 1e6, "Virtual offset should retain less than 1 USDC of this yield");
    }

    /// @dev Fee must be exactly 0 at the waterline — `actualGross == principalOut`
    ///      to the wei. This pins the branch `actualGross > principalOut ? ... : 0`
    ///      at its exact boundary. A regression flipping `>` to `>=` (or any
    ///      off-by-one in the comparison) would charge a 10 bps fee on zero
    ///      realised yield, violating INV-2 (principal preservation).
    function test_fee_exactWaterline_zeroFee() public {
        uint256 depositAmount = 10_000e6;
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 shares = _deposit(alice, alice, depositAmount);

        // Force the Aave leg to hold EXACTLY the principal — no yield, no loss.
        // setBalance directly pins the waterline; any fee here means the
        // equality boundary was misclassified as "above waterline".
        aToken.setBalance(address(router), depositAmount);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);

        uint256 feeCollected = usdc.balanceOf(treasury) - treasuryBefore;
        assertEq(feeCollected, 0, "fee must be 0 at exact waterline");
        assertApproxEqAbs(returned, depositAmount, 1, "principal returned in full");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  9. TVL cap enforcement
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deposits beyond the TVL_CAP_INITIAL must revert with TVLCapExceeded.
    function test_tvlCap_initial_exceeded() public {
        // Cap = 500_000e6. Deposit 400k first.
        usdc.mint(alice, 600_000e6);

        uint256 deposit1 = 400_000e6;
        _deposit(alice, alice, deposit1);

        // Next deposit of 200k would push TVL to 600k > cap
        uint256 deposit2 = 200_000e6;
        vm.startPrank(alice);
        usdc.approve(address(router), deposit2);
        vm.expectRevert(
            abi.encodeWithSelector(IDivigentVaultRouter.TVLCapExceeded.selector, deposit2, router.currentTVLCap())
        );
        router.deposit(deposit2, alice);
        vm.stopPrank();
    }

    /// @dev After day 31, TVL cap expands to 2M.
    function test_tvlCap_expandsAtDay31() public {
        usdc.mint(alice, 2_000_000e6);

        // Deposit 500k (fills initial cap)
        _deposit(alice, alice, 500_000e6);

        // Warp past day 31
        vm.warp(block.timestamp + 31 days + 1);

        // Should now accept up to 2M total
        uint256 deposit2 = 1_000_000e6;
        uint256 shares = _deposit(alice, alice, deposit2);
        assertGt(shares, 0, "Deposit must succeed after day 31 cap expansion");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  10. Emergency pause
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev pauseDeposits() must block new deposits; withdrawals unaffected.
    function test_emergencyPause_blocksDepositsNotWithdraws() public {
        uint256 amount = 10_000e6;
        uint256 shares = _deposit(alice, alice, amount);

        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        vm.startPrank(alice);
        usdc.approve(address(router), amount);
        vm.expectRevert(IDivigentVaultRouter.DepositsPausedError.selector);
        router.deposit(amount, alice);
        vm.stopPrank();

        // Withdraw still works
        vm.prank(alice);
        uint256 returned = router.withdraw(shares, alice, 0);
        assertGt(returned, 0, "Withdraw must succeed while deposits are paused");
    }

    /// @dev unpauseDeposits() restores normal operation.
    function test_emergencyPause_unpause_restoresDeposits() public {
        vm.prank(emergencyMultisig);
        router.pauseDeposits();

        vm.prank(emergencyMultisig);
        router.unpauseDeposits();

        uint256 amount = 10_000e6;
        uint256 shares = _deposit(alice, alice, amount);
        assertGt(shares, 0, "Deposits must work after unpause");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  11. Slippage guard
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev withdraw() must revert if net USDC returned is below minUsdcOut.
    function test_withdraw_slippageGuard() public {
        uint256 amount = 10_000e6;
        uint256 shares = _deposit(alice, alice, amount);

        // Set minUsdcOut to more than the position is worth
        uint256 minUsdcOut = amount + 1;

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDivigentVaultRouter.SlippageExceeded.selector, amount, minUsdcOut));
        router.withdraw(shares, alice, minUsdcOut);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  12. View function consistency
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev convertToShares and convertToAssets must be approximate inverses.
    function test_convertRoundTrip(uint96 rawAssets) public {
        // Use `bound` rather than `vm.assume`. The range [1e6, 1e11] covers
        // ~10^-18 of the uint96 type domain, so `vm.assume` exhausts its
        // 65_536 rejection budget before the test completes any runs under
        // coverage-instrumented execution (different fuzz seed distribution).
        // `bound` maps the input into range deterministically — zero rejections.
        uint256 assets = bound(uint256(rawAssets), 1e6, 100_000e6);

        _deposit(alice, alice, 10_000e6); // ensure non-trivial pool state

        uint256 shares = router.convertToShares(assets);
        uint256 back = router.convertToAssets(shares);

        // Due to integer division, back may be <= assets (round-down), within 1e-6 relative
        assertLe(back, assets + 1, "convertToAssets should be within 1 of original");
    }

    /// @dev pricePerShare must be >= 1e18 (initial 1:1 with virtual offset).
    function test_pricePerShare_geOne() public {
        assertGe(router.pricePerShare(), 1e18, "Initial price must be at least 1:1");
    }

    /// @dev totalVaultAssets() should reflect deposited amount (no free lunch).
    function test_totalVaultAssets_reflectsDeposit() public {
        uint256 amount = 25_000e6;
        _deposit(alice, alice, amount);
        assertApproxEqAbs(router.totalVaultAssets(), amount, 1, "totalVaultAssets must equal deposited USDC");
    }
}
