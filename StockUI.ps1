<#
    StockUI.ps1  -  US Stock Screener desktop UI  (3-tab version)
    -------------------------------------------------------------
    PowerShell + WinForms. No install needed (ships with Windows).

    TABS:
      Screen      - browse/filter the screened universe, live price overlay
      Test Trades - paper-trading log, editable grid, P/L, scorecard
      Cohorts     - owner-drawn bar charts: price bands, % below buckets,
                    market cap tiers

    BACKEND: CSV files in .\data\  (no database)
      screen_data.csv   - the full screen (slow refresh)
      live_prices.csv   - live prices for visible tickers (fast refresh)
      trades.csv        - the paper-trading log
      screen_status.txt - progress text during a full re-screen
      screen_meta.txt   - last-run timestamp + counts

    Launch via Launch.bat (double-click).

    NOTE: file is intentionally pure ASCII - Windows PowerShell 5.1 reads
    .ps1 as ANSI, so any non-ASCII char breaks the parser.
#>

# ============================================================
# Setup
# ============================================================
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
} catch {
    $errMsg = "Failed to load WinForms/.NET: $($_.Exception.Message)"
    try { $errMsg | Out-File (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "error_log.txt") } catch {}
    Write-Host $errMsg -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataDir     = Join-Path $ScriptDir "data"
$ScreenCsv   = Join-Path $DataDir "screen_data.csv"
$LiveCsv     = Join-Path $DataDir "live_prices.csv"
$TradesCsv   = Join-Path $DataDir "trades.csv"
$PinnedCsv   = Join-Path $DataDir "pinned.csv"
$StatusFile  = Join-Path $DataDir "screen_status.txt"
$MetaFile    = Join-Path $DataDir "screen_meta.txt"
$PriceScript = Join-Path $ScriptDir "price_refresh.py"
$FullScript  = Join-Path $ScriptDir "screener_full.py"

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

# Find Python
$PythonExe = $null
foreach ($cand in @("python", "py")) {
    $found = Get-Command $cand -ErrorAction SilentlyContinue
    if ($found) { $PythonExe = $found.Source; break }
}

# Colors (one place, reused)
$ColNavy    = [System.Drawing.Color]::FromArgb(31,56,100)
$ColMid     = [System.Drawing.Color]::FromArgb(47,84,150)
$ColOrange  = [System.Drawing.Color]::FromArgb(197,90,17)
$ColFilter  = [System.Drawing.Color]::FromArgb(242,245,250)
$ColAltRow  = [System.Drawing.Color]::FromArgb(247,249,252)
$ColGreen   = [System.Drawing.Color]::FromArgb(226,239,218)
$ColRed     = [System.Drawing.Color]::FromArgb(252,228,228)
$ColYellow  = [System.Drawing.Color]::FromArgb(255,242,204)
$ColWhite   = [System.Drawing.Color]::White

# State
$script:AllRows       = @()
$script:LivePrices    = @{}
$script:PinnedSet     = New-Object System.Collections.Generic.HashSet[string]
$script:PriceJob      = $null
$script:FullJob       = $null
$script:LastPriceKick = [datetime]::MinValue
$script:ScrollDebounceSec = 4

# Atomic file replace: write a .tmp first, then swap it into place in a single
# filesystem operation so a reader never sees a half-written file. On Windows
# PowerShell 5.1 (.NET Framework) File.Move won't overwrite an existing file,
# so we use File.Replace when the destination exists (also atomic, same volume).
function Move-FileAtomic($tmp, $dest) {
    if (Test-Path $dest) {
        [System.IO.File]::Replace($tmp, $dest, $null)
    } else {
        [System.IO.File]::Move($tmp, $dest)
    }
}

# ============================================================
# Data loading
# ============================================================
function Load-ScreenData {
    if (-not (Test-Path $ScreenCsv)) { $script:AllRows = @(); return $false }
    try {
        $script:AllRows = @(Import-Csv $ScreenCsv)
        return $true
    } catch {
        $script:AllRows = @()
        return $false
    }
}

# Populate the Sector ComboBox from all unique sectors in the loaded data,
# and the Industry ComboBox from industries that exist within the currently
# selected sector. The selected sector drives which industries are listed.
# Both combos have "(All)" as the first item to represent no filter.
# Preserves the user's existing selections across a re-screen if those values
# still exist in the new data.
function Populate-SectorIndustry {
    if (-not $cmbSector -or -not $cmbIndustry) { return }
    if (-not $script:AllRows -or $script:AllRows.Count -eq 0) {
        # Suspend events while we wipe to avoid Apply-Filters firing mid-clear
        $script:SuspendFilterEvents = $true
        $cmbSector.Items.Clear()
        $cmbIndustry.Items.Clear()
        [void]$cmbSector.Items.Add("(All)")
        [void]$cmbIndustry.Items.Add("(All)")
        $cmbSector.SelectedIndex = 0
        $cmbIndustry.SelectedIndex = 0
        $script:SuspendFilterEvents = $false
        return
    }
    $prevSec = [string]$cmbSector.SelectedItem
    $prevInd = [string]$cmbIndustry.SelectedItem

    $sectors = @()
    foreach ($r in $script:AllRows) {
        if ($r.PSObject.Properties['Sector'] -and $r.Sector) { $sectors += [string]$r.Sector }
    }
    $sectors = $sectors | Sort-Object -Unique

    $script:SuspendFilterEvents = $true
    $cmbSector.Items.Clear()
    [void]$cmbSector.Items.Add("(All)")
    foreach ($s in $sectors) { [void]$cmbSector.Items.Add($s) }
    # Restore prior selection if possible, else (All)
    $newIdx = 0
    if ($prevSec) {
        $hit = $cmbSector.Items.IndexOf($prevSec)
        if ($hit -ge 0) { $newIdx = $hit }
    }
    $cmbSector.SelectedIndex = $newIdx
    $script:SuspendFilterEvents = $false

    # Now populate industries based on whichever sector ended up selected
    Populate-Industries -PreserveSelection $prevInd
}

# Helper: fill the Industry combo with industries that exist in the data
# under the currently-selected sector. If sector is "(All)", show all
# industries. Preserves a passed-in selection if it still exists in the list.
function Populate-Industries {
    param([string]$PreserveSelection = "")
    if (-not $cmbIndustry) { return }
    if (-not $script:AllRows) { return }

    $selectedSector = [string]$cmbSector.SelectedItem
    $industries = @()
    foreach ($r in $script:AllRows) {
        if (-not $r.PSObject.Properties['Industry'] -or -not $r.Industry) { continue }
        if ($selectedSector -and $selectedSector -ne "(All)") {
            if (-not $r.PSObject.Properties['Sector']) { continue }
            if ([string]$r.Sector -ne $selectedSector) { continue }
        }
        $industries += [string]$r.Industry
    }
    $industries = $industries | Sort-Object -Unique

    $script:SuspendFilterEvents = $true
    $cmbIndustry.Items.Clear()
    [void]$cmbIndustry.Items.Add("(All)")
    foreach ($s in $industries) { [void]$cmbIndustry.Items.Add($s) }
    # Try to keep the user's previous industry selection if it still applies
    $newIdx = 0
    if ($PreserveSelection) {
        $hit = $cmbIndustry.Items.IndexOf($PreserveSelection)
        if ($hit -ge 0) { $newIdx = $hit }
    }
    $cmbIndustry.SelectedIndex = $newIdx
    $script:SuspendFilterEvents = $false
}

function Load-LivePrices {
    $script:LivePrices = @{}
    if (-not (Test-Path $LiveCsv)) { return }
    try {
        foreach ($r in (Import-Csv $LiveCsv)) {
            $script:LivePrices[$r.Ticker] = @{
                Price     = $r.LivePrice
                High      = $r.Live52WHigh
                PctBelow  = $r.LivePctBelow
                UpdatedAt = $r.UpdatedAt
            }
        }
    } catch { }
}

function Get-MetaInfo {
    if (-not (Test-Path $MetaFile)) { return "No screen data yet - click 'Re-run Full Screen'." }
    try {
        $m = @{}
        foreach ($line in Get-Content $MetaFile) {
            if ($line -match "^(.+?)=(.+)$") { $m[$matches[1]] = $matches[2] }
        }
        return "Screen last run: $($m['last_run'])  |  $($m['passed']) of $($m['total_screened']) passed"
    } catch { return "Screen data present." }
}

function Load-Pinned {
    $script:PinnedSet.Clear()
    if (-not (Test-Path $PinnedCsv)) { return }
    try {
        foreach ($line in (Get-Content $PinnedCsv)) {
            $t = $line.Trim().ToUpper()
            if ($t -and $t -ne "TICKER") { [void]$script:PinnedSet.Add($t) }
        }
    } catch { }
}

function Save-Pinned {
    try {
        $tmp = $PinnedCsv + ".tmp"
        $sw = New-Object System.IO.StreamWriter($tmp, $false, [System.Text.Encoding]::UTF8)
        $sw.WriteLine("Ticker")
        foreach ($t in $script:PinnedSet) { $sw.WriteLine($t) }
        $sw.Close()
        Move-FileAtomic $tmp $PinnedCsv
    } catch { }
}

# ============================================================
# SCREEN TAB - filtering + grid
# ============================================================
function Apply-Filters {
    if (-not $script:AllRows -or $script:AllRows.Count -eq 0) {
        $grid.Rows.Clear()
        $lblCount.Text = "0 stocks"
        return
    }

    $minP = 0.0;      [double]::TryParse($txtMinPrice.Text, [ref]$minP)  | Out-Null
    $maxP = 999999.0; [double]::TryParse($txtMaxPrice.Text, [ref]$maxP)  | Out-Null
    $minC = 0.0;      [double]::TryParse($txtMinCap.Text,   [ref]$minC)  | Out-Null
    $maxDrop = 100.0; [double]::TryParse($txtMaxDrop.Text,  [ref]$maxDrop)| Out-Null
    # Single-select dropdowns: empty string or "(All)" means no filter
    $sectorPick = ""
    if ($cmbSector -and $cmbSector.SelectedItem) {
        $val = [string]$cmbSector.SelectedItem
        if ($val -and $val -ne "(All)") { $sectorPick = $val }
    }
    $industryPick = ""
    if ($cmbIndustry -and $cmbIndustry.SelectedItem) {
        $val = [string]$cmbIndustry.SelectedItem
        if ($val -and $val -ne "(All)") { $industryPick = $val }
    }
    $trendOnly = ($chkTrendUp -and $chkTrendUp.Checked)
    $aiOnly    = ($chkAIonly -and $chkAIonly.Checked)

    # Split into pinned (always shown, on top) and the rest (filtered)
    $pinnedRows = @()
    $otherRows  = @()
    foreach ($row in $script:AllRows) {
        $tk = ($row.Ticker.ToString().ToUpper())
        if ($script:PinnedSet.Contains($tk)) {
            $pinnedRows += $row
        } else {
            $p = [double]$row.Price
            $c = [double]$row.MarketCapM
            $d = [double]$row.PctBelow
            if ($p -lt $minP -or $p -gt $maxP) { continue }
            if ($c -lt $minC) { continue }
            if ($d -gt $maxDrop) { continue }
            # New tag-based filters (only applied if the column exists)
            if ($sectorPick -and $row.PSObject.Properties['Sector']) {
                if ([string]$row.Sector -ne $sectorPick) { continue }
            }
            if ($industryPick -and $row.PSObject.Properties['Industry']) {
                if ([string]$row.Industry -ne $industryPick) { continue }
            }
            if ($trendOnly -and $row.PSObject.Properties['TrendUp']) {
                if ([string]$row.TrendUp -ne "Y") { continue }
            }
            if ($aiOnly -and $row.PSObject.Properties['AI']) {
                if ([string]$row.AI -ne "Y") { continue }
            }
            $otherRows += $row
        }
    }
    # Pinned first, then filtered rest in original order
    $ordered = @($pinnedRows) + @($otherRows)

    $grid.SuspendLayout()
    $grid.Rows.Clear()
    foreach ($row in $ordered) {
        $tk = $row.Ticker
        $isPinned = $script:PinnedSet.Contains($tk.ToString().ToUpper())
        $live = $script:LivePrices[$tk]
        $livePrice = if ($live) { $live.Price } else { "" }
        $liveUpd   = if ($live) { $live.UpdatedAt } else { "" }

        $cPrice = "{0:N2}" -f [double]$row.Price
        $cHigh  = "{0:N2}" -f [double]$row.High52W
        $cPct   = "{0:N1}%" -f [double]$row.PctBelow
        $cCap   = "{0:N1}" -f [double]$row.MarketCapM
        $cFlag  = [string]$row.DataFlag
        if ($livePrice -ne "" -and $livePrice -ne $null) {
            $cLive = "{0:N2}" -f [double]$livePrice
        } else {
            $cLive = "-"
        }
        # Show a pin marker on the ticker for pinned rows
        $displayTk = if ($isPinned) { "[*] $tk" } else { $tk }

        $cAvgVol = if ($row.PSObject.Properties['AvgVolK']) { $row.AvgVolK } else { "" }
        $cDolVol = if ($row.PSObject.Properties['AvgDolVolM']) { $row.AvgDolVolM } else { "" }
        # Sector + Industry no longer displayed as grid columns (v1.2.0) -
        # they live in the dropdowns above. The data is still in $row for
        # filtering, just not rendered.
        $cIndex  = if ($row.PSObject.Properties['Indexes']) { $row.Indexes } else { "" }
        $cAI     = if ($row.PSObject.Properties['AI']) { $row.AI } else { "" }
        $cUran   = if ($row.PSObject.Properties['Uranium']) { $row.Uranium } else { "" }
        $c3mo    = if ($row.PSObject.Properties['Chg3moPct']) { "{0:N1}%" -f [double]$row.Chg3moPct } else { "" }
        $c3moPx  = if ($row.PSObject.Properties['Px3moAgo']) { "{0:N2}" -f [double]$row.Px3moAgo } else { "" }
        $cTrend  = if ($row.PSObject.Properties['TrendUp']) { $row.TrendUp } else { "" }

        $idx = $grid.Rows.Add($displayTk, $cPrice, $cLive, $cHigh, $cPct, $cCap,
                              $cAvgVol, $cDolVol, $cIndex,
                              $cAI, $cUran, $c3mo, $c3moPx, $cTrend, $cFlag)

        if ($isPinned) {
            # Subtle: very pale blue tint + bold navy ticker (not garish yellow)
            $grid.Rows[$idx].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(234,242,252)
            $grid.Rows[$idx].Cells[0].Style.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
            $grid.Rows[$idx].Cells[0].Style.ForeColor = $ColNavy
        } elseif ([double]$row.PctBelow -gt 70) {
            $grid.Rows[$idx].DefaultCellStyle.BackColor = $ColRed
        }
        if ($livePrice -ne "" -and $livePrice -ne $null) {
            $delta = [double]$livePrice - [double]$row.Price
            if ([math]::Abs($delta) -ge 0.01) {
                $col = if ($delta -gt 0) { $ColGreen } else { $ColRed }
                $grid.Rows[$idx].Cells[2].Style.BackColor = $col
            }
        }
    }
    $grid.ResumeLayout()
    $shown = $otherRows.Count
    $pinned = $pinnedRows.Count
    if ($pinned -gt 0) {
        $lblCount.Text = "$shown stocks  +  $pinned pinned"
        Set-Status "$shown stocks shown  -  $pinned pinned"
    } else {
        $lblCount.Text = "$shown stocks"
        Set-Status "$shown stocks shown"
    }
}

# ============================================================
# Background: live price refresh
# ============================================================
function Start-PriceRefresh {
    param([switch]$Force)
    if (-not $PythonExe) { Set-Status "Python not found - can't refresh live prices."; return }
    if ($script:PriceJob -and $script:PriceJob.State -eq "Running") { return }
    $script:LastPriceKick = [datetime]::Now

    # Fetch EVERY ticker currently in the (filtered) screen grid, plus every
    # trade-tab ticker. We do not subset to the scrolling window any more -
    # that caused rows to "pop in" with prices as the user scrolled, making
    # the grid feel like it was reshuffling. Now: one button press -> all
    # visible rows get prices in one shot, results stay static until the
    # next refresh.
    $allTickers = @()
    if ($grid.Rows.Count -gt 0) {
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
            $raw = [string]$grid.Rows[$i].Cells[0].Value
            # Strip the "[*] " pin marker if present
            $clean = $raw -replace '^\[\*\]\s*', ''
            if ($clean) { $allTickers += $clean.Trim().ToUpper() }
        }
    }
    if ($tradesGrid -and $tradesGrid.Rows.Count -gt 0) {
        for ($i = 0; $i -lt $tradesGrid.Rows.Count; $i++) {
            $t = $tradesGrid.Rows[$i].Cells[0].Value
            if ($t) { $allTickers += ([string]$t).Trim().ToUpper() }
        }
    }
    $allTickers = $allTickers | Select-Object -Unique
    if ($allTickers.Count -eq 0) { return }

    Set-Status "Refreshing live prices for $($allTickers.Count) tickers..."
    $argList = @($PriceScript) + $allTickers
    $script:PriceJob = Start-Job -ScriptBlock {
        param($py, $jobArgs)
        & $py @jobArgs 2>&1
    } -ArgumentList $PythonExe, $argList
}

