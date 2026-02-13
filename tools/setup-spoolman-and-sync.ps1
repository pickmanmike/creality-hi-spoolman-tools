<#
.SYNOPSIS
  Setup helper for running Spoolman (Docker) alongside PrintGuard (host port 8000),
  and keeping Spoolman filaments synced from Filament-Sync's material_database.json.

.DESCRIPTION
  - Checks listener ports (default: PrintGuard=8000, Spoolman=7912).
  - Optionally ensures a Spoolman docker-compose.yml exists (persistent ./data storage).
  - Optionally starts/ensures Spoolman via docker compose (only if needed).
  - Optionally runs the Creality->Spoolman filament sync script.
  - Optionally creates:
      * a wrapper BAT for Creality Print post-processing (Filament-Sync then Spoolman sync)
      * a Scheduled Task to run the sync on a schedule
      * Firewall rules (requires admin)

NOTES
  - Designed for Windows + PowerShell 7.x (pwsh)
  - Does NOT install Docker Desktop.
#>

[CmdletBinding()]
param(
  # Spoolman settings
  [int]$SpoolmanHostPort = 7912,
  [string]$SpoolmanUrl = "http://127.0.0.1:7912",  # base URL (NOT /api/v1)
  [string]$SpoolmanImage = "ghcr.io/donkie/spoolman:latest",
  [string]$TimeZone = "America/New_York",

  # PrintGuard settings (port check only)
  [int]$PrintGuardHostPort = 8000,

  # Paths
  [string]$SpoolmanRoot = "$env:USERPROFILE\spoolman",
  [string]$SpoolmanComposeDir = "",  # auto-detect if blank
  [string]$FilamentSyncRoot = "$env:USERPROFILE\Filament-Sync",
  [string]$MaterialDatabasePath = "$env:USERPROFILE\Filament-Sync\data\material_database.json",
  [string]$SyncScriptPath = (Join-Path $PSScriptRoot "sync-creality-materials-to-spoolman-masters.ps1"),

  # Actions
  [switch]$EnsureSpoolmanDocker,
  [switch]$ForceComposeUp,
  [switch]$OverwriteComposeFile,

  [switch]$RunSyncNow,
  [switch]$UpdateExisting,
  [switch]$DryRun,
  [switch]$SkipIfSpoolmanDown,

  [switch]$CreateFilamentSyncWrapperBat,
  [string]$WrapperBatName = "windows-sync-with-spoolman.bat",

  [switch]$CreateScheduledTask,
  [string]$ScheduledTaskName = "Spoolman-CrealityMaterialSync",
  [ValidatePattern('^\d{2}:\d{2}$')]
  [string]$ScheduledTaskTime = "03:07",

  [switch]$EnsureFirewallRules,

  # Diagnostics
  [switch]$ShowDockerMountInfo
)

# ---------- Helpers ----------
function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "[INFO] $msg" }
function Write-Warn($msg) { Write-Warning $msg }

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Assert-FileExists([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Label not found: $Path"
  }
}

function Normalize-SpoolmanBaseUrl([string]$Url) {
  $u = ($Url ?? "").Trim()
  if ([string]::IsNullOrWhiteSpace($u)) { return $u }

  while ($u.EndsWith("/")) { $u = $u.Substring(0, $u.Length - 1) }
  if ($u.ToLower().EndsWith("/api/v1")) {
    $u = $u.Substring(0, $u.Length - "/api/v1".Length)
  }
  return $u
}

function Get-ListenersForPort([int]$Port) {
  $results = @()

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
      foreach ($c in $conns) {
        $procName = $null
        try { $procName = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch {}
        $results += [pscustomobject]@{
          Port = $Port
          PID  = $c.OwningProcess
          Process = $procName
          LocalAddress = $c.LocalAddress
        }
      }
    } catch {}
  }

  if ($results.Count -eq 0) {
    try {
      $lines = netstat -ano | Select-String -Pattern "LISTENING" | Select-String -Pattern "[:.]$Port\s"
      foreach ($l in $lines) {
        $parts = ($l -replace '\s+', ' ').Trim().Split(' ')
        $pid = [int]$parts[-1]
        $procName = $null
        try { $procName = (Get-Process -Id $pid -ErrorAction Stop).ProcessName } catch {}
        $results += [pscustomobject]@{
          Port = $Port
          PID  = $pid
          Process = $procName
          LocalAddress = $parts[1]
        }
      }
    } catch {}
  }

  return $results
}

