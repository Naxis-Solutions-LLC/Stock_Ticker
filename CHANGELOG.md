# Changelog

All notable changes to the US Stock Screener are recorded here.
Format loosely follows Keep a Changelog. Dates are when the build was cut.

## [1.6.0] - 2026-06-18

### Added
- **Optional proxy mode for AI Research** so the Anthropic API key never has to
  ship to customers. When a proxy URL is configured (`--proxy-url`, the
  `STOCK_PROXY_URL` env var, or an embedded default), `claude_analysis.py` calls
  your server-side proxy with a revocable `x-app-token` instead of calling
  Anthropic directly. Falls back to the original direct/env-key path when no proxy
  is set, so nothing breaks for users who bring their own key.
- **`wix-proxy/`** - a ready-to-deploy Wix Velo implementation: `http-functions.js`
  (validates the app token, reads the key from Wix Secrets Manager, calls Claude,
  returns the same 7-field JSON) plus `DEPLOY.md` (step-by-step setup, testing,
  cost/kill-switch notes, and the Velo timeout caveat).

## [1.5.2] - 2026-06-18

### Fixed
- **Chart tab crash ("Cannot convert value 'nan' to type System.Double").** Thinly
  traded names (e.g. UEC) can have no-trade days with NaN OHLC, which were written
  to detail_history.csv as the string "nan" and crashed the price chart's double
  casts. Two-part fix: (1) the chart now drops rows whose OHLC/Volume are
  non-numeric before drawing (and SMA points are guarded the same way), so a stray
  value can never crash it; (2) stock_detail.py no longer emits those rows -
  no-trade days with missing OHLC are skipped when writing history.

## [1.5.1] - 2026-06-17

### Changed
- **Sector and Industry filters are now multi-select.** The two single-select
  dropdowns are replaced with checklists (CheckedListBox) - check any number of
  sectors and/or industries; checking none means "no filter" (show all). The
  Industry list is scoped to the checked sector(s), and checks are preserved
  across a full re-screen. The More panel is a little taller to fit the lists.

## [1.5.0] - 2026-06-17

UX pass implementing the findings in docs/UX_REVIEW.md (P0 -> P2). Additive;
screener math, CSV formats, and the data layer are unchanged.

### Changed (clarity)
- **Tab naming.** "Analyze" -> **Chart**, "Analysis" -> **AI Research** (the two
  were near-homographs). Right-click reads "Chart {ticker}" and "AI research on
  {ticker}". Tabs are ordered to match the workflow: Screen, Chart, AI Research,
  Test Trades, Cohorts.
- **"ALGORITHM SCORECARD" -> "PERFORMANCE"** (there is no algorithm; it is a
  paper-trading summary).
- **Human-readable numbers** in the Screen grid: market cap and dollar volume as
  `$11.3B` / `$827M`, share volume as `41.7M`, prices prefixed with `$`. Display
  only - underlying values stay numeric for filtering and sorting.
- **Friendly column headers + tooltips** (no more "Uran", "$Vol M", "3mo Px").

### Added (clarity / effort / accessibility)
- **Numeric column sort.** Click a header to sort numerically (not lexically);
  pinned rows stay on top; a sort glyph shows the active column.
- **Find box** on the Screen filter bar - jump to a ticker in the current view.
- **Curated columns by default** with a "Show all columns" toggle (under More).
- **Color-independent signals**: up/down carets on live-price moves and on trade
  P/L, in addition to the green/pink fill.
- **Cohorts: "Use current Screen filters"** to restrict the bands to the active
  filter.
- **AI Research: approximate per-call cost** line from the returned token usage.

### Changed (confidence / safety)
- One consistent busy state for live refresh (button disables + "Refreshing...").
- **Delete-trade confirmation** (was silent + auto-saved with no undo).
- Autosave made explicit ("Edits save automatically"); Save button -> "Save Now".
- Freshness/uncertainty surfaced in-app: "Live prices ~15 min delayed" and a
  not-advice caption on the Chart tab.
- Consistent universe/runtime numbers (~6,900 tickers, 25-40 min) across the
  README, the screener, and the in-app dialogs.
- Launch.bat reframes the console as a "log window (safe to minimize)" instead of
  a "keep open, don't close" rule.

## [1.4.0] - 2026-06-17