# Poll the price job. The price_refresh.py script writes live_prices.csv
# atomically after EACH batch of 50, so we can refresh the grid progressively
# while the job is still running - the user sees prices come in instead of
# staring at "-" for 90 seconds.
$script:LastLiveCsvMTime = [datetime]::MinValue
function Check-PriceJob {
    if (-not $script:PriceJob) { return }
    if ($script:PriceJob.State -eq "Running") {
        # While running, see if the CSV got updated (batch finished) and reload
        if (Test-Path $LiveCsv) {
            try {
                $mt = (Get-Item $LiveCsv).LastWriteTime
                if ($mt -gt $script:LastLiveCsvMTime) {
                    $script:LastLiveCsvMTime = $mt
                    Load-LivePrices
                    Apply-Filters
                    Recompute-Trades
                }
            } catch { }
        }
        return
    }
    # Job has finished
    Receive-Job $script:PriceJob | Out-Null
    Remove-Job $script:PriceJob -Force
    $script:PriceJob = $null
    Load-LivePrices
    Apply-Filters
    Recompute-Trades
    Set-Status "Live prices updated $(Get-Date -Format 'HH:mm:ss')."
}

# ============================================================
# Background: full re-screen
# ============================================================
function Start-FullScreen {
    if (-not $PythonExe) {
        [System.Windows.Forms.MessageBox]::Show("Python not found. Install from python.org and check 'Add to PATH'.","No Python") | Out-Null
        return
    }
    if ($script:FullJob -and $script:FullJob.State -eq "Running") {
        [System.Windows.Forms.MessageBox]::Show("A full screen is already running.","Please wait") | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This re-screens ~5,500 US stocks. It takes 25-40 minutes and runs in the background - you can keep using the app. Start now?",
        "Re-run Full Screen",
        [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($confirm -ne "Yes") { return }

    "Starting..." | Set-Content $StatusFile
    $script:FullJob = Start-Job -ScriptBlock {
        param($py, $screenScript)
        & $py $screenScript 2>&1
    } -ArgumentList $PythonExe, $FullScript

    $btnFullScreen.Enabled = $false
    $btnFullScreen.Text = "Full Screen running..."
    $progressBar.Visible = $true
    $progressBar.Style = "Marquee"
    Set-Status "Full screen started - running in background."
}

function Check-FullJob {
    if (-not $script:FullJob) { return }
    if (Test-Path $StatusFile) {
        try {
            $s = (Get-Content $StatusFile -Raw).Trim()
            if ($s) {
                $lblProgress.Text = $s
                if ($s -match "Screening\s+(\d+)\s*/\s*(\d+)") {
                    $done = [int]$matches[1]; $tot = [int]$matches[2]
                    if ($tot -gt 0) {
                        $progressBar.Style = "Continuous"
                        $progressBar.Value = [Math]::Min(100, [int](($done / $tot) * 100))
                    }
                }
            }
        } catch { }
    }
    if ($script:FullJob.State -ne "Running") {
        Receive-Job $script:FullJob | Out-Null
        Remove-Job $script:FullJob -Force
        $script:FullJob = $null
        $btnFullScreen.Enabled = $true
        $btnFullScreen.Text = "Re-run Full Screen"
        $progressBar.Visible = $false
        $progressBar.Value = 0
        Load-ScreenData
        Populate-SectorIndustry
        Apply-Filters
        Draw-Cohorts
        $lblMeta.Text = Get-MetaInfo
        Set-Status "Full screen finished. Data reloaded."
    }
}

function Set-Status($msg) { $statusLabel.Text = $msg }

# ============================================================
# TEST TRADES TAB
# ============================================================
function Load-Trades {
    $tradesGrid.Rows.Clear()
    if (-not (Test-Path $TradesCsv)) { return }
    try {
        foreach ($t in (Import-Csv $TradesCsv)) {
            $tradesGrid.Rows.Add($t.Ticker, $t.BuyDate, $t.BuyPrice, $t.Qty,
                                 "", "", "", "", $t.SellDate, $t.SellPrice, "", "", "", $t.Notes) | Out-Null
        }
    } catch { }
    Recompute-Trades
}

function Save-Trades {
    $tmp = $TradesCsv + ".tmp"
    try {
        $sw = New-Object System.IO.StreamWriter($tmp, $false, [System.Text.Encoding]::UTF8)
        $sw.WriteLine("Ticker,BuyDate,BuyPrice,Qty,SellDate,SellPrice,Notes")
        for ($i = 0; $i -lt $tradesGrid.Rows.Count; $i++) {
            $r = $tradesGrid.Rows[$i]
            $tk = [string]$r.Cells[0].Value
            if ([string]::IsNullOrWhiteSpace($tk)) { continue }
            $vals = @(
                $tk,
                [string]$r.Cells[1].Value,
                [string]$r.Cells[2].Value,
                [string]$r.Cells[3].Value,
                [string]$r.Cells[8].Value,
                [string]$r.Cells[9].Value,
                [string]$r.Cells[13].Value
            )
            $escaped = foreach ($v in $vals) {
                if ($v -match '[,"]') { '"' + ($v -replace '"','""') + '"' } else { $v }
            }
            $sw.WriteLine($escaped -join ",")
        }
        $sw.Close()
        Move-FileAtomic $tmp $TradesCsv
        Set-Status "Trades saved $(Get-Date -Format 'HH:mm:ss')."
    } catch {
        Set-Status "Could not save trades: $($_.Exception.Message)"
    }
}

# Returns @{Price; Source} where Source is "live", "snap", or $null if no data.
# Prefers live (most recent) over snapshot (from screen).
function Get-BestPrice($ticker) {
    if ([string]::IsNullOrWhiteSpace($ticker)) { return $null }
    $tk = $ticker.ToString().ToUpper()
    # 1. Live price (most recent)
    if ($script:LivePrices.ContainsKey($tk)) {
        $lp = $script:LivePrices[$tk].Price
        if ($lp -ne $null -and $lp -ne "") {
            return @{ Price = [double]$lp; Source = "live" }
        }
    }
    # 2. Snapshot from the screen data
    foreach ($row in $script:AllRows) {
        if ($row.Ticker -eq $tk) {
            return @{ Price = [double]$row.Price; Source = "snap" }
        }
    }
    return $null
}

# Fire a one-shot background fetch for a single ticker so unknowns populate fast.
# Used when the user types a ticker we have no data for.
function Fetch-OneTicker($ticker) {
    if (-not $PythonExe) { return }
    if ([string]::IsNullOrWhiteSpace($ticker)) { return }
    # Don't stack on top of an existing job
    if ($script:PriceJob -and $script:PriceJob.State -eq "Running") { return }
    $tk = $ticker.ToString().ToUpper().Trim()
    Set-Status "Fetching live price for $tk..."
    $script:LastPriceKick = [datetime]::Now
    $argList = @($PriceScript, $tk)
    $script:PriceJob = Start-Job -ScriptBlock {
        param($py, $jobArgs)
        & $py @jobArgs 2>&1
    } -ArgumentList $PythonExe, $argList
}

# When the user types/changes the Ticker cell in row $r, auto-fill Buy Date
# (today, if blank) and Buy Price (current price, if blank). Investment and Qty
# remain for the user to enter, per design.
function AutoFill-TradeRow($r) {
    if ($r -lt 0 -or $r -ge $tradesGrid.Rows.Count) { return }
    $row = $tradesGrid.Rows[$r]
    $tk = [string]$row.Cells[0].Value
    if ([string]::IsNullOrWhiteSpace($tk)) { return }
    $tk = $tk.ToUpper().Trim()
    # Normalize the ticker cell to uppercase so all lookups are consistent
    if ($row.Cells[0].Value -ne $tk) { $row.Cells[0].Value = $tk }

    # Auto-fill Buy Date with today if blank
    if ([string]::IsNullOrWhiteSpace([string]$row.Cells[1].Value)) {
        $row.Cells[1].Value = (Get-Date).ToString("yyyy-MM-dd")
    }

    # Auto-fill Buy Price with current price if blank
    if ([string]::IsNullOrWhiteSpace([string]$row.Cells[2].Value)) {
        $best = Get-BestPrice $tk
        if ($best -ne $null) {
            $row.Cells[2].Value = "{0:N2}" -f $best.Price
            $tag = if ($best.Source -eq "live") { "live" } else { "snapshot" }
            Set-Status "Auto-filled $tk at `$$($row.Cells[2].Value) ($tag). Enter Qty to complete."
        } else {
            # No data yet - kick a one-shot fetch so it fills in shortly
            Fetch-OneTicker $tk
        }
    }
}

# ============================================================
# CONTEXT MENU ACTIONS  (right-click on either grid)
# ============================================================

# Extract a clean ticker from a row's ticker cell, stripping the "[*] " pin marker
function Get-RowTicker($row) {
    if (-not $row) { return $null }
    $raw = [string]$row.Cells[0].Value
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $clean = $raw -replace '^\[\*\]\s*', ''
    return $clean.Trim().ToUpper()
}

# Send the right-clicked screen-row ticker to the Test Trades tab
function CtxAction-SendToTrades($ticker) {
    if ([string]::IsNullOrWhiteSpace($ticker)) { return }
    # Add a new row at the top of trades grid, set the ticker, auto-fill the rest
    $newIdx = $tradesGrid.Rows.Add($ticker)
    AutoFill-TradeRow $newIdx
    Recompute-Trades
    Save-Trades
    $tabs.SelectedTab = $tabTrades
    $tradesGrid.CurrentCell = $tradesGrid.Rows[$newIdx].Cells[3]  # focus Qty
    Set-Status "Sent $ticker to Trades. Enter Qty to complete."
}

# Toggle pin on a ticker. Pinned tickers persist to pinned.csv and stay
# on top of the screen grid regardless of filters.
function CtxAction-TogglePin($ticker) {
    if ([string]::IsNullOrWhiteSpace($ticker)) { return }
    $t = $ticker.ToUpper()
    if ($script:PinnedSet.Contains($t)) {
        [void]$script:PinnedSet.Remove($t)
        Set-Status "Unpinned $t."
    } else {
        [void]$script:PinnedSet.Add($t)
        Set-Status "Pinned $t. It will stay on top, even when filtered."
    }
    Save-Pinned
    Apply-Filters
}

function CtxAction-RefreshTicker($ticker) {
    if ([string]::IsNullOrWhiteSpace($ticker)) { return }
    Fetch-OneTicker $ticker
}

function CtxAction-CopyTicker($ticker) {
    if ([string]::IsNullOrWhiteSpace($ticker)) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($ticker)
        Set-Status "Copied '$ticker' to clipboard."
    } catch {
        Set-Status "Clipboard failed: $($_.Exception.Message)"
    }
}

function CtxAction-OpenYahoo($ticker) {
    if ([string]::IsNullOrWhiteSpace($ticker)) { return }
    try {
        Start-Process "https://finance.yahoo.com/quote/$ticker"
    } catch {
        Set-Status "Could not open browser: $($_.Exception.Message)"
    }
}

function CtxAction-DeleteTradeRow($rowIdx) {
    if ($rowIdx -lt 0 -or $rowIdx -ge $tradesGrid.Rows.Count) { return }
    $tradesGrid.Rows.RemoveAt($rowIdx)
    Recompute-Trades
    Save-Trades
}

# Export the CURRENTLY DISPLAYED screen grid (filters + pins + sort applied)
# to a formatted .xlsx via export_excel.py.
function Export-ToExcel {
    if ($grid.Rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nothing to export - the screen grid is empty.","Export") | Out-Null
        return
    }
    if (-not $PythonExe) {
        [System.Windows.Forms.MessageBox]::Show("Python not found - needed to build the Excel file.","Export") | Out-Null
        return
    }

    # Ask: current filtered view, or the full dataset?
    $scope = [System.Windows.Forms.MessageBox]::Show(
        "Export the CURRENT VIEW (your filters, pins and sort)?" + [char]13 + [char]10 + [char]13 + [char]10 +
        "Yes  = current view (what's on screen now)" + [char]13 + [char]10 +
        "No   = the FULL dataset (every screened stock)" + [char]13 + [char]10 +
        "Cancel = don't export",
        "Export Scope",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($scope -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
    $useFullData = ($scope -eq [System.Windows.Forms.DialogResult]::No)

    # Ask where to save
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Excel Workbook (*.xlsx)|*.xlsx"
    $dlg.FileName = "Stock_Screen_$(Get-Date -Format 'yyyy-MM-dd_HHmm').xlsx"
    $dlg.Title = "Export screen to Excel"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $outPath = $dlg.FileName

    # Stage export data to data/export_screen.csv
    $exportCsv = Join-Path $DataDir "export_screen.csv"
    try {
        if ($useFullData) {
            # Full dataset: just copy screen_data.csv verbatim (all screener columns)
            if (Test-Path $ScreenCsv) {
                Copy-Item $ScreenCsv $exportCsv -Force
            } else {
                [System.Windows.Forms.MessageBox]::Show("No screen_data.csv to export.","Export Error") | Out-Null
                return
            }
        } else {
            # Current view: dump the visible grid (strip the [*] pin marker)
            $sw = New-Object System.IO.StreamWriter($exportCsv, $false, [System.Text.Encoding]::UTF8)
            $heads = @()
            foreach ($col in $grid.Columns) { $heads += $col.HeaderText }
            $sw.WriteLine(($heads | ForEach-Object {
                if ($_ -match '[,"]') { '"' + ($_ -replace '"','""') + '"' } else { $_ }
            }) -join ",")
            for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
                $vals = @()
                for ($c = 0; $c -lt $grid.Columns.Count; $c++) {
                    $v = [string]$grid.Rows[$i].Cells[$c].Value
                    if ($c -eq 0) { $v = $v -replace '^\[\*\]\s*', '' }
                    if ($v -match '[,"]') { $v = '"' + ($v -replace '"','""') + '"' }
                    $vals += $v
                }
                $sw.WriteLine($vals -join ",")
            }
            $sw.Close()
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not stage export data: $($_.Exception.Message)","Export Error") | Out-Null
        return
    }

    Set-Status "Building Excel file..."
    try {
        $exportScript = Join-Path $ScriptDir "export_excel.py"
        $p = Start-Process -FilePath $PythonExe -ArgumentList @($exportScript, $outPath) `
             -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -eq 0 -and (Test-Path $outPath)) {
            Set-Status "Exported to $outPath"
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Exported to:`r`n$outPath`r`n`r`nOpen it now?",
                "Export Complete",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-Process $outPath
            }
        } else {
            Set-Status "Export failed (exit $($p.ExitCode))."
            [System.Windows.Forms.MessageBox]::Show("Export failed. Make sure openpyxl is installed: pip install openpyxl","Export Error") | Out-Null
        }
    } catch {
        Set-Status "Export error."
        [System.Windows.Forms.MessageBox]::Show("Export error: $($_.Exception.Message)","Export Error") | Out-Null
    }
}

function Recompute-Trades {
    if (-not $tradesGrid) { return }
    $totInv = 0.0; $totCurVal = 0.0; $totPL = 0.0
    $nLogged = 0; $nClosed = 0; $nOpen = 0; $nWin = 0; $nLoss = 0
    $best = $null; $worst = $null

    for ($i = 0; $i -lt $tradesGrid.Rows.Count; $i++) {
        $r = $tradesGrid.Rows[$i]
        $tk = [string]$r.Cells[0].Value
        if ([string]::IsNullOrWhiteSpace($tk)) { continue }
        $nLogged++

        $buyPrice = 0.0;  $hasBuy  = [double]::TryParse([string]$r.Cells[2].Value, [ref]$buyPrice)
        $qty = 0.0;       $hasQty  = [double]::TryParse([string]$r.Cells[3].Value, [ref]$qty)
        $sellPrice = 0.0; $hasSell = [double]::TryParse([string]$r.Cells[9].Value, [ref]$sellPrice)

        if ($hasBuy -and $hasQty) {
            $inv = $buyPrice * $qty
            $r.Cells[4].Value = "{0:N2}" -f $inv
            $totInv += $inv
        } else { $r.Cells[4].Value = ""; $inv = 0 }

        # Prefer the live price, but fall back to the screen snapshot so a
        # freshly loaded trade shows a price immediately instead of "-" until
        # the first live refresh lands. (Get-BestPrice does live -> snapshot.)
        $best = Get-BestPrice $tk
        $curPrice = $null
        if ($best -ne $null) {
            $curPrice = $best.Price
            $r.Cells[5].Value = "{0:N2}" -f $curPrice
        } else {
            $r.Cells[5].Value = "-"
        }

        if ($curPrice -ne $null -and $hasQty) {
            $curVal = $curPrice * $qty
            $r.Cells[6].Value = "{0:N2}" -f $curVal
            $totCurVal += $curVal
        } else { $r.Cells[6].Value = "" }

        $status = "Need buy info"
        if ($hasBuy -and $hasQty) {
            if ($hasSell) { $status = "Closed" } else { $status = "Open" }
        }
        $r.Cells[7].Value = $status
        $r.Cells[12].Value = $status

        $pl = $null; $plPct = $null
        if ($hasBuy -and $hasQty) {
            if ($hasSell) {
                $pl = ($sellPrice - $buyPrice) * $qty
                $plPct = ($sellPrice - $buyPrice) / $buyPrice
            } elseif ($curPrice -ne $null) {
                $pl = ($curPrice - $buyPrice) * $qty
                $plPct = ($curPrice - $buyPrice) / $buyPrice
            }
        }
        if ($pl -ne $null) {
            $r.Cells[10].Value = "{0:N2}" -f $pl
            $r.Cells[11].Value = "{0:P1}" -f $plPct
            $totPL += $pl
            if ($pl -gt 0) { $nWin++ } elseif ($pl -lt 0) { $nLoss++ }
            if ($best  -eq $null -or $pl -gt $best)  { $best  = $pl }
            if ($worst -eq $null -or $pl -lt $worst) { $worst = $pl }
            $plColor = if ($pl -gt 0) { $ColGreen } elseif ($pl -lt 0) { $ColRed } else { $ColWhite }
            $r.Cells[10].Style.BackColor = $plColor
            $r.Cells[11].Style.BackColor = $plColor
        } else {
            $r.Cells[10].Value = ""
            $r.Cells[11].Value = ""
        }

        if ($status -eq "Closed") { $nClosed++ }
        elseif ($status -eq "Open") { $nOpen++ }
    }

    $lblTotInv.Text = "Total Invested:  `$" + ("{0:N2}" -f $totInv)
    $lblTotVal.Text = "Current Value:  `$" + ("{0:N2}" -f $totCurVal)
    $plStr = "{0:N2}" -f $totPL
    $lblTotPL.Text  = "Total P/L:  `$" + $plStr
    $lblTotPL.ForeColor = if ($totPL -gt 0) { [System.Drawing.Color]::DarkGreen }
                          elseif ($totPL -lt 0) { [System.Drawing.Color]::DarkRed }
                          else { [System.Drawing.Color]::Black }

    $winRate = if (($nWin + $nLoss) -gt 0) { "{0:P1}" -f ($nWin / ($nWin + $nLoss)) } else { "-" }
    $totRet  = if ($totInv -gt 0) { "{0:P1}" -f ($totPL / $totInv) } else { "-" }
    $bestStr  = if ($best  -ne $null) { "`$" + ("{0:N2}" -f $best) }  else { "-" }
    $worstStr = if ($worst -ne $null) { "`$" + ("{0:N2}" -f $worst) } else { "-" }

    $lblScore.Text = @"
ALGORITHM SCORECARD

Positions logged:   $nLogged
Closed trades:      $nClosed
Open trades:        $nOpen

Winners (P/L > 0):  $nWin
Losers  (P/L < 0):  $nLoss
Win rate:           $winRate

Total P/L:          $plStr
Total return:       $totRet
Best trade:         $bestStr
Worst trade:        $worstStr
"@
}

# ============================================================
# COHORTS TAB - per price-band top-15 horizontal bar charts
# Each band gets a ranked list of the 15 stocks furthest below their
# 52-week high, drawn as horizontal bars (Excel-Charts-tab style).
# ============================================================
function Get-CohortData {
    # Returns ordered hashtable: band-label -> list of @{Ticker; Pct} sorted desc
    $result = [ordered]@{
        '$10-25' = @()
        '$25-40' = @()
        '$40-60' = @()
    }
    if (-not $script:AllRows -or $script:AllRows.Count -eq 0) { return $result }

    foreach ($row in $script:AllRows) {
        $p = [double]$row.Price
        $d = [double]$row.PctBelow
        $entry = @{ Ticker = $row.Ticker; Pct = $d }
        if ($p -lt 25) { $result['$10-25'] += $entry }
        elseif ($p -lt 40) { $result['$25-40'] += $entry }
        else { $result['$40-60'] += $entry }
    }
    # Sort each band desc by Pct, take top 15
    foreach ($k in @($result.Keys)) {
        $sorted = $result[$k] | Sort-Object -Property { [double]$_.Pct } -Descending
        $top = @($sorted | Select-Object -First 15)
        $result[$k] = $top
    }
    return $result
}

function Draw-HBarChart {
    param($g, $x, $y, $w, $h, $title, $rows)
    # rows: array of @{Ticker; Pct}, already sorted desc by Pct (largest first)
    $titleFont = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $tickFont  = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $axisFont  = New-Object System.Drawing.Font("Segoe UI", 8)
    $valFont   = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $navyBrush = New-Object System.Drawing.SolidBrush($ColNavy)
    $midBrush  = New-Object System.Drawing.SolidBrush($ColMid)
    $blackBrush= New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
    $greyPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200,200,200))
    $gridPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(230,230,230))

    # GDI objects are native handles that the GC frees only on a non-deterministic
    # finalizer pass. This panel repaints on every resize / tab switch, so without
    # explicit disposal the handle count climbs over a long session. Dispose in a
    # finally so every exit path (including the early "no rows" return) cleans up.
    try {
    # Title
    $g.DrawString($title, $titleFont, $navyBrush, [single]$x, [single]$y)

    if (-not $rows -or $rows.Count -eq 0) {
        $f = New-Object System.Drawing.Font("Segoe UI", 10)
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gray)
        $g.DrawString("(no stocks in this band)", $f, $b, [single]($x + 20), [single]($y + 40))
        $f.Dispose(); $b.Dispose()
        return
    }

    # Layout: title takes top 28px; left label gutter 60px; bottom axis label 24px
    $padTop = 30
    $labelGutter = 56
    $axisBottom = 22
    $plotX = $x + $labelGutter
    $plotY = $y + $padTop
    $plotW = $w - $labelGutter - 20
    $plotH = $h - $padTop - $axisBottom

    # Max value for scaling - round up to next 10%
    $maxPct = 0
    foreach ($r in $rows) { if ([double]$r.Pct -gt $maxPct) { $maxPct = [double]$r.Pct } }
    if ($maxPct -le 0) { $maxPct = 10 }
    $axisMax = [Math]::Ceiling($maxPct / 10) * 10

    # Vertical gridlines + axis labels (every 10%)
    $steps = [int]($axisMax / 10)
    if ($steps -lt 1) { $steps = 1 }
    for ($i = 0; $i -le $steps; $i++) {
        $frac = $i / $steps
        $gx = $plotX + ($frac * $plotW)
        $g.DrawLine($gridPen, [single]$gx, [single]$plotY, [single]$gx, [single]($plotY + $plotH))
        $lbl = ("{0:N1}%" -f ($frac * $axisMax))
        $ls = $g.MeasureString($lbl, $axisFont)
        $g.DrawString($lbl, $axisFont, $blackBrush, [single]($gx - $ls.Width/2), [single]($plotY + $plotH + 4))
    }
    # Y-axis line
    $g.DrawLine($greyPen, [single]$plotX, [single]$plotY, [single]$plotX, [single]($plotY + $plotH))

    # Bars - one per row
    $n = $rows.Count
    $rowH = $plotH / $n
    $barH = [Math]::Max(8, $rowH * 0.6)
    # Excel screenshot has the LARGEST value at the BOTTOM, so we'll plot
    # in reverse: largest pct gets drawn at the bottom of the chart.
    for ($i = 0; $i -lt $n; $i++) {
        $r = $rows[$i]
        $val = [double]$r.Pct
        $barW = ($val / $axisMax) * $plotW
        # bottom-up index: largest (index 0) goes to bottom
        $rowFromBottom = $i
        $by = $plotY + $plotH - (($rowFromBottom + 1) * $rowH) + ($rowH - $barH) / 2
        $rect = New-Object System.Drawing.RectangleF([single]$plotX, [single]$by, [single]$barW, [single]$barH)
        $g.FillRectangle($midBrush, $rect)
        # Ticker label to the left of axis
        $tk = [string]$r.Ticker
        $ts = $g.MeasureString($tk, $tickFont)
        $g.DrawString($tk, $tickFont, $blackBrush,
            [single]($plotX - $ts.Width - 4),
            [single]($by + ($barH - $ts.Height) / 2))
        # Value at end of bar
        $vstr = "{0:N1}%" -f $val
        $vs = $g.MeasureString($vstr, $valFont)
        $g.DrawString($vstr, $valFont, $blackBrush,
            [single]($plotX + $barW + 4),
            [single]($by + ($barH - $vs.Height) / 2))
    }
    } finally {
        foreach ($d in @($titleFont,$tickFont,$axisFont,$valFont,$navyBrush,$midBrush,$blackBrush,$greyPen,$gridPen)) {
            if ($d) { $d.Dispose() }
        }
    }
}

