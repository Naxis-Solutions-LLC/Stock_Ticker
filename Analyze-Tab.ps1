# Analyze-Tab.ps1  --  US Stock Screener v1.3.0
#
# Self-contained module for the "Analyze" tab. Dot-source this from StockUI.ps1
# and call Add-AnalyzeTab once. See StockUI-integration-snippets.txt for the
# two short edits required in StockUI.ps1.
#
# Architecture:
#   - Add-AnalyzeTab builds the tab UI (top bar, chart, side panels, status)
#     and returns an API hashtable containing an AnalyzeTicker scriptblock.
#   - Right-click "Analyze {ticker}" calls $analyzeApi.AnalyzeTicker $ticker.
#   - That launches python stock_detail.py TICKER in the background.
#   - A WinForms timer polls data/detail_status.txt every 750ms; when it sees
#     "Done", it loads the 4 CSVs and repaints.
#   - Period buttons (1M/3M/6M/1Y/YTD) only re-slice the already-loaded
#     history and invalidate the chart -- no re-fetch.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


function Add-AnalyzeTab {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TabControl]$TabControl,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$ScriptDir
    )

    # Shared state. PSCustomObject so closures pick it up by reference.
    $state = [pscustomobject]@{
        Ticker      = ""
        Summary     = $null
        History     = @()
        Analysts    = $null
        Earnings    = @()
        Period      = "1Y"
        ChartPanel  = $null
        VolPanel    = $null
        StatusFile  = Join-Path $DataDir "detail_status.txt"
        SummaryCsv  = Join-Path $DataDir "detail_summary.csv"
        HistoryCsv  = Join-Path $DataDir "detail_history.csv"
        AnalystsCsv = Join-Path $DataDir "detail_analysts.csv"
        EarningsCsv = Join-Path $DataDir "detail_earnings.csv"
        Fetching    = $false
        FetchProc   = $null
        Labels      = @{}
        StatusLabel = $null
        HeaderLabel = $null
        SubLabel    = $null
        QuoteLabel  = $null
        TickerBox   = $null
    }

    # ----------------------------- tab + root layout
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Chart"
    $tab.BackColor = [System.Drawing.Color]::White

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = "Fill"
    $root.ColumnCount = 1
    $root.RowCount = 3
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 60)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 22)))

    # ----------------------------- top bar
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = "Fill"
    $top.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $lblTicker = New-Object System.Windows.Forms.Label
    $lblTicker.Text = "Ticker:"
    $lblTicker.AutoSize = $true
    $lblTicker.Location = New-Object System.Drawing.Point(8, 10)
    $top.Controls.Add($lblTicker)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(56, 6)
    $txt.Width = 90
    $txt.CharacterCasing = "Upper"
    $txt.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
    $top.Controls.Add($txt)
    $state.TickerBox = $txt

    $btnFetch = New-Object System.Windows.Forms.Button
    $btnFetch.Text = "Re-fetch"
    $btnFetch.Location = New-Object System.Drawing.Point(154, 5)
    $btnFetch.Size = New-Object System.Drawing.Size(80, 24)
    $top.Controls.Add($btnFetch)

    $btnFetch.Add_Click({
        $tkr = $state.TickerBox.Text.Trim().ToUpper()
        if ($tkr) { & $script:_Az_AnalyzeTickerFn $tkr }
    }.GetNewClosure())

    $txt.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $tkr = $state.TickerBox.Text.Trim().ToUpper()
            if ($tkr) { & $script:_Az_AnalyzeTickerFn $tkr }
            $e.SuppressKeyPress = $true
        }
    }.GetNewClosure())

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.AutoSize = $false
    $hdr.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $hdr.Location = New-Object System.Drawing.Point(248, 4)
    $hdr.Size = New-Object System.Drawing.Size(700, 24)
    $top.Controls.Add($hdr)
    $state.HeaderLabel = $hdr

    $sub = New-Object System.Windows.Forms.Label
    $sub.AutoSize = $false
    $sub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $sub.ForeColor = [System.Drawing.Color]::DimGray
    $sub.Location = New-Object System.Drawing.Point(248, 28)
    $sub.Size = New-Object System.Drawing.Size(700, 20)
    $top.Controls.Add($sub)
    $state.SubLabel = $sub

    $qt = New-Object System.Windows.Forms.Label
    $qt.AutoSize = $false
    $qt.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Bold)
    $qt.TextAlign = "MiddleRight"
    $qt.Location = New-Object System.Drawing.Point(760, 8)
    $qt.Size = New-Object System.Drawing.Size(280, 28)
    $qt.Anchor = "Top", "Right"
    $top.Controls.Add($qt)
    $state.QuoteLabel = $qt

    $root.Controls.Add($top, 0, 0)

    # ----------------------------- main split (left: chart, right: panels)
    $main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.Dock = "Fill"
    $main.ColumnCount = 2
    $main.RowCount = 1
    [void]$main.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Percent", 100)))
    [void]$main.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Absolute", 410)))

    $left = New-Object System.Windows.Forms.TableLayoutPanel
    $left.Dock = "Fill"
    $left.ColumnCount = 1
    $left.RowCount = 3
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 32)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 100)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 120)))

    # period buttons strip
    $periodStrip = New-Object System.Windows.Forms.Panel
    $periodStrip.Dock = "Fill"

    $btnX = 8
    foreach ($p in @("1M", "3M", "6M", "1Y", "YTD")) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $p
        $b.Tag = $p
        $b.Size = New-Object System.Drawing.Size(48, 24)
        $b.Location = New-Object System.Drawing.Point($btnX, 4)
        $b.FlatStyle = "Flat"
        if ($p -eq "1Y") {
            $b.BackColor = [System.Drawing.Color]::FromArgb(31, 119, 180)
            $b.ForeColor = [System.Drawing.Color]::White
        }
        $b.Add_Click({
            param($sender, $e)
            $state.Period = $sender.Tag
            foreach ($c in $sender.Parent.Controls) {
                if ($c -is [System.Windows.Forms.Button]) {
                    if ($c.Tag -eq $state.Period) {
                        $c.BackColor = [System.Drawing.Color]::FromArgb(31, 119, 180)
                        $c.ForeColor = [System.Drawing.Color]::White
                    }
                    else {
                        $c.BackColor = [System.Drawing.SystemColors]::Control
                        $c.ForeColor = [System.Drawing.SystemColors]::ControlText
                    }
                }
            }
            $state.ChartPanel.Invalidate()
            $state.VolPanel.Invalidate()
        }.GetNewClosure())
        $periodStrip.Controls.Add($b)
        $btnX += 52
    }
    $left.Controls.Add($periodStrip, 0, 0)

    # price chart (owner-drawn)
    $chartPanel = New-Object System.Windows.Forms.Panel
    $chartPanel.Dock = "Fill"
    $chartPanel.BackColor = [System.Drawing.Color]::White
    $state.ChartPanel = $chartPanel
    $chartPanel.Add_Paint({
        param($sender, $e)
        _Az_DrawPriceChart -Graphics $e.Graphics -Bounds $sender.ClientRectangle -State $state
    }.GetNewClosure())
    $chartPanel.Add_Resize({ $state.ChartPanel.Invalidate() }.GetNewClosure())
    $left.Controls.Add($chartPanel, 0, 1)

    # volume chart (owner-drawn)
    $volPanel = New-Object System.Windows.Forms.Panel
    $volPanel.Dock = "Fill"
    $volPanel.BackColor = [System.Drawing.Color]::White
    $state.VolPanel = $volPanel
    $volPanel.Add_Paint({
        param($sender, $e)
        _Az_DrawVolumeChart -Graphics $e.Graphics -Bounds $sender.ClientRectangle -State $state
    }.GetNewClosure())
    $volPanel.Add_Resize({ $state.VolPanel.Invalidate() }.GetNewClosure())
    $left.Controls.Add($volPanel, 0, 2)

    $main.Controls.Add($left, 0, 0)

    # ----------------------------- right column: stacked stat boxes
    $right = New-Object System.Windows.Forms.FlowLayoutPanel
    $right.Dock = "Fill"
    $right.FlowDirection = "TopDown"
    $right.AutoScroll = $true
    $right.WrapContents = $false
    $right.Padding = New-Object System.Windows.Forms.Padding(4)

    $right.Controls.Add((_Az_NewStatBox -Title "Returns" -State $state -Prefix "Ret" -Rows @(
                "1M", "3M", "6M", "YTD", "1Y", "vs 52w High", "vs 52w Low")))

    $right.Controls.Add((_Az_NewStatBox -Title "Key Stats" -State $state -Prefix "Stat" -Rows @(
                "Market Cap", "P/E (TTM)", "Forward P/E", "PEG", "EPS (TTM)",
                "Dividend Yield", "Beta", "Profit Margin", "ROE",
                "Debt/Equity", "Short Float")))

    $right.Controls.Add((_Az_NewStatBox -Title "Analyst View" -State $state -Prefix "Analyst" -Rows @(
                "Target Mean", "  Upside", "Target High", "Target Low",
                "# Analysts", "Recs")))

    $right.Controls.Add((_Az_NewStatBox -Title "Technicals" -State $state -Prefix "Tech" -Rows @(
                "50-day SMA", "200-day SMA", "Px vs SMA50", "Px vs SMA200",
                "RSI(14)", "30d ATR", "30d Avg `$Vol")))

    $right.Controls.Add((_Az_NewStatBox -Title "Next Earnings + Last 4 Surprises" -State $state -Prefix "Earn" -Rows @(
                "Next Date", "EPS Est", "E1", "E2", "E3", "E4")))

    $main.Controls.Add($right, 1, 0)
    $root.Controls.Add($main, 0, 1)

    # ----------------------------- status bar
    $sb = New-Object System.Windows.Forms.Label
    $sb.Dock = "Fill"
    $sb.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $sb.ForeColor = [System.Drawing.Color]::DimGray
    $sb.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 2)
    $sb.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $sb.Text = "Right-click a ticker on the Screen tab, or type one above.  Prices may be delayed/approximate - not investment advice."
    $state.StatusLabel = $sb
    $root.Controls.Add($sb, 0, 2)

    $tab.Controls.Add($root)
    $TabControl.TabPages.Add($tab)

    # ----------------------------- status-polling timer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 750
    $timer.Add_Tick({
            if (-not $state.Fetching) { return }
            if (Test-Path $state.StatusFile) {
                $line = Get-Content $state.StatusFile -Tail 1 -ErrorAction SilentlyContinue
                if ($line) {
                    $state.StatusLabel.Text = "Fetching $($state.Ticker)... $line"
                    if ($line -match "Done") {
                        $state.Fetching = $false
                        _Az_LoadDetailData -State $state
                        $state.StatusLabel.Text = "$($state.Ticker) loaded at $(Get-Date -Format 'HH:mm:ss')"
                    }
                    elseif ($line -match "Error") {
                        $state.Fetching = $false
                        # v1.3.1: surface the actual Python error in the status bar.
                        # Strip Python's "HH:MM:SS " timestamp prefix so it reads cleaner.
                        $cleanLine = $line -replace '^\d{2}:\d{2}:\d{2}\s+', ''
                        $state.StatusLabel.Text = "$($state.Ticker): $cleanLine"
                    }
                }
            }
            # fallback: detect process exit if status file lagged
            if ($state.FetchProc -and $state.FetchProc.HasExited -and $state.Fetching) {
                $state.Fetching = $false
                if (Test-Path $state.SummaryCsv) {
                    _Az_LoadDetailData -State $state
                    $state.StatusLabel.Text = "$($state.Ticker) loaded"
                }
                else {
                    $state.StatusLabel.Text = "Fetch failed -- no data written"
                }
            }
        }.GetNewClosure())
    $timer.Start()

    # ----------------------------- the function the host calls
    $script:_Az_AnalyzeTickerFn = {
        param([string]$Ticker)
        $Ticker = $Ticker.Trim().ToUpper()
        if (-not $Ticker) { return }
        $state.Ticker = $Ticker
        $state.TickerBox.Text = $Ticker
        $state.HeaderLabel.Text = $Ticker
        $state.SubLabel.Text = "Fetching..."
        $state.QuoteLabel.Text = ""
        $state.StatusLabel.Text = "Launching python stock_detail.py $Ticker..."
        $TabControl.SelectedTab = $tab

        # Remove old status so we don't react to a stale "Done"
        if (Test-Path $state.StatusFile) {
            try { Remove-Item $state.StatusFile -Force -ErrorAction SilentlyContinue } catch {}
        }

        $scriptPath = Join-Path $ScriptDir "stock_detail.py"
        if (-not (Test-Path $scriptPath)) {
            $state.StatusLabel.Text = "stock_detail.py not found at $scriptPath"
            [System.Windows.Forms.MessageBox]::Show(
                "stock_detail.py not found at:`n$scriptPath",
                "Analyze", "OK", "Error") | Out-Null
            return
        }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $PythonExe
            $psi.Arguments = "`"$scriptPath`" $Ticker"
            $psi.WorkingDirectory = $ScriptDir
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $state.FetchProc = [System.Diagnostics.Process]::Start($psi)
            $state.Fetching = $true
        }
        catch {
            $state.StatusLabel.Text = "Failed to start python: $_"
        }
    }.GetNewClosure()

    return @{
        Tab           = $tab
        AnalyzeTicker = $script:_Az_AnalyzeTickerFn
    }
}


# ============================================================
#   Helpers below (script-scope, available to host after dot-sourcing)
# ============================================================

function _Az_NewStatBox {
    param([string]$Title, [string[]]$Rows, $State, [string]$Prefix)
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = $Title
    $gb.Width = 395
    $gb.Height = ($Rows.Count * 20) + 26
    $gb.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $gb.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 6)

    $y = 18
    foreach ($r in $Rows) {
        $key = New-Object System.Windows.Forms.Label
        $key.Text = $r
        $key.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
        $key.Location = New-Object System.Drawing.Point(10, $y)
        $key.Size = New-Object System.Drawing.Size(150, 18)
        $gb.Controls.Add($key)

        $val = New-Object System.Windows.Forms.Label
        $val.Text = "-"
        $val.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
        $val.Location = New-Object System.Drawing.Point(165, $y)
        $val.Size = New-Object System.Drawing.Size(220, 18)
        $gb.Controls.Add($val)

        $State.Labels["$Prefix|$r"] = $val
        $y += 20
    }
    return $gb
}

function _Az_LoadDetailData {
    param($State)
    try {
        if (Test-Path $State.SummaryCsv) {
            $State.Summary = Import-Csv $State.SummaryCsv | Select-Object -First 1
        }
        if (Test-Path $State.HistoryCsv) {
            $State.History = @(Import-Csv $State.HistoryCsv)
        }
        if (Test-Path $State.AnalystsCsv) {
            $State.Analysts = Import-Csv $State.AnalystsCsv | Select-Object -First 1
        }
        if (Test-Path $State.EarningsCsv) {
            $State.Earnings = @(Import-Csv $State.EarningsCsv)
        }
    }
    catch {
        $State.StatusLabel.Text = "Load error: $_"
        return
    }
    _Az_RenderDetail -State $State
}

function _Az_RenderDetail {
    param($State)
    $s = $State.Summary
    if (-not $s) { return }

    $State.HeaderLabel.Text = "$($s.Ticker) -- $($s.Name)"
    $sect = $s.Sector
    if ($s.Industry) { $sect += " / $($s.Industry)" }
    $State.SubLabel.Text = "$sect -- as of $($s.DayAsOf)"

    $chg = 0.0; try { $chg = [double]$s.DayChange } catch {}
    $arrow = if ($chg -ge 0) { [char]0x25B2 } else { [char]0x25BC }
    $sign = if ($chg -ge 0) { "+" } else { "" }
    $State.QuoteLabel.Text = "`$$($s.CurrentPrice)  $arrow $sign$($s.DayChange)  ($sign$($s.DayChangePct)%)"
    $State.QuoteLabel.ForeColor = if ($chg -ge 0) {
        [System.Drawing.Color]::FromArgb(0, 128, 0)
    }
    else {
        [System.Drawing.Color]::FromArgb(192, 0, 0)
    }

    # Returns
    $State.Labels["Ret|1M"].Text = _Az_FmtPct $s.Ret1M
    $State.Labels["Ret|3M"].Text = _Az_FmtPct $s.Ret3M
    $State.Labels["Ret|6M"].Text = _Az_FmtPct $s.Ret6M
    $State.Labels["Ret|YTD"].Text = _Az_FmtPct $s.RetYTD
    $State.Labels["Ret|1Y"].Text = _Az_FmtPct $s.Ret1Y
    $State.Labels["Ret|vs 52w High"].Text = "$(_Az_FmtPct $s.PctFrom52wHigh)  ($(_Az_FmtPx $s.Px52wHigh))"
    $State.Labels["Ret|vs 52w Low"].Text = "$(_Az_FmtPct $s.PctFrom52wLow)  ($(_Az_FmtPx $s.Px52wLow))"

    foreach ($k in @("1M", "3M", "6M", "YTD", "1Y")) {
        $v = $s."Ret$k"
        if ($v) {
            try {
                $f = [double]$v
                $State.Labels["Ret|$k"].ForeColor = if ($f -ge 0) {
                    [System.Drawing.Color]::FromArgb(0, 128, 0)
                }
                else {
                    [System.Drawing.Color]::FromArgb(192, 0, 0)
                }
            }
            catch {}
        }
    }

    # Key Stats
    $State.Labels["Stat|Market Cap"].Text = _Az_FmtLarge $s.MarketCap
    $State.Labels["Stat|P/E (TTM)"].Text = _Az_FmtNum $s.PERatio 2
    $State.Labels["Stat|Forward P/E"].Text = _Az_FmtNum $s.ForwardPE 2
    $State.Labels["Stat|PEG"].Text = _Az_FmtNum $s.PEG 2
    $State.Labels["Stat|EPS (TTM)"].Text = if ($s.EPS) { "`$" + [math]::Round([double]$s.EPS, 2) } else { "-" }
    $State.Labels["Stat|Dividend Yield"].Text = if ($s.DividendYieldPct) { "$($s.DividendYieldPct)%" } else { "-" }
    $State.Labels["Stat|Beta"].Text = _Az_FmtNum $s.Beta 2
    $State.Labels["Stat|Profit Margin"].Text = if ($s.ProfitMarginPct) { "$($s.ProfitMarginPct)%" } else { "-" }
    $State.Labels["Stat|ROE"].Text = if ($s.ROEPct) { "$($s.ROEPct)%" } else { "-" }
    $State.Labels["Stat|Debt/Equity"].Text = _Az_FmtNum $s.DebtEquity 2
    $State.Labels["Stat|Short Float"].Text = if ($s.ShortFloatPct) { "$($s.ShortFloatPct)%" } else { "-" }

    # Analyst View
    $a = $State.Analysts
    if ($a) {
        $State.Labels["Analyst|Target Mean"].Text = _Az_FmtPx $a.TargetMean
        $State.Labels["Analyst|  Upside"].Text = _Az_FmtPct $a.UpsideMeanPct
        $State.Labels["Analyst|Target High"].Text = _Az_FmtPx $a.TargetHigh
        $State.Labels["Analyst|Target Low"].Text = _Az_FmtPx $a.TargetLow
        $State.Labels["Analyst|# Analysts"].Text = if ($a.NumAnalysts) { $a.NumAnalysts } else { "-" }
        if ($a.StrongBuy -or $a.Buy -or $a.Hold -or $a.Sell -or $a.StrongSell) {
            $State.Labels["Analyst|Recs"].Text = "$($a.StrongBuy)SB / $($a.Buy)B / $($a.Hold)H / $($a.Sell)S / $($a.StrongSell)SS"
        }
        else {
            $State.Labels["Analyst|Recs"].Text = "-"
        }
    }

    # Technicals
    $State.Labels["Tech|50-day SMA"].Text = _Az_FmtPx $s.SMA50
    $State.Labels["Tech|200-day SMA"].Text = _Az_FmtPx $s.SMA200
    $State.Labels["Tech|Px vs SMA50"].Text = _Az_FmtPct $s.PxVsSMA50Pct
    $State.Labels["Tech|Px vs SMA200"].Text = _Az_FmtPct $s.PxVsSMA200Pct
    if ($s.RSI14) {
        try {
            $f = [double]$s.RSI14
            $hint = if ($f -ge 70) { " (overbought)" }
            elseif ($f -le 30) { " (oversold)" }
            else { " (neutral)" }
            $State.Labels["Tech|RSI(14)"].Text = "$($s.RSI14)$hint"
        }
        catch { $State.Labels["Tech|RSI(14)"].Text = $s.RSI14 }
    }
    else { $State.Labels["Tech|RSI(14)"].Text = "-" }
    $State.Labels["Tech|30d ATR"].Text = if ($s.ATR30) { "`$" + [math]::Round([double]$s.ATR30, 2) } else { "-" }
    $State.Labels["Tech|30d Avg `$Vol"].Text = _Az_FmtLarge $s.AvgDollarVol30

    # Earnings
    $e = $State.Earnings
    if ($e -and $e.Count -gt 0) {
        $State.Labels["Earn|Next Date"].Text = $e[0].DateOrLabel
        $State.Labels["Earn|EPS Est"].Text = if ($e[0].EpsEstimate) { "`$$($e[0].EpsEstimate)" } else { "-" }
        for ($i = 1; $i -le 4; $i++) {
            $key = "E$i"
            if ($i -lt $e.Count) {
                $row = $e[$i]
                $surp = if ($row.SurprisePct) { _Az_FmtPct $row.SurprisePct } else { "-" }
                $State.Labels["Earn|$key"].Text = "$($row.DateOrLabel): est `$$($row.EpsEstimate), act `$$($row.EpsActual)  $surp"
            }
            else {
                $State.Labels["Earn|$key"].Text = "-"
            }
        }
    }

    $State.ChartPanel.Invalidate()
    $State.VolPanel.Invalidate()
}

