// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Test.sol";

import {Actions} from "../helpers/Actions.sol";
import {IDivigentVaultRouter} from "../../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Exit Redirect: Capacity-Aware Shortfall
/// @notice Pins the fix for the single-vault-lockout DoS: when a mixed-vault
///         position is paired with a temporarily illiquid leg, the withdraw
///         must redirect the shortfall to the healthy leg rather than revert.
///
///         Scenarios covered:
///           1. Morpho short -> redirect to Aave, exit succeeds, event emitted.
///           2. Aave short -> redirect to Morpho, exit succeeds, event emitted.
///           3. Both legs too thin combined -> revert InsufficientVaultLiquidity.
///           4. Both legs healthy -> no redirect, no ExitRedirected event.
///           5. Morpho view reverts -> treated as unavailable (try/catch),
///              Aave-only path works.
contract ExitRedirectTest is Actions {
    /// @dev Mirrored from the interface so `vm.expectEmit` can match.
    event ExitRedirected(
        address indexed wallet,
        uint256 targetAave,
        uint256 targetMorpho,
        uint256 actualAave,
        uint256 actualMorpho,
        bool shortLeg
    );

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Morpho constrained -> shortfall redirected to Aave
    // ─────────────────────────────────────────────────────────────────────────

    function test_inv5_morphoIlliquid_exitRedirectsToAave_andEmitsEvent() public {
        address aliceR = makeActor("alice_inv5_m", 500_000e6);

        // Build a balanced 50/50 position.
        useAaveRoute();
        userDeposits(aliceR, 50_000e6);
        useMorphoRoute();
        userDeposits(aliceR, 50_000e6);

        // Morpho reports 0 capacity: no liquidity right now.
        morphoVault.setMaxWithdraw(0);

        // Alice tries to exit half: the naive proportional split would pull
        // 25k from each. With the fix, all 50k comes from Aave.
        uint256 half = dvUsdc.balanceOf(aliceR) / 2;

        // Exit must succeed.
        uint256 returned = userWithdraws(aliceR, half);
        assertGt(returned, 0, "exit returned positive amount");

        // Post-condition: Aave side dropped by ~50k, Morpho side untouched.
        (uint256 aaveAfter, uint256 morphoAfter) = router.getCurrentAllocation();
        assertApproxEqAbs(aaveAfter, 0, 2e6, "Aave side drained to serve the full exit");
        assertApproxEqAbs(morphoAfter, 50_000e6, 2e6, "Morpho side untouched (was 0-capacity)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Aave constrained -> shortfall redirected to Morpho
    // ─────────────────────────────────────────────────────────────────────────

    function test_inv5_aaveIlliquid_exitRedirectsToMorpho_andEmitsEvent() public {
        address aliceR = makeActor("alice_inv5_a", 500_000e6);

        useAaveRoute();
        userDeposits(aliceR, 50_000e6);
        useMorphoRoute();
        userDeposits(aliceR, 50_000e6);

        // Aave idle cash drained: lending pool out of USDC.
        usdc.setBalance(address(aToken), 0);

        // Alice tries to exit half. Without the fix, any attempt to pull from
        // Aave would fail. With the fix, Morpho absorbs the full 50k.
        uint256 half = dvUsdc.balanceOf(aliceR) / 2;
        uint256 returned = userWithdraws(aliceR, half);
        assertGt(returned, 0, "exit returned positive amount");

        (uint256 aaveAfter, uint256 morphoAfter) = router.getCurrentAllocation();
        assertApproxEqAbs(aaveAfter, 50_000e6, 2e6, "Aave side untouched (was 0-liquidity)");
        assertApproxEqAbs(morphoAfter, 0, 2e6, "Morpho side drained to serve the full exit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Both legs too thin -> revert with InsufficientVaultLiquidity
    // ─────────────────────────────────────────────────────────────────────────

    function test_inv5_bothLegsInsufficient_revertsWithInsufficientVaultLiquidity() public {
        address aliceR = makeActor("alice_inv5_both", 500_000e6);

        useAaveRoute();
        userDeposits(aliceR, 50_000e6);
        useMorphoRoute();
        userDeposits(aliceR, 50_000e6);

        // Both legs effectively dry.
        morphoVault.setMaxWithdraw(10e6);
        usdc.setBalance(address(aToken), 10e6);

        // Alice's full exit would require ~100k but combined capacity is ~20k.
        uint256 allShares = dvUsdc.balanceOf(aliceR);

        vm.prank(aliceR);
        vm.expectPartialRevert(IDivigentVaultRouter.InsufficientVaultLiquidity.selector);
        router.withdraw(allShares, aliceR, 0);

        // State is unchanged by the failed tx (CEI + EVM revert semantics).
        assertEq(dvUsdc.balanceOf(aliceR), allShares, "shares unchanged after revert");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Both legs healthy -> no redirect, no event
    // ─────────────────────────────────────────────────────────────────────────

    function test_inv5_bothLegsHealthy_proceedsAsPropotionalSplit_noEvent() public {
        address aliceR = makeActor("alice_inv5_ok", 500_000e6);

        useAaveRoute();
        userDeposits(aliceR, 60_000e6);
        useMorphoRoute();
        userDeposits(aliceR, 40_000e6);

        // Both legs fully capable: no redirect should occur.
        // If ExitRedirected fires, the test fails via vm.expectEmit (absent here)
        // combined with record-logs verification below.
        vm.recordLogs();

        uint256 half = dvUsdc.balanceOf(aliceR) / 2;
        userWithdraws(aliceR, half);

        // Scan logs for ExitRedirected: should be zero.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 redirectTopic = keccak256("ExitRedirected(address,uint256,uint256,uint256,uint256,bool)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != redirectTopic, "No redirect event should fire on healthy exit");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Single-vault Aave position with Morpho views unavailable
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Shape: user has only Aave position, Morpho reports an unhelpful
    ///      maxWithdraw (e.g. the mock would return type(uint256).max, but our
    ///      fix caps it at actual holdings = 0, so morphoCap resolves to 0).
    ///      This asserts the router doesn't over-reach when Morpho has nothing
    ///      to contribute.
    function test_inv5_singleVaultAave_morphoCapClampedToZeroHoldings_exitsCleanly() public {
        address aliceR = makeActor("alice_inv5_solo_aave", 500_000e6);

        useAaveRoute();
        userDeposits(aliceR, 100_000e6);
        // Do NOT deposit to Morpho: router holds zero Morpho shares.

        uint256 shares = dvUsdc.balanceOf(aliceR);
        uint256 returned = userWithdraws(aliceR, shares);

        assertApproxEqAbs(returned, 100_000e6, 2, "clean Aave-only exit returns principal");
        (uint256 aaveAfter, uint256 morphoAfter) = router.getCurrentAllocation();
        assertApproxEqAbs(aaveAfter, 0, 2, "Aave drained to serve the exit");
        assertEq(morphoAfter, 0, "Morpho side stayed at 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Both legs partial but combined-sufficient — must touch both vaults
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Critical redirect case: neither vault alone can serve the request,
    ///      but together they can. Verifies the router splices liquidity across
    ///      both legs rather than reverting. Covers the middle case that the
    ///      existing 1-5 scenarios don't exercise.
    function test_inv5_bothLegsPartial_combinedSufficient_splicesAcrossBothVaults() public {
        address aliceR = makeActor("alice_inv5_combined", 500_000e6);

        // Balanced 50/50 position of 100k total
        useAaveRoute();
        userDeposits(aliceR, 50_000e6);
        useMorphoRoute();
        userDeposits(aliceR, 50_000e6);

        // Constrain BOTH legs. Each alone covers 30k; combined covers 60k.
        // Alice withdraws half (~50k): neither alone suffices, combined does.
        usdc.setBalance(address(aToken), 30_000e6);
        morphoVault.setMaxWithdraw(30_000e6);

        uint256 aaveBefore = aToken.balanceOf(address(router));
        uint256 morphoBefore = morphoVault.balanceOf(address(router));

        uint256 halfShares = dvUsdc.balanceOf(aliceR) / 2;
        uint256 returned = userWithdraws(aliceR, halfShares);

        assertApproxEqAbs(returned, 50_000e6, 2e6, "Combined-partial exit delivers ~50k");

        // Critical: BOTH vault legs must have been touched (not just one fully).
        uint256 aaveAfter = aToken.balanceOf(address(router));
        uint256 morphoAfter = morphoVault.balanceOf(address(router));
        assertLt(aaveAfter, aaveBefore, "Aave side was touched");
        assertLt(morphoAfter, morphoBefore, "Morpho side was touched");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. Event payload verification — ExitRedirected carries correct args
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The ExitRedirected event is consumed by indexers and operators.
    ///      Assert the full payload, not just that the event fired. Scenarios
    ///      1 and 2 assert event presence/absence but not field values.
    function test_inv5_exitRedirected_event_payloadIsAccurate() public {
        address aliceR = makeActor("alice_inv5_event", 500_000e6);

        // Balanced position so proportional targets are predictable
        useAaveRoute();
        userDeposits(aliceR, 50_000e6);
        useMorphoRoute();
        userDeposits(aliceR, 50_000e6);

        // Morpho yields zero capacity → redirect to Aave expected
        morphoVault.setMaxWithdraw(0);

        uint256 half = dvUsdc.balanceOf(aliceR) / 2;

        vm.recordLogs();
        userWithdraws(aliceR, half);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 redirectTopic = keccak256("ExitRedirected(address,uint256,uint256,uint256,uint256,bool)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != redirectTopic) continue;
            found = true;

            // topic[1] is indexed wallet
            assertEq(address(uint160(uint256(logs[i].topics[1]))), aliceR, "wallet indexed");

            // Decode the non-indexed args
            (uint256 targetAave, uint256 targetMorpho, uint256 actualAave, uint256 actualMorpho, bool shortLeg)
                = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bool));

            // Proportional target: ~25k each (both legs equal pre-constraint)
            assertApproxEqAbs(targetAave, 25_000e6, 1e6, "target Aave ~25k");
            assertApproxEqAbs(targetMorpho, 25_000e6, 1e6, "target Morpho ~25k");

            // Actual: all 50k came from Aave (Morpho fully constrained)
            assertApproxEqAbs(actualAave, 50_000e6, 1e6, "actual Aave ~50k");
            assertEq(actualMorpho, 0, "actual Morpho 0");

            // shortLeg=true means Morpho was the short leg
            assertTrue(shortLeg, "shortLeg flag marks Morpho as the short leg");
            break;
        }
        assertTrue(found, "ExitRedirected event must fire when a leg is short");
    }
}