function Draw-Cohorts {
    if (-not $cohortPanel) { return }
    $cohortPanel.Invalidate()
}

# ============================================================
# BUILD THE WINDOW
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "US Stock Screener"
$form.Size = New-Object System.Drawing.Size(1140, 760)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(960, 600)
$form.BackColor = $ColWhite

# ---- Header ----
$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"; $header.Height = 48; $header.BackColor = $ColNavy
$form.Controls.Add($header)

$AppVersion = "?"
try {
    $vf = Join-Path $ScriptDir "VERSION"
    if (Test-Path $vf) { $AppVersion = (Get-Content $vf -Raw).Trim() }
} catch {}

$titleLbl = New-Object System.Windows.Forms.Label
$titleLbl.Text = "  US STOCK SCREENER   v$AppVersion"
$titleLbl.ForeColor = $ColWhite
$titleLbl.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$titleLbl.Dock = "Left"; $titleLbl.AutoSize = $true; $titleLbl.TextAlign = "MiddleLeft"
$header.Controls.Add($titleLbl)

$lblMeta = New-Object System.Windows.Forms.Label
$lblMeta.Text = Get-MetaInfo
$lblMeta.ForeColor = [System.Drawing.Color]::FromArgb(210,228,240)
$lblMeta.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblMeta.Dock = "Right"; $lblMeta.AutoSize = $true; $lblMeta.TextAlign = "MiddleRight"
$lblMeta.Padding = New-Object System.Windows.Forms.Padding(0,0,12,0)
$header.Controls.Add($lblMeta)

