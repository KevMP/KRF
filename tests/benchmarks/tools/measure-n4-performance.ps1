param(
    [ValidateSet('CPU', 'Native')][string]$Profile = 'CPU',
    [string]$StudioPath,
    [ValidateRange(60, 1200)][int]$TimeoutSeconds = 600,
    [switch]$PrepareOnly,
    [string]$PreparedRunDirectory
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path

if ($PreparedRunDirectory) {
    $runDirectory = (Resolve-Path -LiteralPath $PreparedRunDirectory).Path

    if (Test-Path -LiteralPath (Join-Path $runDirectory 'result.json')) { throw 'A prepared trial can only be run once.' }
} else {
    $runDirectory = Join-Path $repository ('build\n4-performance\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
}

. (Join-Path $repository 'tests/integration/studio/Studio.ps1')
$StudioPath = Resolve-TestStudio $repository $StudioPath

if (-not $PreparedRunDirectory) {
    # Capture the measured sources before building/launching, not after the run.
    . "$PSScriptRoot\networking-benchmark-environment.ps1"
    $environment = Get-NetworkingBenchmarkEnvironment $repository $StudioPath
    $hashes = [ordered]@{}
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $files = @(Get-ChildItem -LiteralPath (Join-Path $repository 'src\server\Networking') -Filter '*.luau' -Recurse)
    $files += Get-ChildItem -LiteralPath (Join-Path $repository 'src\shared\Networking') -Filter '*.luau' -Recurse

    $files += @('tests\benchmarks\N4Sustained.luau', 'tests\integration\N4Performance\Utils\Scenario.luau',
        'tests/integration/projects/n4-performance-test.project.json', 'tests\benchmarks\tools\measure-n4-performance.ps1') | ForEach-Object { Get-Item -LiteralPath (Join-Path $repository $_) }

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($repository.Length + 1).Replace('\', '/')
        $hashes[$relative] = [System.BitConverter]::ToString($algorithm.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace('-', '')
    }

    $algorithm.Dispose()
    $environment | Add-Member -NotePropertyName n4SourceSHA256 -NotePropertyValue $hashes

    $project = if ($Profile -eq 'Native') { 'tests/integration/projects/n4-performance-test.project.json' } else { 'test.project.json' }

    $placeFile = Join-Path $runDirectory 'N4Performance.rbxl'
    & rojo build (Join-Path $repository $project) -o $placeFile

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $workloadFile = Join-Path $runDirectory 'workload.luau'

    if ($Profile -eq 'Native') {
        Write-MultiplayerLauncher -Destination $workloadFile -TestName KRFNetworkingBaseline -Marker NETWORKING_BASELINE `
            -ResultBlock NETWORKING_BASELINE_RESULT -PassClientOptions
    } else {
        Copy-Item -LiteralPath (Join-Path $repository 'tests/benchmarks/N4Sustained.luau') -Destination $workloadFile
    }

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
Write-Host "N4 $Profile measurement. Logs: $runDirectory"
$studioProcess = Start-TestStudio $StudioPath $placeFile $scriptFile $runDirectory

if (-not (Wait-TestStudio $studioProcess $TimeoutSeconds)) { throw "N4 measurement timed out: $runDirectory" }

$result = Read-StudioResult (Read-StudioOutput $runDirectory) $marker $runDirectory
$result | Add-Member -NotePropertyName environment -NotePropertyValue $environment
$result | Add-Member -NotePropertyName profile -NotePropertyValue $Profile
$result | ConvertTo-Json -Depth 40 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8

if ($result.success -ne $true) { $result | Select-Object success, reason, phase | Format-List; exit 1 }

Write-Host "__KRF_N4_PERFORMANCE_PASS__ $runDirectory"