function Test-SpoolmanInfo([string]$BaseUrl) {
  $base = Normalize-SpoolmanBaseUrl $BaseUrl
  if ([string]::IsNullOrWhiteSpace($base)) { return $null }
  try {
    return Invoke-RestMethod -Method GET -Uri "$base/api/v1/info" -TimeoutSec 5
  } catch {
    return $null
  }
}

function Ensure-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI not found. Install Docker Desktop (or another Docker engine) first."
  }
  try { docker version | Out-Null } catch {
    throw "Docker is installed but doesn't appear to be running. Start Docker Desktop / engine and retry."
  }
}

function Try-DetectComposeDataDir([string]$ComposePath, [string]$ComposeDir) {
  if (-not (Test-Path -LiteralPath $ComposePath)) { return $null }
  try {
    $lines = Get-Content -LiteralPath $ComposePath -ErrorAction Stop

    # Find a line that references the container destination, then walk upward to find host source.
    $destIdx = $null
    for ($i=0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match "/home/app/\.local/share/spoolman") { $destIdx = $i; break }
    }

    if ($null -ne $destIdx) {
      for ($j=$destIdx; $j -ge [Math]::Max(0, $destIdx-12); $j--) {
        $line = $lines[$j].Trim()

        # Long syntax: source: ./data
        if ($line -match '^\s*source:\s*(.+?)\s*$') {
          $src = $matches[1].Trim().Trim('"').Trim("'")
          if ($src.StartsWith("./") -or $src.StartsWith(".\")) {
            return (Join-Path $ComposeDir ($src.Substring(2)))
          }
          return $src
        }

        # Short syntax: - ./data:/home/app/.local/share/spoolman
        if ($line -match '^\s*-\s*(.+?)\s*:/home/app/\.local/share/spoolman\s*$') {
          $src = $matches[1].Trim().Trim('"').Trim("'")
          if ($src.StartsWith("./") -or $src.StartsWith(".\")) {
            return (Join-Path $ComposeDir ($src.Substring(2)))
          }
          return $src
        }
      }
    }
  } catch {}
  return $null
}

function Ensure-SpoolmanCompose([string]$ComposeDir, [int]$HostPort, [string]$Image, [string]$TZ, [switch]$Overwrite) {
  New-Item -ItemType Directory -Force -Path $ComposeDir | Out-Null
  $composePath = Join-Path $ComposeDir "docker-compose.yml"

  if ((Test-Path -LiteralPath $composePath) -and (-not $Overwrite)) {
    Write-Info "docker-compose.yml already exists; leaving it as-is. Use -OverwriteComposeFile to rewrite it."
    return
  }

  if (Test-Path -LiteralPath $composePath) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $composePath -Destination "$composePath.bak.$ts" -Force
    Write-Info "Backed up existing docker-compose.yml to docker-compose.yml.bak.$ts"
  }

  # Compose spec: omit top-level "version:" to avoid warnings in newer docker compose.
  $yaml = @"
services:
  spoolman:
    image: $Image
    restart: unless-stopped
    volumes:
      - type: bind
        source: ./data
        target: /home/app/.local/share/spoolman
    ports:
      - "$HostPort:8000"
    environment:
      - TZ=$TZ
"@

  Set-Content -LiteralPath $composePath -Value $yaml -Encoding utf8NoBOM
  Write-Ok "Wrote $composePath"

  $dataDir = Join-Path $ComposeDir "data"
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  Write-Info "Ensured Spoolman data dir exists: $dataDir"
}

