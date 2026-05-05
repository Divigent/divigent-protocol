// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.sol";

import {IDivigentVaultRouter} from "../../src/interfaces/IDivigentVaultRouter.sol";

/// @title  Cold-path Morpho-view-gas regression
/// @notice The Morpho `convertToAssets` cold-storage cost on Base mainnet was
///         measured by the auditor at ~220_000 gas. The pre-fix constant of
///         100_000 reliably ran out, set `morphoReachable = false`, and made
///         every withdraw on a Morpho-touching wallet revert with
///         `MorphoUnreachable` — locking the Morpho leg of the protocol.
///
///         The default `forge test` mode silently passed because storage
///         stays warm across calls within a single test transaction. Only
///         `forge test --isolate` reproduces the cold-path that the audit
///         identified, because `--isolate` runs each top-level call in a
///         fresh transaction context with cold storage.
///
///         Run with:
///             forge test --match-contract ForkMorphoGasBudgetTest --isolate
///
///         This file pins three regressions:
///           1. `withdrawCapacity()` reports `morphoReachable == true` from
///              cold storage when the router holds Morpho shares.
///           2. A direct `convertToAssets` probe at the configured budget
///              survives the cold path.
///           3. The user-facing `withdraw()` function — the actual production
///              failure mode the audit identified — succeeds end-to-end and
///              produces all expected wallet/vault state changes.
contract ForkMorphoGasBudgetTest is ForkBase {
    function setUp() public override {
        super.setUp();
        _seedOracle();
    }

    /// @notice Forces the router into a Morpho-only position by zeroing
    ///         Aave's idle USDC reserve BEFORE the first deposit. The
    ///         router's `_canAllocate` check for Aave reads
    ///         `USDC.balanceOf(A_TOKEN) >= amount`, so an empty reserve
    ///         makes Aave unable to accept; the deposit falls through to
    ///         Morpho regardless of the oracle's preferred route.
    ///
    ///         Result: `aToken.balanceOf(router) == 0` and
    ///         `morphoVault.balanceOf(router) > 0`. Cold-path tests then
    ///         exercise the Morpho leg in isolation, with no Aave leg
    ///         masking behaviour.
    function _buildMorphoOnlyExposure(uint256 amount) internal {
        deal(BASE_USDC, BASE_AAVE_ATOKEN_USDC, 0);
        _deposit(alice, amount);

        require(
            morphoVault.balanceOf(address(router)) > 0,
            "precondition: router must hold Morpho shares"
        );
        require(
            aToken.balanceOf(address(router)) == 0,
            "precondition: router must NOT hold Aave shares (Morpho-only)"
        );
    }

    /// @notice With Morpho exposure present, `withdrawCapacity()` must
    ///         report `morphoReachable == true` — even on a cold storage
    ///         read. This fails on the audited code (100_000 gas stipend)
    ///         under `--isolate` and passes after the fix (350_000 floor).
    function testFork_withdrawCapacity_morphoReachable_coldPath() public {
        _buildMorphoOnlyExposure(50_000e6);

        // Top-level external call → executes as its own transaction under
        // `--isolate`, so the SLOADs inside Morpho's `convertToAssets` are
        // cold and incur the full ~220k gas cost the audit measured.
        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();

        assertTrue(
            cap.morphoReachable,
            "F01 regression: cold-path Morpho view ran out of gas"
        );
        assertGt(
            cap.morphoAssetsHeld,
            0,
            "Morpho leg must value its shares when reachable"
        );
    }

    /// @notice A direct, minimal probe: forwarding the router's currently
    ///         configured `morphoViewGas` to `MORPHO_VAULT.convertToAssets`
    ///         must not revert under cold storage. Locks the headroom on
    ///         the floor value (`MIN_MORPHO_VIEW_GAS = 350_000`) so any
    ///         future regression that lowers the floor below the live
    ///         cold-path cost surfaces here.
    function testFork_morphoViewGas_directCall_coldPath() public {
        _buildMorphoOnlyExposure(50_000e6);

        uint256 shares = morphoVault.balanceOf(address(router));
        uint256 budget = router.morphoViewGas();

        // Top-level call → cold under `--isolate`.
        try morphoVault.convertToAssets{gas: budget}(shares) returns (uint256 assets) {
            assertGt(assets, 0, "convertToAssets returned zero with positive shares");
        } catch {
            revert("morphoViewGas insufficient for cold convertToAssets");
        }
    }

    /// @notice After the multisig raises `morphoViewGas` to a higher value
    ///         (still within bounds), `withdrawCapacity()` continues to
    ///         report `morphoReachable == true`. Exercises the setter
    ///         end-to-end against live Morpho rather than mocks. (Note:
    ///         this is a smoke check — it does NOT prove that the call
    ///         site reads the state variable. That property is pinned by
    ///         `test_setMorphoViewGas_wiredIntoPlanWithdrawCapacity` in
    ///         `WithdrawCapacity.t.sol` against a configurable mock.)
    function testFork_setMorphoViewGas_higherValue_stillReachable() public {
        _buildMorphoOnlyExposure(50_000e6);

        vm.prank(multisig);
        router.setMorphoViewGas(750_000);

        IDivigentVaultRouter.VaultCapacity memory cap = router.withdrawCapacity();
        assertTrue(cap.morphoReachable, "raised budget must remain reachable");
    }

    /// @notice Exercises the user-facing withdraw path with Morpho exposure.
    ///
    ///         This test exercises the user-facing
    ///         `router.withdraw(...)` path end-to-end against live Morpho
    ///         on Base under `--isolate`, asserting all the visible
    ///         effects of a successful exit.
    ///
    ///         On the audited code (100_000 gas stipend) under
    ///         `--isolate`, this reverts with `MorphoUnreachable` and the
    ///         test fails. On the fixed code (350_000 floor) the cold-path
    ///         convertToAssets clears, the withdraw plan executes, and all
    ///         four post-conditions below hold.
    function testFork_withdraw_succeedsUnderColdMorphoPath() public {
        uint256 depositAmt = 50_000e6;
        _buildMorphoOnlyExposure(depositAmt);

        uint256 sharesToBurn       = dvUsdc.balanceOf(alice);
        uint256 morphoSharesBefore = morphoVault.balanceOf(address(router));
        uint256 aliceUsdcBefore    = usdc.balanceOf(alice);

        require(sharesToBurn > 0,        "precondition: alice must hold dvUSDC");
        require(morphoSharesBefore > 0,  "precondition: router must hold Morpho shares");

        // Top-level call → cold storage under `--isolate`. This is the
        // exact transaction the audit said reverted with MorphoUnreachable
        // before the fix.
        vm.prank(alice);
        uint256 returned = router.withdraw(sharesToBurn, alice, 0);

        // 1. The wallet receives non-zero USDC.
        assertGt(returned, 0, "withdraw must return non-zero USDC");

        // 2. dvUSDC is fully burned on a full exit.
        assertEq(
            dvUsdc.balanceOf(alice),
            0,
            "all dvUSDC must be burned on full exit"
        );

        // 3. Router's Morpho shares decreased to ~0 (full exit drains the
        //    leg modulo unavoidable rounding dust on the redeem path).
        uint256 morphoSharesAfter = morphoVault.balanceOf(address(router));
        assertLt(
            morphoSharesAfter,
            morphoSharesBefore,
            "Morpho shares must decrease (the leg actually serviced the exit)"
        );
        // A near-zero residual is acceptable — Morpho's withdraw(assets,...)
        // path may leave dust shares due to share/asset rounding.
        assertLe(
            morphoSharesAfter,
            morphoSharesBefore / 1_000_000,
            "Morpho residual must be dust-level on a full exit"
        );

        // 4. INV-4: no USDC stuck in the router after the call returns.
        assertEq(
            usdc.balanceOf(address(router)),
            0,
            "INV-4: router must not retain USDC after withdraw"
        );

        // Wallet USDC balance moved by exactly the returned amount.
        assertEq(
            usdc.balanceOf(alice),
            aliceUsdcBefore + returned,
            "wallet USDC balance must increase by `returned`"
        );
    }
}
