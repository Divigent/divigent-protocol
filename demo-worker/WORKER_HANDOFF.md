# Demo Worker Handoff

This guide is for updating or replacing the Cloudflare Worker that powers the public demo at `demo.divigent.ai`.

## Current Setup

- Frontend repo: `/Users/harshbhatt/Desktop/Divigent/divigent-demo-site`
- Worker source: `/Users/harshbhatt/Desktop/divigent-protocol/demo-worker`
- Live Worker URL: `https://divigent-demo-api.harshbhatt0151.workers.dev`
- Fixed demo wallet: `0x0447E4EA82EeeD2bb5b64D7C74A28AFE3e9249e6`
- Base Sepolia chain id: `84532`

The frontend is static. It does not hold the wallet private key. Deposits and withdrawals go through the Worker, which reads the private key from a Cloudflare secret.

## Update The Existing Worker

1. Open the Worker folder:

```sh
cd /Users/harshbhatt/Desktop/divigent-protocol/demo-worker
```

2. Edit the Worker source:

```text
src/worker.js
```

3. Run the syntax check:

```sh
npm run check
```

4. Deploy:

```sh
npm run deploy
```

If deploying from a non-interactive terminal, set a Cloudflare API token first:

```sh
export CLOUDFLARE_API_TOKEN="..."
npm run deploy
```

5. Verify the deployed Worker:

```sh
curl https://divigent-demo-api.harshbhatt0151.workers.dev/status
```

The response should include the fixed `wallet`, `usdc`, `shares`, `deposited`, `depositsUsed`, and `canDeposit`.

## Worker Secrets

For production, the demo wallet private key must be stored as a Cloudflare secret:

```sh
npx wrangler secret put DEMO_WALLET_PRIVATE_KEY
```

The private key must resolve to:

```text
0x0447E4EA82EeeD2bb5b64D7C74A28AFE3e9249e6
```

Do not commit `.dev.vars` or any private key.

For local development only:

```sh
cp .dev.vars.example .dev.vars
```

Then put the private key in `.dev.vars`.

## Create A New Worker

Use this only if the old Worker is being replaced.

1. Copy the existing Worker folder or create a new Cloudflare Worker project.

2. Keep these parts from `wrangler.jsonc`:

```jsonc
"main": "src/worker.js",
"compatibility_date": "2026-04-30",
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

3. Set allowed frontend origins in `wrangler.jsonc`:

```jsonc
"vars": {
  "ALLOWED_ORIGINS": "https://demo.divigent.ai,http://localhost:4173,null"
}
```

4. Set the `DEMO_WALLET_PRIVATE_KEY` secret on the new Worker.

5. Deploy the new Worker:

```sh
npm run check
npm run deploy
```

6. Verify:

```sh
curl https://NEW_WORKER_URL/status
```

## Attach A Worker To The Demo Site

The Pages frontend chooses its API endpoint in `app.js`:

```js
const DEMO_API_URL = (
  new URLSearchParams(window.location.search).get("api") ||
  window.DIVIGENT_DEMO_API_URL ||
  "https://divigent-demo-api.harshbhatt0151.workers.dev"
).replace(/\/+$/, "");
```

To permanently attach a new Worker, edit this default URL in:

```text
/Users/harshbhatt/Desktop/Divigent/divigent-demo-site/app.js
```

Then deploy the Pages repo:

```sh
cd /Users/harshbhatt/Desktop/Divigent/divigent-demo-site
git add app.js
git commit -m "chore: update demo worker url"
git push origin main
```

GitHub Pages will publish the change automatically.

For temporary testing without changing code, open:

```text
https://demo.divigent.ai/?api=https://NEW_WORKER_URL
```

For local static testing:

```text
file:///Users/harshbhatt/Desktop/Divigent/divigent-demo-site/index.html?api=http://localhost:8787
```

## Common Checks

- If deposits fail with an allowance error, verify the fixed wallet has approved the router and that the latest Worker is deployed.
- If the page does not update after a transaction, check `GET /status`; the frontend uses this endpoint for the canonical demo wallet state.
- If the browser shows CORS errors, add the frontend domain to `ALLOWED_ORIGINS` and redeploy the Worker.
- If Wrangler refuses to deploy in CI or a non-interactive shell, set `CLOUDFLARE_API_TOKEN`.

