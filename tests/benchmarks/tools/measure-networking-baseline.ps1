param(
    [string]$StudioPath,
    [ValidateRange(60, 1200)][int]$TimeoutSeconds = 600,
    [ValidateSet('Networking', 'Observers', 'Audit', 'Commands')][string]$Workload = 'Networking',
    [string]$ImplementationRevision,
    [ValidateRange(1, 4096)][int]$Records = 64,
    [ValidateRange(1024, 4194304)][int]$Bytes = 32768,
    [ValidateSet('full', 'scheduler', 'join-state')][string]$Focus = 'full',
    [switch]$PrepareOnly,
    [string]$PreparedRunDirectory
)
$ErrorActionPreference = 'Stop'

if ($Focus -eq 'scheduler' -and $Workload -ne 'Networking') { throw 'Scheduler focus requires the Networking workload.' }

if ($Focus -eq 'join-state' -and $Workload -ne 'Audit') { throw 'Join-state focus requires the Audit workload.' }

$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path

if ($PreparedRunDirectory) {
    $runDirectory = (Resolve-Path -LiteralPath $PreparedRunDirectory).Path

    if (Test-Path -LiteralPath (Join-Path $runDirectory 'result.json')) { throw 'A prepared trial can only be run once.' }
} else {
    $runDirectory = Join-Path $repository ('build\networking-cpu\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
}

$placeFile = Join-Path $runDirectory 'NetworkingCPU.rbxl'
. (Join-Path $repository 'tests/integration/studio/Studio.ps1')
$StudioPath = Resolve-TestStudio $repository $StudioPath
. "$PSScriptRoot\networking-benchmark-environment.ps1"

if (-not $PreparedRunDirectory) {
    $sourceDirectory = Join-Path $repository 'src'

    if ($ImplementationRevision) {
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

    $hashes = [ordered]@{}
    $files = @(Get-ChildItem -LiteralPath (Join-Path $repository 'tests\benchmarks') -File -Filter '*.luau')
    $files += Get-Item -LiteralPath $PSCommandPath
    $files += Get-Item -LiteralPath (Join-Path $repository 'test.project.json')

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($repository.Length + 1).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }

    $environment | Add-Member -NotePropertyName workloadSourcesSHA256 -NotePropertyValue $hashes
    $environment | Add-Member -NotePropertyName sourceStatus -NotePropertyValue @(& git -c "safe.directory=$repository" -C $repository status --porcelain)
    $environment | Add-Member -NotePropertyName workload -NotePropertyValue $Workload
    $environment | Add-Member -NotePropertyName schedulerBudget -NotePropertyValue ([pscustomobject]@{ records = $Records; bytes = $Bytes })
    $environment | Add-Member -NotePropertyName benchmarkFocus -NotePropertyValue $Focus
    $environment | Add-Member -NotePropertyName studioPath -NotePropertyValue $StudioPath
    $project = Get-Content -LiteralPath (Join-Path $repository 'test.project.json') -Raw | ConvertFrom-Json

    # Preserve every existing project mapping while anchoring run-local paths.
    function Set-AbsoluteProjectPaths($Node) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Name -eq '$path') { $property.Value = Join-Path $repository $property.Value }
            elseif ($property.Value -is [pscustomobject]) { Set-AbsoluteProjectPaths $property.Value }
        }
    }

    Set-AbsoluteProjectPaths $project
    $project.tree.ReplicatedStorage.Packages.KRF.'$path' = $sourceDirectory
    $project.tree.ReplicatedStorage | Add-Member -NotePropertyName NetworkingBenchmarkRecords -NotePropertyValue ([pscustomobject]@{ '$className' = 'IntValue'; '$properties' = @{ Value = $Records } })
    $project.tree.ReplicatedStorage | Add-Member -NotePropertyName NetworkingBenchmarkBytes -NotePropertyValue ([pscustomobject]@{ '$className' = 'IntValue'; '$properties' = @{ Value = $Bytes } })
    $project.tree.ReplicatedStorage | Add-Member -NotePropertyName NetworkingBenchmarkFocus -NotePropertyValue ([pscustomobject]@{ '$className' = 'StringValue'; '$properties' = @{ Value = $Focus } })
    $projectFile = Join-Path $runDirectory 'fixture.project.json'
    [System.IO.File]::WriteAllText($projectFile, ($project | ConvertTo-Json -Depth 25), [System.Text.UTF8Encoding]::new($false))
    & rojo build $projectFile -o $placeFile

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $sourceScript = switch ($Workload) {
        'Observers' { 'tests\benchmarks\MutationObservers.luau' }
        'Audit' { 'tests\benchmarks\NetworkingAudit.luau' }
        'Commands' { 'tests\benchmarks\NetworkingCommands.luau' }
        default { 'tests\benchmarks\NetworkingBaseline.luau' }
    }

    Copy-Item -LiteralPath (Join-Path $repository $sourceScript) -Destination (Join-Path $runDirectory 'workload.luau')
    $environment | Add-Member -NotePropertyName placeSHA256 -NotePropertyValue (Get-FileHash -LiteralPath $placeFile -Algorithm SHA256).Hash
    $environment | Add-Member -NotePropertyName workloadSHA256 -NotePropertyValue (Get-FileHash -LiteralPath (Join-Path $runDirectory 'workload.luau') -Algorithm SHA256).Hash
    $environment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDirectory 'source-environment.json') -Encoding UTF8
}

$environment = Get-Content -LiteralPath (Join-Path $runDirectory 'source-environment.json') -Raw | ConvertFrom-Json
$Workload = $environment.workload

if ($environment.studioPath -ne $StudioPath) { throw 'Prepared trials must use the captured Studio executable.' }

if ($PrepareOnly) { Write-Host "__KRF_NETWORKING_PREPARED__ $runDirectory"; exit 0 }

Write-Host "CPU-only Studio baseline; logs: $runDirectory"
$scriptFile = Join-Path $runDirectory 'workload.luau'

if ((Get-FileHash -LiteralPath $placeFile -Algorithm SHA256).Hash -ne $environment.placeSHA256 -or
    (Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash -ne $environment.workloadSHA256) {
    throw 'Prepared place/workload changed after source capture.'
}

$environment | Add-Member -NotePropertyName startedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
$studioProcess = Start-TestStudio $StudioPath $placeFile $scriptFile $runDirectory

if (-not (Wait-TestStudio $studioProcess $TimeoutSeconds)) {
    throw "CPU baseline timed out. Inspect $runDirectory. No result was verified."
}

$result = Read-StudioResult (Read-StudioOutput $runDirectory) NETWORKING_CPU $runDirectory
$environment | Add-Member -NotePropertyName completedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
$result | Add-Member -NotePropertyName environment -NotePropertyValue $environment
$result | Add-Member -NotePropertyName workload -NotePropertyValue $Workload
$result | ConvertTo-Json -Depth 30 -Compress | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding UTF8

if ($result.success -ne $true) { exit 1 }

Write-Host "__KRF_NETWORKING_CPU_PASS__ Results: $runDirectory"
exit 0
