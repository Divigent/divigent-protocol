# Divigent Protocol Invariants

## Invariant Registry

### VaultRouter (11 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| Router-A | Aggregate solvency | `totalVaultAssets() >= sum(costBasis) - tolerance` | INV-1 |
| Router-B | Per-user solvency | `sharesToAssets(shares[u]) >= costBasis[u] - tolerance` for all u | INV-1 (per-user) |
| Router-C | Principal preservation | `calculateFee(0) == 0` | INV-2 |
| Router-D | Fee bound | `fee <= yield * FEE_BPS / BPS_DENOM` for representative values | INV-3 |
| Router-E | Statelessness | `USDC.balanceOf(router) == 0` between txs | INV-4 |
| Router-F | Permissionless exit | Withdraw not blocked by deposit pause | INV-5 |
| Router-G | Zero shares -> zero cost basis | `shares[u] == 0 => costBasis[u] == 0` | Accounting |
| Router-H | Nonzero cost basis -> nonzero shares | `costBasis[u] > 0 => shares[u] > 0` | Accounting |
| Router-I | Vault asset decomposition | `totalVaultAssets == aave + morpho` | Structural |
| Router-J | TVL cap respected | `totalAssets <= cap + yieldAccrued` | TVL cap |
| Router-K | Authorized wallet consistency | `shares[u] > 0 => authorizedWallets[u]` | Access control |

### dvUSDC (3 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| dvUSDC-A | Non-transferable | P2P transfers always revert | INV-F |
| dvUSDC-B | Access control | `dvUSDC.VAULT_ROUTER() == router` | Structural |
| dvUSDC-C | Supply consistency | `totalSupply == sum(balanceOf[actor])` for all actors | ERC-20 |

### FeeCollector (3 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| FeeCollector-A | Pass-through | `USDC.balanceOf(feeCollector) == 0` | INV-H |
| FeeCollector-B | Access control | `VAULT_ROUTER == router` | Structural |
| FeeCollector-C | Constants immutable | `FEE_BPS == 1000, BPS_DENOM == 10000` | Structural |

### Oracle (3 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| Oracle-A | PPS monotonic | `pricePerShare()` non-decreasing under yield | INV-I |
| Oracle-B | Observation time valid | `lastObservationTime <= block.timestamp` | Time safety |
| Oracle-C | Freshness consistency | `isFresh() <=> elapsed <= MAX_STALENESS` | Staleness |

### Share-Asset (1 invariant)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| ShareAsset-A | Supply * PPS | `supply * PPS / 1e18 ~= totalAssets` (+-1 USDC) | INV-J |

### Accounting (3 invariants)

| ID | Name | Statement | Source |
| --- | --- | --- | --- |
| Accounting-A | Fees bounded | `treasury_balance <= totalYieldAccrued` | Fee model |
| Accounting-B | Net flow | `totalAssets ~= deposits - withdrawals + yield - fees` | Conservation |
| Accounting-C | Counts monotonic | Handler operation counts never decrease | Sanity |

## Tolerance Model

| Invariant | Tolerance | Rationale |
| --- | --- | --- |
| Router-A (aggregate solvency) | `ops * 2 wei` | Virtual offset loses ~2 wei per operation |
| Router-B (per-user solvency) | `ops * 2 wei` | Same virtual offset drift, per-user |
| ShareAsset-A (supply * PPS) | `1 USDC (1e6)` | Standard ERC-4626 rounding |
| Accounting-B (net flow) | `ops * 1e3 + 1e6` | Cumulative rounding across all handlers |

## File structure

```
test/invariants/
  README.md                    -- this file
  Invariants.t.sol             -- main test: wires handlers + 24 invariant entry points
  BaseInvariants.sol           -- all 24 assert functions, organised by component
  handlers/
    DepositHandler.sol         -- bounded random deposits, tracks totalDeposited
    WithdrawHandler.sol        -- bounded random withdrawals, tracks totalWithdrawn
    YieldHandler.sol           -- simulates Aave yield accrual, tracks totalYieldAccrued
    AdminHandler.sol           -- pause/unpause, time warps, oracle observations
```

## Running

```bash
# Standard run (256 sequences, 16 calls each)
forge test --match-contract InvariantTest -vv

# Deep run (10k sequences)
forge test --match-contract InvariantTest -vvvv --fuzz-runs 10000

# Single invariant
forge test --match-test invariant_router_A -vv

# All-in-one (gas-efficient, one check per sequence)
forge test --match-test invariant_ALL -vv
```