function Start-SpoolmanCompose([string]$ComposeDir) {
  Push-Location $ComposeDir
  try {
    Write-Info "Starting/ensuring Spoolman container via docker compose..."
    docker compose up -d | Out-Host
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
      Write-Warn "docker compose up -d returned exit code $exit. If Spoolman is already reachable, this may be harmless."
    }
  } finally {
    Pop-Location
  }
}

function Ensure-FirewallRule([string]$Name, [int]$Port) {
  if (-not (Test-IsAdmin)) {
    Write-Warn "Not running as Administrator, skipping firewall rule '$Name' for TCP $Port."
    return
  }
  $existing = Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Ok "Firewall rule already exists: $Name"
    return
  }
  New-NetFirewallRule -DisplayName $Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
  Write-Ok "Created firewall rule: $Name (TCP $Port, Private profile)"
}

function Get-ScriptParameterNames([string]$ScriptPath) {
  Assert-FileExists $ScriptPath "Sync script"

  # IMPORTANT: Get-Command does NOT support -LiteralPath.
  # Using -LiteralPath can be reinterpreted positionally (as Name + ArgumentList), causing confusing errors.
  $cmd = Get-Command -Name $ScriptPath -ErrorAction Stop

  if ($cmd -is [System.Array]) {
    $cmd = $cmd | Where-Object { $_.CommandType -eq 'ExternalScript' } | Select-Object -First 1
  }
  if (-not $cmd) {
    throw "Could not resolve sync script as an ExternalScript command: $ScriptPath"
  }
  return @($cmd.Parameters.Keys)
}

function Try-GetSpoolmanContainerMountInfo {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $null }
  try {
    $lines = docker ps --format "{{.ID}}||{{.Image}}||{{.Names}}" 2>$null
    if (-not $lines) { return $null }

    $hit = $lines | Where-Object { $_ -match "spoolman" } | Select-Object -First 1
    if (-not $hit) { return $null }

    $parts = $hit -split "\|\|"
    $id = $parts[0]
    $image = $parts[1]
    $name = $parts[2]

    $inspect = docker inspect $id 2>$null | ConvertFrom-Json
    if (-not $inspect) { return $null }
    $obj = $inspect[0]

    $mount = $obj.Mounts | Where-Object {
      $_.Destination -eq "/home/app/.local/share/spoolman" -or $_.Destination -match "/spoolman$"
    } | Select-Object -First 1

    if (-not $mount) { return [pscustomobject]@{ Id=$id; Image=$image; Name=$name; Mount=$null } }

    return [pscustomobject]@{
      Id=$id; Image=$image; Name=$name;
      MountType=$mount.Type; Source=$mount.Source; Destination=$mount.Destination; VolumeName=$mount.Name
    }
  } catch { return $null }
}

function Invoke-SpoolmanSync {
  param(
    [string]$SyncScript,
    [string]$DbPath,
    [string]$BaseUrl,
    [switch]$DoDryRun,
    [switch]$DoUpdateExisting
  )

  Assert-FileExists $DbPath "material_database.json"
  Assert-FileExists $SyncScript "Sync script"

  $paramNames = Get-ScriptParameterNames $SyncScript

  $syncParams = @{}
  if ($paramNames -contains "MaterialDatabasePath") {
    $syncParams["MaterialDatabasePath"] = $DbPath
  } else {
    throw "Sync script does not expose -MaterialDatabasePath (unexpected)."
  }

  if ($paramNames -contains "SpoolmanUrl") {
    $syncParams["SpoolmanUrl"] = (Normalize-SpoolmanBaseUrl $BaseUrl)
  } else {
    throw "Sync script does not expose -SpoolmanUrl (unexpected)."
  }

  if ($DoDryRun -and ($paramNames -contains "DryRun")) {
    $syncParams["DryRun"] = $true
  }

  if ($DoUpdateExisting) {
    if ($paramNames -contains "UpdateExisting") {
      $syncParams["UpdateExisting"] = $true
    } elseif ($paramNames -contains "UpdateExistingFilaments") {
      $syncParams["UpdateExistingFilaments"] = $true
    }
  }
Write-Info ("Calling sync script with params: " + (($syncParams.Keys | Sort-Object) -join ", "))
  & $SyncScript @syncParams

  if (-not $?) {
    throw "Sync script reported failure."
  }
}

