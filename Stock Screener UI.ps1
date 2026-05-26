<#
    StockUI.ps1  —  US Stock Screener desktop UI
    -------------------------------------------------
    PowerShell + WinForms. No install needed (ships with Windows).

    What it does:
      - Loads data/screen_data.csv into a sortable grid
      - Live filter controls: price range, market cap, % below 52W high
      - Overlays live prices from data/live_prices.csv
      - Auto-refreshes visible rows' prices every 60s (background job)
      - Manual "Refresh Prices Now" button
      - "Re-run Full Screen" button -> launches screener_full.py in the
        background, shows progress from data/screen_status.txt
      - Arrow-key navigation, status bar, last-updated stamps

    Launch via Launch.bat (double-click).
#>

# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataDir     = Join-Path $ScriptDir "data"
$ScreenCsv   = Join-Path $DataDir "screen_data.csv"
$LiveCsv     = Join-Path $DataDir "live_prices.csv"
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

# State
$script:AllRows      = @()      # full dataset from CSV
$script:LivePrices   = @{}      # ticker -> @{Price; High; PctBelow; UpdatedAt}
$script:PriceJob     = $null
$script:FullJob      = $null
$script:LastDataLoad = $null
$script:LastPriceKick = [datetime]::MinValue   # debounce: when we last started a price refresh
$script:ScrollDebounceSec = 4                  # min seconds between scroll-triggered refreshes

# ------------------------------------------------------------
# Data loading
# ------------------------------------------------------------
function Load-ScreenData {
    if (-not (Test-Path $ScreenCsv)) {
        $script:AllRows = @()
        return $false
    }
    try {
        $script:AllRows = @(Import-Csv $ScreenCsv)
        $script:LastDataLoad = Get-Date
        return $true
    } catch {
        $script:AllRows = @()
        return $false
    }
}

