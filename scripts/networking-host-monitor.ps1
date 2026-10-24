# Native Studio process-tree telemetry. Sampling runs in the launcher process;
# no resident service or unrelated Studio process is controlled.
function Wait-NetworkingStudio([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds, [int]$LogicalProcessors) {
    $known = @{}
    $known[$Process.Id] = $true
    $previous = @{}
    $samples = [System.Collections.Generic.List[object]]::new()
    $started = [DateTime]::UtcNow
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $monitorCpu = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds
    $monitorAt = $started
    while (-not $Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $sampleStart = [DateTime]::UtcNow
        $nativeProcesses = @(Get-CimInstance Win32_Process -Filter "Name='RobloxStudioBeta.exe'")
        # Resolve descendants repeatedly because CIM enumeration order is unspecified.
        do {
            $added = $false
            foreach ($native in $nativeProcesses) {
                if ($known.ContainsKey([int]$native.ParentProcessId) -and -not $known.ContainsKey([int]$native.ProcessId)) {
                    $known[[int]$native.ProcessId] = $true
                    $added = $true
                }
            }
        } while ($added)
        $processSamples = @(
            foreach ($native in $nativeProcesses) {
                $processId = [int]$native.ProcessId
                if (-not $known.ContainsKey($processId)) { continue }
                $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if (-not $live) { continue }
                $cpuSeconds = $live.TotalProcessorTime.TotalSeconds
                $now = [DateTime]::UtcNow
                $cores = $null
                if ($previous.ContainsKey($processId)) {
                    $elapsed = ($now - $previous[$processId].at).TotalSeconds
                    if ($elapsed -gt 0) { $cores = ($cpuSeconds - $previous[$processId].cpu) / $elapsed }
                }
                $previous[$processId] = @{ at = $now; cpu = $cpuSeconds }
                [pscustomobject]@{
                    processId = $processId
                    parentProcessId = [int]$native.ParentProcessId
                    creationDate = $native.CreationDate.ToUniversalTime().ToString('o')
                    commandLine = $native.CommandLine
                    isLauncher = $processId -eq $Process.Id
                    role = if ($native.CommandLine -match '-task StartServer\b') { 'server' } elseif ($native.CommandLine -match '-task StartClient\b') { 'client' } elseif ($processId -eq $Process.Id) { 'launcher' } else { 'unknown' }
                    instance = if ($native.CommandLine -match '-instanceId (\S+)') { $Matches[1] } else { 'Edit' }
                    cpuCores = $cores
                    machineCpuPercent = if ($null -ne $cores) { 100 * $cores / $LogicalProcessors } else { $null }
                    workingSetMiB = $live.WorkingSet64 / 1MB
                    privateMiB = $live.PrivateMemorySize64 / 1MB
                }
            }
        )
        $cpu = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor)
        $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $monitorNow = [DateTime]::UtcNow
        $monitorNextCpu = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds
        $samples.Add([pscustomobject]@{
            unixMs = [DateTimeOffset]::new($sampleStart).ToUnixTimeMilliseconds()
            hostCpuPercent = ($cpu | Where-Object Name -eq '_Total').PercentProcessorTime
            maxLogicalCpuPercent = ($cpu | Where-Object Name -ne '_Total' | Measure-Object PercentProcessorTime -Maximum).Maximum
            availableMiB = $memory.AvailableMBytes
            committedPercent = $memory.PercentCommittedBytesInUse
            pagesInputPerSec = $memory.PagesInputPersec
            sampleCostMs = ([DateTime]::UtcNow - $sampleStart).TotalMilliseconds
            monitorCpuCores = ($monitorNextCpu - $monitorCpu) / ($monitorNow - $monitorAt).TotalSeconds
            processes = $processSamples
        })
        $monitorCpu = $monitorNextCpu
        $monitorAt = $monitorNow
        $remaining = 1000 - ([DateTime]::UtcNow - $sampleStart).TotalMilliseconds
        if ($remaining -gt 0) { $null = $Process.WaitForExit([int]$remaining) }
        $Process.Refresh()
    }
    $timedOut = -not $Process.HasExited
    if ($timedOut) {
        # Stop only still-live descendants identified above, then the launcher.
        foreach ($native in @(Get-CimInstance Win32_Process -Filter "Name='RobloxStudioBeta.exe'")) {
            if ($known.ContainsKey([int]$native.ProcessId)) {
                Stop-Process -Id $native.ProcessId -ErrorAction SilentlyContinue
            }
        }
    }
    return [pscustomobject]@{
        timedOut = $timedOut
        intervalTargetMs = 1000
        logicalProcessors = $LogicalProcessors
        samples = $samples.ToArray()
    }
}