# ---- Status bar ----
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Ready."
$statusStrip.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusStrip)

# ---- Tab control ----
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabs.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$form.Controls.Add($tabs)
$tabs.BringToFront()

$tabScreen  = New-Object System.Windows.Forms.TabPage; $tabScreen.Text  = "  Screen  "
$tabCohorts = New-Object System.Windows.Forms.TabPage; $tabCohorts.Text = "  Cohorts  "
$tabTrades  = New-Object System.Windows.Forms.TabPage; $tabTrades.Text  = "  Test Trades  "
$tabScreen.BackColor  = $ColWhite
$tabCohorts.BackColor = $ColWhite
$tabTrades.BackColor  = $ColWhite
$tabs.TabPages.AddRange(@($tabScreen, $tabCohorts, $tabTrades))

# ============================================================
# TAB 1: SCREEN
# ============================================================
$filterBar = New-Object System.Windows.Forms.Panel
$filterBar.Dock = "Top"; $filterBar.BackColor = $ColFilter
$tabScreen.Controls.Add($filterBar)

function New-FilterLabel($parent, $text, $x) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, 12)
    $l.Size = New-Object System.Drawing.Size(120, 18)
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $ColNavy
    $parent.Controls.Add($l)
}
function New-FilterBox($parent, $x, $val) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, 32)
    $t.Size = New-Object System.Drawing.Size(90, 24)
    $t.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $t.Text = $val
    $parent.Controls.Add($t)
    return $t
}

