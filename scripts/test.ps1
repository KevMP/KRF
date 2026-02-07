$ErrorActionPreference = "Stop"

$ProjectFile = $args[0]
if (-not $ProjectFile) { $ProjectFile = "test.project.json" }

$PlaceFile = $args[1]
if (-not $PlaceFile) { $PlaceFile = "KRF-Tests.rbxl" }

$TestScript = $args[2]
if (-not $TestScript) { $TestScript = "tests/run-tests.luau" }

Write-Host "Building place -> $PlaceFile"
rojo build $ProjectFile -o $PlaceFile

Write-Host "Running tests..."
run-in-roblox --place $PlaceFile --script $TestScript
