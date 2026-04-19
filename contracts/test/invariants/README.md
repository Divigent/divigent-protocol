# Divigent Protocol Invariants

29 invariants across 8 protocol components. Each is handler-driven: the
fuzzer picks random actions from a bounded action space (`deposit`,
`permitDeposit`, `withdraw`, `accrueYield`, `accrueLoss`, `setOperator`,
`togglePause`, `shockAaveIdle`, `shockMorphoMaxWithdraw`, …) and every
invariant is re-asserted after each step.

The six weak/static invariants the original 30-item registry carried
(Router-C/D, FeeCollector-C/D/E, Accounting-C) were removed in favour of
four adversarial replacements: Router-N (fee-zero on underwater exits),
Router-O (capacity ↔ revert liveness), Accounting-E (per-user
non-dilution), and Operator-A (operator never accumulates USDC).

## Invariant Registry

### VaultRouter (13 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| Router-A | Aggregate solvency | `totalVaultAssets + fees + losses >= sum(costBasis)` within rounding | INV-1 |
| Router-B | Per-user solvency | `currentValue + fees + yield + losses >= costBasis` per actor | INV-1 (per-user) |
| Router-E | Statelessness | `USDC.balanceOf(router) == 0` between txs | INV-4 |
| Router-F | Permissionless exit | Withdraw not blocked by deposit pause | INV-5 |
| Router-G | Zero shares → zero cost basis | `shares[u] == 0 => costBasis[u] == 0` | Accounting |
| Router-H | Nonzero cost basis → nonzero shares | `costBasis[u] > 0 => shares[u] > 0` | Accounting |
| Router-I | Vault asset decomposition | `totalVaultAssets == aave + morpho` | Structural |
| Router-J | TVL cap respected | `totalAssets <= cap + yieldAccrued` | TVL cap |
| Router-K | Authorized wallet consistency | `shares[u] > 0 => authorizedWallets[u]` | Access control |
| Router-L | TVL cap monotonic | `currentTVLCap` never decreases | TVL schedule |
| Router-M | Pause blocks deposits | `depositsPaused => deposit() reverts` | Emergency |
| **Router-N** | **Fee-zero on underwater exit** | For actors where `gross ≤ costBasis`, actual withdraw charges 0 fee | INV-2 (adversarial) |
| **Router-O** | **Capacity ↔ revert liveness** | `withdraw()` succeeds iff `aaveCap + morphoCap ≥ grossUSDC`, else reverts `InsufficientVaultLiquidity` | Exit redirect |

### dvUSDC (3 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| dvUSDC-A | Non-transferable | P2P transfers always revert | INV-F |
| dvUSDC-B | Access control | `dvUSDC.VAULT_ROUTER() == router` | Structural |
| dvUSDC-C | Supply consistency | `totalSupply == sum(balanceOf[actor])` | ERC-20 |

### FeeCollector (2 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| FeeCollector-A | Pass-through | `USDC.balanceOf(feeCollector) == 0` | INV-H |
| FeeCollector-B | Access control | `VAULT_ROUTER == router` | Structural |

### Oracle (3 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| Oracle-A | PPS monotonic | `pricePerShare()` non-decreasing absent loss | INV-I |
| Oracle-B | Observation time valid | `lastObservationTime <= block.timestamp` | Time safety |
| Oracle-C | Freshness consistency | `isFresh() <=> elapsed <= MAX_STALENESS` | Staleness |

### Share-Asset (2 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| ShareAsset-A | Supply * PPS | `supply * PPS / 1e18 ~= totalAssets` (±1 USDC) | INV-J |
| ShareAsset-B | Per-user value conservation | `sum(getPosition.currentValue) ~= totalVaultAssets` | Conservation |

### Share Math (1 invariant)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| ShareMath-B | Round-trip loss | `convertToAssets(convertToShares(x)) <= x` | ERC-4626 |

### Accounting (4 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| Accounting-A | Fees bounded | `treasury_balance <= totalYieldAccrued` | Fee model |
| Accounting-B | Net flow | `totalAssets ~= deposits + yield - withdrawals - fees - losses` | Conservation |
| Accounting-D | Exact fee closure | `treasury ~= realisedYield * FEE_BPS / BPS_DENOM` | INV-2 (exact) |
| **Accounting-E** | **Per-user non-dilution** | `previewRedeem(shares[u])` monotonic between steps absent loss/withdraw | Dilution safety |