function Load-LivePrices {
    $script:LivePrices = @{}
    if (-not (Test-Path $LiveCsv)) { return }
    try {
        $rows = Import-Csv $LiveCsv
        foreach ($r in $rows) {
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
    if (-not (Test-Path $MetaFile)) { return "No screen data yet — click 'Re-run Full Screen'." }
    try {
        $m = @{}
        foreach ($line in Get-Content $MetaFile) {
            if ($line -match "^(.+?)=(.+)$") { $m[$matches[1]] = $matches[2] }
        }
        return "Screen last run: $($m['last_run'])  |  $($m['passed']) of $($m['total_screened']) passed"
    } catch {
        return "Screen data present."
    }
}

# ------------------------------------------------------------
# Filtering + grid population
# ------------------------------------------------------------
function Apply-Filters {
    if (-not $script:AllRows -or $script:AllRows.Count -eq 0) {
        $grid.Rows.Clear()
        $lblCount.Text = "0 stocks"
        return
    }

    $minP = 0.0;     [double]::TryParse($txtMinPrice.Text, [ref]$minP)  | Out-Null
    $maxP = 999999.0;[double]::TryParse($txtMaxPrice.Text, [ref]$maxP)  | Out-Null
    $minC = 0.0;     [double]::TryParse($txtMinCap.Text,   [ref]$minC)  | Out-Null
    $maxDrop = 100.0;[double]::TryParse($txtMaxDrop.Text,  [ref]$maxDrop)| Out-Null

    $filtered = foreach ($row in $script:AllRows) {
        $p = [double]$row.Price
        $c = [double]$row.MarketCapM
        $d = [double]$row.PctBelow
        if ($p -lt $minP -or $p -gt $maxP) { continue }
        if ($c -lt $minC) { continue }
        if ($d -gt $maxDrop) { continue }
        $row
    }
    $filtered = @($filtered)

    # Repaint grid
    $grid.SuspendLayout()
    $grid.Rows.Clear()
    foreach ($row in $filtered) {
        $tk = $row.Ticker
        $live = $script:LivePrices[$tk]
        $livePrice = if ($live) { $live.Price } else { "" }
        $liveUpd   = if ($live) { $live.UpdatedAt } else { "" }
        $idx = $grid.Rows.Add(
            $tk,
            ("{0:N2}" -f [double]$row.Price),
            $(if ($livePrice -ne "") { "{0:N2}" -f [double]$livePrice } else { "—" }),
            ("{0:N2}" -f [double]$row.High52W),
            ("{0:N1}%" -f [double]$row.PctBelow),
            ("{0:N1}" -f [double]$row.MarketCapM),
            $row.DataFlag,
            $liveUpd
        )
        # Tint deep-drop rows
        if ([double]$row.PctBelow -gt 70) {
            $grid.Rows[$idx].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(252,228,228)
        }
        # If live price diverges from snapshot, tint the live cell
        if ($livePrice -ne "") {
            $delta = [double]$livePrice - [double]$row.Price
            if ([math]::Abs($delta) -ge 0.01) {
                $col = if ($delta -gt 0) { [System.Drawing.Color]::FromArgb(226,239,218) } else { [System.Drawing.Color]::FromArgb(252,228,228) }
                $grid.Rows[$idx].Cells[2].Style.BackColor = $col
            }
        }
    }
    $grid.ResumeLayout()
    $lblCount.Text = "$($filtered.Count) stocks"
}

# ------------------------------------------------------------
# Background: live price refresh
# ------------------------------------------------------------
function Start-PriceRefresh {
    param([switch]$Force)

    if (-not $PythonExe) {
        Set-Status "Python not found — can't refresh live prices."
        return
    }
    # Don't stack jobs
    if ($script:PriceJob -and $script:PriceJob.State -eq "Running") { return }

    # Debounce: unless forced (manual button / timer), don't refire too soon
    if (-not $Force) {
        $since = ([datetime]::Now - $script:LastPriceKick).TotalSeconds
        if ($since -lt $script:ScrollDebounceSec) { return }
    }
    $script:LastPriceKick = [datetime]::Now

    # Which tickers are visible right now?
    $visible = @()
    if ($grid.Rows.Count -gt 0) {
        $firstIdx = $grid.FirstDisplayedScrollingRowIndex
        if ($firstIdx -lt 0) { $firstIdx = 0 }
        $count = $grid.DisplayedRowCount($true)
        $endIdx = [Math]::Min($firstIdx + $count + 5, $grid.Rows.Count - 1)
        for ($i = $firstIdx; $i -le $endIdx; $i++) {
            $t = $grid.Rows[$i].Cells[0].Value
            if ($t) { $visible += [string]$t }
        }
    }
    if ($visible.Count -eq 0) { return }

    Set-Status "Refreshing live prices for $($visible.Count) visible tickers..."

    $argList = @($PriceScript) + $visible
    $script:PriceJob = Start-Job -ScriptBlock {
        param($py, $jobArgs)
        & $py @jobArgs 2>&1
    } -ArgumentList $PythonExe, $argList
}

function Check-PriceJob {
    if ($script:PriceJob -and $script:PriceJob.State -ne "Running") {
        Receive-Job $script:PriceJob | Out-Null
        Remove-Job $script:PriceJob -Force
        $script:PriceJob = $null
        Load-LivePrices
        Apply-Filters
        Set-Status "Live prices updated $(Get-Date -Format 'HH:mm:ss')."
    }
}

# ------------------------------------------------------------
# Background: full re-screen
# ------------------------------------------------------------
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
        "This re-screens ~5,500 US stocks. It takes 25-40 minutes and runs in the background — you can keep using the app. Start now?",
        "Re-run Full Screen",
        [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($confirm -ne "Yes") { return }

    "Starting..." | Set-Content $StatusFile
    $script:FullJob = Start-Job -ScriptBlock {
        param($py, $script)
        & $py $script 2>&1
    } -ArgumentList $PythonExe, $FullScript

    $btnFullScreen.Enabled = $false
    $btnFullScreen.Text = "Full Screen running..."
    $progressBar.Visible = $true
    $progressBar.Style = "Marquee"
    Set-Status "Full screen started — running in background."
}

function Check-FullJob {
    if (-not $script:FullJob) { return }

    # Update progress text from status file
    if (Test-Path $StatusFile) {
        try {
            $s = (Get-Content $StatusFile -Raw).Trim()
            if ($s) {
                $lblProgress.Text = $s
                # Parse "Screening 1234 / 5500" for a real percentage
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
        Apply-Filters
        $lblMeta.Text = Get-MetaInfo
        Set-Status "Full screen finished. Data reloaded."
    }
}

# ------------------------------------------------------------
# Status bar helper
# ------------------------------------------------------------
function Set-Status($msg) {
    $statusLabel.Text = $msg
}

# ------------------------------------------------------------
# Build the window
# ------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "US Stock Screener"
$form.Size = New-Object System.Drawing.Size(1100, 720)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(900, 560)
$form.BackColor = [System.Drawing.Color]::White

# ---- Top: title bar ----
$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 50
$header.BackColor = [System.Drawing.Color]::FromArgb(31,56,100)
$form.Controls.Add($header)

$titleLbl = New-Object System.Windows.Forms.Label
$titleLbl.Text = "  US STOCK SCREENER"
$titleLbl.ForeColor = [System.Drawing.Color]::White
$titleLbl.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$titleLbl.Dock = "Left"
$titleLbl.AutoSize = $true
$titleLbl.TextAlign = "MiddleLeft"
$header.Controls.Add($titleLbl)

$lblMeta = New-Object System.Windows.Forms.Label
$lblMeta.Text = Get-MetaInfo
$lblMeta.ForeColor = [System.Drawing.Color]::FromArgb(210,228,240)
$lblMeta.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblMeta.Dock = "Right"
$lblMeta.AutoSize = $true
$lblMeta.TextAlign = "MiddleRight"
$lblMeta.Padding = New-Object System.Windows.Forms.Padding(0,0,12,0)
$header.Controls.Add($lblMeta)

# ---- Filter bar ----
$filterBar = New-Object System.Windows.Forms.Panel
$filterBar.Dock = "Top"
$filterBar.Height = 88
$filterBar.BackColor = [System.Drawing.Color]::FromArgb(242,245,250)
$form.Controls.Add($filterBar)

function New-FilterLabel($text, $x) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, 12)
    $l.Size = New-Object System.Drawing.Size(110, 18)
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = [System.Drawing.Color]::FromArgb(31,56,100)
    $filterBar.Controls.Add($l)
    return $l
}
function New-FilterBox($x, $val) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, 32)
    $t.Size = New-Object System.Drawing.Size(90, 24)
    $t.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $t.Text = $val
    $filterBar.Controls.Add($t)
    return $t
}