### Added
- **Claude-powered "Analysis" tab.** A new tab sends a ticker to the Anthropic
  Claude API and shows fresh, fundamental, qualitative research - investment
  thesis, fundamental strengths, key risks, near-term catalysts, valuation
  narrative, competitive position, and market sentiment - rather than charts or
  moving averages. Ticker box, Analyze button, Copy-to-clipboard, status line,
  and a scrollable results area; Enter submits. The API call runs in a background
  job polled by a timer, so the UI stays responsive.
  - `claude_analysis.py` - Python backend on the official `anthropic` SDK. Reads
    the key from the `ANTHROPIC_API_KEY` environment variable (never hardcoded),
    prompts Claude as a fundamental equity researcher (known facts only,
    acknowledge uncertainty, no invented numbers), and uses structured outputs to
    return exactly 7 fields. Strips markdown fences and parses JSON safely; on any
    failure writes a clean error object (message + hint + raw response) and exits
    non-zero. Model id is a constant (`claude-opus-4-8`) with a `--model` override.
  - `AnalysisTab.ps1` - drop-in WinForms module (`Add-AnalysisTab`), pure ASCII.
  - `INTEGRATION_GUIDE.md` - API key, setting `ANTHROPIC_API_KEY` on Windows,
    installing `anthropic`, wiring, rough per-call cost, troubleshooting table.
  - Right-click a Screen row -> "Ask Claude about {ticker}" opens the tab.
  - `.gitignore` now excludes `.env` and the regenerated `data/claude_analysis.json`.

### Notes
- The feature is additive: with no API key set, the rest of the app behaves
  exactly as before. Requires `pip install anthropic`. Output is qualitative,
  AI-generated, and not investment advice.

## [1.3.2] - 2026-06-16

### Fixed
- **"Export failed. Make sure openpyxl is installed" now shows the real error.**
  The Excel export ran the Python helper without capturing its output and then
  showed a fixed "install openpyxl" message on *any* non-zero exit -- so a wrong
  interpreter, a missing `pandas`, a locked output file, or bad data all looked
  like an openpyxl problem even when openpyxl was installed. The export now
  captures stdout+stderr, shows the actual Python error and which interpreter
  was used, saves the full output to `data/export_error.log`, and tells you to
  `pip install` into *that* interpreter (`"<python>" -m pip install ...`).
- **Test Trades "Cur Price" no longer shows "-" on a freshly loaded trade.**
  `Recompute-Trades` only ever read the live-price cache, so a trade showed no
  current price (and no P/L) until the first 60-second live refresh completed.
  It now goes through `Get-BestPrice`, which prefers the live price but falls
  back to the screen snapshot, so a price appears immediately -- matching the
  Screen tab's behaviour.
- **Atomic saves for `trades.csv` and `pinned.csv`.** Both were written with a
  non-atomic `File.Copy` (tmp -> destination), which can briefly expose a
  half-written file to anything reading it. They now swap into place via a new
  `Move-FileAtomic` helper (`File.Replace` when the target exists, else
  `File.Move`), matching the atomic `os.replace` the Python scripts already use.
- **GDI handle leak in the owner-drawn charts.** The Cohorts bar charts and the
  Analyze price/volume charts created Fonts, Pens, and Brushes on every paint
  (resize, tab switch, period-button click) and never disposed them, so native
  GDI handles accumulated over a long session. All chart drawing now disposes
  its GDI objects in a `finally` block. Shared `[Drawing.Brushes]::*` singletons
  are deliberately left alone.

### Repo hygiene
- Removed committed build artifacts and dev leftovers from version control:
  the `*.zip` distribution packages, the superseded `Stock Screener UI.ps1`,
  `StockUI-integration-snippets.txt`, `diagnose_dropdowns.ps1`, and the
  per-ticker Analyze scratch files (`data/detail_*`). Distribution zips are
  attached on release rather than committed; `.gitignore` now covers `*.zip`
  and the `data/detail_*` runtime files. The shipped dataset (`screen_data.csv`,
  `screen_meta.txt`, `trades.csv`) is still tracked so the app works on unzip.

## [1.3.1] - 2026-05-25

### Fixed
- **"No price history returned for {ticker}" error on Analyze.** v1.3.0
  only retried the `t.history(period="2y")` call twice on exceptions, and
  did NOT retry at all when yfinance returned an empty DataFrame (which is
  Yahoo's silent way of saying "rate limited" -- no exception, just empty
  results). With a hot session that had recently run a full screen + live-
  price refresh, the Analyze fetch would often hit this on the first
  ticker tried and bail immediately. Fix is three-part:
  - **4 retries instead of 2**, matching the screener's pattern.
  - **Exponential backoff** of `2s, 5s, 11s` (with jitter), matching
    `screener_full.py`'s `BASE_BACKOFF * (2 ** attempt) + jitter`
    formula. Max ~18s before giving up.
  - **Empty DataFrame is treated the same as an exception.** Previously
    an empty response just exited the loop without retrying. Now it
    triggers the same backoff path.
