const BASE_SEPOLIA_CHAIN_ID = 84532n;
const BASE_SEPOLIA_RPC_URL = "https://sepolia.base.org";
const USDC_DECIMALS = 6;
const DEMO_DEPOSIT_USDC = "10";
const DEMO_MAX_DEPOSITS = 25n;
const DEMO_WALLET_ADDRESS = "0x0447E4EA82EeeD2bb5b64D7C74A28AFE3e9249e6";
const DEMO_API_URL = (
  new URLSearchParams(window.location.search).get("api") ||
  window.DIVIGENT_DEMO_API_URL ||
  "https://divigent-demo-api.harshbhatt0151.workers.dev"
).replace(/\/+$/, "");
const BASE_SEPOLIA_EXPLORER_TX_URL = "https://sepolia.basescan.org/tx/";
const RAY = 10n ** 27n;
const MORPHO_SWITCH_HURDLE_RAY = RAY / 200n;
const PROJECTION_DECIMALS = 9;
const POSITION_DISPLAY_DECIMALS = 4;
const YIELD_DISPLAY_DECIMALS = 6;
const ACTION_STATUS_CLEAR_MS = 4500;
const PROJECTION_SCALE = 10n ** BigInt(PROJECTION_DECIMALS - USDC_DECIMALS);
const VAULT_TYPES = {
  AAVE: 0,
  MORPHO: 1
};

const BRAND_ASSETS = {
  aave: "./assets/brands/aave-token-round.svg",
  morpho: "./assets/brands/morpho-symbol.svg",
  usdc: "./assets/brands/usdc-token.svg"
};

const ADDRESSES = {
  usdc: "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f",
  dvUsdc: "0xD518B1329d0EC47EeC45775A988a18f93C37862A",
  router: "0x17180C48f904D2b675bBa67519b7879F6b036053"
};

const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)"
];

const ROUTER_ABI = [
  "function ORACLE() view returns (address)",
  "function getPosition(address wallet) view returns (uint256 depositedUSDC, uint256 currentValue, uint256 accruedYield)",
  "function getCurrentAllocation() view returns (uint256 aaveAssets, uint256 morphoAssets)",
  "function getRecommendedRoute(uint256 amount) view returns (uint8 vaultType)",
  "function oracleStatus() view returns (uint256 lastObservationTime, bool fresh)"
];

const ORACLE_ABI = [
  "function getAllRates() view returns (tuple(address vault, uint8 vaultType, uint256 spotRate, uint256 twarRate, bool isSafe)[] rates)"
];

const state = {
  ready: false,
  chainOk: false,
  pendingAction: null,
  address: null,
  eth: 0n,
  usdc: 0n,
  shares: 0n,
  deposited: 0n,
  currentValue: 0n,
  accruedYield: 0n,
  aaveAssets: 0n,
  morphoAssets: 0n,
  recommendedRoute: null,
  actionMessage: "",
  actionTone: "neutral",
  cooldownUntil: 0,
  apyByVault: {
    [VAULT_TYPES.AAVE]: 0n,
    [VAULT_TYPES.MORPHO]: 0n
  },
  provider: null,
  contracts: null
};

const els = {
  networkBadge: document.querySelector("#networkBadge"),
  depositButton: document.querySelector("#depositButton"),
  withdrawButton: document.querySelector("#withdrawButton"),
  actionStatus: document.querySelector("#actionStatus"),
  usdcBalance: document.querySelector("#usdcBalance"),
  shareBalance: document.querySelector("#shareBalance"),
  routeNote: document.querySelector("#routeNote"),
  positionBadge: document.querySelector("#positionBadge"),
  projectedYield: document.querySelector("#projectedYield"),
  elapsedTime: document.querySelector("#elapsedTime"),
  depositedValue: document.querySelector("#depositedValue"),
  positionValue: document.querySelector("#positionValue"),
  activityLog: document.querySelector("#activityLog")
};

let actionStatusTimer = null;
let cooldownTimer = null;

function requireEthers() {
  if (!window.ethers) {
    throw new Error("ethers did not load. Check the ethers CDN script request.");
  }
  return window.ethers;
}

function walletModeLabel() {
  return "Demo wallet";
}

function parseUsdc(value) {
  const [whole, fraction = ""] = value.split(".");
  const padded = fraction.padEnd(USDC_DECIMALS, "0").slice(0, USDC_DECIMALS);
  return BigInt(whole) * 10n ** BigInt(USDC_DECIMALS) + BigInt(padded || "0");
}