New-FilterLabel "Min Price ($)"  16  | Out-Null
$txtMinPrice = New-FilterBox 16 "10"
New-FilterLabel "Max Price ($)"  120 | Out-Null
$txtMaxPrice = New-FilterBox 120 "60"
New-FilterLabel "Min Mkt Cap (M)" 224 | Out-Null
$txtMinCap = New-FilterBox 224 "500"
New-FilterLabel "Max % Below High" 328 | Out-Null
$txtMaxDrop = New-FilterBox 328 "70"

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Apply Filters"
$btnApply.Location = New-Object System.Drawing.Point(432, 31)
$btnApply.Size = New-Object System.Drawing.Size(104, 26)
$btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(47,84,150)
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.FlatStyle = "Flat"
$filterBar.Controls.Add($btnApply)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = "0 stocks"
$lblCount.Location = New-Object System.Drawing.Point(548, 35)
$lblCount.Size = New-Object System.Drawing.Size(120, 20)
$lblCount.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$filterBar.Controls.Add($lblCount)

# ---- Right-side action buttons on filter bar ----
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh Prices Now"
$btnRefresh.Size = New-Object System.Drawing.Size(140, 26)
$btnRefresh.Location = New-Object System.Drawing.Point(700, 31)
$btnRefresh.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnRefresh.FlatStyle = "Flat"
$filterBar.Controls.Add($btnRefresh)

