param(
    [string]$StudioPath,
    [ValidateRange(60, 1200)][int]$TimeoutSeconds = 600,
    [ValidateSet('Networking', 'Observers')][string]$Workload = 'Networking'
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$runDirectory = Join-Path $repository ('build\networking-cpu\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$placeFile = Join-Path $runDirectory 'NetworkingCPU.rbxl'
if (-not $StudioPath) {
    $version = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Roblox\Versions') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'RobloxStudioBeta.exe') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $version) { throw 'Roblox Studio was not found; supply -StudioPath.' }
    $StudioPath = Join-Path $version.FullName 'RobloxStudioBeta.exe'
}
$StudioPath = (Resolve-Path -LiteralPath $StudioPath).Path
& rojo build (Join-Path $repository 'test.project.json') -o $placeFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "CPU-only Studio baseline; logs: $runDirectory"
$outputFile = Join-Path $runDirectory 'result.log'
$scriptFile = Join-Path $repository $(if ($Workload -eq 'Observers') { 'tests\benchmarks\MutationObservers.luau' } else { 'tests\benchmarks\NetworkingBaseline.luau' })
# Direct file output avoids run-in-roblox's 1 MiB HTTP result limit. This is
# the same RunScript mechanism used by the native multiplayer runner.
$studioArguments = @(
    '--task', 'RunScript', '--localPlaceFile', ('"' + $placeFile + '"'),
    '--runScriptFile', ('"' + $scriptFile + '"'), '--outputFile', ('"' + $outputFile + '"'),
    '--quitAfterExecution'
)
$studioProcess = Start-Process -FilePath $StudioPath -ArgumentList $studioArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $runDirectory 'studio.stdout.log') `
    -RedirectStandardError (Join-Path $runDirectory 'studio.stderr.log')
if (-not $studioProcess.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $studioProcess.Id -ErrorAction SilentlyContinue
    throw "CPU baseline timed out. Inspect $runDirectory. No result was verified."
}
$logText = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { '' }
$block = [regex]::Match($logText, '(?ms)^__KRF_NETWORKING_CPU_START__\r?\n(.*?)^__KRF_NETWORKING_CPU_END__\r?$')
if (-not $block.Success) { throw "No complete CPU result. Inspect $runDirectory." }
$result = (($block.Groups[1].Value -split '\r?\n') -join '') | ConvertFrom-Json
. "$PSScriptRoot\networking-benchmark-environment.ps1"
$result | Add-Member -NotePropertyName environment -NotePropertyValue (Get-NetworkingBenchmarkEnvironment $repository $StudioPath)
$result | Add-Member -NotePropertyName workload -NotePropertyValue $Workload
if ($Workload -eq 'Observers') {
    foreach ($relativePath in @('tests/benchmarks/MutationObservers.luau', 'src/server/Tags/TagController.luau', 'src/server/Property/PropertyController.luau', 'src/server/Resource/ResourceController.luau', 'src/server/Resource/utils/ResourceMutationJournal.luau', 'src/server/Networking/PublicationRuntime.luau')) {
        $result.environment.harnessSHA256[$relativePath] = (Get-FileHash -LiteralPath (Join-Path $repository $relativePath) -Algorithm SHA256).Hash
    }
}
$result | ConvertTo-Json -Depth 30 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8
if ($result.success -ne $true) { exit 1 }
Write-Host "__KRF_NETWORKING_CPU_PASS__ Results: $runDirectory"
exit 0
