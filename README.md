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

## The three tabs

**Screen** - every stock that passed the filters. Filter bar for price range,
market cap, and max % below 52-week high. Live prices overlay in their own
column and tint green/pink when they move off the snapshot price. Deep-drop
stocks (>70% below high) are tinted pink. "Refresh Prices Now" and the 60-second
auto-refresh keep visible rows current. "Re-run Full Screen" launches the full
~5,500-ticker re-screen in the background with a progress bar.

**Test Trades** - a paper-trading log. Type in the white columns (Ticker, Buy
Date, Buy Price, Qty); Investment, Current Value, P/L, and Status calculate
automatically. Add a Sell Price to close a trade (P/L becomes realized).
Current price comes from the same live-price feed as the Screen tab. The
right-side panel is the Algorithm Scorecard - positions, win rate, total P/L,
best/worst trade. The bottom strip shows running totals. Edits auto-save to
data/trades.csv; "+ Add Row" / "Delete Row" / "Save Trades" / "Recalculate"
buttons are up top.

**Cohorts** - bar charts showing how the screened stocks break down, by price
band ($10-25 / $25-40 / $40-60), by distance below the 52-week high (0-10% /
10-25% / 25-50% / 50-70% / 70%+), and by market-cap tier ($500M-1B / $1-5B /
$5-20B / $20B+). These are drawn directly by the app (no chart component
dependency) and refresh after each full screen.

## The files

  Launch.bat          - Double-click to open the app.
  StockUI.ps1         - The desktop UI (PowerShell + WinForms, 3 tabs).
  screener_full.py    - The slow full-universe screen. Writes data/screen_data.csv.
  price_refresh.py    - The fast live-price pull. Writes data/live_prices.csv.
  trades_init.py      - Creates data/trades.csv on first run.
  data/screen_data.csv - The full screen results - the main dataset.
  data/live_prices.csv - Live prices for recently-viewed tickers (auto-managed).
  data/trades.csv      - Your paper-trading log.
  data/screen_status.txt / screen_meta.txt - Progress + last-run info.

## How the refresh works

Two layers, deliberately separate:

Slow layer - the full screen. screener_full.py pulls ~5,500 US tickers,
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
