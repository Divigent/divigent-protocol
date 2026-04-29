// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "./helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Tiny Supply + Huge Donation
/// @notice Pins the first-depositor inflation defence and the behaviour of
///         the preview functions under a degenerate but reachable regime:
///         a very small `totalSupply` paired with a very large donation
///         (aToken mint, direct Morpho `accrueYield`, etc.).
///
///         Without a meaningful virtual offset in the share
///         maths, an attacker could:
///           1. Deposit 1 wei (gets 1 share).
///           2. Donate 1e18 USDC directly to the router's aToken balance.
///           3. Victim deposits → `shares = amount / (1 + donation) ≈ 0`.
///           4. Attacker redeems 1 share for all the donation + victim
///              principal.
///
///         The router's defence is twofold:
///           - `VIRTUAL_OFFSET` raises the donation cost needed to force
///             zero-share or large floor-loss deposit outcomes.
///             (victim always gets at least 1 share).
///           - The attack is NOT PROFITABLE: the attacker sacrifices the
///             donation, which goes into the vault's PPS and benefits every
///             holder proportionally. The attacker recovers less than they
///             invested (`deposit + donation`).
///
///         The tests below pin both properties: preview math doesn't break,
///         and the attacker's net is strictly negative.
contract TinySupplyDonationTest is Actions {
    /// @notice After a huge donation, `previewDeposit` must not return 0
    ///         for a legitimately-sized deposit — the user must still get
    ///         at least 1 share for any deposit above `MIN_DEPOSIT`.
    function test_previewDeposit_afterHugeDonation_returnsNonZero() public {
        address seeder = makeActor("tiny_seeder", 1_000_000e6);
        address victim = makeActor("tiny_victim", 1_000_000e6);

        // Warp past day 91 to remove the TVL cap — donations inflate
        // `totalVaultAssets` well beyond the 500k/2M early caps, so without
        // this the victim's deposit would revert for an unrelated reason.
        fastForward(92 days);

        useAaveRoute();

        userDeposits(seeder, 10e6);
        // Donate 10M USDC worth of aTokens directly.
        aToken.mint(address(router), 10_000_000e6);

        uint256 preview = router.previewDeposit(1_000e6);
        assertGt(preview, 0, "previewDeposit must not be zero even after huge donation");

        uint256 actualShares = userDeposits(victim, 1_000e6);
        assertEq(actualShares, preview, "actual mint matches preview (same tx, no drift)");
    }

    /// @notice The first-depositor inflation attack is UNPROFITABLE: even
    ///         though the attacker can redeem more than their deposit
    ///         principal (the donation inflated the PPS), they cannot
    ///         recover more than they invested overall (`deposit + donation`).
    ///         The donation is effectively burned / proportionally given to
    ///         other holders.
    function test_firstDepositorInflation_attackIsUnprofitable() public {
        address attacker = makeActor("tiny_attacker", 10_000_000e6);
        address victim = makeActor("tiny_victim_2", 1_000_000e6);

        fastForward(92 days); // remove TVL cap
        useAaveRoute();

        uint256 attackerCapitalBefore = usdc.balanceOf(attacker);
        uint256 victimCapitalBefore = usdc.balanceOf(victim);

        // 1. Attacker deposits minimum.
        uint256 attackerShares = userDeposits(attacker, 10e6);
        assertGt(attackerShares, 0, "attacker gets shares");

        // 2. Attacker donates 100k USDC directly into the vault (aToken mint).
        //    This reduces their external USDC balance by 100k.
        uint256 donation = 100_000e6;
        usdc.burn(attacker, donation);
        aToken.mint(address(router), donation);

        // 3. Victim deposits 50k USDC.
        uint256 victimShares = userDeposits(victim, 50_000e6);
        assertGt(victimShares, 0, "victim still gets shares despite inflated PPS");

        // 4. Attacker redeems all shares.
        uint256 attackerReturn = userWithdraws(attacker, attackerShares);

        // UNPROFITABLE: attacker's total invested was (deposit + donation) =
        // 10 + 100_000 = 100_010 USDC. Their redeemable return is less than
        // that, so the "attack" is a net loss.
        uint256 attackerInvested = 10e6 + donation;
        assertLt(attackerReturn, attackerInvested, "attack is unprofitable - return below invested");

        // VICTIM PROTECTED: victim can still withdraw their fair share. This
        // is the load-bearing safety property — the victim is not robbed,
        // the attacker just hurt themselves.
        uint256 victimReturn = userWithdraws(victim, victimShares);

        // Victim recovers close to their 50k principal. Under the donation
        // attack the attacker inflates PPS ~10_000× before the victim
        // deposits; each 1-wei virtual-offset floor in victim-shares
        // amplifies to ~O(inflated PPS) wei in victim-USDC output. Observed
        // drift across (attacker deposit → donation → victim deposit →
        // attacker redeem → victim redeem) is ~3.7k wei. Tolerance of 5k
        // wei (0.005 USDC) is 1.4× the arithmetic bound — tight enough to
        // flag any real siphon (≥0.01 USDC would fail), loose enough to
        // absorb legitimate PPS-amplified floor drift. The earlier 10_000
        // wei bound left double headroom; 5_000 halves that.
        assertApproxEqAbs(victimReturn, 50_000e6, 5_000, "victim recovers principal within PPS-amplified floor drift");

        // Silence unused-warning for the initial capital snapshots
        // (retained for debug-on-failure visibility).
        attackerCapitalBefore;
        victimCapitalBefore;
    }

    /// @notice `previewWithdrawNet` must not revert under large donations for
    ///         serviceable requests. Impossible requests fail with typed max
    ///         deliverable data instead of silently clamping to wallet shares.
    function test_previewWithdrawNet_tinySupplyHugeAssets_doesNotOverflow() public {
        address seeder = makeActor("tiny_preview_seeder", 100_000e6);

        fastForward(92 days); // remove TVL cap before donation
        useAaveRoute();

        userDeposits(seeder, 10e6);

        // Inflate assets massively via aToken donation (type(uint64).max).
        aToken.mint(address(router), type(uint64).max);

        uint256 shares = router.previewWithdrawNet(1e6, seeder);
        assertGt(shares, 0, "preview returns non-zero for small request");

        uint256 walletShares = dvUsdc.balanceOf(seeder);
        uint256 maxDeliverable = router.previewRedeem(walletShares, seeder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDivigentVaultRouter.UnserviceableNet.selector,
                type(uint128).max,
                maxDeliverable
            )
        );
        router.previewWithdrawNet(type(uint128).max, seeder);
    }
}
