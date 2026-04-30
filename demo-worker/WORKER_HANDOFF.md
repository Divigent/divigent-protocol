# Demo Worker Private Key Handoff

This guide is for teammates who need to keep the public demo running while the usual maintainer is away.

The most common task is updating the demo wallet private key. Creating a new Worker is only needed if the Cloudflare Worker itself is being replaced.

## Current Setup

- Public frontend repo: `/Users/harshbhatt/Desktop/Divigent/divigent-demo-site`
- Worker source in protocol repo: `/Users/harshbhatt/Desktop/divigent-protocol/demo-worker`
- Live Worker URL: `https://divigent-demo-api.harshbhatt0151.workers.dev`
- Current fixed demo wallet: `0x0447E4EA82EeeD2bb5b64D7C74A28AFE3e9249e6`
- Base Sepolia chain id: `84532`

The private key must never be committed. The frontend never stores it. The Worker reads it from the Cloudflare secret named:

```text
DEMO_WALLET_PRIVATE_KEY
```

## If You Are Changing To A New Private Key

A different private key means a different wallet address. In that case, update both backend and frontend constants.

1. Get the new wallet address from the new private key using a trusted local wallet/tool. Do not paste the private key into chat, docs, GitHub, or shell history.

2. Fund the new wallet on Base Sepolia with:

- Base Sepolia ETH for gas
- Base Sepolia USDC for deposits

3. Update the Worker fixed wallet address in:

```text
/Users/harshbhatt/Desktop/divigent-protocol/demo-worker/src/worker.js
```

Change:

```js
const DEMO_WALLET_ADDRESS = "OLD_ADDRESS";
```

to the new wallet address.

4. Update the frontend fixed wallet address in the Pages repo:

```text
/Users/harshbhatt/Desktop/Divigent/divigent-demo-site/app.js
```

Change:

```js
const DEMO_WALLET_ADDRESS = "OLD_ADDRESS";
```

to the same new wallet address.

5. Also update the protocol repo copy so future syncs do not drift:

```text
/Users/harshbhatt/Desktop/divigent-protocol/demo/app.js
```

6. Put the new private key into the Worker secret:

```sh
cd /Users/harshbhatt/Desktop/divigent-protocol/demo-worker
npx wrangler secret put DEMO_WALLET_PRIVATE_KEY
```

7. Check and deploy the Worker:

```sh
npm run check
npm run deploy
```

8. Commit and push the protocol repo changes:

```sh
cd /Users/harshbhatt/Desktop/divigent-protocol
git add demo-worker/src/worker.js demo/app.js
git commit -m "chore: rotate demo wallet"
git push origin feat-mvp-demo
```

9. Commit and push the Pages frontend change:

```sh
cd /Users/harshbhatt/Desktop/Divigent/divigent-demo-site
git add app.js
git commit -m "chore: rotate demo wallet"
git push origin main
```

10. Verify the Worker:

```sh
curl https://divigent-demo-api.harshbhatt0151.workers.dev/status
```

The `wallet` field must equal the new wallet address.

11. Hard refresh:

```text
https://demo.divigent.ai
```

The dashboard should read the new wallet state.

## If You Create A Brand-New Worker

Do this only if the current Worker is being replaced. A private-key rotation alone does not require a new Worker.

1. Create or copy a Worker project with the same `src/worker.js` logic.

2. Ensure `wrangler.jsonc` includes:

```jsonc
"main": "src/worker.js",
"durable_objects": {
  "bindings": [
    {
      "name": "DEMO_WALLET_COORDINATOR",
      "class_name": "DemoWalletCoordinator"
    }
  ]
},
"migrations": [
  {
    "tag": "v1",
    "new_sqlite_classes": ["DemoWalletCoordinator"]
  }
]
```

3. Set allowed frontend origins:

```jsonc
"vars": {
  "ALLOWED_ORIGINS": "https://demo.divigent.ai,http://localhost:4173,null"
}
```

4. Set the private key secret:

```sh
npx wrangler secret put DEMO_WALLET_PRIVATE_KEY
```

5. Deploy the new Worker:

```sh
npm run check
npm run deploy
```

6. Test the new Worker directly:

```sh
curl https://NEW_WORKER_URL/status
```

7. Attach the new Worker URL to the Pages frontend by changing the default `DEMO_API_URL` in:

```text
/Users/harshbhatt/Desktop/Divigent/divigent-demo-site/app.js
```

Current shape:

```js
const DEMO_API_URL = (
  new URLSearchParams(window.location.search).get("api") ||
  window.DIVIGENT_DEMO_API_URL ||
  "https://divigent-demo-api.harshbhatt0151.workers.dev"
).replace(/\/+$/, "");
```

Replace the default URL with the new Worker URL, then push `main` in the Pages repo.

For temporary testing without editing the frontend, use:

```text
https://demo.divigent.ai/?api=https://NEW_WORKER_URL
```

## Safety Rules

- Never commit `.dev.vars`.
- Never commit, screenshot, paste, or chat the private key.
- If the private key changes to a different wallet, update `DEMO_WALLET_ADDRESS` in both Worker and frontend.
- If the Worker secret private key does not match `DEMO_WALLET_ADDRESS`, the Worker intentionally fails.
- If deposits fail after a rotation, check `/status`, wallet funding, wallet address constants, and the deployed Worker version.

