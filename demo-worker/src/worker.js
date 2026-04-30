import { ethers } from "ethers";

const BASE_SEPOLIA_CHAIN_ID = 84532n;
const USDC_DECIMALS = 6n;
const DEMO_DEPOSIT_USDC = 10n;
const DEMO_DEPOSIT_AMOUNT = DEMO_DEPOSIT_USDC * 10n ** USDC_DECIMALS;
const DEMO_MAX_DEPOSITS = 25n;
const DEMO_MAX_DEPOSITED = DEMO_DEPOSIT_AMOUNT * DEMO_MAX_DEPOSITS;
const MAX_UINT256 = (1n << 256n) - 1n;
const ACTION_COOLDOWN_MS = 3000;
const IP_ACTION_COOLDOWN_MS = 10000;
const IP_DAILY_DEPOSIT_LIMIT = 3;
const IDEMPOTENCY_TTL_MS = 60000;
const COORDINATOR_NAME = "divigent-base-sepolia-demo-wallet-v1";

const DEMO_WALLET_ADDRESS = "0x0447E4EA82EeeD2bb5b64D7C74A28AFE3e9249e6";

const ADDRESSES = {
  usdc: "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f",
  dvUsdc: "0xD518B1329d0EC47EeC45775A988a18f93C37862A",
  router: "0x17180C48f904D2b675bBa67519b7879F6b036053"
};

const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)"
];

const ROUTER_ABI = [
  "function authorizedWallets(address wallet) view returns (bool)",
  "function initialize()",
  "function deposit(uint256 amount, address wallet, uint256 minSharesOut) returns (uint256)",
  "function withdraw(uint256 shares, address wallet, uint256 minUsdcOut) returns (uint256)",
  "function getPosition(address wallet) view returns (uint256 depositedUSDC, uint256 currentValue, uint256 accruedYield)"
];

class HttpError extends Error {
  constructor(status, message, options = {}) {
    super(message);
    this.status = status;
    this.retryAfterMs = options.retryAfterMs;
  }
}

function json(data, status = 200, request, env, extraHeaders = {}) {
  return new Response(JSON.stringify(data, bigintReplacer), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...corsHeaders(request, env),
      ...extraHeaders
    }
  });
}

function bigintReplacer(_key, value) {
  return typeof value === "bigint" ? value.toString() : value;
}

function jsonSafe(value) {
  return JSON.parse(JSON.stringify(value, bigintReplacer));
}

function allowedOrigins(env) {
  return String(env.ALLOWED_ORIGINS || "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
}

function requestOrigin(request) {
  return request.headers.get("origin") || "";
}

function isAllowedOrigin(request, env) {
  const origin = requestOrigin(request);
  if (!origin) return true;
  return allowedOrigins(env).includes(origin);
}

function corsHeaders(request, env) {
  const origin = requestOrigin(request);
  const allowOrigin = origin && isAllowedOrigin(request, env) ? origin : "*";
  return {
    "access-control-allow-origin": allowOrigin,
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type,idempotency-key",
    "access-control-max-age": "86400",
    "vary": "Origin"
  };
}

function assertAllowedOrigin(request, env) {
  if (!isAllowedOrigin(request, env)) {
    throw new HttpError(403, "Origin is not allowed for the demo API.");
  }
}

function clientIp(request) {
  const forwarded = request.headers.get("cf-connecting-ip") || request.headers.get("x-forwarded-for");
  return forwarded?.split(",")[0]?.trim() || "unknown";
}

function utcDay() {
  return new Date().toISOString().slice(0, 10);
}

function idempotencyKey(request) {
  const value = request.headers.get("idempotency-key")?.trim();
  if (!value) return "";
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(value)) {
    throw new HttpError(400, "Invalid idempotency key.");
  }
  return value;
}

async function assertNoParameters(request) {
  const text = await request.text();
  if (!text.trim()) return;

  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new HttpError(400, "Request body must be empty JSON.");
  }

  if (payload && typeof payload === "object" && Object.keys(payload).length === 0) return;
  throw new HttpError(400, "This endpoint does not accept parameters.");
}

