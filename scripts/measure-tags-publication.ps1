param()
$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$runDirectory = Join-Path $repository ("build\tags-scaling\" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$placeFile = Join-Path $runDirectory "TagsScaling.rbxl"
$logFile = Join-Path $runDirectory "result.log"
& "$PSScriptRoot\fix-studio-path.ps1"
& rojo build (Join-Path $repository "test.project.json") -o $placeFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Measuring in uninstrumented Studio; results: $runDirectory"
$output = & run-in-roblox --place $placeFile --script (Join-Path $repository "tests\benchmarks\TagsPublication.luau") 2>&1
$runExitCode = $LASTEXITCODE
$output | Set-Content -LiteralPath $logFile -Encoding UTF8
if ($runExitCode -ne 0) {
    $output | Write-Host
    exit $runExitCode
}
$resultLine = $output | ForEach-Object { $_.ToString() } | Where-Object { $_.StartsWith("__KRF_TAGS_SCALING__ ") }
if (@($resultLine).Count -ne 1) { throw "Expected exactly one completed scaling result. Inspect $logFile." }
$result = $resultLine.Substring("__KRF_TAGS_SCALING__ ".Length) | ConvertFrom-Json
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$result | Add-Member -NotePropertyName cpu -NotePropertyValue $cpu.Name
$contentFolder = (Get-ItemProperty "HKCU:\Software\Roblox\RobloxStudio").ContentFolder
$studioFile = Get-Item -LiteralPath (Join-Path (Split-Path -Parent $contentFolder.TrimEnd('\')) "RobloxStudioBeta.exe")
$result | Add-Member -NotePropertyName configuredStudioVersion -NotePropertyValue $studioFile.VersionInfo.FileVersion
$result | Add-Member -NotePropertyName measuredAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString("o"))
$result | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $runDirectory "measurement.json") -Encoding UTF8
$result.rows | ForEach-Object {
    [pscustomobject]@{
        ActiveVisibleIds = $_.activeVisibleIds
        Mode = $_.mode
        MedianUs = [math]::Round($_.latency.medianUs, 2)
        P95Us = [math]::Round($_.latency.p95Us, 2)
    }
} | Format-Table -AutoSize
