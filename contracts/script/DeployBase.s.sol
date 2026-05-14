// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DivigentFeeCollector} from "../src/DivigentFeeCollector.sol";
import {DivigentVaultRouter} from "../src/DivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../src/DivigentYieldOracle.sol";
import {DvUSDC} from "../src/dvUSDC.sol";

/// @title  DeployBase
/// @author Divigent Protocol
/// @notice Production deployment script for Base Mainnet (Chain ID: 8453).
///
///         Deploys the full Divigent stack against real protocol contracts:
///           - Aave V3 Pool (verified on basescan.org)
///           - Morpho Steakhouse USDC vault (MetaMorpho ERC-4626)
///           - Circle USDC (native on Base)
///
///         Deployment order (circular dependency resolution):
///           1. DivigentYieldOracle (no dependencies on other Divigent contracts)
///           2. Predict VaultRouter address via CREATE nonce
///           3. DivigentFeeCollector (needs router address for access control)
///           4. DvUSDC (needs router address for mint/burn gate)
///           5. DivigentVaultRouter (wires everything together)
///           6. Post-deploy: verify addresses, write report
///              (Oracle is seeded by its own constructor — no on-chain
///              observation call is possible in the deploy tx because
///              the 5-minute MIN_OBSERVATION_INTERVAL would early-return.
///              The first real observation must be recorded by a keeper
///              in a follow-up tx, ≥5 minutes after deployment.)
///
///         Security:
///           - No proxy pattern. All contracts are immutable at deployment.
///           - Treasury MUST be a 2-of-3 Gnosis Safe multisig (not an EOA).
///           - Emergency multisig MUST be a separate multisig from treasury.
///           - Chain ID is enforced: script reverts on wrong chain.
///
/// @dev    Usage:
///         ```
///         forge script script/DeployBase.s.sol:DeployBase \
///           --rpc-url $BASE_RPC_URL \
///           --private-key $PRIVATE_KEY \
///           --broadcast \
///           --verify \
///           --etherscan-api-key $BASESCAN_API_KEY
///         ```
///
///         Required env vars:
///           PRIVATE_KEY          Deployer EOA private key
///           TREASURY             2-of-3 Gnosis Safe address for fee collection
///           EMERGENCY_MULTISIG   Separate multisig for deposit pause authority
///           ORACLE_ADMIN         Separate multisig for oracle parameter administration
///
///         Optional env vars:
///           BASE_RPC_URL         Base mainnet RPC (default: https://mainnet.base.org)
contract DeployBase is Script {
    // ═════════════════════════════════════════════════════════════════════════
    //  Base Mainnet Addresses (verified on basescan.org)
    // ═════════════════════════════════════════════════════════════════════════

    address constant USDC           = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_POOL      = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_ATOKEN    = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant MORPHO_VAULT   = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;

    // ═════════════════════════════════════════════════════════════════════════
    //  Deployment Report
    // ═════════════════════════════════════════════════════════════════════════

    struct DeployReport {
        address deployer;
        address treasury;
        address emergencyMultisig;
        address oracleAdmin;
        address oracle;
        address feeCollector;
        address dvUsdc;
        address router;
        uint256 chainId;
        uint256 deployedAt;
    }

    function run() external {
        // ── Input validation ─────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envAddress("TREASURY");
        address emergencyMultisig = vm.envAddress("EMERGENCY_MULTISIG");
        address oracleAdmin = vm.envAddress("ORACLE_ADMIN");

        require(block.chainid == 8453, "Wrong chain: must be Base Mainnet (8453)");
        require(treasury != address(0), "TREASURY must not be zero address");
        require(emergencyMultisig != address(0), "EMERGENCY_MULTISIG must not be zero address");
        require(oracleAdmin != address(0), "ORACLE_ADMIN must not be zero address");
        require(treasury != deployer, "TREASURY must not be the deployer EOA (use a multisig)");
        require(emergencyMultisig != deployer, "EMERGENCY_MULTISIG must not be the deployer EOA");
        require(oracleAdmin != deployer, "ORACLE_ADMIN must not be the deployer EOA");
        require(treasury != emergencyMultisig, "TREASURY and EMERGENCY_MULTISIG must be different");
        require(oracleAdmin != emergencyMultisig, "ORACLE_ADMIN and EMERGENCY_MULTISIG must be different");
        require(oracleAdmin != treasury, "ORACLE_ADMIN and TREASURY must be different");

        // ── Pre-deploy checks ────────────────────────────────────────────────
        _preDeployChecks(deployer);

        // ── Deploy ───────────────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Divigent Protocol: Base Mainnet Deployment ===");
        console2.log("Deployer:            ", deployer);
        console2.log("Treasury:            ", treasury);
        console2.log("Emergency Multisig:  ", emergencyMultisig);
        console2.log("Oracle Admin:        ", oracleAdmin);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // Step 1: Oracle (no Divigent dependencies)
        DivigentYieldOracle oracle = new DivigentYieldOracle(
            AAVE_POOL, AAVE_ATOKEN, USDC, MORPHO_VAULT, oracleAdmin, emergencyMultisig
        );

        // Step 2: Predict router address
        uint256 nonce = vm.getNonce(deployer);
        address predictedRouter = vm.computeCreateAddress(deployer, nonce + 2);

        // Step 3: FeeCollector (locked to predicted router)
        DivigentFeeCollector feeCollector = new DivigentFeeCollector(
            USDC, treasury, predictedRouter
        );

        // Step 4: dvUSDC (locked to predicted router)
        DvUSDC dvUsdc = new DvUSDC(predictedRouter);

        // Step 5: Router (wires everything)
        DivigentVaultRouter router = new DivigentVaultRouter(
            USDC, AAVE_POOL, AAVE_ATOKEN, MORPHO_VAULT,
            address(oracle), address(feeCollector), address(dvUsdc),
            emergencyMultisig
        );

        require(address(router) == predictedRouter, "Router address mismatch");

        vm.stopBroadcast();

        // ── Post-deploy verification ─────────────────────────────────────────
        _postDeployVerification(oracle, feeCollector, dvUsdc, router, treasury, emergencyMultisig, oracleAdmin);

        // ── Write report ─────────────────────────────────────────────────────
        DeployReport memory report = DeployReport({
            deployer: deployer,
            treasury: treasury,
            emergencyMultisig: emergencyMultisig,
            oracleAdmin: oracleAdmin,
            oracle: address(oracle),
            feeCollector: address(feeCollector),
            dvUsdc: address(dvUsdc),
            router: address(router),
            chainId: block.chainid,
            deployedAt: block.timestamp
        });

        _writeReport(report);
        _logReport(report);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Pre-Deploy Checks
    // ═════════════════════════════════════════════════════════════════════════

    function _preDeployChecks(address deployer) internal view {
        // Verify external contracts exist
        require(USDC.code.length > 0, "USDC contract not found at expected address");
        require(AAVE_POOL.code.length > 0, "Aave V3 Pool not found at expected address");
        require(AAVE_ATOKEN.code.length > 0, "Aave aUSDC not found at expected address");
        require(MORPHO_VAULT.code.length > 0, "Morpho Steakhouse not found at expected address");

        // Verify deployer has ETH for gas
        require(deployer.balance > 0.01 ether, "Deployer needs ETH for gas");

        // Verify Morpho vault's underlying is USDC
        (bool ok, bytes memory data) = MORPHO_VAULT.staticcall(
            abi.encodeWithSignature("asset()")
        );
        require(ok && abi.decode(data, (address)) == USDC, "Morpho vault asset is not USDC");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Post-Deploy Verification
    // ═════════════════════════════════════════════════════════════════════════

    function _postDeployVerification(
        DivigentYieldOracle oracle,
        DivigentFeeCollector feeCollector,
        DvUSDC dvUsdc,
        DivigentVaultRouter router,
        address treasury,
        address emergencyMultisig,
        address oracleAdmin
    ) internal view {
        // Wiring checks
        require(address(router.USDC()) == USDC, "Router USDC mismatch");
        require(address(router.AAVE_POOL()) == AAVE_POOL, "Router Aave Pool mismatch");
        require(address(router.A_TOKEN()) == AAVE_ATOKEN, "Router aToken mismatch");
        require(address(router.MORPHO_VAULT()) == MORPHO_VAULT, "Router Morpho mismatch");
        require(address(router.ORACLE()) == address(oracle), "Router Oracle mismatch");
        require(address(router.FEE_COLLECTOR()) == address(feeCollector), "Router FeeCollector mismatch");
        require(address(router.DV_USDC()) == address(dvUsdc), "Router dvUSDC mismatch");
        require(router.EMERGENCY_MULTISIG() == emergencyMultisig, "Router multisig mismatch");

        // Cross-contract wiring
        require(feeCollector.VAULT_ROUTER() == address(router), "FeeCollector router mismatch");
        require(feeCollector.treasury() == treasury, "FeeCollector treasury mismatch");
        require(dvUsdc.VAULT_ROUTER() == address(router), "dvUSDC router mismatch");

        // Oracle reads real rates
        require(oracle.lastObservationTime() > 0, "Oracle not seeded");
        require(oracle.ORACLE_ADMIN() == oracleAdmin, "Oracle admin mismatch");
        require(oracle.owner() == emergencyMultisig, "Oracle owner mismatch");
        require(oracle.minDifferentialRay() == oracle.DEFAULT_MIN_DIFFERENTIAL_RAY(), "Oracle differential mismatch");

        // USDC approvals
        require(
            IERC20(USDC).allowance(address(router), AAVE_POOL) == type(uint256).max,
            "Router missing Aave USDC approval"
        );
        require(
            IERC20(USDC).allowance(address(router), MORPHO_VAULT) == type(uint256).max,
            "Router missing Morpho USDC approval"
        );
        require(
            IERC20(USDC).allowance(address(router), address(feeCollector)) == type(uint256).max,
            "Router missing FeeCollector USDC approval"
        );

        // Protocol state
        require(!router.depositsPaused(), "Deposits should not be paused at deploy");
        require(dvUsdc.totalSupply() == 0, "dvUSDC supply should be 0 at deploy");
        require(router.totalVaultAssets() == 0, "TVA should be 0 at deploy");
        require(router.currentTVLCap() == 500_000e6, "Initial TVL cap should be $500k");

        console2.log("All post-deploy verifications passed.");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Report
    // ═════════════════════════════════════════════════════════════════════════

    function _writeReport(DeployReport memory r) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", r.chainId);
        vm.serializeUint(obj, "deployedAt", r.deployedAt);
        vm.serializeAddress(obj, "deployer", r.deployer);
        vm.serializeAddress(obj, "treasury", r.treasury);
        vm.serializeAddress(obj, "emergencyMultisig", r.emergencyMultisig);
        vm.serializeAddress(obj, "oracleAdmin", r.oracleAdmin);
        vm.serializeAddress(obj, "usdc", USDC);
        vm.serializeAddress(obj, "aavePool", AAVE_POOL);
        vm.serializeAddress(obj, "aaveAToken", AAVE_ATOKEN);
        vm.serializeAddress(obj, "morphoVault", MORPHO_VAULT);
        vm.serializeAddress(obj, "oracle", r.oracle);
        vm.serializeAddress(obj, "feeCollector", r.feeCollector);
        vm.serializeAddress(obj, "dvUsdc", r.dvUsdc);
        string memory json = vm.serializeAddress(obj, "router", r.router);

        string memory outPath = "deployments/base-mainnet.json";
        vm.writeJson(json, outPath);
        console2.log("Deployment report written to:", outPath);
    }

    function _logReport(DeployReport memory r) internal pure {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("Protocol Contracts:");
        console2.log("  DivigentYieldOracle:   ", r.oracle);
        console2.log("  DivigentFeeCollector:  ", r.feeCollector);
        console2.log("  DvUSDC:                ", r.dvUsdc);
        console2.log("  DivigentVaultRouter:   ", r.router);
        console2.log("");
        console2.log("External Dependencies:");
        console2.log("  USDC:                  ", USDC);
        console2.log("  Aave V3 Pool:          ", AAVE_POOL);
        console2.log("  Aave aUSDC:            ", AAVE_ATOKEN);
        console2.log("  Morpho Steakhouse:     ", MORPHO_VAULT);
        console2.log("");
        console2.log("Access Control:");
        console2.log("  Treasury (fees):       ", r.treasury);
        console2.log("  Emergency Multisig:    ", r.emergencyMultisig);
        console2.log("  Oracle Admin:          ", r.oracleAdmin);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify contracts on Basescan (--verify flag)");
        console2.log("  2. Wait 5 min, then call oracle.recordObservation() for TWAR seeding");
        console2.log("  3. Publish deployment report at divigent.ai/audit");
    }
}
