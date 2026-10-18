param(
    [ValidateSet('CPU', 'Native')][string]$Profile = 'CPU',
    [string]$StudioPath,
    [ValidateRange(60, 1200)][int]$TimeoutSeconds = 600,
    [switch]$PrepareOnly,
    [string]$PreparedRunDirectory
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
if ($PreparedRunDirectory) {
    $runDirectory = (Resolve-Path -LiteralPath $PreparedRunDirectory).Path
    if (Test-Path -LiteralPath (Join-Path $runDirectory 'result.json')) { throw 'A prepared trial can only be run once.' }
} else {
    $runDirectory = Join-Path $repository ('build\n4-performance\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
}
if (-not $StudioPath) {
    $version = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Roblox\Versions') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'RobloxStudioBeta.exe') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $version) { throw 'Roblox Studio was not found; supply -StudioPath.' }
    $StudioPath = Join-Path $version.FullName 'RobloxStudioBeta.exe'
}
$StudioPath = (Resolve-Path -LiteralPath $StudioPath).Path
if (-not $PreparedRunDirectory) {
    # Capture the measured sources before building/launching, not after the run.
    . "$PSScriptRoot\networking-benchmark-environment.ps1"
    $environment = Get-NetworkingBenchmarkEnvironment $repository $StudioPath
    $hashes = [ordered]@{}
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $files = @(Get-ChildItem -LiteralPath (Join-Path $repository 'src\server\Networking') -Filter '*.luau' -Recurse)
    $files += Get-ChildItem -LiteralPath (Join-Path $repository 'src\shared\Networking') -Filter '*.luau' -Recurse
    $files += @('tests\benchmarks\N4Sustained.luau', 'tests\integration\N4Performance\Utils\Scenario.luau',
        'n4-performance-test.project.json', 'scripts\measure-n4-performance.ps1') | ForEach-Object { Get-Item -LiteralPath (Join-Path $repository $_) }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($repository.Length + 1).Replace('\', '/')
        $hashes[$relative] = [System.BitConverter]::ToString($algorithm.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace('-', '')
    }
    $algorithm.Dispose()
    $environment | Add-Member -NotePropertyName n4SourceSHA256 -NotePropertyValue $hashes
    $project = if ($Profile -eq 'Native') { 'n4-performance-test.project.json' } else { 'test.project.json' }
    $script = if ($Profile -eq 'Native') { 'scripts\run-networking-baseline-tests.luau' } else { 'tests\benchmarks\N4Sustained.luau' }
    $placeFile = Join-Path $runDirectory 'N4Performance.rbxl'
    & rojo build (Join-Path $repository $project) -o $placeFile
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Copy-Item -LiteralPath (Join-Path $repository $script) -Destination (Join-Path $runDirectory 'workload.luau')
    $environment | Add-Member -NotePropertyName profile -NotePropertyValue $Profile
    $environment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDirectory 'source-environment.json') -Encoding UTF8
}
$environment = Get-Content -LiteralPath (Join-Path $runDirectory 'source-environment.json') -Raw | ConvertFrom-Json
$Profile = $environment.profile
$placeFile = Join-Path $runDirectory 'N4Performance.rbxl'
$scriptFile = Join-Path $runDirectory 'workload.luau'
$marker = if ($Profile -eq 'Native') { 'NETWORKING_BASELINE_RESULT' } else { 'N4_SUSTAINED_RESULT' }
if ($PrepareOnly) { Write-Host "__KRF_N4_PREPARED__ $runDirectory"; exit 0 }
$environment | Add-Member -NotePropertyName sourceCapturedAtUtc -NotePropertyValue $environment.measuredAtUtc
$environment.measuredAtUtc = [DateTime]::UtcNow.ToString('o')
$outputFile = Join-Path $runDirectory 'result.log'
$studioArguments = @('--task', 'RunScript', '--localPlaceFile', ('"' + $placeFile + '"'),
    '--runScriptFile', ('"' + $scriptFile + '"'), '--outputFile', ('"' + $outputFile + '"'), '--quitAfterExecution')
Write-Host "N4 $Profile measurement: $runDirectory"
$studioProcess = Start-Process -FilePath $StudioPath -ArgumentList $studioArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $runDirectory 'studio.stdout.log') `
    -RedirectStandardError (Join-Path $runDirectory 'studio.stderr.log')
if (-not $studioProcess.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $studioProcess.Id -ErrorAction SilentlyContinue
    throw "N4 measurement timed out: $runDirectory"
}
$logText = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { '' }
$pattern = '(?ms)^__KRF_' + $marker + '_START__\r?\n(.*?)^__KRF_' + $marker + '_END__\r?$'
$block = [regex]::Match($logText, $pattern)
if (-not $block.Success) { throw "No complete N4 result: $runDirectory" }
$result = (($block.Groups[1].Value -split '\r?\n') -join '') | ConvertFrom-Json
$result | Add-Member -NotePropertyName environment -NotePropertyValue $environment
$result | Add-Member -NotePropertyName profile -NotePropertyValue $Profile
$result | ConvertTo-Json -Depth 40 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8
if ($result.success -ne $true) { $result | Select-Object success, reason, phase | Format-List; exit 1 }
Write-Host "__KRF_N4_PERFORMANCE_PASS__ $runDirectory"