New-FilterLabel $filterBar "Min Price ($)" 16
$txtMinPrice = New-FilterBox $filterBar 16 "10"
New-FilterLabel $filterBar "Max Price ($)" 120
$txtMaxPrice = New-FilterBox $filterBar 120 "60"
New-FilterLabel $filterBar "Min Mkt Cap (M)" 224
$txtMinCap = New-FilterBox $filterBar 224 "500"
New-FilterLabel $filterBar "Max % Below High" 328
$txtMaxDrop = New-FilterBox $filterBar 328 "70"

# Second filter row: Sector + Industry dropdowns (single-select, with (All) to clear).
# The Industry dropdown is filtered to industries that exist in the selected sector.
$lblSector = New-Object System.Windows.Forms.Label
$lblSector.Text = "Sector"
$lblSector.Location = New-Object System.Drawing.Point(16, 60)
$lblSector.Size = New-Object System.Drawing.Size(180, 18)
$lblSector.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSector.ForeColor = $ColNavy
$filterBar.Controls.Add($lblSector)

$cmbSector = New-Object System.Windows.Forms.ComboBox
$cmbSector.Location = New-Object System.Drawing.Point(16, 80)
$cmbSector.Size = New-Object System.Drawing.Size(220, 24)
$cmbSector.DropDownStyle = "DropDownList"   # read-only list (no free text)
$cmbSector.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbSector.FlatStyle = "Flat"
[void]$cmbSector.Items.Add("(All)")
$cmbSector.SelectedIndex = 0
$filterBar.Controls.Add($cmbSector)

