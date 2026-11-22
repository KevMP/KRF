function Resolve-TestStudio([string]$Repository, [string]$StudioPath) {
    if (-not $StudioPath) {
        $StudioPath = & (Join-Path $Repository 'scripts/fix-studio-path.ps1') -ResolveOnly
    }

    (Resolve-Path -LiteralPath $StudioPath).Path
}

function Write-MultiplayerLauncher(
    [string]$Destination,
    [string]$TestName,
    [string]$Marker,
    [int]$ClientCount = 2,
    [string]$ResultBlock,
    [switch]$PassClientOptions,
    [switch]$SoakSmoke
) {
    $arguments = ConvertTo-Json -InputObject $TestName -Compress

    if ($PassClientOptions) {
        $smoke = ([bool]$SoakSmoke).ToString().ToLowerInvariant()
        $arguments = "{ testName = $arguments, clientCount = $ClientCount, soakSmoke = $smoke }"
    }

    $block = if ($ResultBlock) { ConvertTo-Json -InputObject $ResultBlock -Compress } else { 'nil' }

    $markerLiteral = ConvertTo-Json -InputObject $Marker -Compress
    $launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Multiplayer.luau') -Raw

    # RunScript takes a standalone script. Keep each run's arguments with its logs.
    $source = "--!strict" + [Environment]::NewLine + "local run = (function()" + [Environment]::NewLine +
        $launcher + [Environment]::NewLine + "end)()" + [Environment]::NewLine +
        "run($ClientCount, $arguments, $markerLiteral, $block)" + [Environment]::NewLine + 'return nil'

    [System.IO.File]::WriteAllText($Destination, $source, [System.Text.UTF8Encoding]::new($false))
}

function Start-TestStudio([string]$StudioPath, [string]$PlaceFile, [string]$ScriptFile, [string]$RunDirectory) {
    # RunScript executes in Edit mode with Command Bar permissions.
    $studioArguments = @(
        '--task', 'RunScript',
        '--localPlaceFile', ('"' + $PlaceFile + '"'),
        '--runScriptFile', ('"' + $ScriptFile + '"'),
        '--outputFile', ('"' + (Join-Path $RunDirectory 'result.log') + '"'),
        '--quitAfterExecution'
    )

    Start-Process -FilePath $StudioPath -ArgumentList $studioArguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $RunDirectory 'studio.stdout.log') `
        -RedirectStandardError (Join-Path $RunDirectory 'studio.stderr.log')
}

function Wait-TestStudio([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds) {
    if ($Process.WaitForExit($TimeoutSeconds * 1000)) { return $true }

    Stop-Process -Id $Process.Id -ErrorAction SilentlyContinue

    return $false
}

function Read-StudioOutput([string]$RunDirectory) {
    $outputFile = Join-Path $RunDirectory 'result.log'

    if (Test-Path -LiteralPath $outputFile) {
        return [string](Get-Content -LiteralPath $outputFile -Raw)
    }

    return ''
}

function Read-StudioResult([string]$OutputText, [string]$Marker, [string]$RunDirectory) {
    # Studio echoes the launcher source, so match only complete output lines.
    $prefix = '__KRF_' + $Marker
    $pattern = '(?ms)^' + $prefix + '_START__\r?\n(.*?)^' + $prefix + '_END__\r?$'
    $block = [regex]::Match($OutputText, $pattern)

    if (-not $block.Success) { throw "Studio produced no complete $Marker result. Inspect $RunDirectory." }

    (($block.Groups[1].Value -split '\r?\n') -join '') | ConvertFrom-Json
}
