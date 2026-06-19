# Cloudflare Worker Proxy - Deploy Guide

This replaces the Wix Velo proxy with a Cloudflare Worker. Same contract, but no
execution-time limit, so a full Claude call never times out. Free tier is plenty
(100,000 requests/day).

```
Desktop app --(POST, x-app-token)--> Cloudflare Worker --(key from Worker secret)--> Anthropic
```

The desktop app needs no code change - you just point `STOCK_PROXY_URL` at the
Worker URL instead of the Wix URL.

---

## A. Create the Worker (dashboard, ~10 min, no install)

1. Sign up / log in at **https://dash.cloudflare.com** (free).
2. Left sidebar: **Workers & Pages** -> **Create** -> **Create Worker**.
3. Give it a name (e.g. `stock-ai-proxy`) -> **Deploy** (deploys a placeholder).
4. Click **Edit code**. Select everything in the editor, delete it, and paste the
   entire contents of `worker.js` from this folder. Click **Deploy**.
5. Add the two secrets: **Settings -> Variables and Secrets** (or "Variables") ->
   under **Secrets**, **Add**:
   - `ANTHROPIC_API_KEY` = your `sk-ant-...` key
   - `STOCK_APP_TOKEN`   = your shared app token (the same value the app sends)
   Click **Deploy/Save** so the secrets take effect.
6. Your Worker URL is shown on the Worker's page, like:
   ```
   https://stock-ai-proxy.<your-subdomain>.workers.dev
   ```

> CLI alternative (if you prefer `wrangler`): `npm i -g wrangler`, `wrangler init`,
> paste `worker.js` into `src/index.js`, `wrangler secret put ANTHROPIC_API_KEY`,
> `wrangler secret put STOCK_APP_TOKEN`, `wrangler deploy`.

---

## B. Test it

Health check in a browser:
```
https://stock-ai-proxy.<your-subdomain>.workers.dev/
```
-> `{"ok":true}`

Analyze (PowerShell):
```powershell
Invoke-RestMethod -Method Post -Uri "https://stock-ai-proxy.<your-subdomain>.workers.dev/" -Headers @{ "x-app-token" = "PASTE_YOUR_TOKEN" } -ContentType "application/json" -Body '{"ticker":"HUN"}'
```
-> the 7-field JSON. (No 504s this time.)

---

## C. Point the app at the Worker

**Per machine (env var):**
```
setx STOCK_PROXY_URL "https://stock-ai-proxy.<your-subdomain>.workers.dev/"
setx STOCK_APP_TOKEN "PASTE_YOUR_TOKEN"
```
Restart the app. (Env vars override the embedded defaults.)

**For distributed builds:** update the top of `claude_analysis.py`:
```python
EMBEDDED_PROXY_URL = "https://stock-ai-proxy.<your-subdomain>.workers.dev/"
EMBEDDED_APP_TOKEN = "PASTE_YOUR_TOKEN"
```

---

## D. Notes

- **Model:** the Worker has no timeout pressure, so it defaults to
  `claude-sonnet-4-6` (better than the Velo proxy's Haiku). Change `MODEL` in
  `worker.js` to `claude-opus-4-8` for top quality, or back to Haiku for lowest
  cost, then redeploy.
- **Cost control:** set a monthly spend cap in the Anthropic Console.
- **Kill switch / rotation:** change `STOCK_APP_TOKEN` in the Worker secrets (and
  the app) to revoke. The Anthropic key lives only in the Worker secret.
- **Retire the Wix proxy** once this works - you don't need both.
