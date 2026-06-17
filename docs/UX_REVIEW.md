# UX Review - US Stock Screener (v1.4.0)

Role: UX designer. Deliverable: a prioritized set of UX opportunities and an
engineering handoff. This document does not change app code - it is the spec the
Engineer works from.

Method: two passes. Pass 1 is a first-principles heuristic sweep across the whole
product (what is the user trying to do, where does the product fight them). Pass 2
is a surface-by-surface deep dive with concrete, testable recommendations. The
handoff at the end turns the findings into a P0/P1/P2 backlog.

---

## 0. First principles

Start from the user's jobs-to-be-done, not the current screens:

- **JTBD-1 Find candidates.** "Show me beaten-down but still-viable US stocks I
  could buy." -> Screen tab.
- **JTBD-2 Understand a candidate.** "Is this one actually worth it - the numbers
  and the story?" -> Analyze (charts) + Analysis (Claude narrative).
- **JTBD-3 Track the bet.** "If I'd bought these, am I up? Is the strategy
  working?" -> Test Trades + scorecard.
- **JTBD-4 See the landscape.** "What does the whole opportunity set look like?"
  -> Cohorts.

Three lenses I will hold against every surface:

1. **Clarity** - can a non-quant user read the screen and know what it means and
   what to do next?
2. **Confidence** - does the product tell the truth about freshness, uncertainty,
   and what just happened (feedback, latency, errors)?
3. **Effort** - how many steps, clicks, and "wait, what?" moments between intent
   and outcome?

The single most important context: this is a desktop tool for an individual
investor, not a Bloomberg terminal for a pro. Density that a pro tolerates is
friction for this user. Optimize for "I understood it and trusted it," not "it
exposed every field."

---

## Pass 1 - Heuristic sweep (whole product)

Themes, highest-impact first. Details and fixes are in Pass 2.

### T1. Two tabs named "Analyze" and "Analysis" (naming collision)
The app now has five tabs: Screen, Cohorts, Test Trades, **Analyze**, **Analysis**.
"Analyze" (charts/technicals) and "Analysis" (Claude narrative) are
near-homographs sitting next to each other, and the Screen right-click offers both
"Analyze AAPL" and "Ask Claude about AAPL." Users cannot predict which does what.
This is the clearest, cheapest, highest-impact fix in the app.

### T2. The Screen grid is dense and speaks in code, not English
15 columns, several with cryptic headers ("Mkt Cap M", "$Vol M", "Uran", "3mo
Px"), no tooltips, and market cap shown as a raw millions number (e.g. `11289.0`
for an ~$11B company). The grid is the front door and the primary JTBD; right now
it reads like a CSV dump, not a decision aid.

### T3. Meaning is carried by color alone
P/L cells, live-price moves, and deep-drop rows are signaled only by green/pink
fill. Color-blind users (and anyone on a washed-out screen) lose the signal. No
text/icon backup.

### T4. Feedback is thin and easy to miss
Most state changes ("12 stocks shown", "Trades saved", "Export failed") land in a
single-line status bar that is quiet and transient. Long operations vary wildly:
the full screen has a real progress bar, Claude shows a status line, live refresh
is silent. The user often cannot tell whether something is working, done, or
broken.

### T5. The launch experience leaks implementation
Launch.bat opens a console window the user is told to keep open but not close.
That is an implementation detail (error capture) pushed onto the user as a rule to
remember. First-run also over-promises ("~7,000 stocks", numbers that disagree
across README/dialog/script) and asks for a 25-40 minute commitment with little
framing of the payoff.

### T6. The product occasionally over-claims
README says Cohorts breaks down by price band, distance-below-high, AND market-cap
tier; the app only draws the three price-band charts. The right-side trades panel
is labeled "ALGORITHM SCORECARD" though there is no algorithm - it is a
paper-trading P/L summary. Small gaps, but they erode trust (Confidence lens).

