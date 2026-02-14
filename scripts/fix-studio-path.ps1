# Find newest version folder that actually has RobloxStudioBeta.exe
$version = Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions" -Directory |
  Where-Object { Test-Path (Join-Path $_.FullName "RobloxStudioBeta.exe") } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $version) { throw "Could not find a Roblox Studio version folder with RobloxStudioBeta.exe" }

$contentFolder = (Join-Path $version.FullName "content") + "\"

Set-ItemProperty "HKCU:\Software\Roblox\RobloxStudio" -Name ContentFolder -Value $contentFolder

Write-Host "Updated ContentFolder -> $contentFolder"