function _Az_FmtPct {
    param($v)
    if (-not $v) { return "-" }
    try {
        $f = [double]$v
        $sign = if ($f -ge 0) { "+" } else { "" }
        return "$sign$f%"
    }
    catch { return "-" }
}

function _Az_FmtPx {
    param($v)
    if ($v) { return "`$$v" } else { return "-" }
}

function _Az_FmtNum {
    param($v, [int]$dp = 2)
    if (-not $v) { return "-" }
    try { return [string][math]::Round([double]$v, $dp) }
    catch { return "-" }
}

function _Az_FmtLarge {
    param($v)
    if (-not $v) { return "-" }
    try { $n = [double]$v } catch { return $v }
    if ($n -ge 1e12) { return "`$" + [math]::Round($n / 1e12, 2) + "T" }
    if ($n -ge 1e9)  { return "`$" + [math]::Round($n / 1e9, 2) + "B" }
    if ($n -ge 1e6)  { return "`$" + [math]::Round($n / 1e6, 2) + "M" }
    if ($n -ge 1e3)  { return "`$" + [math]::Round($n / 1e3, 2) + "K" }
    return "`$$n"
}

function _Az_GetPeriodSlice {
    param($History, [string]$Period)
    if (-not $History -or $History.Count -eq 0) { return @() }
    switch ($Period) {
        "1M" { return @($History | Select-Object -Last 21) }
        "3M" { return @($History | Select-Object -Last 63) }
        "6M" { return @($History | Select-Object -Last 126) }
        "1Y" { return $History }
        "YTD" {
            $year = (Get-Date).Year
            return @($History | Where-Object {
                    try { ([datetime]$_.Date).Year -eq $year } catch { $false }
                })
        }
    }
    return $History
}