### T7. Discoverability depends on right-click
Send-to-Trades, Pin, Refresh, Copy, Yahoo, Analyze, Ask Claude all live only in a
right-click menu with no visible affordance. New users will never find them.

### T8. No fast path to a known ticker
On Screen there is no "jump to / search ticker" - the user filters or scrolls. For
JTBD-2 ("I already know I want to look at NVDA"), there is no front door except
typing it into a tab.

---

## Pass 2 - Surface-by-surface deep dive

Each item: Problem -> Recommendation -> Why (principle). Acceptance criteria are
consolidated in the handoff.

### A. Naming & information architecture
- **A1 Rename the two analysis tabs.** "Analyze" -> **"Chart"** (or "Detail");
  "Analysis" -> **"AI Research"** (or "Ask Claude"). Update the Screen right-click
  to match: "Chart AAPL" / "AI research on AAPL". *Why: Clarity. Names must
  predict behavior.*
- **A2 Reorder tabs to match the workflow.** Screen -> (Chart, AI Research grouped
  as "understand") -> Test Trades -> Cohorts. Put the two understand-a-stock tabs
  adjacent and clearly differentiated by name, not by guesswork.
- **A3 Rename "ALGORITHM SCORECARD"** to "Performance" or "Paper-Trading
  Summary." *Why: Confidence. Don't imply a capability that isn't there.*

### B. Screen tab (front door, JTBD-1)
- **B1 Humanize numbers.** Market cap as `$11.3B`, not `11289.0`. Dollar volume as
  `$827M`. Keep raw values for sort/filter, format for display. *Why: Clarity.*
- **B2 Rename/curate columns.** Spell out or tooltip every header ("Uran" ->
  "Uranium", "$Vol M" -> "Avg $ Vol", "3mo Px" -> "Price 3mo ago"). Consider a
  default view of the ~8 columns that drive the decision, with a "More columns"
  toggle for the rest (mirrors the existing "More" filter pattern). *Why: Clarity
  + Effort.*
- **B3 Add a ticker search/jump box** in the filter bar: type a symbol, grid
  scrolls/selects it (and offers "fetch it" if not in the set). *Why: Effort,
  serves JTBD-2 from the front door.*
- **B4 Verify and fix column sorting.** Rows are added as formatted strings, so
  header-click sorts likely sort lexically (so "9" > "1000") and would scramble
  pinned rows. Make numeric columns sort numerically and keep pinned rows pinned
  on top. *Why: Clarity; a screener you can't sort is half a screener.*
- **B5 Surface the data-freshness truth in the UI.** The header shows the last
  full-screen time; also label the Live column / status with "Live prices ~15 min
  delayed (Yahoo)" so users don't treat it as real-time. *Why: Confidence.*
- **B6 Make row actions discoverable.** Add a small "Actions" affordance (a
  caret/kebab on the selected row, or a thin toolbar that acts on the selection)
  duplicating the right-click menu. Keep right-click. *Why: Discoverability.*

### C. Meaning beyond color (cross-cutting, mostly Screen + Trades)
- **C1 Pair color with text/symbol.** P/L cells: prefix `+`/`-` and/or an
  up/down caret in addition to green/pink. Deep-drop rows: a small "DROP" tag or
  the existing Flag text shown prominently, not just pink fill. *Why:
  Accessibility/Clarity; never encode meaning in color alone.*

### D. Feedback & latency (cross-cutting)
- **D1 One consistent "busy" pattern.** Any operation >1s shows the same
  treatment: disable its trigger, show an inline spinner/label near the trigger,
  and a status-bar line. Applies to live refresh (currently silent), export,
  Claude, full screen. *Why: Confidence.*
- **D2 Make completion legible.** Transient status messages should also leave a
  durable trace for important events (e.g., "Saved 14:03", "Export complete" with
  the path as a clickable link/Open button). *Why: Confidence.*
