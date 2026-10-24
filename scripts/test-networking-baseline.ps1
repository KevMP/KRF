param(
    [string]$StudioPath,
    [ValidateSet(2, 4, 6, 8)][int]$ClientCount = 2,
    [ValidateSet('Publication', 'Commands')][string]$Workload = 'Publication',
    [string]$ImplementationRevision,
    [ValidateRange(1, 4096)][int]$Records = 64,
    [ValidateRange(1024, 4194304)][int]$Bytes = 32768,
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
$launcherFile = Join-Path $runDirectory "launcher.luau"
$launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot "run-networking-baseline-tests.luau") -Raw
[System.IO.File]::WriteAllText($launcherFile, $launcher.Replace('local clientCount = 2 --', "local clientCount = $ClientCount --"), [System.Text.UTF8Encoding]::new($false))

if (-not $StudioPath) {
    $version = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Roblox\Versions") -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "RobloxStudioBeta.exe") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $version) { throw "Roblox Studio was not found; supply -StudioPath." }
    $StudioPath = Join-Path $version.FullName "RobloxStudioBeta.exe"
}
$StudioPath = (Resolve-Path -LiteralPath $StudioPath).Path
. "$PSScriptRoot\networking-benchmark-environment.ps1"
. "$PSScriptRoot\networking-host-monitor.ps1"
$sourceDirectory = Join-Path $repository 'src'
if ($ImplementationRevision) {
    # Build the reference without modifying the checkout or historical harness.
    $revision = & git -c "safe.directory=$repository" -C $repository rev-parse --verify "$ImplementationRevision^{commit}"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve implementation revision.' }
    $archive = Join-Path $runDirectory 'implementation.zip'
    & git -c "safe.directory=$repository" -C $repository archive --format=zip "--output=$archive" $revision src
    if ($LASTEXITCODE -ne 0) { throw 'Cannot archive implementation.' }
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $runDirectory 'implementation')
    $sourceDirectory = Join-Path $runDirectory 'implementation\src'
}
$environment = Get-NetworkingBenchmarkEnvironment $repository $StudioPath $sourceDirectory
$environment | Add-Member -NotePropertyName harnessRevision -NotePropertyValue $environment.implementationRevision
if ($ImplementationRevision) { $environment.implementationRevision = "$revision" }
$environment | Add-Member -NotePropertyName requestedClients -NotePropertyValue $ClientCount
$environment | Add-Member -NotePropertyName workload -NotePropertyValue $Workload
$environment | Add-Member -NotePropertyName schedulerBudget -NotePropertyValue ([pscustomobject]@{ records = $Records; bytes = $Bytes })
$environment | Add-Member -NotePropertyName workingTreeStatus -NotePropertyValue (@(& git -c "safe.directory=$repository" -C $repository status --short) -join "`n")
$project = Get-Content -LiteralPath (Join-Path $repository 'networking-baseline-test.project.json') -Raw | ConvertFrom-Json
$project.tree.ReplicatedStorage.Packages.KRF.'$path' = $sourceDirectory
$project.tree.ReplicatedStorage | Add-Member -NotePropertyName NetworkingBenchmarkRecords -NotePropertyValue ([pscustomobject]@{ '$className' = 'IntValue'; '$properties' = @{ Value = $Records } })
$project.tree.ReplicatedStorage | Add-Member -NotePropertyName NetworkingBenchmarkBytes -NotePropertyValue ([pscustomobject]@{ '$className' = 'IntValue'; '$properties' = @{ Value = $Bytes } })
$project.tree.ReplicatedStorage.NetworkingBaselineScenario.'$path' = Join-Path $repository 'tests/integration/NetworkingBaseline/Utils/Scenario.luau'
$project.tree.ServerScriptService.NetworkingBaselineServer.'$path' = Join-Path $repository 'tests/integration/NetworkingBaseline/Server.server.luau'
$project.tree.StarterPlayer.StarterPlayerScripts.NetworkingBaselineClient.'$path' = Join-Path $repository 'tests/integration/NetworkingBaseline/Client.client.luau'
if ($Workload -eq 'Commands') {
    $project.tree.ReplicatedStorage | Add-Member -NotePropertyName NetworkingCommandScenario -NotePropertyValue ([pscustomobject]@{ '$path' = (Join-Path $repository 'tests/integration/NetworkingCommands/Utils/Scenario.luau') })
    $project.tree.ServerScriptService.NetworkingBaselineServer.'$path' = Join-Path $repository 'tests/integration/NetworkingCommands/Server.server.luau'
    $project.tree.StarterPlayer.StarterPlayerScripts.NetworkingBaselineClient.'$path' = Join-Path $repository 'tests/integration/NetworkingCommands/Client.client.luau'
}
$projectFile = Join-Path $runDirectory 'fixture.project.json'
[System.IO.File]::WriteAllText($projectFile, ($project | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))

Write-Host "Building native Networking baseline fixture..."
& rojo build $projectFile -o $placeFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$environment | Add-Member -NotePropertyName placeSHA256 -NotePropertyValue (Get-FileHash -LiteralPath $placeFile -Algorithm SHA256).Hash
$environment | Add-Member -NotePropertyName launcherSHA256 -NotePropertyValue (Get-FileHash -LiteralPath $launcherFile -Algorithm SHA256).Hash
$environment | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $runDirectory 'environment.json') -Encoding UTF8

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
$hostMeasurements = Wait-NetworkingStudio $studioProcess $TimeoutSeconds $environment.logicalProcessors
$hostMeasurements | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'host.json') -Encoding UTF8
if ($hostMeasurements.timedOut) {
    [Console]::Error.WriteLine("Native Networking baseline launcher timed out. Inspect $runDirectory. No test result was verified.")
    exit 2
}
$output = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { "" }
$resultBlock = [regex]::Match($output, '(?ms)^__KRF_NETWORKING_BASELINE_RESULT_START__\r?\n(.*?)^__KRF_NETWORKING_BASELINE_RESULT_END__\r?$')
if (-not $resultBlock.Success) { throw "Studio produced no complete load result. Inspect $runDirectory." }
$encoded = ($resultBlock.Groups[1].Value -split '\r?\n') -join ''
$result = $encoded | ConvertFrom-Json
$environment | Add-Member -NotePropertyName completedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
$result | Add-Member -NotePropertyName environment -NotePropertyValue $environment
$result | Add-Member -NotePropertyName hostMeasurements -NotePropertyValue $hostMeasurements
$result | ConvertTo-Json -Depth 25 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8
if ($result.success -ne $true -or $result.clients -ne $ClientCount -or -not [regex]::IsMatch($output, '(?m)^__KRF_NATIVE_NETWORKING_BASELINE_PASS__\r?$')) {
    $result | Select-Object success, phase, reason | Format-List
    exit 1
}
Write-Host "__KRF_NATIVE_NETWORKING_BASELINE_PASS__ Results: $runDirectory"
exit 0
