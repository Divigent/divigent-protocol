// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DivigentVaultRouter} from "../../../src/DivigentVaultRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title  PermitHandler
/// @notice Exercises the router's `depositWithPermit` path under the invariant
///         fuzzer. The action graph across the rest of the handler suite
///         covers the standard `deposit` call but never the signed-permit
///         variant — so any accounting drift, nonce-handling bug, or state
///         transition specific to that path would be invisible to the
///         invariant sweep without this handler.
///
///         Each invocation:
///           1. Picks one of the pre-keyed actors (deterministic, so permits
///              remain valid across the run).
///           2. Builds a fresh EIP-712 permit digest, signs with the actor's
///              key, produces (v, r, s).
///           3. Calls `router.depositWithPermit(amount, actor, deadline, v, r, s)`
///              from a permissionless relayer address — confirming the relay
///              path is safe AND the permit fuels a legitimate deposit.
///
///         Deposited amounts and counters are recorded so aggregate accounting
///         invariants (`Accounting-B`, `Accounting-D`) see permit-path
///         deposits identically to plain ones.
contract PermitHandler is CommonBase, StdUtils {
    DivigentVaultRouter public router;
    MockERC20 public usdc;

    /// @dev Actor addresses WITH known private keys. Indexed by seed.
    address[] public actors;
    uint256[] public actorKeys;

    /// @dev Permissionless relay address — submits permits for any actor.
    ///      Never deposits for itself; just forwards.
    address public relay;

    uint256 public totalPermitDeposited;
    uint256 public permitDepositCount;

    uint256 internal constant MIN_DEPOSIT = 10e6;
    uint256 internal constant MAX_DEPOSIT = 50_000e6;

    constructor(
        DivigentVaultRouter router_,
        MockERC20 usdc_,
        address[] memory actors_,
        uint256[] memory actorKeys_
    ) {
        require(actors_.length == actorKeys_.length, "PermitHandler: actor/key mismatch");
        router = router_;
        usdc = usdc_;
        actors = actors_;
        actorKeys = actorKeys_;
        relay = address(0x7E1AF);
    }

    function permitDeposit(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 idx = actorSeed % actors.length;
        address actor = actors[idx];
        uint256 key = actorKeys[idx];

        usdc.mint(actor, amount);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, actor, address(router), amount, deadline);

        vm.prank(relay);
        try router.depositWithPermit(amount, actor, deadline, v, r, s) {
            totalPermitDeposited += amount;
            permitDepositCount++;
        } catch {
            // Expected: paused, TVL cap, stale oracle, deadline edge — same
            // failure surface as regular deposits.
        }
    }

    // ── EIP-2612 signing ─────────────────────────────────────────────────────

    function _signPermit(
        uint256 privateKey,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = usdc.nonces(owner);
        bytes32 structHash = keccak256(
            abi.encode(usdc.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }
}
