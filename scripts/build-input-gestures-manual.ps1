$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $repository "build/input-gestures"
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$place = Join-Path $directory "Input-Gestures-Manual.rbxl"
& rojo build (Join-Path $repository "i2-input-gestures-manual.project.json") -o $place
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Open $place in Studio and press Play (F5). The on-screen panel contains the controls and expected results."
