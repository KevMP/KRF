function Get-NetworkingBenchmarkEnvironment([string]$Repository, [string]$StudioPath, [string]$SourceDirectory = (Join-Path $Repository 'src')) {
    $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $revision = & git -c "safe.directory=$Repository" -C $Repository rev-parse HEAD
    $harnessFiles = @(
        'tests/benchmarks/NetworkingBaseline.luau',
        'tests/benchmarks/NetworkingAudit.luau',
        'tests/integration/NetworkingBaseline/Server.server.luau',
        'tests/integration/NetworkingBaseline/Client.client.luau',
        'tests/integration/NetworkingBaseline/Utils/Scenario.luau',
        'tests/integration/NetworkingBaseline/Utils/Probe.luau',
        'networking-baseline-test.project.json',
        'test.project.json',
        'rokit.toml'
        'scripts/test-networking-baseline.ps1'
        'scripts/run-networking-baseline-tests.luau'
        'scripts/networking-host-monitor.ps1'
    )
    $hashes = [ordered]@{}
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    foreach ($relativePath in $harnessFiles) {
        $digest = $algorithm.ComputeHash([System.IO.File]::ReadAllBytes((Join-Path $Repository $relativePath)))
        $hashes[$relativePath] = [System.BitConverter]::ToString($digest).Replace('-', '')
    }
    $algorithm.Dispose()
    $sourceHashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.luau' -Recurse) {
        $relative = 'src/' + $file.FullName.Substring($SourceDirectory.Length + 1).Replace('\', '/')
        $sourceHashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return [pscustomobject]@{
        cpu = $processor.Name
        physicalCores = $processor.NumberOfCores
        logicalProcessors = $processor.NumberOfLogicalProcessors
        physicalMemoryGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
        os = $operatingSystem.Caption
        osVersion = $operatingSystem.Version
        studioFileVersion = (Get-Item -LiteralPath $StudioPath).VersionInfo.FileVersion
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        implementationRevision = "$revision"
        harnessSHA256 = $hashes
        sourceSHA256 = $sourceHashes
    }
}
