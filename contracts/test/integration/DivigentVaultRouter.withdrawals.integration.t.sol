// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDivigentYieldOracle} from "../../src/interfaces/IDivigentYieldOracle.sol";
import {RouterIntegrationBase} from "./RouterIntegrationBase.sol";

contract DivigentVaultRouterWithdrawalsIntegrationTest is RouterIntegrationBase {
    /// @dev When assets are split across Aave and Morpho, withdrawing half the
    ///      shares should redeem proportionally from both venues.
    function test_withdraw_mixedVaults_redeemsProportionally() public {
        uint256 aaveDeposit = 10_000e6;
        uint256 morphoDeposit = 30_000e6;

        // Seed a mixed position: first deposit into Aave, then switch the oracle
        // and deposit into Morpho. With no yield, share math stays 1:1 and the
        // expected proportional redemption is easy to reason about.
        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 aaveShares = _deposit(alice, alice, aaveDeposit);

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);
        uint256 morphoShares = _deposit(alice, alice, morphoDeposit);

        uint256 totalShares = aaveShares + morphoShares;
        uint256 sharesToWithdraw = totalShares / 2;

        assertEq(aToken.balanceOf(address(router)), aaveDeposit, "Aave position seed mismatch");
        assertEq(morphoVault.totalAssets_(), morphoDeposit, "Morpho position seed mismatch");

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 returned = router.withdraw(sharesToWithdraw, alice, 0);

        // Half the shares should redeem half of the total assets, with no fee
        // because no yield was introduced in either venue.
        assertEq(returned, 20_000e6, "Half withdrawal should return half the total assets");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + returned, "Alice should receive the withdrawn USDC");

        // Total held before withdraw = 40k. Half withdrawal should pull:
        //   fromAave   = 20k * 10k / 40k = 5k
        //   fromMorpho = 20k - 5k        = 15k
        assertEq(aToken.balanceOf(address(router)), 5_000e6, "Aave remainder should reflect proportional withdrawal");
        assertEq(morphoVault.totalAssets_(), 15_000e6, "Morpho remainder should reflect proportional withdrawal");
        assertEq(dvUsdc.balanceOf(alice), totalShares - sharesToWithdraw, "Remaining shares mismatch");

        (uint256 remainingBasis,, uint256 accruedYield) = router.getPosition(alice);
        assertEq(remainingBasis, 20_000e6, "Remaining principal should be halved");
        assertEq(accruedYield, 0, "No yield should accrue in the zero-yield mixed-vault scenario");
    }

    /// @dev When Aave is the dominant venue and has accrued yield, a partial mixed-vault
    ///      withdrawal should redeem proportionally and charge fees only on the realized yield.
    function test_withdraw_mixedVaults_aaveDominant_chargesFeeOnlyOnYield() public {
        uint256 aaveDeposit = 30_000e6;
        uint256 morphoDeposit = 10_000e6;
        uint256 aaveYield = 4_000e6;

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.AAVE);
        uint256 aaveShares = _deposit(alice, alice, aaveDeposit);

        oracle.setOptimalVault(IDivigentYieldOracle.VaultType.MORPHO);
        uint256 morphoShares = _deposit(alice, alice, morphoDeposit);

        // Inflate the Aave side only so fee computation has to be realized through
        // the mixed-vault proportional redemption path.
        aToken.mint(address(router), aaveYield);

        uint256 totalShares = aaveShares + morphoShares;
        uint256 sharesToWithdraw = totalShares / 2;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 returned = router.withdraw(sharesToWithdraw, alice, 0);

        // Total assets before withdraw = 44k, so half the shares redeem 22k gross.
        // Principal attributed to half the shares = 20k, realized yield = 2k, fee = 200.
        assertEq(returned, 21_800e6, "Net return should equal principal plus yield minus 10% fee");
        assertApproxEqAbs(
            usdc.balanceOf(treasury) - treasuryBefore,
            200e6,
            1,
            "Treasury should receive 10% of realized yield"
        );
        assertEq(usdc.balanceOf(alice), aliceBefore + returned, "Alice should receive the net withdrawn amount");

        // Proportional gross split before fees:
        //   fromAave   = 22k * 34k / 44k = 17k
        //   fromMorpho = 22k - 17k       = 5k
        assertApproxEqAbs(
            aToken.balanceOf(address(router)),
            17_000e6,
            1,
            "Aave remainder should reflect mixed-vault proportional redemption"
        );
        assertApproxEqAbs(
            morphoVault.totalAssets_(),
            5_000e6,
            1,
            "Morpho remainder should reflect mixed-vault proportional redemption"
        );

        (uint256 remainingBasis,, uint256 accruedYield) = router.getPosition(alice);
        assertEq(remainingBasis, 20_000e6, "Remaining basis should be reduced proportionally");
        assertEq(accruedYield, 2_000e6, "Remaining yield should stay on the unredeemed shares");
    }
}
