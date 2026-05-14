# Divigent Protocol

Non-custodial yield infrastructure for AI agent holding USDC on Base. Divigent
intercepts idle capital intervals in agent payment workflows and deploys them
into audited DeFi lending protocols (Aave V3, Morpho Steakhouse USDC),
generating yield proportional to idle duration.

## Table of Contents

- [Documentation](#documentation)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Dependencies](#dependencies)
- [Quickstart](#quickstart)
- [Development](#development)
- [Test Coverage](#test-coverage)
- [Gas Snapshots](#gas-snapshots)
- [Deployment](#deployment)
- [License](#license)

## Documentation

- [Protocol Whitepaper](./whitepaper/Divigent_Technical_Whitepaper.docx)

## Architecture

Divigent follows a router-oracle-token architecture where a single
VaultRouter orchestrates all capital flows between agent wallets and two
yield-bearing pool / vaults (Aave V3 and Steakhouse USDC Prime MetaMorpho V1), guided by a time-weighted average rate oracle.

```text
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
            ├── Plan capacity via _planWithdrawCapacity (shared with `withdrawCapacity()` view)
            ├── Compute proportional split across Aave and Morpho holdings
            ├── Shortfall redirect: if one vault is illiquid, shift to the other
            ├── Redeem from vaults → USDC arrives in router
            ├── Measure actualGross = USDC delta (excludes stray USDC)
            ├── Compute yield = actualGross - principalOut (floored at 0)
            ├── Fee: 10% of yield → DivigentFeeCollector → Treasury multisig
            └── Transfer net USDC to wallet
```

### Contracts

**DivigentVaultRouter** is the central orchestration contract. It holds all
pooled aTokens (Aave) and MetaMorpho shares (Morpho), manages per-wallet
principal tracking for fee calculation, and enforces access control via
wallet self-registration and an operator delegation model. The router holds
zero USDC at rest between transactions; capital flows atomically from wallet
to vault within the same transaction.

**DivigentYieldOracle** maintains a 48-slot circular buffer of rate
observations and computes a 4-hour time-weighted average rate (TWAR) for each
vault, following the Uniswap V2 accumulator pattern adapted for interest
rates. Aave rates are read directly from `currentLiquidityRate`. Morpho
rates are derived from consecutive share-price snapshots via
`convertToAssets(1e18)`, annualised over the observation interval. The
oracle is permissionless: any address can call `recordObservation()` to
prevent staleness.

**DivigentFeeCollector** calculates and routes the 10% yield fee. Fee is
computed exclusively from realised yield at withdrawal time. If a vault
loses value, the fee is exactly zero. The FeeCollector never holds USDC:
`safeTransferFrom` pulls directly from the router to the treasury multisig
in a single atomic transfer. Treasury is rotatable under a 7-day timelock
with a 14-day grace window, gated by `EMERGENCY_MULTISIG` — recovery path
for USDC blocklist events.

**dvUSDC** is a non-transferable ERC-20 receipt token representing a
proportional share of the protocol's pooled vault position. Non-transferability
is enforced at the EVM level via an `_update()` hook override: any
peer-to-peer transfer reverts. This preserves the per-wallet
`costBasisUSDC` invariant that underpins the fee-on-yield-only model. Only
the VaultRouter can mint and burn dvUSDC.

### Key Design Decisions

**Fee-on-yield-only model.** The fee is computed from
`actualGross - principalOut`, floored at zero. If the underlying vault
loses value (bad debt, impairment), the user absorbs the loss but pays zero
fee. Fee is deducted at withdrawal time from the actual USDC received, not
from an estimate.

**Delta-based USDC measurement.** The router snapshots
`USDC.balanceOf(this)` before vault redemptions and measures the delta
after. Any stray USDC accidentally sent to the router is excluded from
yield and fee calculations.

**Virtual offset share math.** Both `_assetsToShares` and `_sharesToAssets`
add a virtual offset of +1 to numerator and denominator, preventing the
classic first-depositor inflation attack. The tradeoff is O(1) rounding
dust per operation, bounded at approximately 1 USDC unit ($0.000001).

**MetaMorpho 18-decimal shares.** MetaMorpho vaults use
`DECIMALS_OFFSET = 18 - assetDecimals`, producing 18-decimal shares for
6-decimal USDC. The oracle uses `SHARE_UNIT = 1e18` for all Morpho
share-price queries. Using `1e6` would produce zero due to integer
truncation.

**Capacity-aware shortfall redirect.** On withdrawal, if one vault leg has
insufficient liquidity, the shortfall redirects entirely to the other vault
in a single step. The mathematical proof that at most one leg can be short
(given the early-revert guard) is documented in the contract. The capacity
math is factored into `_planWithdrawCapacity()` so `withdraw()` and the
public `withdrawCapacity()` pre-flight view cannot disagree.

**Morpho view-failure resilience.** `withdrawCapacity()` wraps Morpho's
`convertToAssets` in try/catch with a 100k gas limit, returning a
`morphoReachable` flag so SDKs can distinguish "temporarily zero capacity"
from "view path broken." `withdraw()` reverts with a clean
`MorphoUnreachable` error when the view fails and the router has Morpho
exposure.

**Emergency treasury rotation.** `EMERGENCY_MULTISIG` can propose a new
treasury address via a two-step timelock (7-day delay, 14-day grace). Stale
rotations auto-expire with `RotationExpired`. Primary mitigation path for
USDC treasury blacklist events.

### Security Properties

- **Non-custodial:** Router holds zero USDC between transactions. aTokens
  and Morpho shares are immutable contract claims with no admin steal
  vector.
- **Non-upgradeable:** No proxy pattern. External integration addresses are
  immutable. The fee treasury and oracle admin are rotatable via timelocked
  control paths, with oracle-admin recovery governed by an OpenZeppelin
  `Ownable2Step` emergency owner. Ownership renunciation is disabled so the
  oracle-admin recovery path cannot be accidentally destroyed.
- **Permissionless exit:** Withdrawals are never paused. The emergency
  multisig can only pause new deposits.
- **ReentrancyGuard + CEI:** All state mutations occur before external
  vault calls. `nonReentrant` modifier on deposit and withdraw as
  defense-in-depth.
- **Oracle freshness:** Deposits revert with `StaleOracle()` if no
  observation has been recorded within 2 hours. The deposit path
  auto-refreshes the oracle via `try oracle.recordObservation()`.
- **TVL cap schedule:** Contract-enforced phased rollout: $500k (day 0) →
  $2M (day 31) → unlimited (day 91).

### Protocol Invariants

1. **Solvency:** `totalVaultAssets() + totalFeesExtracted >= sum(costBasisUSDC)`
   across all wallets.
2. **Principal preservation:** Fee is exactly zero when realised yield is
   zero.
3. **Fee bound:** Fee never exceeds 10% of realised yield.
4. **Statelessness:** `USDC.balanceOf(router) == 0` after every deposit
   and withdraw.
5. **Permissionless exit:** No state transition blocks a withdrawal if the
   underlying vaults allow redemption.

## Repository Structure

```text
divigent-protocol/
├── contracts/                   # Foundry project
│   ├── src/                     # Protocol contracts
│   │   ├── DivigentVaultRouter.sol
│   │   ├── DivigentYieldOracle.sol
│   │   ├── DivigentFeeCollector.sol
│   │   ├── dvUSDC.sol
│   │   └── interfaces/          # IAaveV3Pool, IMorphoVault, IDivigentVaultRouter, IDivigentYieldOracle
│   ├── test/
│   │   ├── *.t.sol              # Unit tests (per contract)
│   │   ├── mocks/               # MockAavePool, MockMorphoVault, MockERC20, MockOracle
│   │   ├── integration/         # Edge cases, failure modes, flow tests, fuzz properties
│   │   │   ├── flows/           # End-to-end scenarios
│   │   │   ├── fuzz/            # Property-based fuzz (PropertyFuzz, PreviewExecutionParity, PermitOperatorFuzz)
│   │   │   └── helpers/         # Actions.sol test DSL
│   │   ├── invariants/          # Handler-based invariant suite (29 invariants, 7 handlers)
│   │   └── fork/                # Base mainnet fork tests (real Aave V3 + Morpho Steakhouse)
│   ├── script/
│   │   ├── DeployBase.s.sol     # Production deployment (Base mainnet)
│   │   └── DeployBaseSepolia.s.sol
│   ├── snapshots/               # Gas snapshots
│   ├── foundry.toml
│   └── Makefile
├── whitepaper/                  # Technical whitepaper
├── .audit/                      # Findings, remediations, cross-references
└── README.md
```

## Dependencies

### Required

- **[Foundry](https://book.getfoundry.sh/getting-started/installation)** —
  development framework (forge, cast, anvil).

  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```

### Optional

- **[lcov](https://github.com/linux-test-project/lcov)** — coverage HTML
  dashboard generation.

  ```bash
  # macOS
  brew install lcov

  # Ubuntu
  sudo apt install lcov
  ```

### Dependency Strategy

Dependencies are vendored under `contracts/lib/` via `forge install` rather
than managed through external package managers. This approach:

- Mitigates supply-chain attack vectors.
- Ensures dependency immutability across CI environments.
- Provides simplified version control and auditability.

## Quickstart

### 1. Clone

```bash
git clone https://github.com/divigent/divigent-protocol.git
cd divigent-protocol/contracts
```

### 2. Install Dependencies

```bash
forge install
```

### 3. Build

```bash
forge build
```

### 4. Run Tests

```bash
make test          # non-fork suite (unit + integration + fuzz + invariants)
make fork-test     # fork suite (requires BASE_RPC_URL)
make test-all      # everything
```

## Development

### Testing

| Command | Scope |
|---|---|
| `make test` | All non-fork tests (unit, integration, fuzz, invariants) |
| `make test-v` | Same, verbose |
| `make fork-test` | Fork tests against Base mainnet (requires `BASE_RPC_URL`) |
| `make test-all` | Full suite (non-fork + fork) |
| `make test-gas` | Gas report on fork tests |
| `make test-invariants` | Invariant suite only |
| `make test-fuzz` | Solvency fuzz only |
| `make test-integration` | Integration flow tests only |

### Coverage

| Command | Output |
|---|---|
| `make coverage` | Terminal summary |
| `make coverage-lcov` | `lcov.info` file (CI-consumable) |
| `make coverage-html` | `coverage-html/index.html` dashboard (requires lcov) |
| `make coverage-clean` | Remove coverage artifacts |

### Gas Snapshots

Gas snapshots are committed to the repository under `contracts/snapshots/`
so regressions can be detected across pull requests. Update with:

```bash
make snapshot
```

## Test Coverage

Measured against the **production contracts only** (`contracts/src/`).
Fork tests are excluded because they require `BASE_RPC_URL` and duplicate
the unit-level coverage against live mainnet integrations.

Regenerate with `make coverage` (terminal summary), `make coverage-lcov`
(CI-consumable `lcov.info`), or `make coverage-html` (HTML dashboard at
`contracts/coverage-html/index.html`).

<!-- coverage-summary-start -->
| Metric | Coverage | Hit / Total |
|---|---|---|
| **Lines** | **97.82 %** | 403 / 412 |
| **Functions** | **100.00 %** | 58 / 58 |
| **Branches** | **87.38 %** | 90 / 103 |

### Per-contract

| Contract | Lines | Branches | Functions |
|---|---|---|---|
| `DivigentFeeCollector.sol` | 100.0 % (37/37) | 100.0 % (13/13) | 100.0 % (7/7) |
| `dvUSDC.sol` | 100.0 % (15/15) | 100.0 % (3/3) | 100.0 % (6/6) |
| `DivigentVaultRouter.sol` | 97.7 % (254/260) | 84.1 % (58/69) | 100.0 % (35/35) |
| `DivigentYieldOracle.sol` | 97.0 % (97/100) | 88.9 % (16/18) | 100.0 % (10/10) |
<!-- coverage-summary-end -->

The residual uncovered lines/branches are predominantly defence-in-depth
reverts that can only fire under states the test harness cannot reach
(e.g., integer overflow in TWAR accumulation, Morpho view reverts inside
paths that the test mocks don't produce, and the `nonReentrant`
post-condition of `withdraw` when the router is called by a direct
reentrant vault — all reachable only from malicious external contracts,
not from protocol state).

**Test taxonomy:**

- **Unit tests** (per-contract) — every public function, every revert path,
  constructor zero-address checks.
- **Integration flows** — end-to-end journeys (multi-user, operator,
  permit, loss recovery, exit redirect, treasury rotation, withdraw
  capacity pre-flight).
- **Property fuzz** (10k runs each) — preview-vs-execute parity,
  permit/operator sequences, slippage boundaries, fee-on-yield
  correctness.
- **Invariant suite** — 29 invariants × 256 runs × 500 calls per run =
  ~128k handler calls per invariant. 7 handlers (Deposit, Withdraw,
  Yield, Admin, Operator, Liquidity, Permit).
- **Fork tests** — live Base mainnet integration against real Aave V3 and
  Morpho Steakhouse (requires `BASE_RPC_URL`).

## Gas Snapshots

Gas snapshots are stored in `contracts/snapshots/` as JSON files, one per
contract. Regenerate with `make snapshot`.

| Operation | Median Gas |
|---|---|
| `deposit` | 195,880 |
| `withdraw` | 126,284 |
| `recordObservation` | 111,159 |
| `collectFee` | 42,363 |
| `pricePerShare` | 5,933 |

## Deployment

Production deployment targets **Base Mainnet (Chain ID 8453)**. The
deployment script validates inputs, verifies all external dependencies
exist on-chain, and runs post-deploy assertions on contract wiring, USDC
approvals, and protocol initial state.

### Required Environment Variables

| Variable | Purpose |
|---|---|
| `PRIVATE_KEY` | Deployer EOA private key |
| `TREASURY` | 2-of-3 Gnosis Safe address for fee collection (must be a multisig, not an EOA, distinct from deployer and emergency multisig) |
| `EMERGENCY_MULTISIG` | Separate multisig authorised to pause deposits and trigger treasury rotation |

### Optional

| Variable | Default |
|---|---|
| `BASE_RPC_URL` | `https://mainnet.base.org` |
| `BASESCAN_API_KEY` | required only when using `--verify` |

### Run

```bash
forge script script/DeployBase.s.sol:DeployBase \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

The deployment resolves the circular dependency between
`DivigentVaultRouter`, `DivigentFeeCollector`, and `DvUSDC` by predicting
the router's future CREATE address via nonce arithmetic. See the NatSpec
at the top of `script/DeployBase.s.sol` for details.

### Bug Bounty

Details will be published ahead of mainnet deployment.

## License

MIT
