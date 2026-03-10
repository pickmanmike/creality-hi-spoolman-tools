#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SyncScriptPath,
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    [string]$TaskName = "CrealityHi Safe Slot Sync",
    [int]$EveryMinutes = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SyncScriptPath)) { throw "Sync script not found: $SyncScriptPath" }
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$tr = "$pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$SyncScriptPath`" -ConfigPath `"$ConfigPath`" -UpdateRemainingWeight -Apply"

schtasks /Create /TN "$TaskName" /SC MINUTE /MO $EveryMinutes /TR $tr /F | Out-Null
Write-Host ("Registered scheduled task: {0}" -f $TaskName)
Write-Host ("Command: {0}" -f $tr)
