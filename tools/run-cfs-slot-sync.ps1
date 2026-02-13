<#
.SYNOPSIS
  Wrapper to run sync-cfs-slots-to-spoolman.ps1 with sane logging + overlap protection.

.DESCRIPTION
  - Creates a log file per run (Start-Transcript)
  - Keeps last N logs
  - Uses a named mutex to prevent overlapping runs (useful for Task Scheduler)

NOTES
  - Works in Windows PowerShell 5.1 and PowerShell 7+.
  - This wrapper is optional: you can also schedule sync-cfs-slots-to-spoolman.ps1 directly.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSCommandPath) "..\config\cfs-spoolman-bridge.json"),

  [Parameter(Mandatory = $false)]
  [string]$SyncScriptPath = (Join-Path (Split-Path -Parent $PSCommandPath) "sync-cfs-slots-to-spoolman.ps1"),

  [Parameter(Mandatory = $false)]
  [string]$LogDir = (Join-Path (Split-Path -Parent $PSCommandPath) "..\logs"),

  [Parameter(Mandatory = $false)]
  [int]$KeepLogs = 30,

  [switch]$DryRun,
  [switch]$VerboseSlots,
  [switch]$UpdateRemainingWeight,
  [switch]$ClearMissing,
  [switch]$ContinueOnPrinterError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Rotate-Logs([string]$Dir, [int]$Keep) {
  if ($Keep -le 0) { return }
  if (-not (Test-Path -LiteralPath $Dir)) { return }

  $logs = Get-ChildItem -LiteralPath $Dir -Filter 'cfs-slot-sync_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

  if ($logs.Count -le $Keep) { return }

  $toDelete = $logs | Select-Object -Skip $Keep
  foreach ($f in $toDelete) {
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch {}
  }
}

# --- overlap protection (mutex) ---
$mutexName = "CFS-Spoolman-SlotSync"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$hasMutex = $false

try {
  $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(0))
  if (-not $hasMutex) {
    Write-Host "[INFO] Another instance is already running. Exiting."
    exit 0
  }

  Ensure-Directory $LogDir
  Rotate-Logs -Dir $LogDir -Keep $KeepLogs

  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $logPath = Join-Path $LogDir ("cfs-slot-sync_{0}.log" -f $stamp)

  # Start-Transcript exists in 5.1+, but -UseMinimalHeader is 7+.
  $st = Get-Command Start-Transcript -ErrorAction Stop
  if ($st.Parameters.ContainsKey("UseMinimalHeader")) {
    Start-Transcript -Path $logPath -UseMinimalHeader -Force | Out-Null
  } else {
    Start-Transcript -Path $logPath -Force | Out-Null
  }

  try {
    if (-not (Test-Path -LiteralPath $SyncScriptPath)) { throw "SyncScriptPath not found: $SyncScriptPath" }
    if (-not (Test-Path -LiteralPath $ConfigPath))     { throw "ConfigPath not found: $ConfigPath" }

    $args = @("-ConfigPath", $ConfigPath)
    if ($DryRun)                 { $args += "-DryRun" }
    if ($VerboseSlots)           { $args += "-VerboseSlots" }
    if ($UpdateRemainingWeight)  { $args += "-UpdateRemainingWeight" }
    if ($ClearMissing)           { $args += "-ClearMissing" }
    if ($ContinueOnPrinterError) { $args += "-ContinueOnPrinterError" }

    Write-Host "[INFO] Running: $SyncScriptPath $($args -join ' ')"
    & $SyncScriptPath @args
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Sync script exited with code $code" }
  }
  finally {
    Stop-Transcript | Out-Null
  }
}
catch {
  try { Write-Error $_ } catch {}
  exit 1
}
finally {
  if ($hasMutex) { $mutex.ReleaseMutex() | Out-Null }
  $mutex.Dispose()
}
