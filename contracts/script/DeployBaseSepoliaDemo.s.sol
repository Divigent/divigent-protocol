// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DivigentFeeCollector} from "../src/DivigentFeeCollector.sol";
import {DivigentVaultRouter} from "../src/DivigentVaultRouter.sol";
import {DivigentYieldOracle} from "../src/DivigentYieldOracle.sol";
import {DvUSDC} from "../src/dvUSDC.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IMorphoVault} from "../src/interfaces/IMorphoVault.sol";

/// @title DemoFixedApyMorphoVault
/// @notice Minimal ERC-4626-like Morpho stand-in for the Base Sepolia MVP demo.
/// @dev The vault reports a deterministic 0.80% APY through `convertToAssets`.
///      It is intended only as an oracle/routing demo dependency, not as a
///      production vault implementation.
contract DemoFixedApyMorphoVault is IMorphoVault {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_SCALE = 1e18;
    uint256 public constant ASSET_SCALE = 1e6;
    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;
    uint256 public constant FIXED_APY_RAY = 8e24; // 0.80%

    IERC20 public immutable USDC;
    uint256 public immutable DEPLOYED_AT;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroUsdc();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroUsdc();
        USDC = IERC20(usdc_);
        DEPLOYED_AT = block.timestamp;
    }

    function asset() external view override returns (address) {
        return address(USDC);
    }

    function totalAssets() external view override returns (uint256) {
        return convertToAssets(totalSupply);
    }

    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256 assets) {
        return convertToAssets(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        return _assetsToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        uint256 baseAssets = Math.mulDiv(shares, ASSET_SCALE, SHARE_SCALE);
        if (baseAssets == 0) return 0;

        uint256 elapsed = block.timestamp - DEPLOYED_AT;
        uint256 yieldAssets = Math.mulDiv(baseAssets, FIXED_APY_RAY * elapsed, RAY * SECONDS_PER_YEAR);

        assets = baseAssets + yieldAssets;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf[owner];
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 claim = convertToAssets(balanceOf[owner]);
        uint256 liquid = USDC.balanceOf(address(this));
        return claim < liquid ? claim : liquid;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();

        USDC.safeTransferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;

        emit Transfer(address(0), receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        if (receiver == address(0) || owner == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();

        _spendAllowance(owner, shares);

        uint256 ownerShares = balanceOf[owner];
        if (shares > ownerShares) revert InsufficientShares(shares, ownerShares);

        assets = convertToAssets(shares);
        uint256 liquid = USDC.balanceOf(address(this));
        if (assets > liquid) revert InsufficientLiquidity(assets, liquid);

        balanceOf[owner] = ownerShares - shares;
        totalSupply -= shares;
        USDC.safeTransfer(receiver, assets);

        emit Transfer(owner, address(0), shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        if (receiver == address(0) || owner == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();

        uint256 available = maxWithdraw(owner);
        if (assets > available) revert InsufficientLiquidity(assets, available);

        shares = _assetsToShares(assets, Math.Rounding.Ceil);
        _spendAllowance(owner, shares);

        uint256 ownerShares = balanceOf[owner];
        if (shares > ownerShares) revert InsufficientShares(shares, ownerShares);

        balanceOf[owner] = ownerShares - shares;
        totalSupply -= shares;
        USDC.safeTransfer(receiver, assets);

        emit Transfer(owner, address(0), shares);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _assetsToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256 shares) {
        if (assets == 0) return 0;

        uint256 elapsed = block.timestamp - DEPLOYED_AT;
        uint256 denominator = ASSET_SCALE * (RAY * SECONDS_PER_YEAR + FIXED_APY_RAY * elapsed);
        uint256 numerator = SHARE_SCALE * RAY * SECONDS_PER_YEAR;

        shares = Math.mulDiv(assets, numerator, denominator, rounding);
    }

    function _spendAllowance(address owner, uint256 shares) internal {
        if (msg.sender == owner) return;

        uint256 currentAllowance = allowance[owner][msg.sender];
        if (currentAllowance != type(uint256).max) {
            allowance[owner][msg.sender] = currentAllowance - shares;
            emit Approval(owner, msg.sender, allowance[owner][msg.sender]);
        }
    }
}

/// @title DeployBaseSepoliaDemo
/// @notice Deploys the Divigent MVP demo stack on Base Sepolia with a fixed
///         0.80% APY mock Morpho vault.
contract DeployBaseSepoliaDemo is Script {
    // Official Aave address-book Base Sepolia values:
    // https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3BaseSepolia.sol
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant AAVE_POOL = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address constant AAVE_ATOKEN = 0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC;

    uint256 constant MOCK_MORPHO_APY_RAY = 8e24; // 0.80%
    uint256 constant ROUTING_DIFFERENTIAL_RAY = 5e24; // 0.50%

    struct DeployReport {
        address deployer;
        address treasury;
        address emergencyMultisig;
        address mockMorphoVault;
        address oracle;
        address feeCollector;
        address dvUsdc;
        address router;
        uint256 chainId;
        uint256 deployedAt;
        uint256 aaveSupplyApyRayAtDeploy;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envAddress("TREASURY");
        address emergencyMultisig = vm.envAddress("EMERGENCY_MULTISIG");

        uint256 aaveSupplyApyRay = _preDeployChecks(treasury, emergencyMultisig);

        console2.log("");
        console2.log("=== Divigent Protocol: Base Sepolia Demo Deployment ===");
        console2.log("Deployer:           ", deployer);
        console2.log("Treasury:           ", treasury);
        console2.log("Emergency multisig: ", emergencyMultisig);
        console2.log("Aave supply APY ray:", aaveSupplyApyRay);
        console2.log("Mock Morpho APY ray:", MOCK_MORPHO_APY_RAY);
        console2.log("");

        vm.startBroadcast(deployerKey);

        DemoFixedApyMorphoVault mockMorpho = new DemoFixedApyMorphoVault(USDC);

        DivigentYieldOracle oracle = new DivigentYieldOracle(AAVE_POOL, AAVE_ATOKEN, USDC, address(mockMorpho));

        uint256 nonce = vm.getNonce(deployer);
        address predictedRouter = vm.computeCreateAddress(deployer, nonce + 2);

        DivigentFeeCollector feeCollector = new DivigentFeeCollector(USDC, treasury, predictedRouter);

        DvUSDC dvUsdc = new DvUSDC(predictedRouter);

        DivigentVaultRouter router = new DivigentVaultRouter(
            USDC,
            AAVE_POOL,
            AAVE_ATOKEN,
            address(mockMorpho),
            address(oracle),
            address(feeCollector),
            address(dvUsdc),
            emergencyMultisig
        );

        require(address(router) == predictedRouter, "Router address mismatch");

        vm.stopBroadcast();

        _postDeployVerification(mockMorpho, oracle, feeCollector, dvUsdc, router, treasury, emergencyMultisig);

        DeployReport memory report = DeployReport({
            deployer: deployer,
            treasury: treasury,
            emergencyMultisig: emergencyMultisig,
            mockMorphoVault: address(mockMorpho),
            oracle: address(oracle),
            feeCollector: address(feeCollector),
            dvUsdc: address(dvUsdc),
            router: address(router),
            chainId: block.chainid,
            deployedAt: block.timestamp,
            aaveSupplyApyRayAtDeploy: aaveSupplyApyRay
        });

        _writeReport(report);
        _logReport(report);
    }

    function _preDeployChecks(address treasury, address emergencyMultisig)
        internal
        view
        returns (uint256 aaveSupplyApyRay)
    {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "Wrong chain: Base Sepolia only");
        require(treasury != address(0), "TREASURY must not be zero");
        require(emergencyMultisig != address(0), "EMERGENCY_MULTISIG must not be zero");
        require(USDC.code.length > 0, "Base Sepolia USDC missing code");
        require(AAVE_POOL.code.length > 0, "Base Sepolia Aave Pool missing code");
        require(AAVE_ATOKEN.code.length > 0, "Base Sepolia aUSDC missing code");

        (,, uint128 currentLiquidityRate,,,,,, address reserveAToken,,,,,,) =
            IAaveV3Pool(AAVE_POOL).getReserveData(USDC);

        require(reserveAToken == AAVE_ATOKEN, "Aave reserve aToken mismatch");

        aaveSupplyApyRay = uint256(currentLiquidityRate);

        require(
            MOCK_MORPHO_APY_RAY < aaveSupplyApyRay + ROUTING_DIFFERENTIAL_RAY,
            "Mock Morpho would clear routing threshold"
        );
    }

    function _postDeployVerification(
        DemoFixedApyMorphoVault mockMorpho,
        DivigentYieldOracle oracle,
        DivigentFeeCollector feeCollector,
        DvUSDC dvUsdc,
        DivigentVaultRouter router,
        address treasury,
        address emergencyMultisig
    ) internal view {
        require(mockMorpho.asset() == USDC, "Mock Morpho asset mismatch");
        require(mockMorpho.FIXED_APY_RAY() == MOCK_MORPHO_APY_RAY, "Mock Morpho APY mismatch");

        require(address(router.USDC()) == USDC, "Router USDC mismatch");
        require(address(router.AAVE_POOL()) == AAVE_POOL, "Router Aave Pool mismatch");
        require(address(router.A_TOKEN()) == AAVE_ATOKEN, "Router aToken mismatch");
        require(address(router.MORPHO_VAULT()) == address(mockMorpho), "Router Morpho mismatch");
        require(address(router.ORACLE()) == address(oracle), "Router Oracle mismatch");
        require(address(router.FEE_COLLECTOR()) == address(feeCollector), "Router FeeCollector mismatch");
        require(address(router.DV_USDC()) == address(dvUsdc), "Router dvUSDC mismatch");
        require(router.EMERGENCY_MULTISIG() == emergencyMultisig, "Router emergency mismatch");

        require(address(oracle.MORPHO_VAULT()) == address(mockMorpho), "Oracle Morpho mismatch");
        require(feeCollector.VAULT_ROUTER() == address(router), "FeeCollector router mismatch");
        require(feeCollector.treasury() == treasury, "FeeCollector treasury mismatch");
        require(dvUsdc.VAULT_ROUTER() == address(router), "dvUSDC router mismatch");
        require(router.morphoViewGas() == router.MIN_MORPHO_VIEW_GAS(), "Morpho view gas mismatch");
        require(dvUsdc.totalSupply() == 0, "dvUSDC supply should be zero");
        require(router.totalVaultAssets() == 0, "Router TVL should be zero");
    }

    function _writeReport(DeployReport memory r) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", r.chainId);
        vm.serializeUint(obj, "deployedAt", r.deployedAt);
        vm.serializeUint(obj, "aaveSupplyApyRayAtDeploy", r.aaveSupplyApyRayAtDeploy);
        vm.serializeUint(obj, "mockMorphoApyRay", MOCK_MORPHO_APY_RAY);
        vm.serializeAddress(obj, "deployer", r.deployer);
        vm.serializeAddress(obj, "treasury", r.treasury);
        vm.serializeAddress(obj, "emergencyMultisig", r.emergencyMultisig);
        vm.serializeAddress(obj, "usdc", USDC);
        vm.serializeAddress(obj, "aavePool", AAVE_POOL);
        vm.serializeAddress(obj, "aaveAToken", AAVE_ATOKEN);
        vm.serializeAddress(obj, "mockMorphoVault", r.mockMorphoVault);
        vm.serializeAddress(obj, "oracle", r.oracle);
        vm.serializeAddress(obj, "feeCollector", r.feeCollector);
        vm.serializeAddress(obj, "dvUsdc", r.dvUsdc);
        string memory json = vm.serializeAddress(obj, "router", r.router);

        string memory outPath = "deployments/base-sepolia-demo.json";
        vm.writeJson(json, outPath);
        console2.log("Deployment report written to:", outPath);
    }

    function _logReport(DeployReport memory r) internal pure {
        console2.log("");
        console2.log("=== Demo Deployment Complete ===");
        console2.log("Mock Morpho vault:    ", r.mockMorphoVault);
        console2.log("DivigentYieldOracle:  ", r.oracle);
        console2.log("DivigentFeeCollector: ", r.feeCollector);
        console2.log("DvUSDC:               ", r.dvUsdc);
        console2.log("DivigentVaultRouter:  ", r.router);
        console2.log("");
        console2.log("External dependencies:");
        console2.log("USDC:                 ", USDC);
        console2.log("Aave V3 Pool:         ", AAVE_POOL);
        console2.log("Aave aUSDC:           ", AAVE_ATOKEN);
        console2.log("");
        console2.log("Routing story:");
        console2.log("Mock Morpho APY:      0.80%");
        console2.log("Required spread:      0.50%");
        console2.log("Deposits route Aave while Aave APY keeps the Morpho spread below threshold.");
    }
}