$lblIndustry = New-Object System.Windows.Forms.Label
$lblIndustry.Text = "Industry"
$lblIndustry.Location = New-Object System.Drawing.Point(248, 60)
$lblIndustry.Size = New-Object System.Drawing.Size(180, 18)
$lblIndustry.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblIndustry.ForeColor = $ColNavy
$filterBar.Controls.Add($lblIndustry)

$cmbIndustry = New-Object System.Windows.Forms.ComboBox
$cmbIndustry.Location = New-Object System.Drawing.Point(248, 80)
$cmbIndustry.Size = New-Object System.Drawing.Size(280, 24)
$cmbIndustry.DropDownStyle = "DropDownList"
$cmbIndustry.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbIndustry.FlatStyle = "Flat"
[void]$cmbIndustry.Items.Add("(All)")
$cmbIndustry.SelectedIndex = 0
$filterBar.Controls.Add($cmbIndustry)

# Flag that lets Populate-SectorIndustry suspend the SelectedIndexChanged
# handler while it's rebuilding the lists - otherwise Apply-Filters would
# fire on every Add() and we'd thrash through 1500 redraws.
$script:SuspendFilterEvents = $false

$chkTrendUp = New-Object System.Windows.Forms.CheckBox
$chkTrendUp.Text = "Trending up (3mo) only"
$chkTrendUp.Location = New-Object System.Drawing.Point(548, 80)
$chkTrendUp.Size = New-Object System.Drawing.Size(170, 20)
$chkTrendUp.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$filterBar.Controls.Add($chkTrendUp)

$chkAIonly = New-Object System.Windows.Forms.CheckBox
$chkAIonly.Text = "AI only"
$chkAIonly.Location = New-Object System.Drawing.Point(548, 104)
$chkAIonly.Size = New-Object System.Drawing.Size(170, 20)
$chkAIonly.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$filterBar.Controls.Add($chkAIonly)

# --- "More" expander: secondary filters are hidden by default for a calmer bar ---
$script:FiltersExpanded = $false
$collapsedH = 64
$expandedH  = 140   # smaller now that listboxes are gone
$filterBar.Height = $collapsedH

$btnMore = New-Object System.Windows.Forms.Button
$btnMore.Text = "More v"
$btnMore.Size = New-Object System.Drawing.Size(78, 24)
$btnMore.Location = New-Object System.Drawing.Point(548, 32)
$btnMore.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnMore.FlatStyle = "Flat"
$btnMore.BackColor = $ColFilter
$btnMore.ForeColor = $ColNavy
$filterBar.Controls.Add($btnMore)

# The secondary controls start hidden
$lblSector.Visible    = $false
$cmbSector.Visible    = $false
$lblIndustry.Visible  = $false
$cmbIndustry.Visible  = $false
$chkTrendUp.Visible   = $false
$chkAIonly.Visible    = $false

$btnMore.Add_Click({
    $script:FiltersExpanded = -not $script:FiltersExpanded
    $vis = $script:FiltersExpanded
    $lblSector.Visible    = $vis
    $cmbSector.Visible    = $vis
    $lblIndustry.Visible  = $vis
    $cmbIndustry.Visible  = $vis
    $chkTrendUp.Visible   = $vis
    $chkAIonly.Visible    = $vis
    if ($vis) {
        $filterBar.Height = $expandedH
        $btnMore.Text = "Less ^"
    } else {
        $filterBar.Height = $collapsedH
        $btnMore.Text = "More v"
    }
})

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Apply Filters"
$btnApply.Location = New-Object System.Drawing.Point(432, 31)
$btnApply.Size = New-Object System.Drawing.Size(104, 26)
$btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnApply.BackColor = $ColMid; $btnApply.ForeColor = $ColWhite; $btnApply.FlatStyle = "Flat"
$filterBar.Controls.Add($btnApply)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = "0 stocks"
$lblCount.Location = New-Object System.Drawing.Point(636, 8)
$lblCount.Size = New-Object System.Drawing.Size(40, 18)
$lblCount.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblCount.ForeColor = $ColNavy
$lblCount.Visible = $false  # superseded by the summary line; kept for code refs
$filterBar.Controls.Add($lblCount)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh Prices"
$btnRefresh.Size = New-Object System.Drawing.Size(118, 26)
$btnRefresh.Location = New-Object System.Drawing.Point(680, 31)
$btnRefresh.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.BackColor = $ColMid
$btnRefresh.ForeColor = $ColWhite
$filterBar.Controls.Add($btnRefresh)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export to Excel"
$btnExport.Size = New-Object System.Drawing.Size(118, 26)
$btnExport.Location = New-Object System.Drawing.Point(806, 31)
$btnExport.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnExport.FlatStyle = "Flat"
$btnExport.BackColor = [System.Drawing.Color]::FromArgb(33,115,70)
$btnExport.ForeColor = $ColWhite
$filterBar.Controls.Add($btnExport)

# Full Screen: rare + slow, so visually quiet - tucked under Refresh/Export, always visible
$btnFullScreen = New-Object System.Windows.Forms.Button
$btnFullScreen.Text = "Re-run Full Screen (slow)"
$btnFullScreen.Size = New-Object System.Drawing.Size(160, 22)
$btnFullScreen.Location = New-Object System.Drawing.Point(680, 4)
$btnFullScreen.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnFullScreen.FlatStyle = "Flat"
$btnFullScreen.BackColor = $ColFilter
$btnFullScreen.ForeColor = $ColNavy
$filterBar.Controls.Add($btnFullScreen)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = "Auto-refresh prices every 60s"
$chkAuto.Location = New-Object System.Drawing.Point(846, 6)
$chkAuto.Size = New-Object System.Drawing.Size(200, 20)
$chkAuto.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$chkAuto.Checked = $true
$filterBar.Controls.Add($chkAuto)

# Progress strip
$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Dock = "Top"; $progressPanel.Height = 28; $progressPanel.BackColor = $ColYellow
$tabScreen.Controls.Add($progressPanel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, 5)
$progressBar.Size = New-Object System.Drawing.Size(300, 16)
$progressBar.Visible = $false
$progressPanel.Controls.Add($progressBar)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = ""
$lblProgress.Location = New-Object System.Drawing.Point(328, 6)
$lblProgress.Size = New-Object System.Drawing.Size(760, 18)
$lblProgress.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$progressPanel.Controls.Add($lblProgress)

# The grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.BackgroundColor = $ColWhite
$grid.BorderStyle = "None"
$grid.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = $ColMid
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $ColWhite
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersHeightSizeMode = "DisableResizing"
$grid.ColumnHeadersHeight = 32
$grid.AlternatingRowsDefaultCellStyle.BackColor = $ColAltRow
# Cleaner look: more row breathing room, soft gridlines, no harsh cell borders
$grid.RowTemplate.Height = 26
$grid.GridColor = [System.Drawing.Color]::FromArgb(232,235,240)
$grid.CellBorderStyle = "SingleHorizontal"
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(210,224,244)
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4,0,4,0)
$grid.AllowUserToResizeRows = $false

foreach ($h in @("Ticker","Price","Live","52W High","% Below","Mkt Cap M","Avg Vol K","`$Vol M","Index","AI","Uran","3mo %","3mo Px","Trend","Flag")) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $h; $col.Name = $h
    $grid.Columns.Add($col) | Out-Null
}
$tabScreen.Controls.Add($grid)
$grid.BringToFront()

