// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";
import {RouterIntegrationBase} from "./RouterIntegrationBase.sol";

/// @notice Multi-user accounting: one wallet's withdrawals must not mutate another
///         wallet's recorded principal, dvUSDC balance, or USDC balance.
contract DivigentVaultRouterAccountingIntegrationTest is RouterIntegrationBase {
    /// @dev Alice and Bob deposit into different venues (mixed TVL). When Alice
    ///      partially withdraws, Bob's on-chain accounting rows stay unchanged.
    function test_accounting_alicePartialWithdraw_leavesBobLedgerUntouched() public {
        uint256 aliceDeposit = 50_000e6;
        uint256 bobDeposit = 20_000e6;

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 aliceShares = _deposit(alice, alice, aliceDeposit);

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);
        uint256 bobShares = _deposit(bob, bob, bobDeposit);

        (uint256 bobBasisBefore,,) = router.getPosition(bob);
        uint256 bobDvBefore = dvUsdc.balanceOf(bob);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        assertEq(bobBasisBefore, bobDeposit);
        assertEq(bobDvBefore, bobShares);

        vm.prank(alice);
        router.withdraw(aliceShares / 2, alice, 0);

        assertEq(dvUsdc.balanceOf(bob), bobDvBefore, "Bob dvUSDC balance must not change");
        assertEq(usdc.balanceOf(bob), bobUsdcBefore, "Bob should not receive USDC from Alice's withdraw");

        (uint256 bobBasisAfter,,) = router.getPosition(bob);
        assertEq(bobBasisAfter, bobBasisBefore);
        assertEq(bobBasisAfter, bobDeposit);
    }

    /// @dev Same mixed TVL setup as above; when Bob partially withdraws, Alice's
    ///      principal, dvUSDC, and USDC balances must stay unchanged.
    function test_accounting_bobPartialWithdraw_leavesAliceLedgerUntouched() public {
        uint256 aliceDeposit = 50_000e6;
        uint256 bobDeposit = 20_000e6;

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 aliceShares = _deposit(alice, alice, aliceDeposit);

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);
        uint256 bobShares = _deposit(bob, bob, bobDeposit);

        (uint256 aliceBasisBefore,,) = router.getPosition(alice);
        uint256 aliceDvBefore = dvUsdc.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        assertEq(aliceBasisBefore, aliceDeposit);
        assertEq(aliceDvBefore, aliceShares);

        vm.prank(bob);
        router.withdraw(bobShares / 2, bob, 0);

        assertEq(dvUsdc.balanceOf(alice), aliceDvBefore, "Alice dvUSDC balance must not change");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "Alice should not receive USDC from Bob's withdraw");

        (uint256 aliceBasisAfter,,) = router.getPosition(alice);
        assertEq(aliceBasisAfter, aliceBasisBefore);
        assertEq(aliceBasisAfter, aliceDeposit);
    }
}