function Create-WrapperBat {
  param(
    [string]$FsRoot,
    [string]$BatName,
    [string]$SetupScriptPath,
    [string]$DbPath,
    [string]$BaseUrl,
    [bool]$DoUpdateExisting
  )

  Assert-FileExists $FsRoot "Filament-Sync folder"
  Assert-FileExists $SetupScriptPath "setup-spoolman-and-sync.ps1"

  $targetBat  = Join-Path $FsRoot $BatName
  $windowsSync = Join-Path $FsRoot "windows-sync.bat"
  $mainJs      = Join-Path $FsRoot "main.js"

  $callFilamentSync = $null
  if (Test-Path -LiteralPath $windowsSync) {
    $callFilamentSync = "call `"$windowsSync`""
  } elseif (Test-Path -LiteralPath $mainJs) {
    $callFilamentSync = "node `"$mainJs`""
  } else {
    throw "Could not find windows-sync.bat or main.js in $FsRoot"
  }

  $updateFlag = ""
  if ($DoUpdateExisting) { $updateFlag = " -UpdateExisting" }

  $bat = @"
@echo off
setlocal EnableExtensions

REM Run Filament-Sync (generates data\material_database.json and uploads to printer)
pushd "%~dp0"
$callFilamentSync
set FS_ERR=%ERRORLEVEL%
popd

if not "%FS_ERR%"=="0" (
  echo [ERROR] Filament-Sync failed with exit code %FS_ERR%
  exit /b %FS_ERR%
)

REM Run Spoolman sync (non-critical: don't block printing if Spoolman is down)
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$SetupScriptPath" -RunSyncNow$updateFlag -SkipIfSpoolmanDown -MaterialDatabasePath "$DbPath" -SpoolmanUrl "$BaseUrl"

exit /b %ERRORLEVEL%
"@

  Set-Content -LiteralPath $targetBat -Value $bat -Encoding ascii
  Write-Ok "Created wrapper: $targetBat"
}

function Ensure-ScheduledSyncTask {
  param(
    [string]$TaskName,
    [string]$AtHHmm,
    [string]$SetupScriptPath,
    [string]$DbPath,
    [string]$BaseUrl,
    [bool]$DoUpdateExisting
  )

  try { Import-Module ScheduledTasks -ErrorAction Stop } catch { throw "ScheduledTasks module not available." }
  Assert-FileExists $SetupScriptPath "setup-spoolman-and-sync.ps1"

  $arg = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$SetupScriptPath`" -RunSyncNow -MaterialDatabasePath `"$DbPath`" -SpoolmanUrl `"$BaseUrl`""
  if ($DoUpdateExisting) { $arg += " -UpdateExisting" }

  $action  = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument $arg
  $atTime  = (Get-Date).Date.Add([TimeSpan]::Parse($AtHHmm))
  $trigger = New-ScheduledTaskTrigger -Daily -At $atTime

  $userId = "$env:USERDOMAIN\$env:USERNAME"
  # Choose a LogonType that exists on this OS/PowerShell (InteractiveToken is not valid everywhere)
  $ltEnum = [Microsoft.PowerShell.Cmdletization.GeneratedTypes.ScheduledTask.LogonTypeEnum]
  $ltNames = [enum]::GetNames($ltEnum)
  $picked = $null
  foreach ($name in @("Interactive","InteractiveOrPassword","Password","S4U","None")) {
    if ($ltNames -contains $name) { $picked = [enum]::Parse($ltEnum, $name); break }
  }
  if (-not $picked) { $picked = [enum]::Parse($ltEnum, "Interactive") }

  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType $picked -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Write-Ok "Scheduled Task created/updated: $TaskName (Daily @ $AtHHmm, runs when user is logged in)"
}

# ---------- Main ----------
Write-Step "Preflight"
Write-Info "PowerShell: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw "Please run this with PowerShell 7+ (pwsh)."
}

