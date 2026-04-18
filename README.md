# Divigent Protocol

Non-custodial yield infrastructure for AI agent USDC on Base. Divigent intercepts idle capital intervals in agent payment workflows and deploys them into audited DeFi lending protocols, generating yield proportional to idle duration.

## Architecture

Divigent follows a router-oracle-token architecture where a single VaultRouter orchestrates all capital flows between agent wallets and two yield-bearing vaults (Aave V3 and Morpho MetaMorpho), guided by a time-weighted average rate oracle.

```
Agent Wallet
    │
    ├── deposit(amount, wallet)
    │       │
    │       ▼
    │   DivigentVaultRouter
    │       ├── Pull USDC from wallet
    │       ├── Query DivigentYieldOracle for optimal vault
    │       │       └── 4-hour TWAR comparison (Aave vs Morpho)
    │       │       └── Morpho wins only if TWAR gap >= 50bps AND vault is safe
    │       ├── Supply USDC to selected vault
    │       │       ├── Aave V3 Pool: supply() → aTokens (rebasing, 1:1 with USDC)
    │       │       └── Morpho Steakhouse: deposit() → vault shares (ERC-4626, 18 decimals)
    │       ├── Mint dvUSDC to wallet (non-transferable receipt token, 6 decimals)
    │       └── Record costBasisUSDC[wallet] += amount
    │
    └── withdraw(shares, wallet, minUsdcOut)
            │
            ▼
        DivigentVaultRouter
            ├── Burn dvUSDC from wallet
            ├── Reduce costBasisUSDC[wallet] (proportional to shares burned)
            ├── Compute proportional split across Aave and Morpho holdings
            ├── Shortfall redirect: if one vault is illiquid, shift to the other
            ├── Redeem from vaults → USDC arrives in router
            ├── Measure actualGross = USDC delta (excludes stray USDC)
            ├── Compute yield = actualGross - principalOut (floored at 0)
            ├── Fee: 10% of yield → DivigentFeeCollector → Treasury multisig
            └── Transfer net USDC to wallet
```

### Contracts

**DivigentVaultRouter** is the central orchestration contract. It holds all pooled aTokens (Aave) and MetaMorpho shares (Morpho), manages per-wallet principal tracking for fee calculation, and enforces access control via wallet self-registration and an operator delegation model. The router holds zero USDC at rest between transactions; capital flows atomically from wallet to vault within the same transaction.

**DivigentYieldOracle** maintains a 48-slot circular buffer of rate observations and computes a 4-hour time-weighted average rate (TWAR) for each vault, following the Uniswap V2 accumulator pattern adapted for interest rates. Aave rates are read directly from `currentLiquidityRate`. Morpho rates are derived from consecutive share-price snapshots via `convertToAssets(1e18)`, annualised over the observation interval. The oracle is permissionless: any address can call `recordObservation()` to prevent staleness.

**DivigentFeeCollector** calculates and routes the 10% yield fee. Fee is computed exclusively from realised yield at withdrawal time. If a vault loses value, the fee is exactly zero. The FeeCollector never holds USDC: `safeTransferFrom` pulls directly from the router to the treasury multisig in a single atomic transfer.

**dvUSDC** is a non-transferable ERC-20 receipt token representing a proportional share of the protocol's pooled vault position. Non-transferability is enforced at the EVM level via an `_update()` hook override: any peer-to-peer transfer reverts. This preserves the per-wallet `costBasisUSDC` invariant that underpins the fee-on-yield-only model. Only the VaultRouter can mint and burn dvUSDC.

### Key Design Decisions

**Fee-on-yield-only model.** The fee is computed from `actualGross - principalOut`, floored at zero. If the underlying vault loses value (bad debt, impairment), the user absorbs the loss but pays zero fee. Fee is deducted at withdrawal time from the actual USDC received, not from an estimate.

**Delta-based USDC measurement.** The router snapshots `USDC.balanceOf(this)` before vault redemptions and measures the delta after. Any stray USDC accidentally sent to the router is excluded from yield and fee calculations.

**Virtual offset share math.** Both `_assetsToShares` and `_sharesToAssets` add a virtual offset of +1 to numerator and denominator, preventing the classic first-depositor inflation attack. The tradeoff is O(1) rounding dust per operation, bounded at approximately 1 USDC unit ($0.000001).

**MetaMorpho 18-decimal shares.** MetaMorpho vaults use `DECIMALS_OFFSET = 18 - assetDecimals`, producing 18-decimal shares for 6-decimal USDC. The oracle uses `SHARE_UNIT = 1e18` for all Morpho share-price queries. Using `1e6` would produce zero due to integer truncation.

**Capacity-aware shortfall redirect.** On withdrawal, if one vault leg has insufficient liquidity, the shortfall redirects entirely to the other vault in a single step. The mathematical proof that at most one leg can be short (given the early-revert guard) is documented in the contract.

### Security Properties