- **D3 Right-size expectations before long waits.** Before the full screen, state
  plainly: "~6,900 tickers, about 25-40 minutes, runs in the background - you can
  keep using the app." Use one consistent number everywhere (see F1). *Why:
  Confidence + Effort.*

### E. Trust, safety, destructive actions
- **E1 Confirm destructive trade deletes** (Delete Row / context delete) or
  provide an Undo. Today a row vanishes and auto-saves with no recovery. *Why:
  Error recovery.*
- **E2 Keep the Claude disclaimer visible** (already present) and add a one-line
  "not advice / may be stale / verify numbers" caption on the Chart tab too where
  fundamentals are shown. *Why: Confidence.*
- **E3 Clarify autosave vs the Save button.** Trades autosave on edit, yet there
  is a "Save Trades" button - users won't know if their work is safe. Either show
  a subtle "All changes saved" indicator and de-emphasize the button, or remove
  the button. *Why: Confidence + Clarity.*

### F. Onboarding & launch
- **F1 Make the universe/runtime numbers consistent and honest.** One source of
  truth (the screener), referenced by README, the first-run dialog, and the
  button tooltip. *Why: Confidence.*
- **F2 Reduce the console-window burden.** Either launch without a user-visible
  console (the app already writes error_log.txt and shows a startup error box), or
  reframe the console as "log window (safe to minimize)". The current "keep open,
  don't close" rule is implementation leaking into UX. *Why: Effort. (Engineer to
  confirm error-visibility tradeoff.)*
