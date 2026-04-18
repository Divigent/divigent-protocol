// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Inflation Protection: End-to-End Flow
/// @notice Verifies the virtual-offset protection (`+1` in numerator and denominator
///         of `_assetsToShares`) actually defends against the classic ERC-4626
///         first-depositor inflation attack.
///
///         The attack pattern:
///           1. Attacker becomes the first depositor with MIN_DEPOSIT.
///           2. Attacker "donates" a large amount of aTokens directly to the router
///              (in production: by supplying USDC to Aave on behalf of the router).
///           3. PPS spikes; the attacker holds the only shares.
///           4. Victim deposits: share math now rounds heavily down.
///           5. Attacker withdraws and tries to recover deposit + donation.
///
///         What the virtual offset enforces:
///           - Victim never mints zero shares for a positive deposit (assuming
///             reasonable donation-to-deposit ratio).
///           - Victim's loss is bounded: they never lose the majority of their deposit.
///           - Attacker's donation is permanently locked in the pool. Their net
///             position (withdraw + fee they paid - deposit - donation) is negative --
///             the attack is unprofitable.
contract InflationProtectionTest is Actions {
    function test_donationAttack_virtualOffsetMakesAttackUnprofitable() public {
        // ─── Setup: attacker and victim, both well-funded ──────────────────

        address attacker = makeActor("attacker_donate", 2_000_000e6);
        address victim = makeActor("victim_donate", 1_000_000e6);

        useAaveRoute();

        // ─── Phase 1: Attacker becomes first depositor with MIN_DEPOSIT ───

        uint256 attackerDeposit = router.MIN_DEPOSIT(); // 10 USDC
        uint256 attackerShares = userDeposits(attacker, attackerDeposit);

        assertEq(attackerShares, attackerDeposit, "Phase1: first deposit mints 1:1");
        assertEq(router.pricePerShare(), 1e18, "Phase1: PPS = 1.0");

        // ─── Phase 2: Attacker "donates" aTokens to inflate share value ───
        //
        // In production, this is done by supplying USDC to Aave with the router
        // as the recipient: Aave mints aTokens to the router, none of which the
        // attacker controls. We simulate by minting aTokens directly to the router.

        uint256 donationAmount = 100_000e6; // attacker spends $100k to inflate
        aToken.mint(address(router), donationAmount);

        uint256 ppsAfterDonation = router.pricePerShare();
        assertGt(ppsAfterDonation, 1_000e18, "Phase2: PPS spikes by ~10,000x after donation");

        // ─── Phase 3: Victim deposits ─────────────────────────────────────

        uint256 victimDeposit = 50_000e6; // a substantial deposit
        uint256 victimShares = userDeposits(victim, victimDeposit);

        // Virtual-offset protection: victim must mint >0 shares despite the inflated
        // PPS. Without the +1 offset, the share calculation would round to zero and
        // the deposit would revert with ZeroAmount, locking out new depositors entirely.
        assertGt(victimShares, 0, "Phase3: virtual offset protects against zero-share mint");

        // ─── Phase 4: Victim withdraws ────────────────────────────────────

        uint256 victimReturn = userWithdraws(victim, victimShares);

        // The virtual offset doesn't make the attack zero-cost to the victim --
        // they still take some loss because their share is small relative to the
        // donated aTokens. But that loss is BOUNDED. They must never lose the
        // majority of their deposit to a donation attack.
        assertGt(
            victimReturn,
            (victimDeposit * 9) / 10,
            "Phase4: victim's loss bounded to <10% of deposit (virtual-offset protection)"
        );

        // ─── Phase 5: Attacker exits ──────────────────────────────────────

        // Treasury delta is not asserted directly here: the headline check is
        // attacker's net P&L, computed below. The fee they paid to treasury makes
        // them MORE unprofitable, never less, so it's bounded into the assertion.
        uint256 attackerReturn = userWithdraws(attacker, attackerShares);

        // ─── The headline assertion: attacker is UNPROFITABLE ──────────────
        //
        // Attacker's total cost = MIN_DEPOSIT + donationAmount.
        // Attacker's gross gain = attackerReturn (USDC out to attacker).
        // Attacker also paid attackerFeeCollected to treasury: they don't recover that.
        // Net = (attackerReturn) - (attackerDeposit + donationAmount).
        // Must be negative for the attack to be uneconomic.

        int256 attackerCost = int256(attackerDeposit + donationAmount);
        int256 attackerNetPnL = int256(attackerReturn) - attackerCost;

        assertLt(attackerNetPnL, 0, "Phase5: attacker's net P&L is negative: attack is unprofitable");

        // The attacker should lose substantially more than they extracted from
        // the victim. If attacker's loss < victim's loss, the attack would be
        // a value transfer, profitable for attacker. Verify the inequality.
        uint256 attackerLoss = uint256(-attackerNetPnL);
        uint256 victimLoss = victimDeposit - victimReturn;

        assertGt(
            attackerLoss,
            victimLoss,
            "Phase5: attacker loses MORE than victim -> attack is value-destructive for attacker"
        );

        // ─── Final cleanup ──────────────────────────────────────────────────

        assertEq(dvUsdc.totalSupply(), 0, "All shares burned");
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds no USDC (INV-4)");

        // Some aToken dust likely remains in the router due to virtual-offset rounding
        // at extreme PPS values. The dust is permanently locked: it's not a leak
        // to anyone, but it documents that the protection has a residual cost.
        // No assertion on the dust size; it's a property of the protection itself.
    }
}