# ---- Screen grid context menu (right-click) ----
$screenMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miSendTrades = $screenMenu.Items.Add("Send to Test Trades")
$miPin        = $screenMenu.Items.Add("Pin to Top")
$screenMenu.Items.Add("-") | Out-Null  # separator
$miRefresh1   = $screenMenu.Items.Add("Refresh this ticker now")
$miCopy1      = $screenMenu.Items.Add("Copy ticker to clipboard")
$miYahoo1     = $screenMenu.Items.Add("View on Yahoo Finance")

# Holds the right-clicked ticker for the duration of the menu interaction
$script:CtxScreenTicker = $null

$grid.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $grid.ClearSelection()
        $grid.Rows[$e.RowIndex].Selected = $true
        $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[0]
        $script:CtxScreenTicker = Get-RowTicker $grid.Rows[$e.RowIndex]
        # Update Pin/Unpin label
        if ($script:CtxScreenTicker -and $script:PinnedSet.Contains($script:CtxScreenTicker)) {
            $miPin.Text = "Unpin"
        } else {
            $miPin.Text = "Pin to Top"
        }
    }
})
$grid.ContextMenuStrip = $screenMenu

$miSendTrades.Add_Click({ CtxAction-SendToTrades $script:CtxScreenTicker })
$miPin.Add_Click({        CtxAction-TogglePin     $script:CtxScreenTicker })
$miRefresh1.Add_Click({   CtxAction-RefreshTicker $script:CtxScreenTicker })
$miCopy1.Add_Click({      CtxAction-CopyTicker    $script:CtxScreenTicker })
$miYahoo1.Add_Click({     CtxAction-OpenYahoo     $script:CtxScreenTicker })

# ============================================================
# v1.3.0 - "Analyze {ticker}" right-click menu item
# Sits at the bottom of the Screen-grid context menu. Calls into
# $script:analyzeApi, which is created later (just before ShowDialog).
# ============================================================
$screenMenu.Items.Add("-") | Out-Null  # separator
$miAnalyze = $screenMenu.Items.Add("Analyze...")
$miAnalyze.Add_Click({
    if (-not $script:CtxScreenTicker) { return }
    if (-not $script:analyzeApi)      { return }
    & $script:analyzeApi.AnalyzeTicker $script:CtxScreenTicker
})

# Update the menu text dynamically when it opens so it reads "Analyze AAPL"
# rather than a generic label. CellMouseDown already populates $script:CtxScreenTicker.
$screenMenu.Add_Opening({
    if ($script:CtxScreenTicker) {
        $miAnalyze.Text = "Analyze $($script:CtxScreenTicker)"
    } else {
        $miAnalyze.Text = "Analyze..."
    }
})

# ============================================================
# TAB 2: TEST TRADES
# ============================================================
$tradesTop = New-Object System.Windows.Forms.Panel
$tradesTop.Dock = "Top"; $tradesTop.Height = 56; $tradesTop.BackColor = $ColFilter
$tabTrades.Controls.Add($tradesTop)

$lblTradesHelp = New-Object System.Windows.Forms.Label
$lblTradesHelp.Text = "Type a Ticker - Buy Date (today) and Buy Price (live) auto-fill. Then just enter Qty. Add Sell Price to close a trade."
$lblTradesHelp.Location = New-Object System.Drawing.Point(16, 8)
$lblTradesHelp.Size = New-Object System.Drawing.Size(720, 18)
$lblTradesHelp.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$tradesTop.Controls.Add($lblTradesHelp)

$btnAddTrade = New-Object System.Windows.Forms.Button
$btnAddTrade.Text = "+ Add Row"
$btnAddTrade.Location = New-Object System.Drawing.Point(16, 28)
$btnAddTrade.Size = New-Object System.Drawing.Size(90, 24)
$btnAddTrade.FlatStyle = "Flat"
$tradesTop.Controls.Add($btnAddTrade)

$btnDelTrade = New-Object System.Windows.Forms.Button
$btnDelTrade.Text = "Delete Row"
$btnDelTrade.Location = New-Object System.Drawing.Point(114, 28)
$btnDelTrade.Size = New-Object System.Drawing.Size(90, 24)
$btnDelTrade.FlatStyle = "Flat"
$tradesTop.Controls.Add($btnDelTrade)

$btnSaveTrades = New-Object System.Windows.Forms.Button
$btnSaveTrades.Text = "Save Trades"
$btnSaveTrades.Location = New-Object System.Drawing.Point(212, 28)
$btnSaveTrades.Size = New-Object System.Drawing.Size(100, 24)
$btnSaveTrades.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnSaveTrades.BackColor = $ColMid; $btnSaveTrades.ForeColor = $ColWhite; $btnSaveTrades.FlatStyle = "Flat"
$tradesTop.Controls.Add($btnSaveTrades)

$btnRecalc = New-Object System.Windows.Forms.Button
$btnRecalc.Text = "Recalculate"
$btnRecalc.Location = New-Object System.Drawing.Point(320, 28)
$btnRecalc.Size = New-Object System.Drawing.Size(100, 24)
$btnRecalc.FlatStyle = "Flat"
$tradesTop.Controls.Add($btnRecalc)

# Scorecard panel (right side)
$scorePanel = New-Object System.Windows.Forms.Panel
$scorePanel.Dock = "Right"; $scorePanel.Width = 240; $scorePanel.BackColor = $ColAltRow
$tabTrades.Controls.Add($scorePanel)

$lblScore = New-Object System.Windows.Forms.Label
$lblScore.Dock = "Fill"
$lblScore.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$lblScore.Padding = New-Object System.Windows.Forms.Padding(12,12,8,8)
$lblScore.Text = "ALGORITHM SCORECARD`r`n`r`n(no trades yet)"
$scorePanel.Controls.Add($lblScore)

# Totals panel (bottom)
$totalsPanel = New-Object System.Windows.Forms.Panel
$totalsPanel.Dock = "Bottom"; $totalsPanel.Height = 36; $totalsPanel.BackColor = $ColYellow
$tabTrades.Controls.Add($totalsPanel)

$lblTotInv = New-Object System.Windows.Forms.Label
$lblTotInv.Text = "Total Invested:  `$0.00"
$lblTotInv.Location = New-Object System.Drawing.Point(16, 9)
$lblTotInv.Size = New-Object System.Drawing.Size(240, 20)
$lblTotInv.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$totalsPanel.Controls.Add($lblTotInv)

$lblTotVal = New-Object System.Windows.Forms.Label
$lblTotVal.Text = "Current Value:  `$0.00"
$lblTotVal.Location = New-Object System.Drawing.Point(272, 9)
$lblTotVal.Size = New-Object System.Drawing.Size(240, 20)
$lblTotVal.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$totalsPanel.Controls.Add($lblTotVal)

$lblTotPL = New-Object System.Windows.Forms.Label
$lblTotPL.Text = "Total P/L:  `$0.00"
$lblTotPL.Location = New-Object System.Drawing.Point(528, 9)
$lblTotPL.Size = New-Object System.Drawing.Size(260, 20)
$lblTotPL.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$totalsPanel.Controls.Add($lblTotPL)

# The trades grid
$tradesGrid = New-Object System.Windows.Forms.DataGridView
$tradesGrid.Dock = "Fill"
$tradesGrid.AllowUserToAddRows = $false
$tradesGrid.AllowUserToDeleteRows = $false
$tradesGrid.SelectionMode = "CellSelect"
$tradesGrid.RowHeadersVisible = $false
$tradesGrid.AutoSizeColumnsMode = "Fill"
$tradesGrid.BackgroundColor = $ColWhite
$tradesGrid.BorderStyle = "None"
$tradesGrid.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tradesGrid.EnableHeadersVisualStyles = $false
$tradesGrid.ColumnHeadersDefaultCellStyle.BackColor = $ColMid
$tradesGrid.ColumnHeadersDefaultCellStyle.ForeColor = $ColWhite
$tradesGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$tradesGrid.ColumnHeadersHeightSizeMode = "DisableResizing"
$tradesGrid.ColumnHeadersHeight = 30

$tradeCols = @(
    @{H="Ticker";     RO=$false},
    @{H="Buy Date";   RO=$false},
    @{H="Buy Price";  RO=$false},
    @{H="Qty";        RO=$false},
    @{H="Investment"; RO=$true},
    @{H="Cur Price";  RO=$true},
    @{H="Cur Value";  RO=$true},
    @{H="_st";        RO=$true},
    @{H="Sell Date";  RO=$false},
    @{H="Sell Price"; RO=$false},
    @{H="P/L $";      RO=$true},
    @{H="P/L %";      RO=$true},
    @{H="Status";     RO=$true},
    @{H="Notes";      RO=$false}
)
foreach ($c in $tradeCols) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $c.H
    $col.ReadOnly = $c.RO
    if (-not $c.RO) { $col.DefaultCellStyle.BackColor = $ColWhite }
    else { $col.DefaultCellStyle.BackColor = $ColAltRow }
    $tradesGrid.Columns.Add($col) | Out-Null
}
$tradesGrid.Columns[7].Visible = $false
$tabTrades.Controls.Add($tradesGrid)
$tradesGrid.BringToFront()