- **F3 First-run value framing.** The bundled dataset means the app is useful
  immediately - say so on first run ("You're looking at a saved screen from
  <date>. Re-run anytime for fresh data.") instead of leading with the 25-40
  minute task. *Why: Effort, time-to-value.*

### G. Cohorts (JTBD-4)
- **G1 Match the product to the promise.** Either add the distance-below-high and
  market-cap-tier breakdowns the README claims, or trim the README. Today only
  the three price-band charts render. *Why: Confidence.*
- **G2 Let Cohorts reflect the current filter.** Charts only update after a full
  screen; let them optionally reflect the active Screen filters so the landscape
  view answers "the landscape of what I'm actually looking at." *Why: Clarity.*

### H. Chart / AI Research tabs (JTBD-2)
- **H1 Empty/initial states with a clear call to action.** Both tabs should, when
  empty, say what they do and how to start ("Right-click a stock on Screen, or
  type a ticker above"). The AI Research tab already does this well; mirror it.
- **H2 Loading-state honesty for Claude.** Keep the "10-30s" expectation; add a
  subtle animated indicator so a long pause never reads as a freeze. *Why:
  Confidence.*
- **H3 Cost transparency (optional).** The result already carries token usage;
  optionally show "~$0.07 this call" so cost-sensitive users stay informed. *Why:
  Confidence.*

---

## Engineering handoff - prioritized backlog

Effort: S (<0.5 day), M (~1 day), L (>1 day). All changes must preserve existing
behavior and stay pure ASCII in .ps1/.py (Windows PowerShell 5.1 ANSI parsing).

### P0 - do first (high impact, low cost)
| ID | Change | Files | Effort | Acceptance criteria |
|----|--------|-------|--------|---------------------|
| A1 | Rename tabs: "Analyze"->"Chart", "Analysis"->"AI Research"; update right-click labels to match | `Analyze-Tab.ps1`, `AnalysisTab.ps1`, `StockUI.ps1` | S | Tab strip reads Screen / Cohorts / Test Trades / Chart / AI Research; right-click shows "Chart AAPL" and "AI research on AAPL"; no other behavior changes |
| A3 | Rename "ALGORITHM SCORECARD" -> "Performance" | `StockUI.ps1` | S | Trades panel header and the empty-state string both updated |
| B1 | Format market cap and $ volume for humans ($X.XB / $XXXM); keep raw values for any sort/filter | `StockUI.ps1` (Apply-Filters render) | M | Grid shows `$11.3B` not `11289.0`; filters still work on the underlying number |
| B2a | Spell out / tooltip cryptic headers | `StockUI.ps1` (column setup) | S | No header is an unexplained abbreviation; hovering a header shows a plain-English description |
| C1 | Add +/- sign and up/down caret to P/L and live-delta cells (color stays) | `StockUI.ps1` (Recompute-Trades, Apply-Filters) | M | P/L readable in grayscale; meaning not lost without color |
| F1/G1 | Make universe/runtime numbers consistent; reconcile README Cohorts claim with what renders | `README.md`, `screener_full.py`, `StockUI.ps1` first-run dialog | S | One number used everywhere; README matches the rendered cohorts |

### P1 - next (meaningful, moderate cost)
| ID | Change | Files | Effort | Acceptance criteria |
|----|--------|-------|--------|---------------------|
| B3 | Ticker search/jump box on the Screen filter bar | `StockUI.ps1` | M | Typing a symbol selects/scrolls to its row; offers to fetch if absent |
| B4 | Numeric (not lexical) column sort; pinned rows stay on top | `StockUI.ps1` | M | Clicking "Price"/"% Below"/"Mkt Cap" sorts numerically asc/desc; pins remain pinned |
| B5/E2 | Surface "Live ~15 min delayed" and a not-advice caption where relevant | `StockUI.ps1`, `AnalysisTab.ps1` | S | Freshness/uncertainty visible in-app, not just the README |
| D1/D2 | One consistent busy+done pattern (disable trigger, inline indicator, durable completion message; Open button after export) | `StockUI.ps1` | M | Every >1s action looks busy while running and confirms on completion |
| E1 | Confirm-or-undo on trade row delete | `StockUI.ps1` | S | Deleting a trade requires confirmation or can be undone |
| E3 | Resolve autosave vs Save-button ambiguity | `StockUI.ps1` | S | User can tell at a glance that edits are saved |
| B6 | Visible row-actions affordance duplicating right-click | `StockUI.ps1` | M | Actions reachable without discovering right-click |

### P2 - later (worthwhile, larger or lower-traffic)
| ID | Change | Files | Effort | Acceptance criteria |
|----|--------|-------|--------|---------------------|
| B2b | Default curated column set + "More columns" toggle | `StockUI.ps1` | M | First view shows the decision-driving columns; rest behind a toggle |
| A2 | Reorder tabs to match workflow | `StockUI.ps1` | S | Understand-a-stock tabs are adjacent |
| F2/F3 | Reduce console-window burden; first-run value framing | `Launch.bat`, `StockUI.ps1` | M | No "keep this open" rule, or it is reframed as a log; first run leads with the saved dataset, not the 40-min task |
| G2 | Cohorts optionally reflect the active filter | `StockUI.ps1` | L | A toggle makes cohorts recompute from the filtered set |
| H3 | Per-call cost line in AI Research | `AnalysisTab.ps1` | S | Optional "~$X.XX this call" from the usage already returned |

### Quick wins (bundle into one PR)
A1, A3, B2a, F1 - all S, all high signal-to-noise, no behavioral risk.

---

## Guardrails for the Engineer
- **Additive and reversible.** No change should alter screener math, CSV formats,
  or the data layer. Display formatting must not change the values used for
  filtering, sorting, export, or P/L.
- **Pure ASCII** in `.ps1`/`.py`. Use text like "DROP" or ASCII carets (`^`/`v`),
  not Unicode arrows, for the color-independent signals.
- **No new runtime dependencies** for P0/P1 (keep the "nothing to install beyond
  Python" promise).
- **Verify on Windows.** The UI is statically checked here; each item needs a
  real PowerShell/WinForms run before it ships.

## Out of scope (note for product, not this pass)
Theming/dark mode, full accessibility audit (screen-reader/tab-order), persisted
user preferences (column choices, default filters), and multi-monitor/DPI scaling.
Worth a dedicated pass once the P0/P1 clarity work lands.
