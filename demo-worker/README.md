# Divigent Demo API

Small Cloudflare Worker API for the public `demo.divigent.ai` frontend.

The frontend is static and must not contain the demo wallet private key. This Worker stores the key as a Cloudflare secret and exposes only locked-down demo actions:

- `GET /state`
- `GET /status`
- `POST /deposit`
- `POST /withdraw`

`POST /deposit` ignores request parameters and always deposits exactly `10 USDC` from the fixed demo wallet, up to `25` total deposits. `POST /withdraw` ignores request parameters and withdraws all dvUSDC back to the same fixed demo wallet.

The Worker routes all signed actions through a singleton Durable Object. The object serializes transactions, reads the deposit cap from chain, uses the pending nonce for each transaction, rate-limits repeated use from the same IP, and dedupes repeated clicks with the `idempotency-key` header.

## Setup

```sh
cd demo-worker
npm install
cp .dev.vars.example .dev.vars
```

Put the demo wallet private key in `.dev.vars` for local development only. Do not commit `.dev.vars`.

For production, set it as a Cloudflare secret:

```sh
npx wrangler secret put DEMO_WALLET_PRIVATE_KEY
```

Deploy:

```sh
npm run deploy
```

Point `api.demo.divigent.ai` at this Worker in Cloudflare, then publish the static demo to GitHub Pages at `demo.divigent.ai`.

For local frontend testing with the Worker:

```text
file:///.../demo/index.html?api=http://localhost:8787
```
