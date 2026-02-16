#requires -Version 5.1
<#
.SYNOPSIS
  Wrapper to run sync-cfs-slots-to-spoolman.ps1 with stable logging + overlap protection.

.DESCRIPTION
  - Creates a per-run log file under <repo>\logs\
  - Appends a one-line summary to <repo>\logs\cfs-slot-sync_status.log
  - Uses a named mutex to prevent overlapping runs (Task Scheduler friendly)
  - Passes common switches through to the main sync script

.NOTES
  - Works in Windows PowerShell 5.1 and PowerShell 7+.
  - Recommended Task Scheduler action:
      Program/script:  pwsh.exe
      Arguments:       -NoLogo -NoProfile -ExecutionPolicy Bypass -File "...\tools\run-cfs-slot-sync.ps1"
      Start in:        ...\tools
#>

[CmdletBinding()]
param(
  # Path to the bridge config (default: ..\config\cfs-spoolman-bridge.json)
  [Parameter(Mandatory = $false)]
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSCommandPath) "..\config\cfs-spoolman-bridge.json"),

  # Path to the main sync script (default: tools\sync-cfs-slots-to-spoolman.ps1)
  [Parameter(Mandatory = $false)]
  [string]$SyncScriptPath = (Join-Path (Split-Path -Parent $PSCommandPath) "sync-cfs-slots-to-spoolman.ps1"),

  # Folder where logs are stored (default: ..\logs)
  [Parameter(Mandatory = $false)]
  [string]$LogDir = (Join-Path (Split-Path -Parent $PSCommandPath) "..\logs"),

  # Keep the most recent N run logs (0 disables count-based retention)
  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 10000)]
  [int]$KeepLogs = 30,

  # Also delete logs older than N days (0 disables age-based retention)
  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 3650)]
  [int]$KeepDays = 14,

  # Named mutex for overlap protection ("Local\" is safest for non-admin scheduled tasks)
  [Parameter(Mandatory = $false)]
  [string]$MutexName = "Local\CFS-Spoolman-SlotSync",

  # Pass-through switches (mirrors sync-cfs-slots-to-spoolman.ps1)
  [switch]$DryRun,
  [switch]$VerboseSlots,
  [switch]$UpdateRemainingWeight,
  [switch]$ClearMissing,
  [switch]$ContinueOnPrinterError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-Count([object]$Items) {
  # Guarantees array context so .Count is safe even when there is 0 or 1 item.
  return @($Items).Count
}

