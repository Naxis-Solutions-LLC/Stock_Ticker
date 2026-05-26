# Diagnostic: figure out why dropdowns are empty
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$csv = Join-Path $ScriptDir "data\screen_data.csv"

Write-Host "=== Diagnostic for empty sector/industry dropdowns ==="
Write-Host ""
Write-Host "CSV path: $csv"
Write-Host "Exists: $(Test-Path $csv)"
if (-not (Test-Path $csv)) { Write-Host "FILE MISSING - re-run full screen"; pause; exit }

$size = (Get-Item $csv).Length
$mtime = (Get-Item $csv).LastWriteTime
Write-Host "Size: $size bytes"
Write-Host "Modified: $mtime"
Write-Host ""

# Header line
$header = (Get-Content $csv -TotalCount 1)
Write-Host "Header line:"
Write-Host "  $header"
Write-Host ""

# Import and inspect
$rows = @(Import-Csv $csv)
Write-Host "Row count: $($rows.Count)"
if ($rows.Count -gt 0) {
    Write-Host ""
    Write-Host "First row properties:"
    $rows[0].PSObject.Properties | ForEach-Object {
        Write-Host "  $($_.Name) = '$($_.Value)'"
    }
    Write-Host ""
    # Count rows with Sector data
    $hasSector = 0
    $emptySector = 0
    $noSectorProp = 0
    $sectorSamples = @{}
    foreach ($r in $rows) {
        $prop = $r.PSObject.Properties['Sector']
        if (-not $prop) { $noSectorProp++; continue }
        $v = [string]$r.Sector
        if ($v -eq "" -or $v -eq $null) { $emptySector++; continue }
        $hasSector++
        if (-not $sectorSamples.ContainsKey($v)) { $sectorSamples[$v] = 0 }
        $sectorSamples[$v]++
    }
    Write-Host "Sector data summary:"
    Write-Host "  Rows with valid Sector: $hasSector"
    Write-Host "  Rows with empty Sector: $emptySector"
    Write-Host "  Rows missing Sector property entirely: $noSectorProp"
    Write-Host ""
    Write-Host "Unique sectors in data:"
    $sectorSamples.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object {
        Write-Host "  $($_.Key): $($_.Value) rows"
    }
}
Write-Host ""
Write-Host "Press Enter to close..."
Read-Host
