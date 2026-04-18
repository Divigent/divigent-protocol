# ──────────────────────────────────────────────────────────────────────────────
# Divigent Protocol — Contract Commands
# ──────────────────────────────────────────────────────────────────────────────

# ── Build ─────────────────────────────────────────────────────────────────────

.PHONY: build clean

build:
	forge build

clean:
	forge clean

# ── Test ──────────────────────────────────────────────────────────────────────

.PHONY: test test-v fork-test test-all test-gas

test:
	forge test --no-match-contract Fork -v

test-v:
	forge test --no-match-contract Fork -vv

fork-test:
	BASE_RPC_URL=https://mainnet.base.org forge test --match-contract Fork -vv

test-all: test fork-test

test-gas:
	BASE_RPC_URL=https://mainnet.base.org forge test --match-contract ForkGasProfile --gas-report

# ── Specific Test Suites ──────────────────────────────────────────────────────

.PHONY: test-invariants test-fuzz test-integration test-fork-deposit test-fork-withdraw

test-invariants:
	forge test --match-contract InvariantTest -vv

test-fuzz:
	forge test --match-contract SolvencyInvariant -vv

test-integration:
	forge test --match-path "test/integration/*" -vv

test-fork-deposit:
	BASE_RPC_URL=https://mainnet.base.org forge test --match-contract ForkDeposit -vvv

test-fork-withdraw:
	BASE_RPC_URL=https://mainnet.base.org forge test --match-contract ForkWithdraw -vvv

# ── Static Analysis ──────────────────────────────────────────────────────────

.PHONY: slither echidna medusa

slither:
	slither src/ \
		--solc-remaps "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/" \
		--exclude-dependencies

echidna:
	echidna test/echidna/EchidnaVaultRouter.sol \
		--contract EchidnaVaultRouter \
		--config echidna.yaml \
		--solc-args "--via-ir --optimize"

medusa:
	medusa fuzz --config medusa.json

# ── Coverage ──────────────────────────────────────────────────────────────────

.PHONY: coverage

coverage:
	forge coverage --no-match-contract Fork

# ── Snapshot ──────────────────────────────────────────────────────────────────

.PHONY: snapshot

snapshot:
	forge snapshot --no-match-contract Fork

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help

help:
	@echo ""
	@echo "  Build"
	@echo "    make build              Build all contracts"
	@echo "    make clean              Remove build artifacts"
	@echo ""
	@echo "  Test"
	@echo "    make test               Run all non-fork tests"
	@echo "    make test-v             Run with verbose output"
	@echo "    make fork-test          Run fork tests on Base mainnet"
	@echo "    make test-all           Run everything"
	@echo "    make test-gas           Gas report on fork tests"
	@echo ""
	@echo "  Specific Suites"
	@echo "    make test-invariants    30 Maple-style invariant tests"
	@echo "    make test-fuzz          Solvency fuzz tests"
	@echo "    make test-integration   Integration flow tests"
	@echo ""
	@echo "  Static Analysis"
	@echo "    make slither            Run Slither"
	@echo "    make echidna            Run Echidna (50k calls)"
	@echo "    make medusa             Run Medusa"
	@echo ""
	@echo "  Other"
	@echo "    make coverage           Forge coverage report"
	@echo "    make snapshot           Gas snapshot"
	@echo ""
