# AnalysisTab.ps1  --  Claude-powered "Analysis" tab for the US Stock Screener.
#
# Drop-in module. Dot-source it from StockUI.ps1 and call Add-AnalysisTab once,
# the same way Analyze-Tab.ps1 is wired in. It adds a 4th-or-later tab and never
# changes existing screener / live-price / detail behavior.
#
#   . (Join-Path $ScriptDir "AnalysisTab.ps1")
#   $script:analysisApi = Add-AnalysisTab -TabControl $tabs -DataDir $DataDir `
#                            -PythonExe $pyForAnalyze -ScriptDir $ScriptDir
#
# $analysisApi.AnalyzeTicker is a scriptblock { param($Ticker) } the right-click
# menu (or anything else) can call to analyze a ticker. See INTEGRATION_GUIDE.md.
#
# The heavy work (the Claude API call) runs in a background job so the UI stays
# responsive; a WinForms timer polls the job and renders the result when it lands.
#
# NOTE: this file is intentionally pure ASCII - Windows PowerShell 5.1 reads .ps1
# as ANSI, so any non-ASCII character (em dash, smart quote) breaks the parser.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


function Get-AnalysisTroubleshooting {
    return @"
Troubleshooting:
  - 'ANTHROPIC_API_KEY is not set': set the environment variable, then fully
    restart the app (close the launching console too). See INTEGRATION_GUIDE.md.
  - 'anthropic package is not installed': run  pip install anthropic
  - Authentication failed: the key is wrong or revoked - create a new one at
    console.anthropic.com and set ANTHROPIC_API_KEY to it.
  - Network error: check your internet connection, VPN, or firewall.
"@
}