# Auto-detect compose directory:
# Prefer C:\Users\User\spoolman\docker-compose.yml (aligns with spoolman\data)
# Fallback to C:\Users\User\spoolman\server\docker-compose.yml
if ([string]::IsNullOrWhiteSpace($SpoolmanComposeDir)) {
  $rootCompose  = Join-Path $SpoolmanRoot "docker-compose.yml"
  $serverCompose = Join-Path (Join-Path $SpoolmanRoot "server") "docker-compose.yml"

  if (Test-Path -LiteralPath $rootCompose) {
    $SpoolmanComposeDir = $SpoolmanRoot
  } elseif (Test-Path -LiteralPath $serverCompose) {
    $SpoolmanComposeDir = Join-Path $SpoolmanRoot "server"
  } else {
    $SpoolmanComposeDir = $SpoolmanRoot
  }
}

# Keep SpoolmanUrl consistent if user changed port but left default URL
if ($SpoolmanUrl -eq "http://127.0.0.1:7912" -and $SpoolmanHostPort -ne 7912) {
  $SpoolmanUrl = "http://127.0.0.1:$SpoolmanHostPort"
}
$SpoolmanUrl = Normalize-SpoolmanBaseUrl $SpoolmanUrl

$composePath = Join-Path $SpoolmanComposeDir "docker-compose.yml"
$dataDirFromCompose = Try-DetectComposeDataDir -ComposePath $composePath -ComposeDir $SpoolmanComposeDir

# Data dir candidates (in priority order)
$dataDirCandidates = @()
if ($dataDirFromCompose) { $dataDirCandidates += $dataDirFromCompose }
$dataDirCandidates += (Join-Path $SpoolmanRoot "data")
$dataDirCandidates += (Join-Path $SpoolmanComposeDir "data")
$dataDirCandidates = $dataDirCandidates | Select-Object -Unique

Write-Info "SpoolmanUrl: $SpoolmanUrl"
Write-Info "SpoolmanHostPort: $SpoolmanHostPort"
Write-Info "PrintGuardHostPort: $PrintGuardHostPort"
Write-Info "ComposeDir: $SpoolmanComposeDir"
Write-Info "ComposeFile: $composePath"
if ($dataDirFromCompose) { Write-Info "Detected data dir from compose: $dataDirFromCompose" }

Write-Step "Port checks"
if ($SpoolmanHostPort -eq $PrintGuardHostPort) {
  throw "Port conflict: both SpoolmanHostPort and PrintGuardHostPort are $SpoolmanHostPort. Pick a different SpoolmanHostPort (e.g. 7912)."
}

$pg = Get-ListenersForPort $PrintGuardHostPort
if ($pg.Count -gt 0) {
  Write-Info "Port $PrintGuardHostPort listeners:"
  $pg | Format-Table -AutoSize | Out-Host
} else {
  Write-Info "No listeners found on port $PrintGuardHostPort."
}

$sm = Get-ListenersForPort $SpoolmanHostPort
if ($sm.Count -gt 0) {
  Write-Info "Port $SpoolmanHostPort listeners:"
  $sm | Format-Table -AutoSize | Out-Host
} else {
  Write-Info "No listeners found on port $SpoolmanHostPort."
}

Write-Step "Spoolman status"
$info = Test-SpoolmanInfo $SpoolmanUrl
if ($info) {
  Write-Ok "Spoolman reachable. Version: $($info.version)"
} else {
  Write-Warn "Spoolman not reachable at $SpoolmanUrl"
}

