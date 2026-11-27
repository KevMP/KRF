param(
    [Parameter(Mandatory)][string]$Suite,
    [string]$StudioPath,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
. "$PSScriptRoot\Studio.ps1"

$suites = @{
    i1 = @{ Project = 'i1-input'; TestName = 'KRFI1Input'; Place = 'Input' }
    i2 = @{ Project = 'i2-input-gestures'; TestName = 'KRFI2InputGestures'; Place = 'InputGestures' }
    i3 = @{ Project = 'i3-input-sequences'; TestName = 'KRFI3InputSequences'; Place = 'InputSequences' }
    i4 = @{ Project = 'i4-action-routes'; TestName = 'KRFI4ActionRoutes'; Place = 'ActionRoutes' }
    i5 = @{ Project = 'i5-action-requests'; TestName = 'KRFI5ActionRequests'; Place = 'ActionRequests' }
    i6 = @{ Project = 'i6-action-input'; TestName = 'KRFI6ActionInput'; Place = 'ActionInput' }
    i7 = @{ Project = 'i7-controls'; TestName = 'KRFI7Controls'; Place = 'Controls' }
    i8 = @{ Project = 'i8-action-observations'; TestName = 'KRFI8ActionObservations'; Place = 'ActionObservations' }
    'n4-association' = @{ Project = 'n4-association'; TestName = 'KRFN4Association'; Place = 'N4Association' }
    n5 = @{ Project = 'n5-actor-view'; TestName = 'KRFN5ActorViews'; Place = 'ActorViews' }
    n6 = @{ Project = 'n6-tags-view'; TestName = 'KRFN6TagsView'; Place = 'TagsView' }
    n7 = @{ Project = 'n7-resources-view'; TestName = 'KRFN7ResourcesView'; Place = 'ResourcesView' }
    n8 = @{ Project = 'n8-actions-view'; TestName = 'KRFN8ActionsView'; Place = 'ActionsView' }
    n9 = @{ Project = 'n9-command'; TestName = 'KRFN9Commands'; Place = 'Commands' }
    presentation = @{ Project = 'presentation'; TestName = 'KRFPresentation'; Place = 'Presentation' }
    'presentation-prediction' = @{ Project = 'presentation-prediction'; TestName = 'KRFPresentationPrediction'; Place = 'PresentationPrediction' }
    'presentation-animations' = @{ Project = 'presentation-animations'; TestName = 'KRFPresentationAnimations'; Place = 'PresentationAnimations' }
    networking = @{ Project = 'networking'; TestName = 'KRFNetworking'; Place = 'Networking' }
}

$config = $suites[$Suite]

if (-not $config) { throw "Unknown native suite '$Suite'. Choose from $($suites.Keys | Sort-Object)." }

$StudioPath = Resolve-TestStudio $repository $StudioPath
$runDirectory = Join-Path $repository ("build/$($Suite.ToLowerInvariant())-native/" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$placeFile = Join-Path $runDirectory ($config.Place + '.rbxl')
$launcherFile = Join-Path $runDirectory 'launcher.luau'
$marker = $Suite.ToUpperInvariant().Replace('-', '_')
Write-MultiplayerLauncher -Destination $launcherFile -TestName $config.TestName -Marker $marker

Write-Host "Building native two-client $Suite fixture..."
$project = Join-Path $PSScriptRoot ('../projects/' + $config.Project + '-test.project.json')
& rojo build $project -o $placeFile

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Running Studio. Logs: $runDirectory"
$studioProcess = Start-TestStudio $StudioPath $placeFile $launcherFile $runDirectory

if (-not (Wait-TestStudio $studioProcess $TimeoutSeconds)) {
    [Console]::Error.WriteLine("Native $Suite launcher timed out. Inspect $runDirectory. No test result was verified.")
    exit 2
}

$outputText = Read-StudioOutput $runDirectory
$resultPattern = '(?m)^__KRF_NATIVE_' + $marker + '_(PASS|FAIL)__ (\{[^\r\n]*\})\r?$'
$resultLine = [regex]::Match($outputText, $resultPattern)

if ($resultLine.Success) {
    Write-Host $resultLine.Value
    $result = $resultLine.Groups[2].Value | ConvertFrom-Json

    if ($resultLine.Groups[1].Value -eq 'PASS' -and $result.success -eq $true) { exit 0 }

    if ($resultLine.Groups[1].Value -eq 'FAIL' -and $result.success -eq $false) { exit 1 }
}

[Console]::Error.WriteLine("Studio produced no valid native $Suite result marker. Inspect $runDirectory.")
exit 2
