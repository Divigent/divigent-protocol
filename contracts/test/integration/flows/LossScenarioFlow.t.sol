// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Loss Scenario — End-to-End Flow
/// @notice Stresses the never-before-tested code path where the underlying vault
///         loses value (Aave bad-debt event, Morpho underwater). The router's
///         `actualGross < principalOut` branch sets `actualYield = 0`, so:
///           - The fee charged is exactly zero (INV-2: principal preservation).
///           - Each user takes a proportional haircut on their principal.
///           - costBasis accounting stays internally consistent across users.
///
///         What this catches:
///           - Any bug that accidentally charges fee on losses.
///           - Any bug that distributes losses unevenly across users.
///           - Any bug that breaks pricePerShare under PPS < 1.0.
///           - Any bug in the `actualGross > principalOut ? ... : 0` ternary.
contract LossScenarioFlowTest is Actions {
    function test_loss_principalHaircutDistributedFairly_noFeeCharged() public {
        // ─── Setup: two depositors share the pool ───────────────────────────

        address aliceL = makeActor("alice_loss", 100_000e6);
        address bobL = makeActor("bob_loss", 100_000e6);

        useAaveRoute();
        uint256 aliceDeposit = 60_000e6;
        uint256 bobDeposit = 40_000e6;
        uint256 totalDeposit = aliceDeposit + bobDeposit;

        uint256 aliceShares = userDeposits(aliceL, aliceDeposit);
        uint256 bobShares = userDeposits(bobL, bobDeposit);

        assertEq(router.pricePerShare(), 1e18, "Pre-loss: PPS == 1.0");

        // ─── Simulate Aave bad debt: 20% write-down of router's aToken claim ─
        //
        // In real Aave, bad debt manifests as the aToken/USDC ratio degrading.
        // Mocking it as a direct reduction of the router's aToken balance is the
        // closest faithful model — the router's claim on the pool has shrunk.

        uint256 lossPct = 20; // 20% write-down
        uint256 lossAmount = (totalDeposit * lossPct) / 100; // $20k of $100k
        uint256 aaveAfter = totalDeposit - lossAmount;
        aToken.setBalance(address(router), aaveAfter);

        // ─── Sanity: PPS dropped below 1.0 ──────────────────────────────────

        uint256 ppsAfterLoss = router.pricePerShare();
        assertLt(ppsAfterLoss, 1e18, "Post-loss: PPS < 1.0");

        // Both users should report 0 accruedYield (loss is not "negative yield";
        // it shows up as currentValue < costBasis instead).
        WalletSnap memory aliceLossSnap = snap(aliceL);
        WalletSnap memory bobLossSnap = snap(bobL);
        assertEq(aliceLossSnap.accruedYield, 0, "Alice: loss reported as 0 accruedYield");
        assertEq(bobLossSnap.accruedYield, 0, "Bob:   loss reported as 0 accruedYield");
        assertLt(aliceLossSnap.currentValue, aliceDeposit, "Alice: currentValue < costBasis");
        assertLt(bobLossSnap.currentValue, bobDeposit, "Bob:   currentValue < costBasis");

        // The combined currentValue should equal totalVaultAssets within rounding
        // (proves the loss is shared proportionally via PPS, not lopsided).
        ProtocolSnap memory protoLoss = snapProtocol();
        assertEq(protoLoss.totalVaultAssets, aaveAfter, "Pool's totalVaultAssets reflects the write-down exactly");
        assertApproxEqAbs(
            aliceLossSnap.currentValue + bobLossSnap.currentValue,
            aaveAfter,
            2,
            "Sum of users' currentValue == totalVaultAssets (proportional sharing)"
        );

        // ─── Alice partially withdraws under loss ───────────────────────────

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 partialShares = aliceShares / 2;
        uint256 alicePartial = userWithdraws(aliceL, partialShares);

        // INV-2: NO fee on a loss-path withdraw, ever.
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "INV-2: no fee charged on loss-path partial withdraw");

        // Alice's partial return reflects the proportional loss. Half her shares
        // at PPS ≈ 0.8 → expect roughly $24k (40% of $60k) for $30k of nominal principal.
        uint256 expectedPartial = (aliceDeposit / 2) * (totalDeposit - lossAmount) / totalDeposit;
        assertApproxEqAbs(alicePartial, expectedPartial, 4, "Alice's partial return reflects proportional loss");

        // ─── Alice fully exits ──────────────────────────────────────────────

        uint256 aliceFinal = userWithdraws(aliceL, dvUsdc.balanceOf(aliceL));

        assertEq(usdc.balanceOf(treasury), treasuryBefore, "Still no fee accumulated");
        assertEq(dvUsdc.balanceOf(aliceL), 0, "Alice fully exited");

        // Total Alice received over both withdraws ≈ her share of post-loss pool.
        uint256 aliceTotal = alicePartial + aliceFinal;
        uint256 expectedAliceTotal = (aliceDeposit * (totalDeposit - lossAmount)) / totalDeposit;
        assertApproxEqAbs(
            aliceTotal, expectedAliceTotal, 4, "Alice's total return == her proportional share of post-loss pool"
        );

        // ─── Bob's position unchanged by Alice's exits ──────────────────────

        WalletSnap memory bobAfterAlice = snap(bobL);
        assertEq(bobAfterAlice.dvUsdcBalance, bobShares, "Bob's shares untouched");
        assertEq(bobAfterAlice.costBasis, bobDeposit, "Bob's costBasis untouched");

        // Bob's currentValue should still reflect his proportional share of what's left.
        ProtocolSnap memory protoMid = snapProtocol();
        assertApproxEqAbs(
            bobAfterAlice.currentValue,
            protoMid.totalVaultAssets,
            4,
            "Bob's currentValue == remaining pool (he's the sole holder now)"
        );

        // ─── Bob fully exits ────────────────────────────────────────────────

        uint256 bobReturn = userWithdraws(bobL, bobShares);
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "Final: treasury collected nothing on the loss");

        uint256 expectedBobTotal = (bobDeposit * (totalDeposit - lossAmount)) / totalDeposit;
        assertApproxEqAbs(bobReturn, expectedBobTotal, 4, "Bob's return == his proportional share of post-loss pool");

        // ─── Conservation: users + treasury == totalDeposit - lossAmount ────

        uint256 totalReturned = aliceTotal + bobReturn;
        uint256 totalToTreasury = usdc.balanceOf(treasury) - treasuryBefore;
        assertEq(totalToTreasury, 0, "Conservation: zero fee under loss");
        assertApproxEqAbs(
            totalReturned, totalDeposit - lossAmount, 8, "Conservation: users recovered exactly post-loss pool value"
        );

        // ─── Cleanup ────────────────────────────────────────────────────────

        assertEq(dvUsdc.totalSupply(), 0, "All shares burned");
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds no USDC (INV-4)");
        assertLe(aToken.balanceOf(address(router)), 4, "aToken dust <= 4 wei");
    }
}