### Operator (1 invariant)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| **Operator-A** | **Never accumulates USDC** | `usdc.balanceOf(operator) == INITIAL_OPERATOR_BALANCE` at all times | No operator value capture |

## Tolerance Model

| Invariant | Tolerance | Rationale |
| --- | --- | --- |
| Router-A (aggregate solvency) | `fees + losses + ops * 2 wei` | Virtual offset + external loss + per-op rounding |
| Router-B (per-user solvency) | `fees + yield + losses + ops * 2 wei` | Same, plus yield/fees that may have exited |
| Router-N (underwater exit fee) | 2 wei margin on underwater check | Rounding in `_sharesToAssets` + withdraw-time recompute |
| Accounting-B (net flow) | `ops * 1e3 + 1e6` | Cumulative rounding across all handlers |
| Accounting-D (exact fee closure) | `ops * 2 wei` | Per-withdraw fee + gross flooring |
| Accounting-E (non-dilution) | 2 wei per actor | Floor in preview math |
| ShareAsset-A (supply * PPS) | 1 USDC (1e6) | Standard ERC-4626 rounding |

## Handler Action Space

| Handler | Actions | Effect on State |
| --- | --- | --- |
| `DepositHandler` | `deposit(amount, actor)` | Mints shares, increases totalAssets + costBasis |
| `WithdrawHandler` | `withdraw(sharePct, actor)` | Burns shares, pulls USDC from vaults, charges fee on yield |
| `YieldHandler` | `accrueYield`, `accrueMorphoYield`, `accrueLoss`, `accrueMorphoLoss` | Mutates vault value — aToken mint/burn, Morpho `setTotalAssets` |
| `AdminHandler` | `warpTime`, `recordObservation`, `togglePause`, `warpTimeLong` | Time + oracle + pause toggles |
| `OperatorHandler` | `grantOperator`, `revokeOperator`, `operatorDeposit`, `operatorWithdraw` | Permission and delegated deposits/withdraws |
| `LiquidityHandler` | `shockAaveIdle`, `restoreAaveIdle`, `shockMorphoMaxWithdraw`, `restoreMorphoMaxWithdraw` | Mutates vault **serviceability** — `USDC.balanceOf(aToken)` and Morpho `maxWithdraw` cap |
| `PermitHandler` | `permitDeposit` | Exercises `depositWithPermit` — EIP-2612 signed allowance + relay submission |

The `LiquidityHandler` separation exists because the router reads vault
*value* (`aToken.balanceOf(router)`, `morphoVault.convertToAssets(...)`)
and vault *serviceability* (`USDC.balanceOf(aToken)`, `maxWithdraw`) as
independent axes inside `withdraw()` planning. Value shocks flow through
`YieldHandler`; capacity shocks flow through `LiquidityHandler`. Keeping
the two separate means every shock is attributable in a counterexample.

## File structure

```text
test/invariants/
  README.md                    -- this file
  Invariants.t.sol             -- main test: wires handlers + invariant entry points
  BaseInvariants.sol           -- all assert functions, organised by component
  handlers/
    DepositHandler.sol         -- bounded random deposits
    WithdrawHandler.sol        -- bounded random withdrawals + realised-yield tracking
    YieldHandler.sol           -- Aave/Morpho yield and loss
    AdminHandler.sol           -- pause/unpause, time warps, oracle observations
    OperatorHandler.sol        -- operator grant/revoke and delegated deposits/withdraws
    LiquidityHandler.sol       -- Aave idle cash + Morpho maxWithdraw shocks
    PermitHandler.sol          -- signed-permit deposit path (depositWithPermit)
```

## Running

```bash
# Standard run (256 sequences, 16 calls each)
forge test --match-contract InvariantTest -vv

# Deep run (10k sequences)
forge test --match-contract InvariantTest -vvvv --fuzz-runs 10000

# Single invariant
forge test --match-test invariant_router_N -vv

# All-in-one (one check per sequence — fastest, loses per-invariant attribution)
forge test --match-test invariant_ALL -vv
```
