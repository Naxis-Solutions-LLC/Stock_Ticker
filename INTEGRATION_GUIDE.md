# Claude Analysis Feature - Setup and Integration

This adds an "Analysis" tab to the US Stock Screener that sends a ticker to the
Anthropic Claude API and shows fresh, qualitative research: investment thesis,
strengths, risks, catalysts, valuation narrative, competitive position, and market
sentiment. It is fundamental and narrative - NOT charts or moving averages.

The feature is fully additive. It does not change the screener, live-price, or
existing Analyze pipelines. If you never set an API key, the rest of the app works
exactly as before.

Three files make it up:

    claude_analysis.py    Python backend. Calls Claude, returns the 7-field JSON.
    AnalysisTab.ps1       PowerShell WinForms tab (drop-in module).
    INTEGRATION_GUIDE.md  This file.

---

## 1. Get a Claude API key

1. Go to https://console.anthropic.com and sign in (or create an account).
2. Add a small amount of credit under Billing (pay-as-you-go).
3. Open API Keys and click "Create Key". Copy it - it looks like
   `sk-ant-api03-...`. You only see it once.

Keep the key private. Treat it like a password. Never paste it into a file that
gets committed to git (the included `.gitignore` already excludes `.env` and the
analysis temp file).

---

## 2. Set ANTHROPIC_API_KEY on Windows

The backend reads the key from the `ANTHROPIC_API_KEY` environment variable. It is
never hardcoded.

Permanent (recommended) - run once in a terminal, then RESTART the app:

    setx ANTHROPIC_API_KEY "sk-ant-api03-your-key-here"

`setx` writes the variable for future processes. Programs already running (your
terminal, the app, VS Code) will NOT see it until they are restarted. Close the
launching console window too - the app inherits its environment.

To set it via the GUI instead: Start menu -> "Edit environment variables for your
account" -> New -> Name `ANTHROPIC_API_KEY`, Value your key -> OK, then restart.

Just this session (temporary, goes away when the window closes):

    PowerShell:   $env:ANTHROPIC_API_KEY = "sk-ant-api03-your-key-here"
    cmd.exe:      set ANTHROPIC_API_KEY=sk-ant-api03-your-key-here

Verify it is set (open a NEW terminal after setx):

    PowerShell:   $env:ANTHROPIC_API_KEY
    cmd.exe:      echo %ANTHROPIC_API_KEY%

Optional - a .env file: if you prefer, put `ANTHROPIC_API_KEY=sk-ant-...` in a file
named `.env` in this folder and load it in your shell before launching. `.env` is
already in `.gitignore`. The backend itself only reads the environment variable, so
you must export it into the environment one way or another.

---

## 3. Install the anthropic package

You already have Python for the screener. Install the SDK into the SAME Python the
app uses:

    pip install anthropic

If the app finds a different Python than your terminal, install into that exact one
(the Export feature taught us this lesson). To be safe:

    python -m pip install anthropic

Confirm:

    python -c "import anthropic, sys; print(sys.executable, anthropic.__version__)"

---

## 4. Wire AnalysisTab.ps1 into StockUI.ps1

`StockUI.ps1` already dot-sources `Analyze-Tab.ps1` near the end (in the INITIAL
LOAD block, just before `$form.ShowDialog()`). Add the Analysis tab right next to
it. Find this existing block:

    try {
        . (Join-Path $ScriptDir "Analyze-Tab.ps1")
        $pyForAnalyze = if ($PythonExe) { $PythonExe } else { "python" }
        $script:analyzeApi = Add-AnalyzeTab `
            -TabControl $tabs `
            -DataDir    $DataDir `
            -PythonExe  $pyForAnalyze `
            -ScriptDir  $ScriptDir
    }
    catch { ... }

Immediately AFTER that `try/catch`, add:

    # Claude-powered Analysis tab (additive)
    try {
        . (Join-Path $ScriptDir "AnalysisTab.ps1")
        $pyForClaude = if ($PythonExe) { $PythonExe } else { "python" }
        $script:analysisApi = Add-AnalysisTab `
            -TabControl $tabs `
            -DataDir    $DataDir `
            -PythonExe  $pyForClaude `
            -ScriptDir  $ScriptDir
    }
    catch {
        $script:analysisApi = $null
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to load Analysis tab:`r`n$($_.Exception.Message)",
            "Stock Screener", "OK", "Warning") | Out-Null
    }