if ($EnsureSpoolmanDocker) {
  Write-Step "Ensure Spoolman via Docker Compose"
  Ensure-SpoolmanCompose -ComposeDir $SpoolmanComposeDir -HostPort $SpoolmanHostPort -Image $SpoolmanImage -TZ $TimeZone -Overwrite:$OverwriteComposeFile

  $needComposeUp = $ForceComposeUp -or (-not $info)
  if ($needComposeUp) {
    Ensure-Docker
    Start-SpoolmanCompose -ComposeDir $SpoolmanComposeDir

    $deadline = (Get-Date).AddSeconds(45)
    do {
      Start-Sleep -Seconds 2
      $info = Test-SpoolmanInfo $SpoolmanUrl
    } until ($info -or (Get-Date) -gt $deadline)

    if (-not $info) {
      throw "Spoolman still not reachable at $SpoolmanUrl after docker compose up -d"
    }
    Write-Ok "Spoolman up after compose. Version: $($info.version)"
  } else {
    Write-Info "Spoolman already reachable; skipping docker compose up (use -ForceComposeUp to run it anyway)."
  }

  # DB persistence check (best-effort)
  $dbFound = $false
  foreach ($d in $dataDirCandidates) {
    $db = Join-Path $d "spoolman.db"
    if (Test-Path -LiteralPath $db) {
      Write-Ok "Detected Spoolman DB file: $db"
      $dbFound = $true
      break
    }
  }
  if (-not $dbFound) {
    Write-Warn ("Could not find spoolman.db in: " + ($dataDirCandidates -join ", ") +
      ". Spoolman docs recommend confirming your data folder contains spoolman.db to ensure persistence.")
  }

  if ($ShowDockerMountInfo) {
    Write-Step "Docker mount info (diagnostic)"
    Ensure-Docker
    $mi = Try-GetSpoolmanContainerMountInfo
    if ($mi) {
      $mi | Format-List | Out-Host
    } else {
      Write-Warn "Could not detect a running Spoolman container via docker ps/inspect."
    }
  }
}

if ($EnsureFirewallRules) {
  Write-Step "Firewall rules (optional)"
  Ensure-FirewallRule -Name "Allow Spoolman TCP $SpoolmanHostPort (Private)" -Port $SpoolmanHostPort
  Ensure-FirewallRule -Name "Allow PrintGuard TCP $PrintGuardHostPort (Private)" -Port $PrintGuardHostPort
}

if ($RunSyncNow) {
  Write-Step "Run Creality -> Spoolman sync"
  if (-not $info) { $info = Test-SpoolmanInfo $SpoolmanUrl }

  if (-not $info) {
    $msg = "Spoolman not reachable at $SpoolmanUrl; cannot sync."
    if ($SkipIfSpoolmanDown) {
      Write-Warn "$msg Skipping due to -SkipIfSpoolmanDown."
    } else {
      throw $msg
    }
  } else {
    Invoke-SpoolmanSync -SyncScript $SyncScriptPath -DbPath $MaterialDatabasePath -BaseUrl $SpoolmanUrl -DoDryRun:$DryRun -DoUpdateExisting:$UpdateExisting
    Write-Ok "Sync completed."
  }
} else {
  Write-Info "Skipping sync run (use -RunSyncNow to run it)."
}

if ($CreateFilamentSyncWrapperBat) {
  Write-Step "Create Filament-Sync wrapper BAT (post-processing hook)"
  $thisScript = $PSCommandPath
  Create-WrapperBat -FsRoot $FilamentSyncRoot -BatName $WrapperBatName -SetupScriptPath $thisScript -DbPath $MaterialDatabasePath -BaseUrl $SpoolmanUrl -DoUpdateExisting:$UpdateExisting
}

if ($CreateScheduledTask) {
  Write-Step "Create Scheduled Task (daily sync)"
  $thisScript = $PSCommandPath
  Ensure-ScheduledSyncTask -TaskName $ScheduledTaskName -AtHHmm $ScheduledTaskTime -SetupScriptPath $thisScript -DbPath $MaterialDatabasePath -BaseUrl $SpoolmanUrl -DoUpdateExisting:$UpdateExisting
}

Write-Step "Done"
Write-Ok "Setup complete."
Write-Info "Spoolman UI: $SpoolmanUrl"
Write-Info "PrintGuard UI (if running): http://localhost:$PrintGuardHostPort"