# ---- Trades grid context menu (right-click) ----
$tradesMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh2 = $tradesMenu.Items.Add("Refresh this ticker now")
$miCopy2    = $tradesMenu.Items.Add("Copy ticker to clipboard")
$miYahoo2   = $tradesMenu.Items.Add("View on Yahoo Finance")
$tradesMenu.Items.Add("-") | Out-Null
$miDelTrade = $tradesMenu.Items.Add("Delete this row")

$script:CtxTradeTicker = $null
$script:CtxTradeRowIdx = -1

$tradesGrid.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $tradesGrid.ClearSelection()
        $tradesGrid.Rows[$e.RowIndex].Selected = $true
        $script:CtxTradeRowIdx = $e.RowIndex
        $script:CtxTradeTicker = Get-RowTicker $tradesGrid.Rows[$e.RowIndex]
    }
})
$tradesGrid.ContextMenuStrip = $tradesMenu

$miRefresh2.Add_Click({ CtxAction-RefreshTicker $script:CtxTradeTicker })
$miCopy2.Add_Click({    CtxAction-CopyTicker    $script:CtxTradeTicker })
$miYahoo2.Add_Click({   CtxAction-OpenYahoo     $script:CtxTradeTicker })
$miDelTrade.Add_Click({ CtxAction-DeleteTradeRow $script:CtxTradeRowIdx })

# ============================================================
# TAB 3: COHORTS
# ============================================================
$cohortHelp = New-Object System.Windows.Forms.Panel
$cohortHelp.Dock = "Top"; $cohortHelp.Height = 40; $cohortHelp.BackColor = $ColFilter
$tabCohorts.Controls.Add($cohortHelp)

$lblCohortHelp = New-Object System.Windows.Forms.Label
$lblCohortHelp.Text = "For each price band: the 15 stocks furthest below their 52-week high. Updates after each full screen."
$lblCohortHelp.Location = New-Object System.Drawing.Point(16, 11)
$lblCohortHelp.Size = New-Object System.Drawing.Size(950, 18)
$lblCohortHelp.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$cohortHelp.Controls.Add($lblCohortHelp)

$cohortPanel = New-Object System.Windows.Forms.Panel
$cohortPanel.Dock = "Fill"
$cohortPanel.BackColor = $ColWhite
$cohortPanel.AutoScroll = $true
$tabCohorts.Controls.Add($cohortPanel)
$cohortPanel.BringToFront()

$cohortPanel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($ColWhite)

    $cohorts = Get-CohortData
    if ($cohorts.Count -eq 0 -or -not $script:AllRows -or $script:AllRows.Count -eq 0) {
        $f = New-Object System.Drawing.Font("Segoe UI", 11)
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gray)
        $g.DrawString("No screen data yet. Run a full screen first.", $f, $b, 30, 30)
        $f.Dispose(); $b.Dispose()
        return
    }

    # One horizontal-bar chart per price band, stacked vertically
    $chartW = 900
    $chartH = 320
    $x = 30
    $y = 14
    foreach ($band in @('$10-25', '$25-40', '$40-60')) {
        $rows = $cohorts[$band]
        $title = "$band  -  Top 15 furthest below 52W high"
        Draw-HBarChart $g $x $y $chartW $chartH $title $rows
        $y += $chartH + 24
    }
    $sender.AutoScrollMinSize = New-Object System.Drawing.Size(($chartW + 60), $y)
})

# ============================================================
# TIMERS
# ============================================================
$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 1000
$jobTimer.Add_Tick({ Check-PriceJob; Check-FullJob })
$jobTimer.Start()

$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 60000
$autoTimer.Add_Tick({ if ($chkAuto.Checked) { Start-PriceRefresh -Force } })
$autoTimer.Start()

# ============================================================
# EVENT WIRING
# ============================================================
$btnApply.Add_Click({ Apply-Filters })
$btnRefresh.Add_Click({ Start-PriceRefresh -Force })
$btnExport.Add_Click({ Export-ToExcel })
$btnFullScreen.Add_Click({ Start-FullScreen })

$enterApply = {
    param($s, $e)
    if ($e.KeyCode -eq "Return") { $e.SuppressKeyPress = $true; Apply-Filters }
}
$txtMinPrice.Add_KeyDown($enterApply)
$txtMaxPrice.Add_KeyDown($enterApply)
$txtMinCap.Add_KeyDown($enterApply)
$txtMaxDrop.Add_KeyDown($enterApply)

# When the user picks a different sector, repopulate the industry dropdown
# with industries that exist within that sector. The (All) sector option
# shows every industry. The SuspendFilterEvents flag prevents this from
# firing during Populate-SectorIndustry's own internal rebuilds.
$cmbSector.Add_SelectedIndexChanged({
    if ($script:SuspendFilterEvents) { return }
    Populate-Industries
    Apply-Filters
})
$cmbIndustry.Add_SelectedIndexChanged({
    if ($script:SuspendFilterEvents) { return }
    Apply-Filters
})

$chkTrendUp.Add_CheckedChanged({ Apply-Filters })
$chkAIonly.Add_CheckedChanged({ Apply-Filters })

# Scroll no longer triggers price refresh - that caused rows to "shuffle"
# as partial price data arrived during a scroll. Prices now update only
# via the Refresh button or the 60-second auto-refresh timer.

$btnAddTrade.Add_Click({ $tradesGrid.Rows.Add() | Out-Null })
$btnDelTrade.Add_Click({
    if ($tradesGrid.CurrentRow -and -not $tradesGrid.CurrentRow.IsNewRow) {
        $tradesGrid.Rows.Remove($tradesGrid.CurrentRow)
        Recompute-Trades
    }
})
$btnSaveTrades.Add_Click({ Save-Trades })
$btnRecalc.Add_Click({ Recompute-Trades })
$tradesGrid.Add_CellEndEdit({
    param($s, $e)
    # If the user just edited the Ticker column, auto-fill Buy Date + Buy Price
    if ($e.ColumnIndex -eq 0) {
        AutoFill-TradeRow $e.RowIndex
    }
    Recompute-Trades
    Save-Trades
})

$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabCohorts) { Draw-Cohorts }
})

$form.Add_FormClosing({
    foreach ($j in @($script:PriceJob, $script:FullJob)) {
        if ($j) {
            Stop-Job $j -ErrorAction SilentlyContinue
            Remove-Job $j -Force -ErrorAction SilentlyContinue
        }
    }
    $jobTimer.Stop()
    $autoTimer.Stop()
})

# ============================================================
# INITIAL LOAD + SHOW
# ============================================================
try {
    if (-not (Test-Path $TradesCsv) -and $PythonExe) {
        try { & $PythonExe (Join-Path $ScriptDir "trades_init.py") 2>&1 | Out-Null } catch {}
    }

    Load-Pinned

    if (Load-ScreenData) {
        Load-LivePrices
        Populate-SectorIndustry
        Apply-Filters
        Set-Status "Loaded $($script:AllRows.Count) stocks. Auto-refresh ON."
        Start-PriceRefresh -Force
    } else {
        Set-Status "No screen data yet. Click 'Re-run Full Screen' to build it (25-40 min)."
        if (-not $PythonExe) {
            $lblProgress.Text = "Note: Python not found on PATH - needed for refreshes and full screen."
        }
        # First-launch helper dialog: explain what to do. Easier than expecting
        # the user to spot the status bar text.
        if ($PythonExe) {
            $msg = @"
Welcome to the US Stock Screener.

This is a first-time install with no screened stocks yet.

To build the initial dataset:
  1. Close this dialog
  2. Click the 'Re-run Full Screen (slow)' button at the top
  3. Wait 25-40 minutes while it screens ~7,000 US stocks
     (you can keep using the app, the grid stays empty until done)
  4. When complete, the grid populates and the Sector/Industry
     dropdowns will be available under 'More v'

Your test trades and pinned stocks persist between screen runs.
"@
            [System.Windows.Forms.MessageBox]::Show($msg, "First Launch - Build Screen Data",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    }

    Load-Trades


    # ============================================================
    # v1.3.0 - Build the Analyze tab
    # Dot-sources Analyze-Tab.ps1 (a self-contained module) and lets it
    # add the 4th tab to $tabs. The returned $analyzeApi.AnalyzeTicker
    # scriptblock is what the right-click menu item invokes.
    # ============================================================
    try {
        . (Join-Path $ScriptDir "Analyze-Tab.ps1")
        $pyForAnalyze = if ($PythonExe) { $PythonExe } else { "python" }
        $script:analyzeApi = Add-AnalyzeTab `
            -TabControl $tabs `
            -DataDir    $DataDir `
            -PythonExe  $pyForAnalyze `
            -ScriptDir  $ScriptDir
    }
    catch {
        $script:analyzeApi = $null
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to load Analyze tab:`r`n$($_.Exception.Message)",
            "Stock Screener", "OK", "Warning") | Out-Null
    }

    [void]$form.ShowDialog()
}
catch {
    $errText = "Startup error on line $($_.InvocationInfo.ScriptLineNumber):`r`n$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
    try { $errText | Out-File (Join-Path $ScriptDir "error_log.txt") } catch {}
    try {
        [System.Windows.Forms.MessageBox]::Show($errText, "Stock Screener - Startup Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
        Write-Host $errText -ForegroundColor Red
        Read-Host "Press Enter to exit"
    }
    exit 1
}