function formatFixed(value, decimals = 2, valueDecimals = USDC_DECIMALS) {
  let scaledValue = value;

  if (valueDecimals > decimals) {
    const divisor = 10n ** BigInt(valueDecimals - decimals);
    scaledValue = (value + divisor / 2n) / divisor;
  } else if (valueDecimals < decimals) {
    scaledValue = value * 10n ** BigInt(decimals - valueDecimals);
  }

  if (decimals === 0) return `${scaledValue}`;

  const unit = 10n ** BigInt(decimals);
  const whole = scaledValue / unit;
  const fraction = (scaledValue % unit).toString().padStart(decimals, "0");
  return `${whole}.${fraction}`;
}

function formatToken(value, decimals = 2, tokenDecimals = USDC_DECIMALS) {
  return formatFixed(value, decimals, tokenDecimals);
}

function formatScaled(value, decimals = PROJECTION_DECIMALS) {
  return formatFixed(value, decimals, PROJECTION_DECIMALS);
}

function formatApy(value) {
  const hundredthsOfPercent = (value * 10000n + RAY / 2n) / RAY;
  const whole = hundredthsOfPercent / 100n;
  const fraction = (hundredthsOfPercent % 100n).toString().padStart(2, "0");
  return `${whole}.${fraction}%`;
}

function formatApyGap(value) {
  return formatApy(value < 0n ? -value : value);
}

function demoDepositAmount() {
  return parseUsdc(DEMO_DEPOSIT_USDC);
}

function demoMaxDeposited() {
  return demoDepositAmount() * DEMO_MAX_DEPOSITS;
}

function demoDepositCount() {
  const amount = demoDepositAmount();
  if (amount === 0n) return 0n;
  return state.deposited / amount;
}

function canDepositMore() {
  return state.deposited + demoDepositAmount() <= demoMaxDeposited();
}

function shortHash(hash) {
  return `${hash.slice(0, 10)}...${hash.slice(-6)}`;
}

function vaultName(vaultType) {
  if (vaultType === VAULT_TYPES.AAVE) return "Aave";
  if (vaultType === VAULT_TYPES.MORPHO) return "Morpho";
  return "--";
}

function brandKey(label) {
  if (label === "Aave") return "aave";
  if (label === "Morpho") return "morpho";
  if (label === "USDC") return "usdc";
  return null;
}

function createBrandIcon(label, className = "brand-symbol") {
  const key = brandKey(label);
  if (!key) return document.createTextNode("");

  const icon = document.createElement("img");
  icon.className = `${className} ${key}-symbol`;
  icon.src = BRAND_ASSETS[key];
  icon.alt = "";
  icon.setAttribute("aria-hidden", "true");
  return icon;
}

function createBrandInline(label) {
  const span = document.createElement("span");
  span.className = `brand-inline ${brandKey(label) || "unknown"}-inline`;
  span.append(createBrandIcon(label), document.createTextNode(label));
  return span;
}

function setBrandedText(element, text) {
  element.replaceChildren();

  const pattern = /Aave|Morpho|USDC/g;
  let index = 0;
  let match;

  while ((match = pattern.exec(text)) !== null) {
    const before = text[match.index - 1] || "";
    const after = text[match.index + match[0].length] || "";
    const embedded = /[A-Za-z0-9]/.test(before) || /[A-Za-z0-9]/.test(after);

    if (embedded) continue;

    if (match.index > index) {
      element.append(document.createTextNode(text.slice(index, match.index)));
    }

    element.append(createBrandInline(match[0]));
    index = match.index + match[0].length;
  }

  if (index < text.length) {
    element.append(document.createTextNode(text.slice(index)));
  }
}

function createUsdcAmount(value) {
  const span = document.createElement("span");
  span.className = "token-amount";

  const number = document.createElement("span");
  number.className = "token-number";
  number.textContent = value;

  span.append(number, createBrandInline("USDC"));
  return span;
}

function setUsdcAmount(element, value) {
  element.replaceChildren(createUsdcAmount(value));
}

function parseVaultType(value) {
  if (value === null || value === undefined) return null;
  return Number(value);
}

function rateField(rate, key, index) {
  return BigInt(rate?.[key] ?? rate?.[index] ?? 0);
}

function updateRates(rates) {
  state.apyByVault[VAULT_TYPES.AAVE] = 0n;
  state.apyByVault[VAULT_TYPES.MORPHO] = 0n;

  for (const rate of rates || []) {
    const vaultType = parseVaultType(rate?.vaultType ?? rate?.[1]);
    if (vaultType === null) continue;

    const twarRate = rateField(rate, "twarRate", 3);
    const spotRate = rateField(rate, "spotRate", 2);
    state.apyByVault[vaultType] = twarRate > 0n ? twarRate : spotRate;
  }
}