# True only if the value parses as a finite number. Guards against "nan"/""/null
# in history rows (thinly-traded names can have NaN OHLC on no-trade days), which
# would otherwise crash [double] casts in the chart drawing.
function _Az_IsNum($v) {
    $d = 0.0
    return [double]::TryParse([string]$v, [ref]$d)
}

function _Az_DrawPriceChart {
    param([System.Drawing.Graphics]$Graphics,
        [System.Drawing.Rectangle]$Bounds,
        $State)

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.Clear([System.Drawing.Color]::White)

    $rows = _Az_GetPeriodSlice -History $State.History -Period $State.Period
    if (-not $rows -or $rows.Count -lt 2) {
        $f = New-Object System.Drawing.Font("Segoe UI", 10)
        $Graphics.DrawString("(no data -- analyze a ticker to begin)",
            $f, [System.Drawing.Brushes]::DimGray, 20, 20)
        $f.Dispose()
        return
    }

    # Drop rows with non-numeric OHLC (e.g. "nan" on no-trade days) so a stray
    # value can never crash the chart.
    $rows = @($rows | Where-Object {
        (_Az_IsNum $_.Open) -and (_Az_IsNum $_.High) -and (_Az_IsNum $_.Low) -and (_Az_IsNum $_.Close)
    })
    if ($rows.Count -lt 2) {
        $f = New-Object System.Drawing.Font("Segoe UI", 10)
        $Graphics.DrawString("(no chartable price data for this period)",
            $f, [System.Drawing.Brushes]::DimGray, 20, 20)
        $f.Dispose()
        return
    }

    $padL = 56; $padR = 12; $padT = 12; $padB = 26
    $w = $Bounds.Width - $padL - $padR
    $h = $Bounds.Height - $padT - $padB
    if ($w -lt 50 -or $h -lt 50) { return }

    $lows = $rows | ForEach-Object { [double]$_.Low }
    $highs = $rows | ForEach-Object { [double]$_.High }
    $yMin = ($lows | Measure-Object -Minimum).Minimum
    $yMax = ($highs | Measure-Object -Maximum).Maximum
    $yRange = $yMax - $yMin
    if ($yRange -le 0) { $yRange = [math]::Max($yMax * 0.02, 1.0) }
    $yMin -= $yRange * 0.03
    $yMax += $yRange * 0.03
    $yRange = $yMax - $yMin

    # GDI pens/brushes/fonts are native handles; dispose them on every paint
    # (this panel repaints on resize, tab switch, and each period-button click)
    # so a long Analyze session doesn't leak handles. [Drawing.Brushes]::* are
    # shared singletons and are deliberately NOT disposed.
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(230, 230, 230))
    $axisPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 180, 180))
    $labelF = New-Object System.Drawing.Font("Segoe UI", 8)
    $labelB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 110, 110))
    try {

    for ($i = 0; $i -le 5; $i++) {
        $py = $padT + ($h * $i / 5.0)
        $price = $yMax - ($yRange * $i / 5.0)
        $Graphics.DrawLine($gridPen, $padL, $py, $padL + $w, $py)
        $Graphics.DrawString(("`${0:F2}" -f $price), $labelF, $labelB, 2, $py - 7)
    }
    $Graphics.DrawLine($axisPen, $padL, $padT, $padL, $padT + $h)
    $Graphics.DrawLine($axisPen, $padL, $padT + $h, $padL + $w, $padT + $h)

    $nRows = $rows.Count
    for ($i = 0; $i -lt 5; $i++) {
        $idx = [int][math]::Floor($i * ($nRows - 1) / 4.0)
        if ($nRows -eq 1) { $idx = 0 }
        $px = $padL + ($w * $idx / [double][math]::Max(1, $nRows - 1))
        $Graphics.DrawString($rows[$idx].Date, $labelF, $labelB, $px - 28, $padT + $h + 4)
    }

    # build pixel coords once
    $XAt = { param([int]$i) $padL + ($w * $i / [double][math]::Max(1, $nRows - 1)) }
    $YAt = { param([double]$v) $padT + ($h * ($yMax - $v) / $yRange) }

    # close line
    $closePen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(31, 119, 180), 2.0)
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt $nRows; $i++) {
        $c = [double]$rows[$i].Close
        $pts.Add((New-Object System.Drawing.PointF(
                    ([float](& $XAt $i)), ([float](& $YAt $c)))))
    }
    if ($pts.Count -ge 2) { $Graphics.DrawLines($closePen, $pts.ToArray()) }

    # SMA50
    $sma50Pen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(255, 140, 0), 1.5)
    $sma50Pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt $nRows; $i++) {
        if (_Az_IsNum $rows[$i].SMA50) {
            $v = [double]$rows[$i].SMA50
            $sma50Pts.Add((New-Object System.Drawing.PointF(
                        ([float](& $XAt $i)), ([float](& $YAt $v)))))
        }
    }
    if ($sma50Pts.Count -ge 2) { $Graphics.DrawLines($sma50Pen, $sma50Pts.ToArray()) }

    # SMA200
    $sma200Pen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(204, 0, 0), 1.5)
    $sma200Pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt $nRows; $i++) {
        if (_Az_IsNum $rows[$i].SMA200) {
            $v = [double]$rows[$i].SMA200
            $sma200Pts.Add((New-Object System.Drawing.PointF(
                        ([float](& $XAt $i)), ([float](& $YAt $v)))))
        }
    }
    if ($sma200Pts.Count -ge 2) { $Graphics.DrawLines($sma200Pen, $sma200Pts.ToArray()) }

    # legend
    $legendF = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $lx = $padL + 8; $ly = $padT + 4
    $lbClose  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(31, 119, 180))
    $lbSma50  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 140, 0))
    $lbSma200 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(204, 0, 0))
    $Graphics.FillRectangle($lbClose, $lx, $ly + 3, 14, 3)
    $Graphics.DrawString("Close", $legendF, [System.Drawing.Brushes]::Black, $lx + 18, $ly - 2)
    $Graphics.FillRectangle($lbSma50, $lx + 70, $ly + 3, 14, 3)
    $Graphics.DrawString("SMA50", $legendF, [System.Drawing.Brushes]::Black, $lx + 88, $ly - 2)
    $Graphics.FillRectangle($lbSma200, $lx + 145, $ly + 3, 14, 3)
    $Graphics.DrawString("SMA200", $legendF, [System.Drawing.Brushes]::Black, $lx + 163, $ly - 2)
    } finally {
        foreach ($d in @($gridPen, $axisPen, $labelF, $labelB, $closePen,
                          $sma50Pen, $sma200Pen, $legendF, $lbClose, $lbSma50, $lbSma200)) {
            if ($d) { $d.Dispose() }
        }
    }
}

