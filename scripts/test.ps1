$ErrorActionPreference = "Stop"

$ProjectFile = $args[0]
if (-not $ProjectFile) { $ProjectFile = "test.project.json" }

$PlaceFile = $args[1]
if (-not $PlaceFile) { $PlaceFile = "KRF-Tests.rbxl" }

$TestScript = $args[2]
if (-not $TestScript) { $TestScript = "tests/run-tests.luau" }

$CoverageOutput = $args[3]
if (-not $CoverageOutput) { $CoverageOutput = "coverage/coverage-final.json" }

$CoverageStartMarker = "__KRF_COVERAGE_START__"
$CoverageEndMarker = "__KRF_COVERAGE_END__"
$RobloxPluginsDirectory = Join-Path $env:LOCALAPPDATA "Roblox\Plugins"

Write-Host "Fixing Roblox Studio content path..."
& "$PSScriptRoot\fix-studio-path.ps1"

if (-not (Test-Path -LiteralPath $RobloxPluginsDirectory)) {
	Write-Host "Creating Roblox plugins directory..."
	New-Item -ItemType Directory -Force -Path $RobloxPluginsDirectory | Out-Null
}

Write-Host "Building place -> $PlaceFile"
rojo build $ProjectFile -o $PlaceFile

Write-Host "Running tests..."
$runOutput = run-in-roblox --place $PlaceFile --script $TestScript 2>&1
$exitCode = $LASTEXITCODE

if ($runOutput) {
	$printingCoverageBlock = $false
	foreach ($line in $runOutput) {
		$text = $line.ToString()
		if ($text -eq $CoverageStartMarker) {
			$printingCoverageBlock = $true
			Write-Host "[coverage] Captured Istanbul payload from Roblox test run."
			continue
		}

		if ($text -eq $CoverageEndMarker) {
			$printingCoverageBlock = $false
			continue
		}

		if (-not $printingCoverageBlock) {
			Write-Host $text
		}
	}
}

$joinedOutput = ($runOutput | ForEach-Object { $_.ToString() }) -join "`n"
$coveragePattern = [regex]::Escape($CoverageStartMarker) + "`r?`n(?<json>\{.*?\})`r?`n" + [regex]::Escape($CoverageEndMarker)
$coverageMatch = [regex]::Match($joinedOutput, $coveragePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

if ($coverageMatch.Success) {
	$coverageDirectory = Split-Path -Parent $CoverageOutput
	if ($coverageDirectory) {
		New-Item -ItemType Directory -Force -Path $coverageDirectory | Out-Null
	}

	$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($CoverageOutput, $coverageMatch.Groups["json"].Value, $utf8NoBom)
	Write-Host "Coverage report written -> $CoverageOutput"
} else {
	Write-Warning "Coverage markers were not found in test output."
}

exit $exitCode