- **Non-custodial:** Router holds zero USDC between transactions. aTokens and Morpho shares are immutable contract claims with no admin steal vector.
- **Non-upgradeable:** No proxy pattern. All contract addresses are immutable. No admin key can modify fee recipients, vault addresses, or token behaviour.
- **Permissionless exit:** Withdrawals are never paused. The emergency multisig can only pause new deposits.
- **ReentrancyGuard + CEI:** All state mutations occur before external vault calls. `nonReentrant` modifier on deposit and withdraw as defense-in-depth.
- **Oracle freshness:** Deposits revert with `StaleOracle()` if no observation has been recorded within 2 hours. The deposit path auto-refreshes the oracle via `try oracle.recordObservation()`.
- **TVL cap schedule:** Contract-enforced phased rollout: $500k (day 0) → $2M (day 31) → unlimited (day 91).

### Protocol Invariants

1. **Solvency:** `totalVaultAssets() + totalFeesExtracted >= sum(costBasisUSDC)` across all wallets.
2. **Principal preservation:** Fee is exactly zero when realised yield is zero.
3. **Fee bound:** Fee never exceeds 10% of realised yield.
4. **Statelessness:** `USDC.balanceOf(router) == 0` after every deposit and withdraw.
5. **Permissionless exit:** No state transition blocks a withdrawal if the underlying vaults allow redemption.

## Repository Organisation

```
contracts/
├── src/                           Protocol contracts
│   ├── DivigentVaultRouter.sol      Central routing, deposit, withdraw, share math
│   ├── DivigentYieldOracle.sol      TWAR oracle, rate comparison, safety checks
│   ├── DivigentFeeCollector.sol     Fee calculation, atomic treasury routing
│   ├── dvUSDC.sol                   Non-transferable receipt token
│   └── interfaces/                  IAaveV3Pool, IMorphoVault, IDivigentVaultRouter, IDivigentYieldOracle
├── test/
│   ├── *.t.sol                      Unit tests (per contract)
│   ├── mocks/                       MockAavePool, MockMorphoVault, MockERC20, MockOracle
│   ├── integration/                 Edge cases, vault failure modes, findings validation, solvency fuzz
│   │   ├── flows/                   End-to-end scenarios (16 flow tests)
│   │   │   └── validation/          Revert-path enumeration (deposit, withdraw)
│   │   ├── fuzz/                    Property-based fuzz tests
│   │   └── helpers/                 Actions.sol test DSL
│   ├── invariants/                  Maple-style handler-based invariant suite (30 invariants, 5 handlers)
│   ├── fork/                        Base mainnet fork tests (real Aave V3 + Morpho Steakhouse)
│   └── echidna/                     Echidna/Medusa assertion harness
├── script/
│   ├── DeployBase.s.sol             Production deployment (Base mainnet)
│   └── DeployBaseSepolia.s.sol      Testnet deployment (Base Sepolia)
├── snapshots/                       Gas snapshots (Aave V4 pattern)
├── foundry.toml
└── Makefile
```

## Setup

### Prerequisites

- [Foundry](https://getfoundry.sh)

### Dependencies

Dependencies are vendored locally via `forge install` to prevent supply chain attack vectors and ensure dependency immutability.

```bash
cd contracts
forge install
```

## Development

```bash
make build                    # Compile all contracts
make test                     # Run unit + integration + invariant tests
make fork-test                # Run fork tests against Base mainnet
make test-all                 # Everything
make slither                  # Static analysis
make coverage                 # Coverage report
make snapshot                 # Gas snapshot
make help                     # List all commands
```

## Gas Snapshots

Gas snapshots are stored in `snapshots/` as JSON files, one per contract. These are committed to the repository so that gas regressions can be detected across pull requests.

| Operation | Median Gas |
|-----------|-----------|
| `deposit` | 195,880 |
| `withdraw` | 126,284 |
| `recordObservation` | 111,159 |
| `collectFee` | 42,363 |
| `pricePerShare` | 5,933 |

## Deployment

Production deployment targets Base Mainnet (Chain ID 8453). The deployment script validates inputs, verifies all external dependencies exist on-chain, and runs 15 post-deploy assertions on contract wiring, USDC approvals, and protocol initial state.

See `script/` for deployment scripts and instructions.

## Security

### Static Analysis

Slither, Echidna, and Medusa have been run against the full contract suite. Zero true-positive findings.

### Assumptions

The protocol makes the following assumptions about external dependencies:

- **USDC is not globally paused by Circle.** A global pause halts all deposits and withdrawals. This is an accepted external risk (occurred once, March 2023).
- **Treasury multisig is not USDC-blacklisted.** If Circle blacklists the treasury address, fee collection reverts, blocking all withdrawals.
- **Aave V3 has sufficient withdrawal liquidity.** The exit-redirect mechanism shifts shortfall to Morpho if Aave is constrained, but simultaneous depletion of both pools would block withdrawals until liquidity returns.
- **Morpho Steakhouse vault is solvent.** The oracle checks that the share price has not fallen below 1 USDC. An unsafe Morpho vault is excluded from routing.
- **MetaMorpho shares use 18 decimals.** MetaMorpho applies `DECIMALS_OFFSET = 18 - assetDecimals`. The oracle's `SHARE_UNIT = 1e18` depends on this.

## License

MIT
