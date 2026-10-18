param(
    [string]$StudioPath,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$runDirectory = Join-Path $repository ("build\networking-baseline\" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$placeFile = Join-Path $runDirectory "NetworkingBaseline.rbxl"
$outputFile = Join-Path $runDirectory "result.log"
$stdoutFile = Join-Path $runDirectory "studio.stdout.log"
$stderrFile = Join-Path $runDirectory "studio.stderr.log"
$launcherFile = Join-Path $PSScriptRoot "run-networking-baseline-tests.luau"

if (-not $StudioPath) {
    $version = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Roblox\Versions") -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "RobloxStudioBeta.exe") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $version) { throw "Roblox Studio was not found; supply -StudioPath." }
    $StudioPath = Join-Path $version.FullName "RobloxStudioBeta.exe"
}
$StudioPath = (Resolve-Path -LiteralPath $StudioPath).Path

Write-Host "Building native Networking baseline fixture..."
& rojo build (Join-Path $repository "networking-baseline-test.project.json") -o $placeFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# RunScript executes in the Edit DataModel with Command Bar permissions. The
# Luau launcher starts actual multiplayer simulation via StudioTestService.
$studioArguments = @(
    "--task", "RunScript",
    "--localPlaceFile", ('"' + $placeFile + '"'),
    "--runScriptFile", ('"' + $launcherFile + '"'),
    "--outputFile", ('"' + $outputFile + '"'),
    "--quitAfterExecution"
)
Write-Host "Running Studio; logs: $runDirectory"
$studioProcess = Start-Process -FilePath $StudioPath -ArgumentList $studioArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
if (-not $studioProcess.WaitForExit($TimeoutSeconds * 1000)) {
    # Only stop the process launched by this invocation, never an existing Studio.
    Stop-Process -Id $studioProcess.Id -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("Native Networking baseline launcher timed out. Inspect $runDirectory. No test result was verified.")
    exit 2
}
$output = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { "" }
$resultBlock = [regex]::Match($output, '(?ms)^__KRF_NETWORKING_BASELINE_RESULT_START__\r?\n(.*?)^__KRF_NETWORKING_BASELINE_RESULT_END__\r?$')
if (-not $resultBlock.Success) { throw "Studio produced no complete load result. Inspect $runDirectory." }
$encoded = ($resultBlock.Groups[1].Value -split '\r?\n') -join ''
$result = $encoded | ConvertFrom-Json
. "$PSScriptRoot\networking-benchmark-environment.ps1"
$result | Add-Member -NotePropertyName environment -NotePropertyValue (Get-NetworkingBenchmarkEnvironment $repository $StudioPath)
$result | ConvertTo-Json -Depth 25 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8
if ($result.success -ne $true -or -not [regex]::IsMatch($output, '(?m)^__KRF_NATIVE_NETWORKING_BASELINE_PASS__\r?$')) {
    $result | Select-Object success, phase, reason | Format-List
    exit 1
}
Write-Host "__KRF_NATIVE_NETWORKING_BASELINE_PASS__ Results: $runDirectory"
exit 0