function Add-AnalysisTab {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TabControl]$TabControl,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$ScriptDir
    )

    # Shared state - PSCustomObject so closures capture it by reference.
    $state = [pscustomobject]@{
        Ticker      = ""
        Job         = $null
        Timer       = $null
        OutFile     = (Join-Path $DataDir "claude_analysis.json")
        Script      = (Join-Path $ScriptDir "claude_analysis.py")
        PythonExe   = $PythonExe
        ResultsBox  = $null
        StatusLabel = $null
        TickerBox   = $null
        AnalyzeBtn  = $null
        CopyBtn     = $null
    }

    # ----------------------------- tab + top bar
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "AI Research"
    $tab.BackColor = [System.Drawing.Color]::White

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = "Top"; $top.Height = 76
    $top.BackColor = [System.Drawing.Color]::FromArgb(242, 245, 250)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Ticker:"; $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point(12, 14)
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $top.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(64, 11)
    $txt.Width = 90
    $txt.CharacterCasing = "Upper"
    $txt.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
    $top.Controls.Add($txt)
    $state.TickerBox = $txt

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Analyze"
    $btn.Location = New-Object System.Drawing.Point(164, 9)
    $btn.Size = New-Object System.Drawing.Size(90, 26)
    $btn.FlatStyle = "Flat"
    $btn.BackColor = [System.Drawing.Color]::FromArgb(47, 84, 150)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $top.Controls.Add($btn)
    $state.AnalyzeBtn = $btn

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy"
    $btnCopy.Location = New-Object System.Drawing.Point(262, 9)
    $btnCopy.Size = New-Object System.Drawing.Size(70, 26)
    $btnCopy.FlatStyle = "Flat"
    $top.Controls.Add($btnCopy)
    $state.CopyBtn = $btnCopy

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Qualitative, AI-generated research. Not investment advice. Verify facts before acting."
    $lblHint.AutoSize = $true
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblHint.Location = New-Object System.Drawing.Point(12, 46)
    $top.Controls.Add($lblHint)

    # ----------------------------- status bar (bottom)
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = "Bottom"; $status.Height = 22
    $status.TextAlign = "MiddleLeft"
    $status.BackColor = [System.Drawing.Color]::FromArgb(242, 245, 250)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $status.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $status.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    $status.Text = "Enter a ticker and click Analyze."
    $state.StatusLabel = $status

    # ----------------------------- results area (scrollable, read-only)
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock = "Fill"
    $rtb.ReadOnly = $true
    $rtb.BackColor = [System.Drawing.Color]::White
    $rtb.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $rtb.BorderStyle = "None"
    $rtb.WordWrap = $true
    $rtb.DetectUrls = $false
    $rtb.Multiline = $true
    $rtb.ScrollBars = "Vertical"
    $state.ResultsBox = $rtb

    # Add Fill first, then the docked edges, so the layout resolves correctly.
    $tab.Controls.Add($rtb)
    $tab.Controls.Add($top)
    $tab.Controls.Add($status)
    [void]$TabControl.TabPages.Add($tab)

    # ----------------------------- render helpers (RichTextBox section formatting)
    $appendHeader = {
        param($text)
        $b = $state.ResultsBox
        $b.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
        $b.SelectionColor = [System.Drawing.Color]::FromArgb(31, 56, 100)
        $b.AppendText([string]$text + "`r`n`r`n")
    }.GetNewClosure()

    $appendSection = {
        param($title, $body)
        $b = $state.ResultsBox
        $b.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $b.SelectionColor = [System.Drawing.Color]::FromArgb(47, 84, 150)
        $b.AppendText([string]$title + "`r`n")
        $b.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
        $b.SelectionColor = [System.Drawing.Color]::Black
        $text = [string]$body
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "(not provided)" }
        $b.AppendText($text + "`r`n`r`n")
    }.GetNewClosure()

    $appendSectionList = {
        param($title, $items)
        $b = $state.ResultsBox
        $b.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $b.SelectionColor = [System.Drawing.Color]::FromArgb(47, 84, 150)
        $b.AppendText([string]$title + "`r`n")
        $b.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
        $b.SelectionColor = [System.Drawing.Color]::Black
        $arr = @($items)
        if ($arr.Count -eq 0) {
            $b.AppendText("(not provided)`r`n`r`n")
        } else {
            foreach ($it in $arr) { $b.AppendText("  - " + [string]$it + "`r`n") }
            $b.AppendText("`r`n")
        }
    }.GetNewClosure()

    $appendBody = {
        param($text)
        $b = $state.ResultsBox
        $b.SelectionFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
        $b.SelectionColor = [System.Drawing.Color]::DimGray
        $b.AppendText([string]$text + "`r`n`r`n")
    }.GetNewClosure()

    # ----------------------------- render the finished result
    $renderResult = {
        param($jobOut)
        $b = $state.ResultsBox
        $b.Clear()

        $data = $null
        if (Test-Path $state.OutFile) {
            try { $data = (Get-Content $state.OutFile -Raw) | ConvertFrom-Json }
            catch { $data = $null }
        }

        if (-not $data) {
            $state.StatusLabel.Text = "Analysis failed."
            & $appendSection "Error" "Could not read the analysis output file."
            if ($jobOut) { & $appendBody ("Details:`r`n" + [string]$jobOut) }
            & $appendBody (Get-AnalysisTroubleshooting)
            return
        }

        if ($data.PSObject.Properties['error'] -and $data.error) {
            $state.StatusLabel.Text = "Analysis failed."
            & $appendSection "Error" ([string]$data.message)
            if ($data.PSObject.Properties['hint'] -and $data.hint) {
                & $appendBody ([string]$data.hint)
            }
            & $appendBody (Get-AnalysisTroubleshooting)
            if ($data.PSObject.Properties['raw'] -and $data.raw) {
                & $appendSection "Raw response (debug)" ([string]$data.raw)
            }
            return
        }

        & $appendHeader ("" + $state.Ticker + " - Qualitative Analysis")
        & $appendSection     "Investment Thesis"     $data.investment_thesis
        & $appendSectionList "Fundamental Strengths"  $data.fundamental_strengths
        & $appendSectionList "Key Risks"              $data.key_risks
        & $appendSection     "Near-Term Catalysts"    $data.near_term_catalysts
        & $appendSection     "Valuation Narrative"    $data.valuation_narrative
        & $appendSection     "Competitive Position"   $data.competitive_position
        & $appendSection     "Market Sentiment"       $data.market_sentiment

        # Cost transparency (optional): estimate from the token usage Claude returned.
        if ($data.PSObject.Properties['usage'] -and $data.usage) {
            $inTok = 0; $outTok = 0
            try { $inTok = [int]$data.usage.input_tokens } catch { }
            try { $outTok = [int]$data.usage.output_tokens } catch { }
            $mdl = if ($data.PSObject.Properties['model']) { [string]$data.model } else { "" }
            $inRate = 5.0; $outRate = 25.0   # default: Opus-tier ($ per million tokens)
            if ($mdl -like "*sonnet*") { $inRate = 3.0; $outRate = 15.0 }
            elseif ($mdl -like "*haiku*") { $inRate = 1.0; $outRate = 5.0 }
            $cost = ($inTok * $inRate + $outTok * $outRate) / 1000000.0
            & $appendBody ("Approx cost: `$" + ("{0:N3}" -f $cost) + "  (" + $inTok + " in / " + $outTok + " out tokens" + $(if ($mdl) { ", " + $mdl } else { "" }) + ")")
        }

        $b.SelectionStart = 0
        $b.ScrollToCaret()
        $stamp = Get-Date -Format 'HH:mm:ss'
        $state.StatusLabel.Text = "Done $stamp. Qualitative AI research - not investment advice."
    }.GetNewClosure()

    # ----------------------------- poll the background job
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $state.Timer = $timer

    $onTick = {
        if (-not $state.Job) { $state.Timer.Stop(); return }
        if ($state.Job.State -eq "Running") { return }
        $state.Timer.Stop()
        $jobOut = ""
        try { $jobOut = (Receive-Job $state.Job 2>&1 | Out-String) } catch { }
        Remove-Job $state.Job -Force -ErrorAction SilentlyContinue
        $state.Job = $null
        $state.AnalyzeBtn.Enabled = $true
        & $renderResult $jobOut
    }.GetNewClosure()
    $timer.Add_Tick($onTick)

    # ----------------------------- start an analysis (the public entry point)
    $startAnalyze = {
        param($Ticker)
        $tk = ([string]$Ticker).Trim().ToUpper()
        $TabControl.SelectedTab = $tab
        if (-not $tk) { $state.StatusLabel.Text = "Enter a ticker first."; return }
        if (-not $state.PythonExe) {
            $state.StatusLabel.Text = "Python not found - cannot run the analysis."
            return
        }
        if (-not (Test-Path $state.Script)) {
            $state.StatusLabel.Text = "claude_analysis.py not found next to the app."
            return
        }
        if ($state.Job -and $state.Job.State -eq "Running") {
            $state.StatusLabel.Text = "Already analyzing - please wait."
            return
        }

        $state.Ticker = $tk
        $state.TickerBox.Text = $tk
        $state.AnalyzeBtn.Enabled = $false
        $state.ResultsBox.Clear()
        $state.ResultsBox.AppendText("Analyzing " + $tk + " ...")
        $state.StatusLabel.Text = "Analyzing $tk ... contacting Claude (this can take 10-30s)."

        if (Test-Path $state.OutFile) {
            Remove-Item $state.OutFile -Force -ErrorAction SilentlyContinue
        }

        # Call operator + separate args handles spaces in the paths correctly.
        $argList = @($state.Script, $tk, "--output", $state.OutFile)
        $state.Job = Start-Job -ScriptBlock {
            param($py, $jobArgs)
            & $py @jobArgs 2>&1
        } -ArgumentList $state.PythonExe, $argList

        $state.Timer.Start()
    }.GetNewClosure()

    # ----------------------------- wire events
    $state.AnalyzeBtn.Add_Click({ & $startAnalyze $state.TickerBox.Text }.GetNewClosure())

    $state.TickerBox.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            & $startAnalyze $state.TickerBox.Text
        }
    }.GetNewClosure())

    $state.CopyBtn.Add_Click({
        try {
            if ($state.ResultsBox.Text) {
                [System.Windows.Forms.Clipboard]::SetText($state.ResultsBox.Text)
                $state.StatusLabel.Text = "Copied analysis to clipboard."
            }
        } catch {
            $state.StatusLabel.Text = "Clipboard failed: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    return @{
        Tab           = $tab
        AnalyzeTicker = $startAnalyze
    }
}