function Ensure-Directory([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Try-ResolvePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  try {
    if (Test-Path -LiteralPath $Path) {
      return (Resolve-Path -LiteralPath $Path).Path
    }
  } catch {}
  return $Path
}

function Rotate-Logs([string]$Dir, [int]$Keep, [int]$KeepDaysLocal) {
  if (-not (Test-Path -LiteralPath $Dir)) { return }

  $pattern = 'cfs-slot-sync_*.log'
  $logs = Get-ChildItem -LiteralPath $Dir -File -Filter $pattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

  # Age-based retention
  if ($KeepDaysLocal -gt 0) {
    $cutoff = (Get-Date).AddDays(-$KeepDaysLocal)
    foreach ($f in @($logs | Where-Object { $_.LastWriteTime -lt $cutoff })) {
      try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch {}
    }

    # Refresh after deletions
    $logs = Get-ChildItem -LiteralPath $Dir -File -Filter $pattern -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending
  }

  # Count-based retention
  if ($Keep -gt 0) {
    $logCount = Get-Count $logs
    if ($logCount -gt $Keep) {
      foreach ($f in @($logs | Select-Object -Skip $Keep)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch {}
      }
    }
  }
}

# Resolve paths early (nice for status output)
$ConfigPath     = Try-ResolvePath $ConfigPath
$SyncScriptPath = Try-ResolvePath $SyncScriptPath
$LogDir         = Try-ResolvePath $LogDir

Ensure-Directory -Path $LogDir
Rotate-Logs -Dir $LogDir -Keep $KeepLogs -KeepDaysLocal $KeepDays

$statusPath = Join-Path $LogDir 'cfs-slot-sync_status.log'

function Write-Status([string]$msg) {
  "{0} {1}" -f (Get-Date -Format o), $msg | Out-File -FilePath $statusPath -Append -Encoding utf8
}

# --- Overlap protection (mutex) ---
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$hasMutex = $false

try {
  $hasMutex = $mutex.WaitOne(0)
  if (-not $hasMutex) {
    Write-Status "SKIP already-running mutex=$MutexName"
    exit 0
  }

  # If the canonical script name isn't present, fall back to the newest matching file.
  if (-not (Test-Path -LiteralPath $SyncScriptPath)) {
    $toolsDir = Split-Path -Parent $PSCommandPath
    $candidate = Get-ChildItem -LiteralPath $toolsDir -File -Filter 'sync-cfs-slots-to-spoolman*.ps1' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($candidate) { $SyncScriptPath = $candidate.FullName }
  }

  if (-not (Test-Path -LiteralPath $SyncScriptPath)) {
    throw "Main sync script not found: $SyncScriptPath"
  }
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath (copy config\\cfs-spoolman-bridge.example.json to config\\cfs-spoolman-bridge.json and edit it)"
  }

  # Unique log name
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
  $runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $logPath = Join-Path $LogDir "cfs-slot-sync_${stamp}_${runId}.log"

  # Header
  Write-Status "START pid=$PID user=$env:USERNAME computer=$env:COMPUTERNAME log=$logPath"
  "START $(Get-Date -Format o)" | Out-File -FilePath $logPath -Append -Encoding utf8
  "User=$env:USERNAME  Computer=$env:COMPUTERNAME  PWD=$PWD" | Out-File -FilePath $logPath -Append -Encoding utf8
  "PSVersion=$($PSVersionTable.PSVersion)  Edition=$($PSVersionTable.PSEdition)" | Out-File -FilePath $logPath -Append -Encoding utf8
  "ConfigPath=$ConfigPath" | Out-File -FilePath $logPath -Append -Encoding utf8
  "SyncScriptPath=$SyncScriptPath" | Out-File -FilePath $logPath -Append -Encoding utf8
  "---- BEGIN OUTPUT ----" | Out-File -FilePath $logPath -Append -Encoding utf8

  # Build args for the main script
  $args = @('-ConfigPath', $ConfigPath)
  if ($DryRun)                 { $args += '-DryRun' }
  if ($VerboseSlots)           { $args += '-VerboseSlots' }
  if ($UpdateRemainingWeight)  { $args += '-UpdateRemainingWeight' }
  if ($ClearMissing)           { $args += '-ClearMissing' }
  if ($ContinueOnPrinterError) { $args += '-ContinueOnPrinterError' }

  try {
    # Capture *all* streams into the log. (See about_Redirection in PowerShell docs.)
    & $SyncScriptPath @args *>&1 | Out-File -FilePath $logPath -Append -Encoding utf8

    "---- END OUTPUT ----" | Out-File -FilePath $logPath -Append -Encoding utf8
    "SUCCESS $(Get-Date -Format o)" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Status "SUCCESS log=$logPath"
    exit 0
  }
  catch {
    "---- END OUTPUT (ERROR) ----" | Out-File -FilePath $logPath -Append -Encoding utf8
    "ERROR $(Get-Date -Format o)" | Out-File -FilePath $logPath -Append -Encoding utf8
    $_ | Format-List -Force | Out-String | Out-File -FilePath $logPath -Append -Encoding utf8

    Write-Status "FAIL log=$logPath err=$($_.Exception.Message)"
    exit 1
  }
}
finally {
  if ($hasMutex) {
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
  }
  try { $mutex.Dispose() } catch {}
}