function provider(env) {
  return new ethers.JsonRpcProvider(env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org");
}

async function signer(env, rpcProvider) {
  if (!env.DEMO_WALLET_PRIVATE_KEY) {
    throw new HttpError(500, "Demo wallet private key is not configured.");
  }

  const wallet = new ethers.Wallet(env.DEMO_WALLET_PRIVATE_KEY, rpcProvider);
  if (wallet.address.toLowerCase() !== DEMO_WALLET_ADDRESS.toLowerCase()) {
    throw new HttpError(500, "Configured demo wallet secret does not match the fixed demo wallet.");
  }

  return wallet;
}

function contracts(runner) {
  return {
    usdc: new ethers.Contract(ADDRESSES.usdc, ERC20_ABI, runner),
    dvUsdc: new ethers.Contract(ADDRESSES.dvUsdc, ERC20_ABI, runner),
    router: new ethers.Contract(ADDRESSES.router, ROUTER_ABI, runner)
  };
}

async function readDemoState(env) {
  const rpcProvider = provider(env);
  const network = await rpcProvider.getNetwork();
  if (network.chainId !== BASE_SEPOLIA_CHAIN_ID) {
    throw new HttpError(502, `RPC is on chain ${network.chainId}; expected Base Sepolia ${BASE_SEPOLIA_CHAIN_ID}.`);
  }

  const readContracts = contracts(rpcProvider);
  const [eth, usdc, shares, position] = await Promise.all([
    rpcProvider.getBalance(DEMO_WALLET_ADDRESS),
    readContracts.usdc.balanceOf(DEMO_WALLET_ADDRESS),
    readContracts.dvUsdc.balanceOf(DEMO_WALLET_ADDRESS),
    readContracts.router.getPosition(DEMO_WALLET_ADDRESS)
  ]);
  const deposited = BigInt(position[0]);

  return {
    eth: BigInt(eth),
    usdc: BigInt(usdc),
    shares: BigInt(shares),
    deposited,
    currentValue: BigInt(position[1]),
    accruedYield: BigInt(position[2]),
    depositsUsed: deposited / DEMO_DEPOSIT_AMOUNT,
    canDeposit: deposited + DEMO_DEPOSIT_AMOUNT <= DEMO_MAX_DEPOSITED
  };
}

async function ensureCooldown(storage) {
  const now = Date.now();
  const lastActionAt = Number((await storage.get("lastActionAt")) || 0);
  const nextAllowedAt = lastActionAt + ACTION_COOLDOWN_MS;

  if (now < nextAllowedAt) {
    throw new HttpError(429, "Demo wallet is processing too quickly. Try again in a few seconds.", {
      retryAfterMs: nextAllowedAt - now
    });
  }

  await storage.put("lastActionAt", now);
}

async function ensureIpActionLimit(storage, ip) {
  if (ip === "unknown") return;

  const now = Date.now();
  const key = `ip:${ip}:lastActionAt`;
  const lastActionAt = Number((await storage.get(key)) || 0);
  const nextAllowedAt = lastActionAt + IP_ACTION_COOLDOWN_MS;

  if (now < nextAllowedAt) {
    throw new HttpError(429, "Please wait a few seconds before using the demo wallet again.", {
      retryAfterMs: nextAllowedAt - now
    });
  }

  await storage.put(key, now);
}

async function ensureDailyDepositLimit(storage, ip) {
  if (ip === "unknown") return;

  const key = `ip:${ip}:deposits:${utcDay()}`;
  const count = Number((await storage.get(key)) || 0);
  if (count >= IP_DAILY_DEPOSIT_LIMIT) {
    throw new HttpError(429, "Daily demo deposit limit reached for this network.");
  }
}

async function recordDailyDeposit(storage, ip) {
  if (ip === "unknown") return;

  const key = `ip:${ip}:deposits:${utcDay()}`;
  const count = Number((await storage.get(key)) || 0);
  await storage.put(key, count + 1);
}

async function readIdempotentResult(storage, action, ip, key) {
  if (!key) return null;

  const entry = await storage.get(`idempotency:${action}:${ip}:${key}`);
  if (!entry) return null;
  if (Date.now() - Number(entry.createdAt || 0) > IDEMPOTENCY_TTL_MS) return null;
  return entry.result || null;
}

async function writeIdempotentResult(storage, action, ip, key, result) {
  if (!key) return;

  await storage.put(`idempotency:${action}:${ip}:${key}`, {
    createdAt: Date.now(),
    result: jsonSafe(result)
  });
}

async function ensureInitialized(router, nonceRef) {
  const authorized = await router.authorizedWallets(DEMO_WALLET_ADDRESS);
  if (authorized) return null;

  const tx = await router.initialize({ nonce: nonceRef.next++ });
  await tx.wait();
  return tx.hash;
}

async function ensureDepositAllowance(usdc, walletAddress, nonceRef) {
  const allowance = await usdc.allowance(walletAddress, ADDRESSES.router);
  if (BigInt(allowance) >= DEMO_MAX_DEPOSITED) return [];

  const txHashes = [];
  if (BigInt(allowance) > 0n) {
    const resetTx = await usdc.approve(ADDRESSES.router, 0n, { nonce: nonceRef.next++ });
    await resetTx.wait();
    txHashes.push(resetTx.hash);
  }

  const approveTx = await usdc.approve(ADDRESSES.router, MAX_UINT256, {
    nonce: nonceRef.next++
  });
  await approveTx.wait();
  txHashes.push(approveTx.hash);
  return txHashes;
}

export class DemoWalletCoordinator {
  constructor(state, env) {
    this.storage = state.storage;
    this.env = env;
    this.queue = Promise.resolve();
  }

  async fetch(request) {
    try {
      assertAllowedOrigin(request, this.env);
      const url = new URL(request.url);

      if (request.method === "GET" && (url.pathname === "/state" || url.pathname === "/status")) {
        return json(await this.stateResponse(), 200, request, this.env);
      }

      if (request.method === "POST" && url.pathname === "/deposit") {
        await assertNoParameters(request);
        return json(await this.enqueue(() => this.deposit(request)), 200, request, this.env);
      }

      if (request.method === "POST" && url.pathname === "/withdraw") {
        await assertNoParameters(request);
        return json(await this.enqueue(() => this.withdraw(request)), 200, request, this.env);
      }

      throw new HttpError(404, "Demo API route not found.");
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      const retryAfterMs = Number(error.retryAfterMs || 0);
      const body = {
        error: error.message || "Demo API failed.",
        ...(retryAfterMs > 0 ? { retryAfterMs } : {})
      };
      const headers = retryAfterMs > 0 ? { "retry-after": String(Math.ceil(retryAfterMs / 1000)) } : {};
      return json(body, status, request, this.env, headers);
    }
  }

  enqueue(operation) {
    const next = this.queue.then(operation, operation);
    this.queue = next.catch(() => {});
    return next;
  }

  async stateResponse() {
    const demoState = await readDemoState(this.env);
    return {
      wallet: DEMO_WALLET_ADDRESS,
      depositAmount: DEMO_DEPOSIT_AMOUNT,
      maxDeposits: DEMO_MAX_DEPOSITS,
      maxDeposited: DEMO_MAX_DEPOSITED,
      ipDailyDepositLimit: IP_DAILY_DEPOSIT_LIMIT,
      ...demoState
    };
  }

  async deposit(request) {
    const ip = clientIp(request);
    const key = idempotencyKey(request);
    const cached = await readIdempotentResult(this.storage, "deposit", ip, key);
    if (cached) return cached;

    await ensureCooldown(this.storage);
    await ensureIpActionLimit(this.storage, ip);
    await ensureDailyDepositLimit(this.storage, ip);

    const before = await readDemoState(this.env);
    if (!before.canDeposit) {
      throw new HttpError(409, "Deposit limit reached for the shared demo wallet.");
    }
    if (before.eth === 0n) {
      throw new HttpError(409, "Demo wallet needs Base Sepolia ETH for gas.");
    }
    if (before.usdc < DEMO_DEPOSIT_AMOUNT) {
      throw new HttpError(409, "Demo wallet needs at least 10 Base Sepolia USDC.");
    }

    const rpcProvider = provider(this.env);
    const wallet = await signer(this.env, rpcProvider);
    const signedContracts = contracts(wallet);
    const nonceRef = {
      next: await rpcProvider.getTransactionCount(wallet.address, "pending")
    };

    const initializeTxHash = await ensureInitialized(signedContracts.router, nonceRef);
    const approvalTxHashes = await ensureDepositAllowance(signedContracts.usdc, wallet.address, nonceRef);
    const tx = await signedContracts.router.deposit(DEMO_DEPOSIT_AMOUNT, DEMO_WALLET_ADDRESS, 0n, {
      nonce: nonceRef.next++
    });
    await tx.wait();

    const result = {
      action: "deposit",
      txHash: tx.hash,
      setupTxHashes: [initializeTxHash, ...approvalTxHashes].filter(Boolean),
      wallet: DEMO_WALLET_ADDRESS,
      amount: DEMO_DEPOSIT_AMOUNT
    };

    await recordDailyDeposit(this.storage, ip);
    await writeIdempotentResult(this.storage, "deposit", ip, key, result);
    return result;
  }

  async withdraw(request) {
    const ip = clientIp(request);
    const key = idempotencyKey(request);
    const cached = await readIdempotentResult(this.storage, "withdraw", ip, key);
    if (cached) return cached;

    await ensureCooldown(this.storage);
    await ensureIpActionLimit(this.storage, ip);

    const before = await readDemoState(this.env);
    if (before.shares === 0n) {
      throw new HttpError(409, "No dvUSDC position to withdraw.");
    }
    if (before.eth === 0n) {
      throw new HttpError(409, "Demo wallet needs Base Sepolia ETH for gas.");
    }

    const rpcProvider = provider(this.env);
    const wallet = await signer(this.env, rpcProvider);
    const signedContracts = contracts(wallet);
    const nonceRef = {
      next: await rpcProvider.getTransactionCount(wallet.address, "pending")
    };

    const tx = await signedContracts.router.withdraw(before.shares, DEMO_WALLET_ADDRESS, 0n, {
      nonce: nonceRef.next++
    });
    await tx.wait();

    const result = {
      action: "withdraw",
      txHash: tx.hash,
      wallet: DEMO_WALLET_ADDRESS,
      shares: before.shares
    };

    await writeIdempotentResult(this.storage, "withdraw", ip, key, result);
    return result;
  }
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(request, env) });
    }

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ ok: true }, 200, request, env);
    }

    try {
      assertAllowedOrigin(request, env);
      const id = env.DEMO_WALLET_COORDINATOR.idFromName(COORDINATOR_NAME);
      return env.DEMO_WALLET_COORDINATOR.get(id).fetch(request);
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      return json({ error: error.message || "Demo API failed." }, status, request, env);
    }
  }
};
