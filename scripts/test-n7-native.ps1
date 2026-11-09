param(
    [string]$StudioPath,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 180,
    [ValidateSet("n7", "n8", "n9", "i1", "i2", "i3", "i4", "i5", "i6", "i7")][string]$Suite = "n7"
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$runDirectory = Join-Path $repository ("build\" + $Suite + "-native\" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$viewName = switch ($Suite) { "i7" { "Controls" } "i6" { "ActionInput" } "i5" { "ActionRequests" } "i4" { "ActionRoutes" } "i3" { "InputSequences" } "i2" { "InputGestures" } "i1" { "Input" } "n9" { "Commands" } "n8" { "ActionsView" } default { "ResourcesView" } }
$placeFile = Join-Path $runDirectory ($viewName + ".rbxl")
$outputFile = Join-Path $runDirectory "result.log"
$stdoutFile = Join-Path $runDirectory "studio.stdout.log"
$stderrFile = Join-Path $runDirectory "studio.stderr.log"
$launcherName = switch ($Suite) { "i7" { "run-i7-controls-tests.luau" } "i6" { "run-i6-action-input-tests.luau" } "i5" { "run-i5-action-requests-tests.luau" } "i4" { "run-i4-action-routes-tests.luau" } "i3" { "run-i3-input-sequences-tests.luau" } "i2" { "run-i2-input-gestures-tests.luau" } "i1" { "run-i1-input-tests.luau" } "n9" { "run-n9-command-tests.luau" } "n8" { "run-n8-actions-view-tests.luau" } default { "run-n7-resources-view-tests.luau" } }
$launcherFile = Join-Path $PSScriptRoot $launcherName

if (-not $StudioPath) {
    $StudioPath = & "$PSScriptRoot\fix-studio-path.ps1" -ResolveOnly
}
$StudioPath = (Resolve-Path -LiteralPath $StudioPath).Path

Write-Host "Building native two-client $Suite fixture..."
$projectName = switch ($Suite) { "i7" { "i7-controls-test.project.json" } "i6" { "i6-action-input-test.project.json" } "i5" { "i5-action-requests-test.project.json" } "i4" { "i4-action-routes-test.project.json" } "i3" { "i3-input-sequences-test.project.json" } "i2" { "i2-input-gestures-test.project.json" } "i1" { "i1-input-test.project.json" } "n9" { "n9-command-test.project.json" } "n8" { "n8-actions-view-test.project.json" } default { "n7-resources-view-test.project.json" } }
& rojo build (Join-Path $repository $projectName) -o $placeFile
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
    [Console]::Error.WriteLine("Native $Suite launcher timed out. Inspect $runDirectory. No test result was verified.")
    exit 2
}
$output = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { "" }
# Studio also echoes script source into output. Match an actual result line,
# never a marker embedded in the echoed print statement.
$resultPattern = '(?m)^__KRF_NATIVE_' + $Suite.ToUpperInvariant() + '_(PASS|FAIL)__ (\{[^\r\n]*\})\r?$'
$resultLine = [regex]::Match($output, $resultPattern)
if ($resultLine.Success) {
    Write-Host $resultLine.Value
    $result = $resultLine.Groups[2].Value | ConvertFrom-Json
    if ($resultLine.Groups[1].Value -eq "PASS" -and $result.success -eq $true) { exit 0 }
    if ($resultLine.Groups[1].Value -eq "FAIL" -and $result.success -eq $false) { exit 1 }
}
[Console]::Error.WriteLine("Studio produced no valid native $Suite result marker. Inspect $runDirectory for a launcher or Studio error.")
exit 2