function getProjectedPositionValue() {
  return state.currentValue * PROJECTION_SCALE;
}

function getCurrentPositionApyRay() {
  const totalAllocated = state.aaveAssets + state.morphoAssets;
  if (totalAllocated > 0n) {
    const weightedAave = state.aaveAssets * state.apyByVault[VAULT_TYPES.AAVE];
    const weightedMorpho = state.morphoAssets * state.apyByVault[VAULT_TYPES.MORPHO];
    return (weightedAave + weightedMorpho) / totalAllocated;
  }

  if (state.recommendedRoute !== null) {
    return state.apyByVault[state.recommendedRoute] ?? 0n;
  }

  return 0n;
}

function routeLabel(hasPosition) {
  if (hasPosition) {
    if (state.aaveAssets > 0n && state.morphoAssets > 0n) return "Aave + Morpho";
    if (state.aaveAssets > 0n) return vaultName(VAULT_TYPES.AAVE);
    if (state.morphoAssets > 0n) return vaultName(VAULT_TYPES.MORPHO);
  }

  return vaultName(state.recommendedRoute);
}

function routeDecisionLine(hasPosition) {
  const aaveApy = state.apyByVault[VAULT_TYPES.AAVE];
  const morphoApy = state.apyByVault[VAULT_TYPES.MORPHO];
  const switchHurdle = formatApyGap(MORPHO_SWITCH_HURDLE_RAY);
  const prefix = hasPosition ? "This deposit went through" : "Next deposit will go through";

  if (hasPosition && state.aaveAssets > 0n && state.morphoAssets > 0n) {
    return "This position spans Aave and Morpho from prior deposits.";
  }

  if (state.recommendedRoute === null || (aaveApy === 0n && morphoApy === 0n)) {
    return "Loading route comparison.";
  }

  if (state.recommendedRoute === VAULT_TYPES.AAVE) {
    if (morphoApy > aaveApy) {
      const morphoGap = morphoApy - aaveApy;
      if (morphoGap > MORPHO_SWITCH_HURDLE_RAY) {
        return `${prefix} Aave because Morpho did not pass the route safety checks.`;
      }

      return `${prefix} Aave because Morpho is only ${formatApyGap(
        morphoGap
      )} higher, not above the ${switchHurdle} switch threshold.`;
    }

    if (morphoApy === aaveApy) {
      return `${prefix} Aave because Aave and Morpho are tied.`;
    }

    return `${prefix} Aave because it is ${formatApyGap(aaveApy - morphoApy)} higher than Morpho.`;
  }

  if (state.recommendedRoute === VAULT_TYPES.MORPHO) {
    if (morphoApy <= aaveApy) {
      return `${prefix} Morpho by the current router recommendation.`;
    }

    return `${prefix} Morpho because it is ${formatApyGap(
      morphoApy - aaveApy
    )} higher than Aave, clearing the ${switchHurdle} threshold.`;
  }

  return "Route comparison unavailable.";
}

function getProjectedAnnualYieldValue(projectedPositionValue) {
  if (state.shares === 0n) return 0n;

  return (projectedPositionValue * getCurrentPositionApyRay()) / RAY;
}

function addActivity(action, txHash) {
  if (!txHash) return;

  const item = document.createElement("div");
  item.className = "activity-item";

  const label = document.createElement("span");
  label.className = "activity-action";
  label.textContent = action;

  const separator = document.createElement("span");
  separator.className = "activity-separator";
  separator.textContent = "-";

  const link = document.createElement("a");
  link.className = "tx-link";
  link.href = `${BASE_SEPOLIA_EXPLORER_TX_URL}${txHash}`;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  link.textContent = `BaseScan ${shortHash(txHash)}`;

  item.append(label, separator, link);
  els.activityLog.prepend(item);
}

function addLog(message, txHash) {
  if (!txHash) return;
  const action = message.toLowerCase().includes("withdraw") ? "Withdraw" : "Deposit";
  addActivity(action, txHash);
}

function errorMessage(error) {
  return error?.shortMessage || error?.reason || error?.message || "Transaction failed";
}

function cooldownRemainingMs() {
  return Math.max(0, state.cooldownUntil - Date.now());
}

function clearActionStatusTimer() {
  if (!actionStatusTimer) return;
  clearTimeout(actionStatusTimer);
  actionStatusTimer = null;
}

function setActionStatus(message, tone = "neutral", autoClearMs = 0) {
  clearActionStatusTimer();
  state.actionMessage = message;
  state.actionTone = tone;
  render();

  if (!message || autoClearMs <= 0) return;
  actionStatusTimer = setTimeout(() => {
    if (state.actionMessage !== message) return;
    state.actionMessage = "";
    state.actionTone = "neutral";
    render();
  }, autoClearMs);
}

