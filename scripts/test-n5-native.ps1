param(
    [string]$StudioPath,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$runDirectory = Join-Path $repository ("build\n5-native\" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$placeFile = Join-Path $runDirectory "ActorViews.rbxl"
$outputFile = Join-Path $runDirectory "result.log"
$stdoutFile = Join-Path $runDirectory "studio.stdout.log"
$stderrFile = Join-Path $runDirectory "studio.stderr.log"
$launcherFile = Join-Path $PSScriptRoot "run-n5-actor-view-tests.luau"

if (-not $StudioPath) {
    $version = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Roblox\Versions") -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "RobloxStudioBeta.exe") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $version) { throw "Roblox Studio was not found; supply -StudioPath." }
    $StudioPath = Join-Path $version.FullName "RobloxStudioBeta.exe"
}
$StudioPath = (Resolve-Path -LiteralPath $StudioPath).Path

Write-Host "Building native two-client N5 fixture..."
& rojo build (Join-Path $repository "n5-actor-view-test.project.json") -o $placeFile
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
    [Console]::Error.WriteLine("Native N5 launcher timed out. Inspect $runDirectory. No test result was verified.")
    exit 2
}
$output = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { "" }
# Studio also echoes script source into output. Match an actual result line,
# never a marker embedded in the echoed print statement.
$resultLine = [regex]::Match($output, '(?m)^__KRF_NATIVE_N5_(PASS|FAIL)__ (\{[^\r\n]*\})\r?$')
if ($resultLine.Success) {
    Write-Host $resultLine.Value
    $result = $resultLine.Groups[2].Value | ConvertFrom-Json
    if ($resultLine.Groups[1].Value -eq "PASS" -and $result.success -eq $true) { exit 0 }
    if ($resultLine.Groups[1].Value -eq "FAIL" -and $result.success -eq $false) { exit 1 }
}
[Console]::Error.WriteLine("Studio produced no valid native N5 result marker. Inspect $runDirectory for a launcher or Studio error.")
exit 2