- **Useful error message on hard failure.** The old `"No price history
  returned for {ticker}"` told the user nothing actionable. New message:
  `"No price history for {ticker} after 4 attempts. Last cause: <reason>.
  This is almost always a Yahoo rate limit -- wait 1-2 minutes and retry."`
- **Analyze tab status bar shows the actual error** instead of just
  `"see data\detail_error.log"`. The full Python error message (with its
  timestamp prefix stripped) is shown inline so the user doesn't have to
  open a log file to know what happened.

### Note
No data-format changes. Drop-in replacement for `stock_detail.py`,
`Analyze-Tab.ps1`, and `VERSION`. `StockUI.ps1` is unchanged from v1.3.0.

## [1.3.0] - 2026-05-25

### Added
- **New "Analyze" tab** with detailed analysis for a single ticker.
  Triggered from a new right-click context-menu item on the Screen
  tab grid: "Analyze {TICKER}" (last item in the menu). The tab also
  has its own ticker textbox + Re-fetch button so any ticker can be
  analyzed, not just ones currently visible on the Screen tab.
- **Returns panel** showing 1M / 3M / 6M / YTD / 1Y % returns plus
  starting prices, and distance from both the 52-week high and low.
  Green/red color tinting matches the rest of the app.
- **Key Stats panel** with Market Cap, P/E (TTM), Forward P/E, PEG,
  EPS (TTM), Dividend Yield, Beta, Profit Margin, ROE, Debt/Equity,
  and Short Float. All sourced from yfinance's `.info` dict and
  normalized to percent where yfinance flip-flops between decimal
  and percent representations.
- **Owner-drawn price chart** (1Y of daily closes) with 50-day and
  200-day simple moving average overlays, anti-aliased lines, 6
  horizontal gridlines, 5 evenly-spaced date ticks, and a small
  legend. Same paint-handler pattern as the existing Cohorts charts
  -- no chart-library dependency added.
- **Period selector** (1M / 3M / 6M / 1Y / YTD) that reslices the
  already-fetched history without re-fetching from Yahoo. Selected
  button is highlighted in the same accent blue as the Close line.
- **Owner-drawn volume chart** sitting below the price chart on the
  same x-axis, with the y-axis labelled in K / M / B.
- **Analyst View panel** with mean / high / low target price (and
  upside % from current), number of analysts covering, and the
  current Buy/Hold/Sell distribution from
  `Ticker.recommendations`.
- **Technicals panel** with 50-day SMA, 200-day SMA, price vs. each,
  RSI(14) with overbought/neutral/oversold hint, 30-day ATR, and
  30-day average dollar volume.
- **Next Earnings panel** showing the next earnings date with EPS
  estimate, plus the last four earnings dates with estimate, actual,
  and surprise %.

### Backend / data flow
- New `stock_detail.py` (~280 lines): takes a ticker as its only
  argument, fetches 2 years of history (so the 200-day MA has values
  throughout the 1-year view), computes RSI / ATR / SMAs / dollar
  volume, pulls company info, analyst targets, recommendations, and
  earnings dates, and writes four CSVs into `data/`:
    detail_summary.csv   (single row: 40+ fields)
    detail_history.csv   (~252 rows of OHLCV + SMA50 + SMA200)
    detail_analysts.csv  (targets + recommendation counts)
    detail_earnings.csv  (next earnings + last 4 surprises)
  Plus a `detail_status.txt` for UI polling and a
  `detail_error.log` written only on hard failure.
- All four CSVs use the same atomic .tmp+rename write pattern as
  the existing scripts -- the UI never reads a half-written file.
- Resilience: same `fast_info` -> `get_info()` -> `.info` fallback
  pattern established in v1.0.0 and reinforced in v1.2.0; two
  retries with backoff on the main history fetch; handles
  `analyst_price_targets` being either a dict or a DataFrame
  (yfinance has varied between the two).
- Total fetch time per ticker: ~3-5 seconds.

