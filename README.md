# US Stock Screener - Desktop UI

A Windows desktop app for browsing screened US stocks, paper-trading them, and
seeing how the screen breaks down. PowerShell + WinForms - nothing to install
beyond Python (which the screener needs anyway). CSV files are the backend.
No database.

## Quick start

1. Install Python if you don't have it (python.org - check "Add Python to PATH")
2. First time only: open a terminal in this folder and run
   `pip install yfinance pandas requests openpyxl`
3. Double-click **Launch.bat**

A console window opens and stays open (so you can see any startup error) - the
app window appears over it. Minimize the console, don't close it.

## The tabs

**Screen** - every stock that passed the filters. Filter bar for price range,
market cap, and max % below 52-week high. A core set of columns shows by default;
"Show all columns" (under More) reveals the rest. Click a column header to sort
numerically; use "Find" to jump to a ticker. Live prices overlay in their own
column, tint green/pink, and carry an up/down caret when they move off the
snapshot price. Deep-drop stocks (>70% below high) are tinted pink. "Refresh
Prices" and the 60-second auto-refresh keep rows current. "Re-run Full Screen"
launches the full ~6,900-ticker re-screen in the background with a progress bar.
Right-click any row for actions (Chart, AI Research, Pin, Send to Trades, ...).

**Chart** - per-ticker detail: owner-drawn price and volume charts with SMA
overlays, returns, key stats, analyst view, technicals, and earnings. Pick a
period (1M/3M/6M/1Y/YTD). Right-click a Screen row -> "Chart {ticker}", or type
one in.

**AI Research** (optional, needs a Claude API key) - sends a ticker to the
Anthropic Claude API and shows fresh, qualitative research: investment thesis,
fundamental strengths, key risks, near-term catalysts, valuation narrative,
competitive position, and market sentiment. Narrative, fundamental research - not
charts or moving averages. Type a ticker (or right-click a Screen row -> "AI
research on {ticker}"). Additive: with no API key set, the rest of the app works
exactly as before. Setup is in INTEGRATION_GUIDE.md. Output is AI-generated and
not investment advice.

**Test Trades** - a paper-trading log. Type in the white columns (Ticker, Buy
Date, Buy Price, Qty); Investment, Current Value, P/L, and Status calculate
automatically. Add a Sell Price to close a trade (P/L becomes realized).
Current price comes from the same live-price feed as the Screen tab. The
right-side panel is the Performance summary - positions, win rate, total P/L,
best/worst trade. The bottom strip shows running totals. Edits auto-save to
data/trades.csv; "Save Now" forces a save. Deleting a trade asks for confirmation.

**Cohorts** - per price band ($10-25 / $25-40 / $40-60), a horizontal-bar chart of
the 15 stocks furthest below their 52-week high. Drawn directly by the app (no
chart-component dependency). Refreshes after each full screen; tick "Use current
Screen filters" to restrict the bands to your active filters.

## The files

  Launch.bat          - Double-click to open the app.
  StockUI.ps1         - The desktop UI (PowerShell + WinForms).
  Analyze-Tab.ps1     - The per-ticker "Chart" tab module.
  AnalysisTab.ps1     - The Claude-powered "AI Research" tab module.
  claude_analysis.py  - Backend for the AI Research tab (calls the Claude API).
  INTEGRATION_GUIDE.md - Setup for the Claude Analysis feature.
  screener_full.py    - The slow full-universe screen. Writes data/screen_data.csv.
  price_refresh.py    - The fast live-price pull. Writes data/live_prices.csv.
  trades_init.py      - Creates data/trades.csv on first run.
  data/screen_data.csv - The full screen results - the main dataset.
  data/live_prices.csv - Live prices for recently-viewed tickers (auto-managed).
  data/trades.csv      - Your paper-trading log.
  data/screen_status.txt / screen_meta.txt - Progress + last-run info.

## How the refresh works

Two layers, deliberately separate:

Slow layer - the full screen. screener_full.py pulls ~6,900 US tickers,
applies the filters, writes screen_data.csv. 25-40 minutes. Triggered by the
orange button (background, with progress) or a scheduled task.

Fast layer - live prices. price_refresh.py grabs just the current price
and 52-week high for a short list of tickers (the visible Screen rows plus every
ticker in your trades log). Runs every 60 seconds, on scroll, and on demand.

CSV is the hand-off between Python and the UI. Both Python scripts write their
CSVs atomically so the UI never reads a half-written file.

## Scheduling the full screen (optional)

To run the full screen automatically (e.g. nightly at 2am), run this in an
admin terminal from this folder:

    schtasks /create /tn "StockScreenNightly" /tr "python \"%CD%\screener_full.py\"" /sc daily /st 02:00

## Honest notes / limitations

- This UI has not been runtime-tested. It was built and statically checked
  (structure, encoding, here-strings, event handlers), but the build environment
  had no Windows / PowerShell / .NET. If something misbehaves on first run, the
  app catches startup errors and shows them in a message box + writes
  error_log.txt - paste that for a fix.
- "Live price" is delayed ~15 minutes (Yahoo's free data). Fine for tracking,
  not for split-second trading.
- The Cohorts charts are bar charts drawn by the app itself - chosen over a
  charting component specifically so there's no dependency that might be missing.
- trades.csv stores only what you type. All the math is recomputed live, so
  there's never stale P/L in the file.
