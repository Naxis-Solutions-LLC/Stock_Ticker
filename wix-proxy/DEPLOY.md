# Wix Velo Proxy - Deploy Guide

This proxy lets the desktop app's "AI Research" tab work **without putting your
Anthropic API key on customer machines**. The key lives in your Wix site's
Secrets Manager; the app sends only a revocable shared token.

```
Desktop app  --(POST /_functions/analyze, x-app-token)-->  Wix Velo function
                                                              |  reads ANTHROPIC_API_KEY
                                                              v  from Secrets Manager
                                                           Anthropic API
```

Two files matter:
- `http-functions.js` - paste into your site's backend (this folder).
- the app-side change is already in `claude_analysis.py` (proxy mode).

---

## A. One-time Wix setup (about 10 minutes)

You do this in the Wix Editor; the connector cannot deploy site code for you.

1. **Pick a site.** Your account has *Naxis Solutions LLC*, *Brians Test*, and
   *Naxis Solutions*. Use **Brians Test** first to verify, then move to a Naxis
   site for production.

2. **Turn on Dev Mode (Velo).** Open the site in the Editor -> top menu
   **Dev Mode** -> **Turn on Dev Mode** (also called Velo).

3. **Add the two secrets.** Dashboard -> **Settings -> Secrets Manager**
   (or Editor -> Dev Mode -> "Secrets Manager"). Add:
   - `ANTHROPIC_API_KEY` = your Anthropic key (`sk-ant-...`)
   - `STOCK_APP_TOKEN`   = any long random string (e.g. 32+ chars). This is the
     value the app must send. Treat it as a password, but note it is **revocable**
     (just change it here and in the app) - unlike the API key.
   > Note: if Secrets Manager asks you to install the Members Area app first, do so.

4. **Add the backend function.** In the Editor's code tree (left panel), under
   **Backend**, create/open **`http-functions.js`** and paste the entire contents
   of `http-functions.js` from this folder.

5. **Publish the site.** Click **Publish** (top right). HTTP functions only go
   live on the published site.

6. **Find your endpoint URL.** It is:
   ```
   https://<your-published-site>/_functions/analyze
   ```
   - Free site: `https://<username>.wixsite.com/<sitename>/_functions/analyze`
   - Custom domain: `https://<yourdomain>/_functions/analyze`

---

## B. Test the endpoint (before touching the app)

From any machine with curl (replace URL and token):

```bash
curl -s -X POST "https://<your-site>/_functions/analyze" \
  -H "Content-Type: application/json" \
  -H "x-app-token: <your STOCK_APP_TOKEN>" \
  -d "{\"ticker\":\"AAPL\"}"
```

You should get back JSON with `investment_thesis`, `key_risks`, etc. If you get
`{"error":true,...}`, the message says why (bad token, missing secret, etc.).

---

## C. Point the app at the proxy

`claude_analysis.py` uses the proxy whenever a proxy URL is configured. Pick one:

**Option 1 - environment variables (per machine):**
```
setx STOCK_PROXY_URL "https://<your-site>/_functions/analyze"
setx STOCK_APP_TOKEN "<your STOCK_APP_TOKEN>"
```
Then restart the app. (No `ANTHROPIC_API_KEY` needed on that machine.)

**Option 2 - bake into a distributed build (for customers):**
Edit the top of `claude_analysis.py` in the copy you ship:
```python
EMBEDDED_PROXY_URL = "https://<your-site>/_functions/analyze"
EMBEDDED_APP_TOKEN = "<your STOCK_APP_TOKEN>"
```
Customers then need nothing but the app - no key, no env vars. Do **not** commit a
real token to the repo; only paste it into the build you hand out.

If neither a proxy URL nor an env key is set, the app falls back to the original
direct path (the user's own `ANTHROPIC_API_KEY`), so nothing breaks.

---

## D. Operating notes

- **Timeouts:** Velo HTTP functions have a short execution limit. The proxy is set
  for a fast response (no extended thinking, `MAX_TOKENS = 2000`). If you see
  timeouts, switch `MODEL` in `http-functions.js` to `claude-sonnet-4-6` (faster,
  cheaper) and re-publish. If it still times out, the proxy should move to a host
  without that limit (e.g. a Cloudflare Worker) - same logic, different home.
- **Cost control:** set a monthly spend cap in the Anthropic Console, and use a
  **dedicated** key for this so you can revoke/rotate it independently.
- **Kill switch:** to cut everyone off, change `STOCK_APP_TOKEN` in Secrets Manager
  (or delete the secret). To rotate, update it here and in the app build.
- **Security:** the key is only ever in Secrets Manager and is read server-side.
  The app only ever holds the revocable app token.