### UI / wiring
- New `Analyze-Tab.ps1` module (~600 lines) is self-contained. It is
  dot-sourced once from `StockUI.ps1`; `Add-AnalyzeTab` builds the
  tab and returns an API hashtable. The right-click menu item calls
  `$analyzeApi.AnalyzeTicker $ticker`.
- The fetcher runs as a background process; the existing 750ms
  polling pattern (read a status file, update the UI) is reused.
  The UI never blocks on Python.
- Right-click menu wording is dynamic: the menu item reads
  "Analyze {TICKER}" with the actual selected ticker, populated in
  the menu's Opening handler.

### Notes
- No new pip dependencies. yfinance and pandas were already required
  by `screener_full.py`.
- v1.3.0 builds cleanly on the v1.2.2 baseline. Setup.bat is
  unchanged.
- Re-running the full screen is NOT required to use the Analyze
  tab -- it fetches its own data fresh per ticker.

## [1.2.2] - 2026-05-22

### Fixed (packaging)
- **Share zip no longer includes stale sample data.** Previous versions
  bundled a v1.0.0-era `screen_data.csv` (6 columns, no Sector or
  Industry data) as sample data. On first launch the app loaded that
  file and looked broken: dropdowns empty, columns blank, "1205 stocks"
  shown but with no tags. Now the share zip ships with an empty `data/`
  folder and the app shows a clear first-launch dialog explaining how
  to build the dataset.

### Added
- **First-launch dialog box** when no `screen_data.csv` exists. Tells
  the user exactly what to do (click "Re-run Full Screen", wait 25-40
  min) instead of relying on a status-bar message they might miss.

## [1.2.1] - 2026-05-22

### Fixed
- **Sector and Industry dropdowns were stuck on "(All)" only** - the
  populate function was calling `BeginUpdate()` / `EndUpdate()` on the
  ComboBox controls, which silently failed because those methods only
  exist on ListBox (not ComboBox). The exception aborted the function
  before any sector/industry items got added. Removed those calls.

## [1.2.0] - 2026-05-22

### Fixed
- **Live price refresh now actually refreshes every ticker.** v1.1.0
  fetched all tickers but silently dropped any that yfinance's `fast_info`
  call returned None for - which on a 715-ticker grid was usually most
  of them. Result: a refresh would update 39 of 715 rows and overwrite
  the CSV, wiping out previously-good prices on the other 676 (which
  then showed "-"). The fix has three parts:
  - **`.info` fallback with 2 retries:** when `fast_info` returns None
    we now fall back to the slower `get_info()` then `.info` path,
    same as the screener does. Two retries with backoff handle transient
    Yahoo rate-limiting.
  - **Batches of 50 with a 1.0s pause between them.** Instead of
    slamming Yahoo with 715 concurrent requests, we go in 15 polite
    waves. Total time: 60-90 seconds for ~715 tickers.
  - **Merge instead of overwrite.** The Python now reads the existing
    `live_prices.csv` first and updates only tickers it successfully
    fetched. Failed tickers keep their last-known price instead of
    going to "-".
- **Progressive UI updates during refresh.** Since refresh now takes
  60-90s, the Python writes the CSV after every batch (every ~3-5s)
  and the UI's existing 1-second poll detects the change and reloads
  the grid. You see prices fill in as batches complete, instead of
  staring at "-" for 90 seconds.
- **`$Vol M` column header.** The dollar sign in the column header was
  being interpreted by PowerShell as a variable prefix and was getting
  swallowed. Escaped so it renders as a literal `$` now.

### Changed
- **Sector and Industry are now dependent single-select dropdowns** in
  place of the v1.1.0 multi-select listboxes. Pick a Sector and the
  Industry dropdown is filtered to only industries that actually exist
  within that Sector in your data. Each dropdown has `(All)` as the
  first option to clear the filter.
- **Sector and Industry columns removed from the grid.** Since those
  values are now used exclusively for filtering via the dropdowns,
  showing them as columns was redundant grid clutter. The data is still
  in screen_data.csv and is still used for the dropdowns - it just
  isn't rendered as a column anymore.
- **Removed "Clear Sector/Industry" button.** Redundant now that each
  dropdown has its own `(All)` option.
- "More" expander is now 140px tall (was 180px) since the listboxes
  were taller than dropdowns.

## [1.1.0] - 2026-05-20