That is all that is required - the new "Analysis" tab appears with a ticker box,
Analyze button, Copy button, and a scrollable results area.

### Optional: right-click "Ask Claude about TICKER" on the Screen grid

`StockUI.ps1` already builds a right-click menu (`$screenMenu`) and tracks the
clicked ticker in `$script:CtxScreenTicker`. To add a menu item, put this AFTER the
Add-AnalysisTab block above (so `$script:analysisApi` exists):

    $screenMenu.Items.Add("-") | Out-Null   # separator
    $miAskClaude = $screenMenu.Items.Add("Ask Claude about this stock")
    $miAskClaude.Add_Click({
        if ($script:CtxScreenTicker -and $script:analysisApi) {
            & $script:analysisApi.AnalyzeTicker $script:CtxScreenTicker
        }
    })

`AnalyzeTicker` is a `{ param($Ticker) }` scriptblock; it switches to the Analysis
tab and runs the analysis. You can call it from anywhere.

### Optional: pass price/sector/market-cap context

The backend accepts `--price`, `--sector`, and `--market-cap` for richer prompts.
The drop-in tab does not pass them (it stays self-contained), but you can call the
Python directly with context, for example:

    python claude_analysis.py AAPL --sector "Technology" --market-cap "3T" --output out.json

---

## 5. Model and rough per-call cost

The model is set in `claude_analysis.py`:

    MODEL = "claude-opus-4-8"

This is the current, most capable Opus-tier model at build time. Model IDs change
over time - if you ever get a 404 "model not found", update this string or pass
`--model`. You can also switch models without editing the file:

    python claude_analysis.py AAPL --model claude-sonnet-4-6

Rough cost per analysis (one call, adaptive thinking on):

    Opus 4.8   ($5 / $25 per million input/output tokens):  about 5 to 12 cents
    Sonnet 4.6 ($3 / $15 per million):                       roughly half that

A typical call is a few hundred input tokens and a few thousand output tokens
(thinking plus the JSON). The exact token counts are written into the result JSON
under `usage` for your own tracking. The first call with a new output schema has a
small one-time latency while the schema compiles; later calls are faster.

To control cost or latency you can lower `--max-tokens` (default 8000) or switch to
Sonnet. Lowering max-tokens too far risks a cut-off response (the UI will tell you
to raise it).

---

## 6. Security - never commit keys

- The key lives ONLY in the `ANTHROPIC_API_KEY` environment variable. It is never
  written to any file by this feature.
- `.gitignore` already excludes `.env` and `data/claude_analysis.json` (the temp
  result file, which can contain the ticker you looked at but never the key).
- Do not paste your key into `claude_analysis.py`, a commit message, or a chat.
- If a key is ever exposed, revoke it in the Console and create a new one.

---

## 7. Troubleshooting

| Symptom (shown in the Analysis tab)            | Cause / Fix                                                                 |
| ---------------------------------------------- | -------------------------------------------------------------------------- |
| "ANTHROPIC_API_KEY is not set"                 | Set the variable (section 2), then fully restart the app and its console.  |
| "anthropic package is not installed"           | Run `python -m pip install anthropic` into the Python the app uses.        |
| "Authentication failed - the API key was rejected" | Wrong/revoked key. Create a new one at console.anthropic.com and reset it. |
| "Could not reach the Claude API (network error)" | No internet, VPN, or firewall blocking. Check connectivity and retry.     |
| "Rate limited by the Claude API"               | Too many requests, or low plan limits. Wait a minute and retry.            |
| "Claude API returned an error (status 5xx)"    | Temporary server issue. Retry shortly.                                      |
| "The response was cut off (hit max_tokens)"    | Raise `--max-tokens` (default 8000), or the model thought too long.        |
| "Could not parse the model response as JSON"   | Usually transient. Try again. Raw text is shown for debugging.             |
| "Python not found - cannot run the analysis"   | Install Python and ensure it is on PATH; relaunch the app.                 |
| Model 404 / "not found"                        | Update `MODEL` in claude_analysis.py or pass `--model` with a current id.  |

The backend always writes a JSON file even on failure (with `error: true`, a
`message`, a `hint`, and the `raw` model text when relevant), so the tab can show a
readable explanation instead of a blank box.

---

## 8. Reminder

This is qualitative, AI-generated research for consideration. It is not investment
advice, it can be wrong or out of date, and the model is instructed not to invent
specific numbers - verify anything that matters before acting on it.