function startActionCooldown(error) {
  const retryAfterMs = Number(error?.retryAfterMs || 0) || 3000;
  state.cooldownUntil = Date.now() + retryAfterMs;

  if (cooldownTimer) clearTimeout(cooldownTimer);
  cooldownTimer = setTimeout(() => {
    if (cooldownRemainingMs() > 0) return;
    state.cooldownUntil = 0;
    state.actionMessage = "";
    state.actionTone = "neutral";
    render();
  }, retryAfterMs + 50);

  setActionStatus(errorMessage(error), "warning");
}

function showActionError(error) {
  console.error(error);
  if (error?.status === 429) {
    startActionCooldown(error);
    return;
  }

  setActionStatus(errorMessage(error), "warning");
}

function idempotencyKey() {
  if (window.crypto?.randomUUID) return window.crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

async function callDemoApi(action) {
  const response = await fetch(`${DEMO_API_URL}/${action}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "idempotency-key": idempotencyKey()
    },
    body: "{}"
  });
  const result = await response.json().catch(() => ({}));

  if (!response.ok) {
    const error = new Error(result.error || `Demo API ${action} failed with status ${response.status}`);
    const retryAfterSeconds = Number(response.headers.get("retry-after") || 0);
    error.status = response.status;
    error.retryAfterMs = Number(result.retryAfterMs || 0) || retryAfterSeconds * 1000;
    throw error;
  }

  return result;
}

function setPending(action) {
  state.pendingAction = action;
  if (!action) {
    render();
    return;
  }

  setActionStatus(action === "deposit" ? `Depositing ${DEMO_DEPOSIT_USDC} USDC...` : "Withdrawing position...");
}

async function initializeWallet() {
  if (state.ready) return;

  const ethers = requireEthers();
  state.provider = new ethers.JsonRpcProvider(BASE_SEPOLIA_RPC_URL);

  const network = await state.provider.getNetwork();
  state.chainOk = network.chainId === BASE_SEPOLIA_CHAIN_ID;
  if (!state.chainOk) {
    throw new Error(`${walletModeLabel()} is on chain ${network.chainId}; expected Base Sepolia ${BASE_SEPOLIA_CHAIN_ID}.`);
  }

  state.address = DEMO_WALLET_ADDRESS;
  const router = new ethers.Contract(ADDRESSES.router, ROUTER_ABI, state.provider);
  const oracleAddress = await router.ORACLE();
  state.contracts = {
    usdc: new ethers.Contract(ADDRESSES.usdc, ERC20_ABI, state.provider),
    dvUsdc: new ethers.Contract(ADDRESSES.dvUsdc, ERC20_ABI, state.provider),
    router,
    oracle: new ethers.Contract(oracleAddress, ORACLE_ABI, state.provider)
  };
  state.ready = true;
}

function render() {
  const hasPosition = state.shares > 0n;
  const busy = Boolean(state.pendingAction) || cooldownRemainingMs() > 0;
  const depositsUsed = demoDepositCount();
  const depositCapacityLeft = canDepositMore();
  const projectedPositionValue = getProjectedPositionValue();
  const projectedAnnualYield = getProjectedAnnualYieldValue(projectedPositionValue);
  const positionValue = hasPosition
    ? formatScaled(projectedPositionValue, POSITION_DISPLAY_DECIMALS)
    : "0.00";
  const routeText = routeLabel(hasPosition);
  const isBlendedRoute = hasPosition && state.aaveAssets > 0n && state.morphoAssets > 0n;
  const apyRay = getCurrentPositionApyRay();

  els.networkBadge.textContent = state.chainOk ? "Base Sepolia" : "Loading";
  els.networkBadge.className = `status-pill ${state.chainOk ? "success" : "neutral"}`;

  els.usdcBalance.textContent = formatToken(state.usdc);
  setUsdcAmount(els.shareBalance, positionValue);
  setBrandedText(els.routeNote, routeDecisionLine(hasPosition));

  els.positionBadge.textContent = `${depositsUsed} / ${DEMO_MAX_DEPOSITS} deposits`;
  els.positionBadge.className = `status-pill ${
    depositCapacityLeft ? (hasPosition ? "success" : "neutral") : "warning"
  }`;
  if (hasPosition) {
    els.projectedYield.replaceChildren(
      createUsdcAmount(formatScaled(projectedAnnualYield, YIELD_DISPLAY_DECIMALS))
    );
    setBrandedText(
      els.elapsedTime,
      `At ${formatApy(apyRay)} ${isBlendedRoute ? "blended APY via " : ""}${routeText}${
        isBlendedRoute ? "" : " APY"
      }`
    );
  } else {
    els.projectedYield.textContent = "0";
    els.elapsedTime.textContent = "Deposit to start projected APY";
  }
  setUsdcAmount(els.depositedValue, formatToken(state.deposited));
  setUsdcAmount(els.positionValue, positionValue);

  els.depositButton.textContent =
    state.pendingAction === "deposit"
      ? "Depositing..."
      : depositCapacityLeft
        ? `Deposit ${DEMO_DEPOSIT_USDC} USDC`
        : "Deposit limit reached";
  els.withdrawButton.textContent = state.pendingAction === "withdraw" ? "Withdrawing..." : "Withdraw";
  els.depositButton.disabled = busy || !depositCapacityLeft;
  els.withdrawButton.disabled = busy;

  if (els.actionStatus) {
    els.actionStatus.hidden = !state.actionMessage;
    els.actionStatus.textContent = state.actionMessage;
    els.actionStatus.className = `action-status ${state.actionTone}`;
  }
}

async function refreshBalances() {
  try {
    await initializeWallet();

    const depositAmount = demoDepositAmount();
    const [eth, usdc, shares, position, allocation, recommendedRoute, rates] = await Promise.all([
      state.provider.getBalance(state.address),
      state.contracts.usdc.balanceOf(state.address),
      state.contracts.dvUsdc.balanceOf(state.address),
      state.contracts.router.getPosition(state.address),
      state.contracts.router.getCurrentAllocation(),
      state.contracts.router.getRecommendedRoute(depositAmount).catch(() => null),
      state.contracts.oracle.getAllRates().catch(() => [])
    ]);

    state.eth = eth;
    state.usdc = usdc;
    state.shares = shares;
    state.deposited = position[0];
    state.currentValue = position[1];
    state.accruedYield = position[2];
    state.aaveAssets = allocation[0];
    state.morphoAssets = allocation[1];
    state.recommendedRoute = parseVaultType(recommendedRoute);
    updateRates(rates);
    render();
  } catch (error) {
    addLog(errorMessage(error));
    render();
  }
}

async function deposit() {
  try {
    setPending("deposit");
    await refreshBalances();
    if (!canDepositMore()) {
      throw new Error("Deposit limit reached for the shared demo wallet.");
    }

    const result = await callDemoApi("deposit");
    addActivity("Deposit", result.txHash);
    await refreshBalances();
    setActionStatus("Deposit confirmed.", "success", ACTION_STATUS_CLEAR_MS);
  } catch (error) {
    showActionError(error);
  } finally {
    setPending(null);
  }
}

async function withdraw() {
  try {
    setPending("withdraw");
    await refreshBalances();

    if (state.shares === 0n) {
      setActionStatus("No dvUSDC position to withdraw yet.", "warning", ACTION_STATUS_CLEAR_MS);
      return;
    }

    const result = await callDemoApi("withdraw");
    addActivity("Withdraw", result.txHash);
    await refreshBalances();
    setActionStatus("Withdraw confirmed.", "success", ACTION_STATUS_CLEAR_MS);
  } catch (error) {
    showActionError(error);
  } finally {
    setPending(null);
  }
}

function publicState() {
  return {
    ready: state.ready,
    chainOk: state.chainOk,
    address: state.address,
    eth: state.eth.toString(),
    usdc: state.usdc.toString(),
    shares: state.shares.toString(),
    deposited: state.deposited.toString(),
    currentValue: state.currentValue.toString(),
    accruedYield: state.accruedYield.toString(),
    aaveAssets: state.aaveAssets.toString(),
    morphoAssets: state.morphoAssets.toString(),
    recommendedRoute: state.recommendedRoute,
    aaveApyRay: state.apyByVault[VAULT_TYPES.AAVE].toString(),
    morphoApyRay: state.apyByVault[VAULT_TYPES.MORPHO].toString(),
    projectedPositionValue: getProjectedPositionValue().toString(),
    projectedAnnualYield: getProjectedAnnualYieldValue(getProjectedPositionValue()).toString()
  };
}

window.divigentDemo = {
  addresses: ADDRESSES,
  abi: {
    erc20: ERC20_ABI,
    router: ROUTER_ABI,
    oracle: ORACLE_ABI
  },
  refresh: refreshBalances,
  deposit,
  withdraw,
  apiUrl: DEMO_API_URL,
  state: publicState
};

window.deposit = deposit;
window.withdraw = withdraw;
window.depositUsdc = deposit;
window.withdrawUsdc = withdraw;

render();
refreshBalances();
