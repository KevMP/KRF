param(
    [string]$StudioPath,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$runDirectory = Join-Path $repository ("build\tags-load\" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$placeFile = Join-Path $runDirectory "TagsLoad.rbxl"
. (Join-Path $repository 'tests/integration/studio/Studio.ps1')
$StudioPath = Resolve-TestStudio $repository $StudioPath
$launcherFile = Join-Path $runDirectory "launcher.luau"
Write-MultiplayerLauncher -Destination $launcherFile -TestName KRFTagsLoad -Marker TAGS_LOAD -ResultBlock TAGS_LOAD_RESULT

Write-Host "Building native multi-Actor Tags load fixture..."
& rojo build (Join-Path $repository "tests/integration/projects/tags-load-test.project.json") -o $placeFile

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Running Studio. Logs: $runDirectory"
$studioProcess = Start-TestStudio $StudioPath $placeFile $launcherFile $runDirectory

if (-not (Wait-TestStudio $studioProcess $TimeoutSeconds)) {
    [Console]::Error.WriteLine("Native Tags load launcher timed out. Inspect $runDirectory. No test result was verified.")
    exit 2
}

$output = Read-StudioOutput $runDirectory
$result = Read-StudioResult $output TAGS_LOAD_RESULT $runDirectory
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

$result | Add-Member -NotePropertyName environment -NotePropertyValue ([pscustomobject]@{
    cpu = $cpu.Name
    studioFileVersion = (Get-Item -LiteralPath $StudioPath).VersionInfo.FileVersion
    measuredAtUtc = [DateTime]::UtcNow.ToString('o')
})

$result | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8

if ($result.success -ne $true -or -not [regex]::IsMatch($output, '(?m)^__KRF_NATIVE_TAGS_LOAD_PASS__\r?$')) {
    $result | Select-Object success, phase, reason | Format-List
    exit 1
}

$result.cases | ForEach-Object {
    [pscustomobject]@{
        Actors = $_.actors
        Mode = $_.mode
        Batches = $_.committedBatches
        MutationMedianUs = [math]::Round($_.serverMutationUs.median, 2)
        MutationP95Us = [math]::Round($_.serverMutationUs.p95, 2)
        ServerFrameP95Ms = [math]::Round($_.serverHeartbeatMs.p95, 2)
        ObservedMedianMs = [math]::Round($_.consumerObservedEstimateMs.median, 2)
        ObservedP95Ms = [math]::Round($_.consumerObservedEstimateMs.p95, 2)
        NegativeEstimates = $_.consumerObservedEstimateMs.negativeSamples
        WaveAckP95Ms = [math]::Round($_.waveCompletionAckMs.p95, 2)
    }
} | Format-Table -AutoSize

Write-Host "__KRF_NATIVE_TAGS_LOAD_PASS__ Results: $runDirectory"
exit 0