function _Az_DrawVolumeChart {
    param([System.Drawing.Graphics]$Graphics,
        [System.Drawing.Rectangle]$Bounds,
        $State)

    $Graphics.Clear([System.Drawing.Color]::White)
    $rows = _Az_GetPeriodSlice -History $State.History -Period $State.Period
    if (-not $rows -or $rows.Count -lt 2) { return }
    $rows = @($rows | Where-Object { _Az_IsNum $_.Volume })
    if ($rows.Count -lt 2) { return }

    $padL = 56; $padR = 12; $padT = 8; $padB = 18
    $w = $Bounds.Width - $padL - $padR
    $h = $Bounds.Height - $padT - $padB
    if ($w -lt 50 -or $h -lt 30) { return }

    $vols = $rows | ForEach-Object { [double]$_.Volume }
    $vMax = ($vols | Measure-Object -Maximum).Maximum
    if (-not $vMax -or $vMax -eq 0) { return }

    $axisPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 180, 180))
    try {
    $Graphics.DrawLine($axisPen, $padL, $padT, $padL, $padT + $h)
    $Graphics.DrawLine($axisPen, $padL, $padT + $h, $padL + $w, $padT + $h)

    $labelF = New-Object System.Drawing.Font("Segoe UI", 8)
    $labelB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 110, 110))
    $Graphics.DrawString("Vol", $labelF, $labelB, 4, $padT)
    $vMaxLbl = if ($vMax -ge 1e9) { ([math]::Round($vMax / 1e9, 1)).ToString() + "B" }
    elseif ($vMax -ge 1e6) { ([math]::Round($vMax / 1e6, 1)).ToString() + "M" }
    elseif ($vMax -ge 1e3) { ([math]::Round($vMax / 1e3, 1)).ToString() + "K" }
    else { [string]$vMax }
    $Graphics.DrawString($vMaxLbl, $labelF, $labelB, 4, $padT + 14)

    $nRows = $rows.Count
    $barW = [math]::Max(1.0, ($w / [double]$nRows) - 1)
    $volBrush = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(160, 31, 119, 180))

    for ($i = 0; $i -lt $nRows; $i++) {
        $v = [double]$rows[$i].Volume
        if ($v -le 0) { continue }
        $barH = $h * $v / $vMax
        $bx = $padL + ($w * $i / [double]$nRows)
        $by = $padT + $h - $barH
        $Graphics.FillRectangle($volBrush, [float]$bx, [float]$by, [float]$barW, [float]$barH)
    }
    } finally {
        foreach ($d in @($axisPen, $labelF, $labelB, $volBrush)) {
            if ($d) { $d.Dispose() }
        }
    }
}
