param([switch]$ResolveOnly)

$ErrorActionPreference = "Stop"
$registeredKey = Get-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\roblox-studio\shell\open\command" -ErrorAction SilentlyContinue
$studioExecutable = $null

if ($registeredKey) {
    $registeredCommand = [string]$registeredKey.GetValue("")
    $commandMatch = [regex]::Match($registeredCommand, '^(?:"(?<path>[^"]+)"|(?<path>.+?\.exe))(?:\s|$)')
    if (-not $commandMatch.Success) { throw "Could not parse the registered Roblox Studio executable." }
    $studioExecutable = Get-Item -LiteralPath $commandMatch.Groups["path"].Value
} else {
    $studioExecutable = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Roblox\Versions") -Directory |
        ForEach-Object {
            $executable = Join-Path $_.FullName "RobloxStudioBeta.exe"
            if ((Test-Path -LiteralPath $executable -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName "AppSettings.xml") -PathType Leaf)) {
                Get-Item -LiteralPath $executable
            }
        } |
        Sort-Object { [version]($_.VersionInfo.FileVersion -replace ',\s*', '.') } -Descending |
        Select-Object -First 1
}

if (-not $studioExecutable) { throw "Could not find a complete Roblox Studio installation." }
$studioDirectory = $studioExecutable.Directory.FullName
$settingsFile = Join-Path $studioDirectory "AppSettings.xml"
if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
    throw "Roblox Studio installation is incomplete: $settingsFile is missing. Registry was not changed."
}
$settings = [xml](Get-Content -LiteralPath $settingsFile -Raw)
$configuredContent = [string]$settings.Settings.ContentFolder
if ([string]::IsNullOrWhiteSpace($configuredContent)) { throw "Studio AppSettings.xml has no ContentFolder." }
$contentFolder = if ([System.IO.Path]::IsPathRooted($configuredContent)) {
    $configuredContent
} else {
    Join-Path $studioDirectory $configuredContent
}
if (-not (Test-Path -LiteralPath $contentFolder -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $studioDirectory "PlatformContent") -PathType Container)) {
    throw "Roblox Studio content directories are missing. Registry was not changed."
}
$contentFolder = (Resolve-Path -LiteralPath $contentFolder).Path.TrimEnd('\') + "\"

if ($ResolveOnly) {
    Write-Output $studioExecutable.FullName
    return
}

Set-ItemProperty -LiteralPath "HKCU:\Software\Roblox\RobloxStudio" -Name ContentFolder -Value $contentFolder
Write-Host "Updated ContentFolder -> $contentFolder"
