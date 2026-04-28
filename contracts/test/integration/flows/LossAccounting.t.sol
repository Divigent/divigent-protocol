// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Loss Accounting: costBasis Under Vault Loss
/// @notice Tests the specific code path where actualGross < principalOut (vault
///         lost value). The router floors actualYield at 0 and charges zero fee,
///         but still reduces costBasisUSDC by the full principalOut.
///
///         This is correct behavior: the loss is real, the user absorbs it, and
///         the accounting must remain consistent for future withdrawals. These
///         tests verify that:
///           1. costBasis is reduced by principalOut even when user receives less
///           2. Fee is exactly 0 (never negative, never on phantom yield)
///           3. After full exit during loss, costBasis == 0 exactly
///           4. Multi-step partial exits under loss sum correctly
///           5. costBasis-per-share never produces underflow
///           6. Second user entering after loss has clean accounting
contract LossAccountingTest is Actions {
    address internal aliceL;
    address internal bobL;

    uint256 constant DEPOSIT = 50_000e6;
    uint256 constant LOSS_PCT = 30; // 30% write-down

    function setUp() public override {
        super.setUp();
        aliceL = makeActor("alice_lcb", 200_000e6);
        bobL = makeActor("bob_lcb", 200_000e6);
        useAaveRoute();
    }

    /// @notice Core test: partial withdraw during loss, then full exit.
    ///         Verifies costBasis accounting at every step.
    function test_loss_costBasis_partialThenFullExit() public {
        uint256 aliceShares = userDeposits(aliceL, DEPOSIT);
        assertEq(router.costBasisUSDC(aliceL), DEPOSIT, "Post-deposit costBasis == deposit");

        uint256 lossAmount = (DEPOSIT * LOSS_PCT) / 100; // $15k loss
        uint256 postLossAssets = DEPOSIT - lossAmount; // $35k remaining
        aToken.setBalance(address(router), postLossAssets);

        // Verify loss is reflected
        assertEq(router.totalVaultAssets(), postLossAssets, "TVA reflects loss");
        assertLt(router.pricePerShare(), 1e18, "PPS < 1.0 after loss");

        // costBasis unchanged by loss (it tracks deposits, not market value)
        assertEq(router.costBasisUSDC(aliceL), DEPOSIT, "costBasis unchanged by vault loss");

        uint256 partialShares = (aliceShares * 40) / 100;
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        uint256 expectedPrincipalOut = (DEPOSIT * partialShares) / aliceShares;
        uint256 partialReturn = userWithdraws(aliceL, partialShares);

        // costBasis reduced by principalOut (not by actualGross)
        uint256 expectedRemainingCostBasis = DEPOSIT - expectedPrincipalOut;
        assertEq(
            router.costBasisUSDC(aliceL),
            expectedRemainingCostBasis,
            "costBasis reduced by principalOut, not by actualGross"
        );

        // User received LESS than principalOut (loss scenario)
        assertLt(partialReturn, expectedPrincipalOut, "User received less than principalOut (loss)");

        // Zero fee on loss path
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "Zero fee on loss-path withdrawal");

        uint256 remainingShares = dvUsdc.balanceOf(aliceL);
        assertGt(remainingShares, 0, "Still has shares");

        uint256 finalReturn = userWithdraws(aliceL, remainingShares);

        // costBasis EXACTLY zero after full exit
        assertEq(router.costBasisUSDC(aliceL), 0, "costBasis == 0 after full exit during loss");
        assertEq(dvUsdc.balanceOf(aliceL), 0, "Zero shares after full exit");

        // Total received == post-loss vault value (within rounding)
        uint256 totalReceived = partialReturn + finalReturn;
        assertApproxEqAbs(totalReceived, postLossAssets, 4, "Total received == post-loss assets");

        // Still zero fees
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "Still zero fee after full exit");
    }

    /// @notice Multi-step: 5 equal partial withdrawals under loss.
    ///         costBasis should converge to 0 with no underflow.
    function test_loss_costBasis_manyPartialWithdrawals() public {
        uint256 shares = userDeposits(aliceL, DEPOSIT);

        // 30% loss
        aToken.setBalance(address(router), (DEPOSIT * 70) / 100);

        uint256 totalReceived;
        uint256 sharesPer = shares / 5;

        for (uint256 i = 0; i < 4; i++) {
            uint256 costBefore = router.costBasisUSDC(aliceL);
            uint256 sharesBefore = dvUsdc.balanceOf(aliceL);

            uint256 expectedPrincipalOut = (costBefore * sharesPer) / sharesBefore;

            uint256 received = userWithdraws(aliceL, sharesPer);
            totalReceived += received;

            // Fee always 0 during loss
            assertEq(usdc.balanceOf(treasury), 0, "No fee during loss partials");

            // costBasis decreased by principalOut
            assertEq(
                router.costBasisUSDC(aliceL),
                costBefore - expectedPrincipalOut,
                "costBasis tracks principalOut per partial"
            );

            // principalOut > received (loss scenario)
            assertGe(expectedPrincipalOut, received, "principalOut >= received under loss");
        }

        // Final exit: remaining shares
        uint256 remaining = dvUsdc.balanceOf(aliceL);
        totalReceived += userWithdraws(aliceL, remaining);

        // Clean exit
        assertEq(router.costBasisUSDC(aliceL), 0, "costBasis == 0 after 5 partial exits");
        assertEq(dvUsdc.balanceOf(aliceL), 0, "Zero shares");
        assertApproxEqAbs(totalReceived, (DEPOSIT * 70) / 100, 8, "Total == post-loss assets");
    }

    /// @notice Two users: Alice deposits, loss occurs, Bob deposits AFTER loss,
    ///         both withdraw. Bob's costBasis should be clean (no legacy loss).
    function test_loss_costBasis_newDepositorAfterLoss() public {
        // Alice deposits $50k
        userDeposits(aliceL, DEPOSIT);

        // 30% loss: vault has $35k
        uint256 postLossAssets = (DEPOSIT * 70) / 100;
        aToken.setBalance(address(router), postLossAssets);

        // Bob deposits $50k AFTER the loss
        uint256 bobShares = userDeposits(bobL, DEPOSIT);
        assertEq(router.costBasisUSDC(bobL), DEPOSIT, "Bob's costBasis == his deposit");

        // Total assets now: $35k (Alice's depreciated) + $50k (Bob's fresh) = $85k
        assertEq(router.totalVaultAssets(), postLossAssets + DEPOSIT, "TVA == 35k + 50k");

        // Bob withdraws immediately — should get ~$50k back (his deposit, no loss)
        uint256 bobReturn = userWithdraws(bobL, bobShares);

        // Bob should get approximately his deposit back (he entered at post-loss PPS)
        assertApproxEqAbs(bobReturn, DEPOSIT, 4, "Bob gets ~deposit back (entered after loss)");
        assertEq(router.costBasisUSDC(bobL), 0, "Bob's costBasis == 0 after exit");
        assertEq(usdc.balanceOf(treasury), 0, "No fee (no yield for Bob)");
    }

    /// @notice Loss then recovery: deposit, loss, yield (partial recovery), withdraw.
    ///         Fee should only apply to yield ABOVE the loss recovery point.
    function test_loss_costBasis_partialRecoveryThenWithdraw() public {
        uint256 shares = userDeposits(aliceL, DEPOSIT);

        // 20% loss: $50k → $40k
        uint256 postLossAssets = (DEPOSIT * 80) / 100;
        aToken.setBalance(address(router), postLossAssets);

        // Partial recovery: $5k yield → vault has $45k (still underwater vs $50k deposit)
        aToken.mint(address(router), 5_000e6);

        // Still underwater
        WalletSnap memory s = snap(aliceL);
        assertEq(s.accruedYield, 0, "Still underwater: accruedYield == 0");
        assertLt(s.currentValue, DEPOSIT, "currentValue < costBasis (still in loss)");

        // Withdraw all
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 returned = userWithdraws(aliceL, shares);

        // Fee should be 0 because actualGross ($45k) < principalOut ($50k)
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "No fee when still underwater after partial recovery");
        assertEq(router.costBasisUSDC(aliceL), 0, "costBasis == 0 after full exit");
        assertApproxEqAbs(returned, 45_000e6, 4, "Received post-loss + partial recovery amount");
    }

    /// @notice Loss then full recovery + profit: fee should only apply to the
    ///         profit portion above original costBasis.
    function test_loss_costBasis_fullRecoveryPlusProfit() public {
        uint256 shares = userDeposits(aliceL, DEPOSIT);

        // 20% loss: $50k → $40k
        aToken.setBalance(address(router), (DEPOSIT * 80) / 100);

        // Full recovery + profit: $15k yield → vault has $55k ($5k above deposit)
        aToken.mint(address(router), 15_000e6);

        // Now in profit
        WalletSnap memory s = snap(aliceL);
        assertGt(s.currentValue, DEPOSIT, "currentValue > costBasis (recovered + profit)");
        assertGt(s.accruedYield, 0, "accruedYield > 0 (real profit above costBasis)");

        // Withdraw all
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 returned = userWithdraws(aliceL, shares);
        uint256 feeCollected = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 actualGross = returned + feeCollected;
        uint256 actualYield = actualGross - DEPOSIT;

        // Fee should be 10% of realised yield above costBasis. The virtual
        // offset retains a small slice of the recovered profit.
        uint256 grossExpected = 55_000e6;
        uint256 yieldExpected = grossExpected - DEPOSIT; // $5k
        uint256 residualBound = (yieldExpected * 1e6) / (DEPOSIT + 1e6) + 4;

        assertLe(actualYield, yieldExpected, "Realised profit cannot exceed recovered profit");
        assertGe(actualYield + residualBound, yieldExpected, "Profit residual is bounded by virtual share ownership");
        assertEq(feeCollected, feeCollector.calculateFee(actualYield), "Fee only on realised profit above costBasis");
        assertEq(returned, actualGross - feeCollected, "Received gross minus fee");
        assertEq(router.costBasisUSDC(aliceL), 0, "costBasis == 0");
    }

    /// @notice Edge: 99% loss (near-total wipeout).
    ///         costBasis accounting must not underflow or produce phantom values.
    function test_loss_costBasis_nearTotalWipeout() public {
        uint256 shares = userDeposits(aliceL, DEPOSIT);

        // 99% loss: $50k → $500
        aToken.setBalance(address(router), DEPOSIT / 100);

        assertEq(router.costBasisUSDC(aliceL), DEPOSIT, "costBasis unchanged by 99% loss");

        uint256 returned = userWithdraws(aliceL, shares);

        assertEq(router.costBasisUSDC(aliceL), 0, "costBasis == 0 after exit from 99% loss");
        assertApproxEqAbs(returned, DEPOSIT / 100, 4, "Received the 1% that survived");
        assertEq(usdc.balanceOf(treasury), 0, "Zero fee on massive loss");
    }
}