### Fixed
- **Live price refresh no longer reshuffles rows on scroll.** Previously,
  scrolling triggered a partial refresh of just the visible window, which
  meant rows "popped in" with live prices as they scrolled into view,
  making the grid feel like it was moving around. Now "Refresh Prices"
  fetches the entire filtered grid in one shot. Prices remain static
  between refreshes - they only update when the user clicks Refresh or
  the 60-second auto-refresh timer fires.

### Added
- **Sector and Industry multi-select listboxes** behind the More expander.
  Replaces the old "Sector contains" text filter. Lists are populated
  dynamically from the data actually in screen_data.csv (Ctrl-click for
  multi-select). A "Clear Sector/Industry" button resets them in one
  click. Industry filter is brand new.
- **"3mo Px" column** showing the actual price from 3 months ago,
  alongside the existing "3mo %". This makes the 3-month math
  transparent and verifiable at a glance (the math itself was audited
  and looks correct - the new column lets the user confirm on any row).

### Notes
- v1.1.0 requires a fresh full screen run to populate the new Px3moAgo
  column. The screener now writes 16 fields per row (was 15). Existing
  CSVs from v1.0.x will show the new column as blank until re-screened.
- The Sector/Industry pull from Yahoo is unchanged - it's the same
  hardcoded `info.get("sector")` / `info.get("industry")` path, with
  the same get_info()-then-fallback-to-.info resilience added in v1.0.0.

## [1.0.1] - 2026-05-19

### Fixed
- Setup.bat now installs `openpyxl` (required by the Excel export).
  v1.0.0's installer omitted it, so "Export to Excel" failed with
  "Make sure openpyxl is installed" on machines where it wasn't
  already present. The screener itself was unaffected (it doesn't
  use openpyxl), which is why the gap went unnoticed until export.
- README dependency list updated to include openpyxl.

### Note
If upgrading from 1.0.0 without re-running Setup.bat, install the
missing library once:  `pip install openpyxl`

## [1.0.0] - 2026-05-18

First version-controlled release. Feature-complete against the original
9-criteria handwritten spec.

### Screener (screener_full.py)
- HARD filters: price $10-60, market cap > $500M, price below 52-week high,
  avg daily volume > 500K shares, avg daily dollar volume > $5M
- TAGGED (filterable in UI, not hard filters): sector, industry,
  index membership (S&P 500 / Nasdaq-100 / Dow 30), AI (curated list),
  Uranium, 3-month % change, 3-month trend (price up AND positive slope)
- Resilient sector/industry fetch: tries get_info() then falls back to
  the .info property so it works across yfinance versions
- Atomic CSV writes; progress reported to data/screen_status.txt

### UI (StockUI.ps1)
- Three tabs: Screen, Cohorts, Test Trades
- Screen: live price overlay, green/red move tinting, pin-to-top
  (persists to pinned.csv, overrides filters), right-click context menu
  (send to trades, pin, refresh, copy, open in Yahoo)
- Collapsible "More" filter section (Sector / Trending-up / AI-only)
- Cohorts: per-price-band top-15 horizontal bar charts (owner-drawn,
  no charting dependency)
- Test Trades: editable paper-trading log, auto-fill on ticker entry,
  live P/L, algorithm scorecard, right-click menu
- Export to Excel: choice of current view or full dataset, two-sheet
  formatted workbook (Screen + Trades)
- Startup error trapping with message box + error_log.txt

### Backend / packaging
- price_refresh.py: fast per-ticker live price fetch
- export_excel.py: formatted .xlsx builder
- trades_init.py: trades.csv bootstrap
- Setup.bat: first-run installer (Python check, pip install, Desktop shortcut)
- Launch.bat: execution-policy-safe launcher
- CSV-only backend, no database

### Known limitations
- Live prices delayed ~15 min (free Yahoo data)
- Index tags depend on Wikipedia table structure being reachable/stable
- UI not runtime-tested by the author's tooling; verified via user screenshots
- Full screen takes ~45-60 min (per-ticker history + info fetch)

---

## Pre-1.0 history (not individually versioned)

Built iteratively before version control was introduced:
- Initial Python screener -> Excel dashboard with live Stocks data type
- Pivoted away from M365 Stocks data type (unreliable) to a
  Python-fetches-everything / Excel-displays model
- Rebuilt as a PowerShell + WinForms desktop UI (CSV backend)
- Fixed encoding bug (em-dashes broke Windows PowerShell ANSI parsing)
- Added Cohorts charts, Test Trades, context menus, pinning
- Expanded screener from 3 metrics to the full 9-criteria spec
- UI cleanup pass + Excel export
