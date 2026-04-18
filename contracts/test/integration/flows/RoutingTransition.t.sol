// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Actions} from "../helpers/Actions.sol";

/// @title  Routing Transition End-to-End Flow
/// @notice Models the steady-state production scenario: the oracle prefers one
///         vault for a stretch, then market conditions shift and it begins
///         preferring the other. Different users deposit at different times
///         and end up in different vaults. Yield accrues in both. Everyone exits.
///
///         Key property pinned: a deposit is routed by the oracle's preference
///         AT THE TIME OF DEPOSIT. Subsequent oracle changes do NOT migrate
///         existing positions. The protocol naturally accumulates a mixed
///         allocation through this drift, which is the realistic mid-life state.
///
///         What this catches:
///           - Any bug that retroactively rebalances existing positions on oracle flip.
///           - Any bug where the second user's deposit displaces or affects the first.
///           - Any bug in how yield from one vault credits to users who only
///             deposited via the other.
///           - The full mixed-vault withdraw split, exercised by users who didn't
///             deliberately split their own deposits.
contract RoutingTransitionTest is Actions {
    function test_routingTransition_oracleFlipDoesNotMigrateExistingPositions() public {
        address aliceR = makeActor("alice_route", 500_000e6);
        address bobR = makeActor("bob_route", 500_000e6);

        // ----- Phase 1: Oracle prefers Aave; Alice deposits early ---------

        useAaveRoute();
        uint256 aliceDeposit = 60_000e6;
        uint256 aliceShares = userDeposits(aliceR, aliceDeposit);

        // After Alice: 100% of pool in Aave, 0% in Morpho.
        ProtocolSnap memory afterAlice = snapProtocol();
        assertApproxEqAbs(afterAlice.aaveAssets, aliceDeposit, 1, "Phase1: Aave got Alice's deposit");
        assertEq(afterAlice.morphoAssets, 0, "Phase1: Morpho still empty");

        // ----- Phase 2: Time passes, oracle flips to Morpho ---------------

        fastForward(7 days);
        useMorphoRoute();

        // Critical: flipping the oracle is a NO-OP on existing protocol state.
        // Using the custom `assertEq(ProtocolSnap, ProtocolSnap)` overload gives
        // field-by-field failure diagnostics: if any field drifts, the error
        // message points at the specific field, not a generic struct mismatch.
        ProtocolSnap memory afterFlip = snapProtocol();
        assertEq(afterFlip, afterAlice, "Phase2: oracle flip is a no-op on protocol state");
        assertEq(dvUsdc.balanceOf(aliceR), aliceShares, "Phase2: Alice's shares unchanged by oracle flip");

        // ----- Phase 3: Bob deposits AFTER the flip; routes to Morpho -----

        uint256 bobDeposit = 40_000e6;
        uint256 bobShares = userDeposits(bobR, bobDeposit);

        ProtocolSnap memory afterBob = snapProtocol();
        assertApproxEqAbs(
            afterBob.aaveAssets,
            aliceDeposit,
            1,
            "Phase3: Aave side STILL only has Alice's original deposit (no migration)"
        );
        assertApproxEqAbs(afterBob.morphoAssets, bobDeposit, 1, "Phase3: Morpho side has Bob's new deposit");

        // Alice's accounting must be untouched by Bob's deposit.
        WalletSnap memory aliceAfterBob = snap(aliceR);
        assertEq(aliceAfterBob.dvUsdcBalance, aliceShares, "Phase3: Alice's shares untouched by Bob's deposit");
        assertEq(aliceAfterBob.costBasis, aliceDeposit, "Phase3: Alice's costBasis untouched by Bob's deposit");

        // ----- Phase 4: Yield accrues in both vaults simultaneously -------

        fastForward(30 days);
        uint256 aaveYield = 1_200e6; // ~60% of pool got 1.2k
        uint256 morphoYield = 800e6; // ~40% of pool got 0.8k
        uint256 totalYield = aaveYield + morphoYield;
        accrueYieldInBothVaults(aaveYield, morphoYield);

        // ----- Phase 5: Alice exits, exercising the mixed-vault split -----
        //
        // Alice never personally deposited into Morpho, but her exit will pull
        // proportionally from BOTH vaults because the router's pool is mixed.
        // Her yield is her share of the COMBINED pool yield, not just Aave's.

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceReturn = userWithdraws(aliceR, aliceShares);
        uint256 aliceFee = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 aliceYield = (aliceReturn + aliceFee) - aliceDeposit;

        // Alice's expected yield: her share of total pool yield.
        // She owns aliceShares / (aliceShares + bobShares) of the pool.
        uint256 expectedAliceYield = (totalYield * aliceShares) / (aliceShares + bobShares);

        assertApproxEqAbs(
            aliceYield,
            expectedAliceYield,
            4,
            "Phase5: Alice's yield matches her share-weighted slice of COMBINED pool yield"
        );
        assertEq(aliceFee, expectedFee(aliceYield), "Phase5: Alice's fee == 10% of her realised yield");

        // Bob's accounting unchanged by Alice's exit.
        WalletSnap memory bobAfterAlice = snap(bobR);
        assertEq(bobAfterAlice.dvUsdcBalance, bobShares, "Phase5: Bob's shares untouched by Alice's exit");
        assertEq(bobAfterAlice.costBasis, bobDeposit, "Phase5: Bob's costBasis untouched by Alice's exit");

        // ----- Phase 6: Bob exits; receives his share of combined yield ---

        uint256 treasuryBeforeBob = usdc.balanceOf(treasury);
        uint256 bobReturn = userWithdraws(bobR, bobShares);
        uint256 bobFee = usdc.balanceOf(treasury) - treasuryBeforeBob;
        uint256 bobYield = (bobReturn + bobFee) - bobDeposit;

        uint256 expectedBobYield = (totalYield * bobShares) / (aliceShares + bobShares);

        assertApproxEqAbs(
            bobYield, expectedBobYield, 4, "Phase6: Bob's yield matches his share-weighted slice of COMBINED pool yield"
        );
        assertEq(bobFee, expectedFee(bobYield), "Phase6: Bob's fee == 10% of his realised yield");

        // ----- Conservation -------------------------------------------------

        uint256 totalToUsers = aliceReturn + bobReturn;
        uint256 totalToTreasury = aliceFee + bobFee;
        assertApproxEqAbs(
            totalToUsers + totalToTreasury,
            (aliceDeposit + bobDeposit) + totalYield,
            8,
            "Conservation: users + treasury == deposits + yield (rounding tolerance)"
        );

        assertEq(dvUsdc.totalSupply(), 0, "All shares burned");
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds no USDC (INV-4)");
    }
}