$btnFullScreen = New-Object System.Windows.Forms.Button
$btnFullScreen.Text = "Re-run Full Screen"
$btnFullScreen.Size = New-Object System.Drawing.Size(150, 26)
$btnFullScreen.Location = New-Object System.Drawing.Point(848, 31)
$btnFullScreen.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnFullScreen.BackColor = [System.Drawing.Color]::FromArgb(197,90,17)
$btnFullScreen.ForeColor = [System.Drawing.Color]::White
$btnFullScreen.FlatStyle = "Flat"
$filterBar.Controls.Add($btnFullScreen)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = "Auto-refresh prices every 60s"
$chkAuto.Location = New-Object System.Drawing.Point(700, 60)
$chkAuto.Size = New-Object System.Drawing.Size(220, 20)
$chkAuto.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$chkAuto.Checked = $true
$filterBar.Controls.Add($chkAuto)

# ---- Progress (hidden until a full screen runs) ----
$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Dock = "Top"
$progressPanel.Height = 30
$progressPanel.BackColor = [System.Drawing.Color]::FromArgb(255,242,204)
$form.Controls.Add($progressPanel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, 5)
$progressBar.Size = New-Object System.Drawing.Size(300, 18)
$progressBar.Visible = $false
$progressPanel.Controls.Add($progressBar)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = ""
$lblProgress.Location = New-Object System.Drawing.Point(328, 7)
$lblProgress.Size = New-Object System.Drawing.Size(700, 18)
$lblProgress.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$progressPanel.Controls.Add($lblProgress)

# ---- The grid ----
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = "None"
$grid.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(47,84,150)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersHeightSizeMode = "DisableResizing"
$grid.ColumnHeadersHeight = 32
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(247,249,252)

$cols = @(
    @{N="Ticker";       W=80},
    @{N="Price (snap)"; W=90},
    @{N="Live Price";   W=90},
    @{N="52W High";     W=90},
    @{N="% Below High"; W=100},
    @{N="Mkt Cap (M)";  W=100},
    @{N="Data Flag";    W=160},
    @{N="Price Updated";W=130}
)
foreach ($c in $cols) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $c.N
    $col.Name = $c.N
    $grid.Columns.Add($col) | Out-Null
}
$form.Controls.Add($grid)
$grid.BringToFront()

# ---- Status bar ----
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Ready."
$statusStrip.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusStrip)

# ------------------------------------------------------------
# Timers
# ------------------------------------------------------------
# Fast poll: check on background jobs every 1s
$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 1000
$jobTimer.Add_Tick({
    Check-PriceJob
    Check-FullJob
})
$jobTimer.Start()

# Slow tick: kick off a price refresh every 60s
$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 60000
$autoTimer.Add_Tick({
    if ($chkAuto.Checked) { Start-PriceRefresh -Force }
})
$autoTimer.Start()

# ------------------------------------------------------------
# Event wiring
# ------------------------------------------------------------
$btnApply.Add_Click({ Apply-Filters })
$btnRefresh.Add_Click({ Start-PriceRefresh -Force })
$btnFullScreen.Add_Click({ Start-FullScreen })

# Enter key in any filter box = apply
$enterApply = {
    param($s, $e)
    if ($e.KeyCode -eq "Return") {
        $e.SuppressKeyPress = $true
        Apply-Filters
    }
}
$txtMinPrice.Add_KeyDown($enterApply)
$txtMaxPrice.Add_KeyDown($enterApply)
$txtMinCap.Add_KeyDown($enterApply)
$txtMaxDrop.Add_KeyDown($enterApply)

# When user scrolls the grid, refresh prices for the newly-visible rows
$grid.Add_Scroll({
    # Light debounce: only if auto is on and no job running
    if ($chkAuto.Checked -and -not ($script:PriceJob -and $script:PriceJob.State -eq "Running")) {
        Start-PriceRefresh
    }
})

# Clean up jobs on close
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

# ------------------------------------------------------------
# Initial load
# ------------------------------------------------------------
if (Load-ScreenData) {
    Load-LivePrices
    Apply-Filters
    Set-Status "Loaded $($script:AllRows.Count) stocks from screen_data.csv. Auto-refresh is ON."
    # Kick an immediate price refresh for the first screenful
    Start-PriceRefresh -Force
} else {
    Set-Status "No screen_data.csv found. Click 'Re-run Full Screen' to build it (takes 25-40 min)."
    if (-not $PythonExe) {
        $lblProgress.Text = "Note: Python not found on PATH — needed for refreshes and full screen."
    }
}

# Go
[void]$form.ShowDialog()
