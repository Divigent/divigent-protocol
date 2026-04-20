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

# ── Coverage ──────────────────────────────────────────────────────────────────

.PHONY: coverage coverage-lcov coverage-html coverage-clean

# Terminal summary (fast)
coverage:
	forge coverage --no-match-contract Fork --ir-minimum --report summary

# Generate lcov.info (consumed by HTML generator / CI dashboards)
coverage-lcov:
	forge coverage --no-match-contract Fork --ir-minimum --report lcov
	@echo "lcov.info written."

# Generate an HTML dashboard (requires `lcov` / `genhtml` installed)
coverage-html: coverage-lcov
	@if ! command -v genhtml >/dev/null 2>&1; then \
		echo "genhtml not found. Install:"; \
		echo "  macOS:  brew install lcov"; \
		echo "  Ubuntu: sudo apt install lcov"; \
		exit 1; \
	fi
	genhtml lcov.info \
		--output-directory coverage-html \
		--title "Divigent Protocol Coverage" \
		--legend \
		--branch-coverage \
		--ignore-errors category,inconsistent,corrupt
	@echo "HTML coverage written to: coverage-html/index.html"

coverage-clean:
	rm -f lcov.info
	rm -rf coverage-html

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
	@echo "    make test-invariants    30 invariant tests"
	@echo "    make test-fuzz          Solvency fuzz tests"
	@echo "    make test-integration   Integration flow tests"
	@echo ""
	@echo "  Coverage"
	@echo "    make coverage           Terminal summary"
	@echo "    make coverage-lcov      Generate lcov.info"
	@echo "    make coverage-html      Generate HTML dashboard (requires lcov)"
	@echo "    make coverage-clean     Remove coverage artifacts"
	@echo ""
	@echo "  Other"
	@echo "    make snapshot           Gas snapshot"
	@echo ""
