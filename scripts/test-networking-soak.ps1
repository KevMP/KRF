param([switch]$Smoke, [string]$StudioPath)

# npm can inherit a PowerShell 7 module path. Windows PowerShell must load its
# own utility/CIM modules rather than the incompatible first match on that path.
$env:PSModulePath = "$PSHOME\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility" -Force

# One uninterrupted server/two-client session. Results use the existing ignored
# build/networking-baseline/<run>/ layout, provenance and host process monitor.
& "$PSScriptRoot\test-networking-baseline.ps1" -Workload Soak -ClientCount 2 -Records 128 `
    -SoakSmoke:$Smoke -StudioPath $StudioPath -TimeoutSeconds $(if ($Smoke) { 240 } else { 3000 })
exit $LASTEXITCODE
