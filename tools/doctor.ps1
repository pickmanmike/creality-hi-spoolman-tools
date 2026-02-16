#requires -Version 5.1
<#
.SYNOPSIS
  Environment diagnostics for Creality Hi Spoolman Tools (PowerShell).

.DESCRIPTION
  Runs a set of local sanity checks to help catch common “works on my machine” issues:

  - PowerShell version / feature compatibility (especially Windows PowerShell 5.1 vs PowerShell 7+)
  - Execution Policy & file blocking (Zone.Identifier)
  - Repo layout / expected files
  - Spoolman reachability (REST API)
  - Optional: Docker availability (for local Spoolman)
  - Optional: SSH availability / basic connectivity (for Creality Hi slot sync)
  - Optional: Filament-Sync material_database.json presence

  Output:
    - A human-readable table
    - Optional JSON report file (use -ReportPath)

.NOTES
  - Safe by default: no changes are made unless you pass -Fix.
  - Exit codes:
      0 = OK (no FAIL/WARN)
      1 = WARN only
      2 = FAIL present

.EXAMPLE
  # From repo root (recommended: PowerShell 7+)
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1

.EXAMPLE
  # Validate config + test SSH TCP connectivity to printers
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1 -ConfigPath .\config\cfs-spoolman-bridge.json -TestSsh

.EXAMPLE
  # Also validate Filament-Sync output file
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1 -MaterialDatabasePath "$env:USERPROFILE\Filament-Sync\data\material_database.json"

.EXAMPLE
  # Write a JSON report for issue reports
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\doctor.ps1 -ReportPath .\logs
#>

[CmdletBinding()]
param(
  # Repo root. If omitted, we assume this script lives under <repo>\tools and auto-detect.
  [Parameter(Mandatory = $false)]
  [string]$RepoRoot,

  # Bridge config used by CFS slot sync.
  [Parameter(Mandatory = $false)]
  [string]$ConfigPath,

  # Spoolman base URL, e.g. http://127.0.0.1:7912
  [Parameter(Mandatory = $false)]
  [string]$SpoolmanUrl,

  # Path to Filament-Sync material_database.json.
  [Parameter(Mandatory = $false)]
  [string]$MaterialDatabasePath,

  # Also check Docker tooling (useful if you host Spoolman locally).
  [switch]$CheckDocker,

  # Try lightweight connectivity tests to printers in config (no credentials required).
  [switch]$TestSsh,

  # Apply safe fixes (copy example config if missing, create folders, unblock files).
  [switch]$Fix,

  # Write a JSON report (helpful for bug reports).
  [Parameter(Mandatory = $false)]
  [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Helpers
# -----------------------------
$script:Results = @()

function Add-Result {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][ValidateSet('OK','WARN','FAIL','INFO')][string]$Status,
    [Parameter(Mandatory = $true)][string]$Details,
    [string]$FixHint = ''
  )

  $script:Results += [pscustomobject]@{
    Name    = $Name
    Status  = $Status
    Details = $Details
    FixHint = $FixHint
  }
}

function Try-GetCommand([string]$Command) {
  try { return (Get-Command $Command -ErrorAction Stop) } catch { return $null }
}

function Try-GetCommandPath([string]$Command) {
  $cmd = Try-GetCommand $Command
  if ($null -eq $cmd) { return $null }
  return $cmd.Source
}

function Ensure-Directory([string]$Path) {
  if (-not $Path) { return }
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Normalize-BaseUrl([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  $u = $Url.Trim()
  while ($u.EndsWith('/')) { $u = $u.Substring(0, $u.Length - 1) }
  if ($u.ToLowerInvariant().EndsWith('/api/v1')) {
    $u = $u.Substring(0, $u.Length - '/api/v1'.Length)
  }
  return $u
}

function Read-FirstLines([string]$Path, [int]$Count = 60) {
  try { return Get-Content -LiteralPath $Path -TotalCount $Count -ErrorAction Stop } catch { return @() }
}

function Get-RequiredPsVersion([string]$Path) {
  $lines = Read-FirstLines -Path $Path -Count 80
  foreach ($ln in $lines) {
    if ($ln -match '^\s*#requires\s+-Version\s+([0-9]+(\.[0-9]+)?)\s*$') {
      try { return [version]$Matches[1] } catch { return $null }
    }
  }
  return $null
}

function Script-Contains([string]$Path, [string]$Needle) {
  try {
    $txt = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    return ($txt -like "*$Needle*")
  } catch {
    return $false
  }
}

function Cmdlet-SupportsParameter([string]$CmdletName, [string]$ParamName) {
  try {
    $cmd = Get-Command $CmdletName -ErrorAction Stop
    return $cmd.Parameters.ContainsKey($ParamName)
  } catch {
    return $false
  }
}

function Test-TcpConnect([string]$Host, [int]$Port, [int]$TimeoutMs = 1500) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($Host, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      $client.Close()
      return $false
    }
    $client.EndConnect($iar) | Out-Null
    $client.Close()
    return $true
  } catch {
    return $false
  }
}

function Parse-JsonFile([string]$Path) {
  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  return ($raw | ConvertFrom-Json)
}

function Expand-PathLike([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $p = $Path.Trim()
  if ($p.StartsWith('~')) {
    $p = Join-Path -Path $HOME -ChildPath $p.Substring(1).TrimStart('\','/')
  }
  try { return [Environment]::ExpandEnvironmentVariables($p) } catch { return $p }
}

function Get-EffectiveExecutionPolicy {
  try { return (Get-ExecutionPolicy -ErrorAction Stop) } catch { return $null }
}

function Get-Severity([string]$Status) {
  switch ($Status) {
    'FAIL' { return 0 }
    'WARN' { return 1 }
    'OK'   { return 2 }
    'INFO' { return 3 }
    default { return 9 }
  }
}

function Get-Count([object]$Items) {
  # PowerShell returns a *scalar* (not an array) when a pipeline produces exactly 1 object.
  # Under StrictMode, calling .Count on that scalar throws: "The property 'Count' cannot be found on this object."
  # @(...) forces array context (0..N items), making .Count safe.
  return @($Items).Count
}

function Get-FirstPropValue {
  <#
    Tolerate config schema drift (e.g. sshKey vs sshKeyPath).
    Returns the first non-empty property value found.
  #>
  param(
    [Parameter(Mandatory = $true)]$Obj,
    [Parameter(Mandatory = $true)][string[]]$Names
  )
  if ($null -eq $Obj) { return $null }
  foreach ($n in $Names) {
    try {
      if ($Obj.PSObject.Properties.Name -contains $n) {
        $v = $Obj.$n
        if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
          return $v
        }
      }
    } catch {}
  }
  return $null
}

# -----------------------------
# Locate repo
# -----------------------------
$scriptDir = Split-Path -Parent $PSCommandPath

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  # assume <repo>\tools\doctor.ps1
  try {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
  } catch {
    $RepoRoot = (Get-Location).Path
  }
}

$toolsDir  = Join-Path $RepoRoot 'tools'
$configDir = Join-Path $RepoRoot 'config'
$logsDir   = Join-Path $RepoRoot 'logs'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $configDir 'cfs-spoolman-bridge.json'
}

# -----------------------------
# Environment summary
# -----------------------------
try {
  $psv = $PSVersionTable.PSVersion
  $pse = $PSVersionTable.PSEdition
  Add-Result -Name 'PowerShell (current)' -Status 'INFO' -Details ("{0} ({1})" -f $psv, $pse)

  $pwshPath = Try-GetCommandPath 'pwsh'
  if ($psv.Major -ge 7) {
    Add-Result -Name 'pwsh.exe' -Status 'OK' -Details 'You are already running PowerShell 7+.' 
  } elseif ($pwshPath) {
    Add-Result -Name 'pwsh.exe' -Status 'OK' -Details ("Installed: {0}" -f $pwshPath) -FixHint 'Recommendation: run these tools with pwsh for best compatibility.'
  } else {
    Add-Result -Name 'pwsh.exe' -Status 'WARN' -Details 'PowerShell 7+ not detected.' -FixHint 'Install PowerShell 7+ (pwsh).'
  }
} catch {
  Add-Result -Name 'PowerShell' -Status 'WARN' -Details 'Unable to read $PSVersionTable.'
}

try {
  $isAdmin = $false
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    $isAdmin = $false
  }
  Add-Result -Name 'Admin rights' -Status 'INFO' -Details (if ($isAdmin) { 'Yes' } else { 'No' })
} catch {}

try {
  if ($env:OS -and $env:OS -notlike '*Windows*') {
    Add-Result -Name 'OS' -Status 'FAIL' -Details ("Unsupported OS: {0}" -f $env:OS) -FixHint 'These tools are intended for Windows 10/11.'
  } else {
    $osCaption = $null
    try {
      $osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
    } catch {
      $osCaption = [System.Environment]::OSVersion.VersionString
    }
    Add-Result -Name 'OS' -Status 'INFO' -Details $osCaption
  }
} catch {}

# Basic “sharing on GitHub” sanity
try {
  $gitPath = Try-GetCommandPath 'git'
  if ($gitPath) {
    Add-Result -Name 'git' -Status 'OK' -Details ("Found: {0}" -f $gitPath)
  } else {
    Add-Result -Name 'git' -Status 'WARN' -Details 'git not found on PATH.' -FixHint 'If you plan to contribute back, install Git for Windows.'
  }
} catch {}

# -----------------------------
# Repo layout sanity
# -----------------------------
if (-not (Test-Path -LiteralPath $RepoRoot)) {
  Add-Result -Name 'Repo root' -Status 'FAIL' -Details ("Not found: {0}" -f $RepoRoot)
} else {
  Add-Result -Name 'Repo root' -Status 'OK' -Details $RepoRoot
}

foreach ($d in @($toolsDir, $configDir)) {
  if (Test-Path -LiteralPath $d) {
    Add-Result -Name ("Folder: {0}" -f (Split-Path -Leaf $d)) -Status 'OK' -Details $d
  } else {
    Add-Result -Name ("Folder: {0}" -f (Split-Path -Leaf $d)) -Status 'FAIL' -Details ("Missing: {0}" -f $d)
  }
}

$expectedFiles = @(
  (Join-Path $toolsDir 'sync-cfs-slots-to-spoolman.ps1'),
  (Join-Path $toolsDir 'run-cfs-slot-sync.ps1'),
  (Join-Path $toolsDir 'sync-creality-materials-to-spoolman-masters.ps1'),
  (Join-Path $toolsDir 'sync-creality-materials-to-spoolman.ps1'),
  (Join-Path $toolsDir 'setup-spoolman-and-sync.ps1'),
  (Join-Path $configDir 'cfs-spoolman-bridge.example.json')
)

foreach ($f in $expectedFiles) {
  if (Test-Path -LiteralPath $f) {
    Add-Result -Name ("File: {0}" -f (Split-Path -Leaf $f)) -Status 'OK' -Details (Split-Path -Leaf $f)
  } else {
    Add-Result -Name ("File: {0}" -f (Split-Path -Leaf $f)) -Status 'FAIL' -Details ("Missing: {0}" -f $f)
  }
}

# -----------------------------
# Execution Policy
# -----------------------------
try {
  $ep = Get-EffectiveExecutionPolicy
  if ($null -eq $ep) {
    Add-Result -Name 'ExecutionPolicy' -Status 'WARN' -Details 'Unable to read execution policy.'
  } elseif ($ep -in @('Restricted','AllSigned')) {
    Add-Result -Name 'ExecutionPolicy' -Status 'WARN' -Details ("{0} (may block running scripts)" -f $ep) -FixHint 'Tip: run with -ExecutionPolicy Bypass (Process scope) when invoking scripts.'
  } else {
    Add-Result -Name 'ExecutionPolicy' -Status 'OK' -Details $ep
  }
} catch {
  Add-Result -Name 'ExecutionPolicy' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Zone.Identifier (blocked files)
# -----------------------------
try {
  $blocked = @()
  if (Test-Path -LiteralPath $RepoRoot) {
    $candidates = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Include *.ps1,*.json,*.bat,*.cmd -ErrorAction SilentlyContinue
    foreach ($item in $candidates) {
      try {
        $zi = Get-Item -LiteralPath $item.FullName -Stream Zone.Identifier -ErrorAction Stop
        if ($zi) { $blocked += $item.FullName }
      } catch {
        # not blocked or stream not supported
      }
    }
  }

  if ($blocked.Count -gt 0) {
    Add-Result -Name 'Blocked files' -Status 'WARN' -Details ("{0} file(s) are blocked (Zone.Identifier)." -f $blocked.Count) -FixHint 'Run: Get-ChildItem -Recurse -File | Unblock-File'

    if ($Fix) {
      try {
        foreach ($p in $blocked) {
          try { Unblock-File -LiteralPath $p -ErrorAction Stop } catch {}
        }
        Add-Result -Name 'Fix: Unblock-File' -Status 'OK' -Details 'Attempted to unblock blocked files.'
      } catch {
        Add-Result -Name 'Fix: Unblock-File' -Status 'WARN' -Details $_.Exception.Message
      }
    }
  } else {
    Add-Result -Name 'Blocked files' -Status 'OK' -Details 'No Zone.Identifier streams detected.'
  }
} catch {
  Add-Result -Name 'Blocked files' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Script compatibility checks
# -----------------------------
try {
  $supportsConvertFromJsonDepth = Cmdlet-SupportsParameter -CmdletName 'ConvertFrom-Json' -ParamName 'Depth'

  foreach ($scriptPath in @(
    (Join-Path $toolsDir 'sync-cfs-slots-to-spoolman.ps1'),
    (Join-Path $toolsDir 'run-cfs-slot-sync.ps1'),
    (Join-Path $toolsDir 'sync-creality-materials-to-spoolman-masters.ps1'),
    (Join-Path $toolsDir 'sync-creality-materials-to-spoolman.ps1'),
    (Join-Path $toolsDir 'setup-spoolman-and-sync.ps1')
  )) {
    if (-not (Test-Path -LiteralPath $scriptPath)) { continue }

    $name = 'Compatibility: ' + (Split-Path -Leaf $scriptPath)
    $req = Get-RequiredPsVersion -Path $scriptPath
    $cur = $PSVersionTable.PSVersion

    if ($null -ne $req -and $cur -lt $req) {
      Add-Result -Name $name -Status 'FAIL' -Details ("Requires PowerShell {0}+ (current: {1})" -f $req, $cur)
      continue
    }

    # Heuristic checks for known cross-version foot-guns
    $needsDepth = Script-Contains -Path $scriptPath -Needle 'ConvertFrom-Json -Depth'
    if ($needsDepth -and -not $supportsConvertFromJsonDepth) {
      Add-Result -Name $name -Status 'FAIL' -Details 'Uses ConvertFrom-Json -Depth, but your PowerShell does not support -Depth.' -FixHint 'Use PowerShell 7+ (recommended) or 6.2+.'
      continue
    }

    $usesNullCoalesce = Script-Contains -Path $scriptPath -Needle ' ?? '
    if ($usesNullCoalesce -and $cur.Major -lt 7) {
      Add-Result -Name $name -Status 'FAIL' -Details 'Uses the ?? operator (PowerShell 7+ feature), but you are running Windows PowerShell 5.1.' -FixHint 'Run with pwsh (PowerShell 7+).'
      continue
    }

    # setup script explicitly requires PS7 (even if it doesn't use #requires)
    $setupWants7 = ($scriptPath -like '*setup-spoolman-and-sync.ps1') -and (Script-Contains -Path $scriptPath -Needle 'Please run this with PowerShell 7+')
    if ($setupWants7 -and $cur.Major -lt 7) {
      Add-Result -Name $name -Status 'FAIL' -Details 'This script explicitly requires PowerShell 7+ (pwsh).' -FixHint 'Install PowerShell 7+ and run with pwsh.exe.'
      continue
    }

    Add-Result -Name $name -Status 'OK' -Details 'No obvious version blockers detected.'
  }

  if (-not $supportsConvertFromJsonDepth) {
    Add-Result -Name 'ConvertFrom-Json -Depth' -Status 'WARN' -Details 'This PowerShell does not support ConvertFrom-Json -Depth.' -FixHint 'Some scripts require PowerShell 6.2+ / 7+.'
  } else {
    Add-Result -Name 'ConvertFrom-Json -Depth' -Status 'OK' -Details 'Supported.'
  }
} catch {
  Add-Result -Name 'Script compatibility' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Config file checks
# -----------------------------
$cfg = $null
try {
  $exampleCfg = Join-Path $configDir 'cfs-spoolman-bridge.example.json'

  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    if (Test-Path -LiteralPath $exampleCfg) {
      Add-Result -Name 'Config: cfs-spoolman-bridge.json' -Status 'WARN' -Details ("Missing: {0}" -f $ConfigPath) -FixHint 'Copy config\cfs-spoolman-bridge.example.json to config\cfs-spoolman-bridge.json and edit it.'

      if ($Fix) {
        try {
          Ensure-Directory -Path $configDir
          Copy-Item -LiteralPath $exampleCfg -Destination $ConfigPath -Force -ErrorAction Stop
          Add-Result -Name 'Fix: create config' -Status 'OK' -Details ("Created: {0}" -f $ConfigPath) -FixHint 'Now edit it with your printer IP, SSH key path, etc.'
        } catch {
          Add-Result -Name 'Fix: create config' -Status 'WARN' -Details $_.Exception.Message
        }
      }
    } else {
      Add-Result -Name 'Config: cfs-spoolman-bridge.json' -Status 'FAIL' -Details ("Missing: {0} (and example config missing)" -f $ConfigPath)
    }
  } else {
    Add-Result -Name 'Config: cfs-spoolman-bridge.json' -Status 'OK' -Details $ConfigPath
    try {
      $cfg = Parse-JsonFile -Path $ConfigPath
      Add-Result -Name 'Config: JSON parse' -Status 'OK' -Details 'Valid JSON.'
    } catch {
      Add-Result -Name 'Config: JSON parse' -Status 'FAIL' -Details $_.Exception.Message
    }
  }
} catch {
  Add-Result -Name 'Config checks' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Config structure sanity (non-network)
# -----------------------------
if ($null -ne $cfg) {
  try {
    # printers[]
    if (-not ($cfg.PSObject.Properties.Name -contains 'printers')) {
      Add-Result -Name 'Config: printers[]' -Status 'WARN' -Details 'Config has no printers[] array.' -FixHint 'Add at least one printer under "printers" with name + host.'
    } else {
      $printers = @($cfg.printers)
      if ((Get-Count $printers) -eq 0) {
        Add-Result -Name 'Config: printers[]' -Status 'WARN' -Details 'printers[] is empty.' -FixHint 'Add at least one printer under "printers" with name + host.'
      } else {
        Add-Result -Name 'Config: printers[]' -Status 'OK' -Details ("{0} printer(s) configured." -f (Get-Count $printers))

        foreach ($p in $printers) {
          $pName = [string](Get-FirstPropValue -Obj $p -Names @('name','printer','label'))
          if ([string]::IsNullOrWhiteSpace($pName)) { $pName = '(unnamed printer)' }
          $host  = [string](Get-FirstPropValue -Obj $p -Names @('host','ip','address'))

          if ([string]::IsNullOrWhiteSpace($host)) {
            Add-Result -Name ("Config: printer {0}" -f $pName) -Status 'FAIL' -Details 'Missing host/ip in config.' -FixHint 'Set "host" to the printer IP or hostname.'
            continue
          }

          if ($host -match '192\\.168\\.1\\.123|<|example|printer') {
            Add-Result -Name ("Config: printer {0}" -f $pName) -Status 'WARN' -Details ("Host looks like a placeholder: {0}" -f $host) -FixHint 'Replace with your real printer IP (e.g. 192.168.x.x).'
          } else {
            Add-Result -Name ("Config: printer {0}" -f $pName) -Status 'OK' -Details ("Host={0}" -f $host)
          }
        }
      }
    }
  } catch {
    Add-Result -Name 'Config: printers[]' -Status 'WARN' -Details $_.Exception.Message
  }

  # (SSH-specific config validation happens later in the SSH section.)
}

# -----------------------------
# Determine Spoolman URL + headers
# -----------------------------
$headers = @{}
try {
  if ($null -ne $cfg) {
    if ($cfg.PSObject.Properties.Name -contains 'spoolmanHeaders' -and $cfg.spoolmanHeaders) {
      try {
        foreach ($p in $cfg.spoolmanHeaders.PSObject.Properties) {
          $headers[$p.Name] = [string]$p.Value
        }
      } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($SpoolmanUrl) -and ($cfg.PSObject.Properties.Name -contains 'spoolmanUrl')) {
      $SpoolmanUrl = [string]$cfg.spoolmanUrl
    }
  }

  if ([string]::IsNullOrWhiteSpace($SpoolmanUrl)) {
    $SpoolmanUrl = 'http://127.0.0.1:7912'
  }

  $base = Normalize-BaseUrl $SpoolmanUrl
  if ([string]::IsNullOrWhiteSpace($base)) {
    Add-Result -Name 'Spoolman URL' -Status 'FAIL' -Details 'No Spoolman URL provided or found in config.'
  } else {
    $uri = $null
    if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$uri)) {
      Add-Result -Name 'Spoolman URL' -Status 'FAIL' -Details ("Invalid URI: {0}" -f $base)
    } else {
      Add-Result -Name 'Spoolman URL' -Status 'OK' -Details $base

      if (($uri.Host -in @('127.0.0.1','localhost')) -and ($uri.Port -eq 8000)) {
        Add-Result -Name 'Spoolman port' -Status 'WARN' -Details 'Spoolman URL uses port 8000 on localhost.' -FixHint 'Many setups map container port 8000 to host port 7912 to avoid conflicts.'
      } elseif (($uri.Host -in @('127.0.0.1','localhost')) -and ($uri.Port -eq 7912)) {
        Add-Result -Name 'Spoolman port' -Status 'OK' -Details 'Using port 7912 (common Docker mapping).'
      }
    }
  }
} catch {
  Add-Result -Name 'Spoolman URL' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Spoolman reachability
# -----------------------------
try {
  $base = Normalize-BaseUrl $SpoolmanUrl
  if (-not [string]::IsNullOrWhiteSpace($base)) {
    $infoUri   = $base + '/api/v1/info'
    $healthUri = $base + '/api/v1/health'

    $irm = Get-Command Invoke-RestMethod -ErrorAction Stop
    $supportsTimeout = $irm.Parameters.ContainsKey('TimeoutSec')

    $opts = @{
      Uri = $infoUri
      Method = 'GET'
      Headers = $headers
      ErrorAction = 'Stop'
    }
    if ($supportsTimeout) { $opts.TimeoutSec = 4 }

    $info = $null
    $infoOk = $false
    try {
      $info = Invoke-RestMethod @opts
      $infoOk = $true
    } catch {
      $infoOk = $false
    }

    if ($infoOk) {
      $ver = $null
      try {
        if ($info.PSObject.Properties.Name -contains 'version') { $ver = [string]$info.version }
      } catch {}
      if ([string]::IsNullOrWhiteSpace($ver)) {
        Add-Result -Name 'Spoolman API (/info)' -Status 'OK' -Details 'Reachable.'
      } else {
        Add-Result -Name 'Spoolman API (/info)' -Status 'OK' -Details ("Reachable. Version: {0}" -f $ver)
      }
    } else {
      $opts.Uri = $healthUri
      $healthOk = $false
      try {
        $null = Invoke-RestMethod @opts
        $healthOk = $true
      } catch {
        $healthOk = $false
      }

      if ($healthOk) {
        Add-Result -Name 'Spoolman API (/health)' -Status 'OK' -Details 'Reachable.'
        Add-Result -Name 'Spoolman API (/info)' -Status 'WARN' -Details 'Health works but /info failed (API might be older or blocked).' -FixHint 'Update Spoolman or verify reverse proxy rules.'
      } else {
        $u2 = [Uri]$base
        $tcpOk = Test-TcpConnect -Host $u2.Host -Port $u2.Port -TimeoutMs 1500
        if ($tcpOk) {
          Add-Result -Name 'Spoolman API' -Status 'FAIL' -Details ("TCP connects to {0}:{1} but HTTP API failed." -f $u2.Host, $u2.Port) -FixHint 'Check Spoolman logs / auth headers / reverse proxy.'
        } else {
          Add-Result -Name 'Spoolman API' -Status 'FAIL' -Details ("Cannot reach {0} (HTTP + TCP)." -f $base) -FixHint 'Ensure Spoolman is running and reachable on that host/port.'
        }
      }
    }
  }
} catch {
  Add-Result -Name 'Spoolman API' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Optional: Docker
# -----------------------------
if ($CheckDocker) {
  try {
    $dockerPath = Try-GetCommandPath 'docker'
    if (-not $dockerPath) {
      Add-Result -Name 'Docker' -Status 'FAIL' -Details 'docker not found on PATH.' -FixHint 'Install Docker Desktop (or host Spoolman elsewhere).'
    } else {
      Add-Result -Name 'Docker' -Status 'OK' -Details ("Found: {0}" -f $dockerPath)
      try {
        $composeOut = & docker compose version 2>$null
        if ($LASTEXITCODE -eq 0 -and $composeOut) {
          Add-Result -Name 'Docker Compose' -Status 'OK' -Details (($composeOut | Out-String).Trim())
        } else {
          Add-Result -Name 'Docker Compose' -Status 'WARN' -Details 'docker compose not available (or failed).' -FixHint 'Upgrade Docker Desktop / ensure Compose plugin is installed.'
        }
      } catch {
        Add-Result -Name 'Docker Compose' -Status 'WARN' -Details $_.Exception.Message
      }
    }
  } catch {
    Add-Result -Name 'Docker' -Status 'WARN' -Details $_.Exception.Message
  }
}

# -----------------------------
# SSH tooling + optional connectivity
# -----------------------------
try {
  $sshPath = Try-GetCommandPath 'ssh'
  if (-not $sshPath) {
    Add-Result -Name 'SSH client' -Status 'FAIL' -Details 'ssh.exe not found on PATH.' -FixHint 'Install/enable the Windows "OpenSSH Client" optional feature.'
  } else {
    Add-Result -Name 'SSH client' -Status 'OK' -Details ("Found: {0}" -f $sshPath)
  }
} catch {
  Add-Result -Name 'SSH client' -Status 'WARN' -Details $_.Exception.Message
}

if ($null -ne $cfg) {
  try {
    # Root-level SSH settings (tolerates schema drift: sshKey vs sshKeyPath)
    $sshAuth = [string](Get-FirstPropValue -Obj $cfg -Names @('sshAuth'))
    if ([string]::IsNullOrWhiteSpace($sshAuth)) { $sshAuth = 'auto' }

    $sshPass = [string](Get-FirstPropValue -Obj $cfg -Names @('sshPassword','password'))
    $sshKeyRaw = [string](Get-FirstPropValue -Obj $cfg -Names @('sshKeyPath','sshKey','keyPath','identityFile'))

    if (-not [string]::IsNullOrWhiteSpace($sshKeyRaw)) {
      $sshKeyPath = Expand-PathLike $sshKeyRaw
      if ($sshKeyRaw -like '*<YOU>*') {
        Add-Result -Name 'Config: sshKeyPath' -Status 'WARN' -Details 'SSH key path still contains the <YOU> placeholder.' -FixHint 'Replace <YOU> with your Windows username (or set a correct full path).'
      } elseif (-not (Test-Path -LiteralPath $sshKeyPath)) {
        Add-Result -Name 'Config: sshKeyPath' -Status 'WARN' -Details ("SSH key not found: {0}" -f $sshKeyPath) -FixHint 'Generate an SSH key (ssh-keygen) and update sshKeyPath.'
      } else {
        Add-Result -Name 'Config: sshKeyPath' -Status 'OK' -Details ("Found: {0}" -f $sshKeyPath)
      }
    } elseif ($sshAuth -eq 'key') {
      Add-Result -Name 'Config: sshKeyPath' -Status 'WARN' -Details 'sshAuth is "key" but no sshKeyPath/sshKey is set.' -FixHint 'Set sshKeyPath (recommended) or sshKey to your private key path.'
    }

    # Per-printer SSH key overrides
    if ($cfg.PSObject.Properties.Name -contains 'printers') {
      foreach ($p in @($cfg.printers)) {
        $pName = [string](Get-FirstPropValue -Obj $p -Names @('name','printer','label'))
        if ([string]::IsNullOrWhiteSpace($pName)) { $pName = '(unnamed printer)' }

        $pKeyRaw = [string](Get-FirstPropValue -Obj $p -Names @('sshKeyPath','sshKey','keyPath','identityFile'))
        if ([string]::IsNullOrWhiteSpace($pKeyRaw)) { continue }

        $pKeyPath = Expand-PathLike $pKeyRaw
        $itemName = "Config: printer {0} sshKeyPath" -f $pName

        if ($pKeyRaw -like '*<YOU>*') {
          Add-Result -Name $itemName -Status 'WARN' -Details 'SSH key path contains <YOU> placeholder.' -FixHint 'Replace <YOU> with your Windows username.'
        } elseif (-not (Test-Path -LiteralPath $pKeyPath)) {
          Add-Result -Name $itemName -Status 'WARN' -Details ("SSH key not found: {0}" -f $pKeyPath) -FixHint 'Fix the path or generate the key.'
        } else {
          Add-Result -Name $itemName -Status 'OK' -Details ("Found: {0}" -f $pKeyPath)
        }
      }
    }

    # If password mode is configured, Task Scheduler will hang unless Posh-SSH is present.
    $wantsPassword = $false
    if ($sshAuth -eq 'password') { $wantsPassword = $true }
    if (-not [string]::IsNullOrWhiteSpace($sshPass)) { $wantsPassword = $true }

    if ($wantsPassword) {
      $posh = Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue
      if ($posh) {
        Add-Result -Name 'Posh-SSH (password SSH)' -Status 'OK' -Details 'Posh-SSH module is available for non-interactive password SSH.'
      } else {
        Add-Result -Name 'Posh-SSH (password SSH)' -Status 'WARN' -Details 'sshPassword is set (or sshAuth=password), but Posh-SSH is not installed.' -FixHint 'For Task Scheduler, prefer sshAuth="key" or install the Posh-SSH module.'
      }
    }
  } catch {
    Add-Result -Name 'Config: SSH settings' -Status 'WARN' -Details $_.Exception.Message
  }
}

if ($TestSsh -and $null -ne $cfg) {
  try {
    if (-not ($cfg.PSObject.Properties.Name -contains 'printers')) {
      Add-Result -Name 'Printers' -Status 'WARN' -Details 'Config has no printers[] array.'
    } else {
      $printers = @($cfg.printers)
      if ($printers.Count -eq 0) {
        Add-Result -Name 'Printers' -Status 'WARN' -Details 'printers[] is empty.'
      } else {
        foreach ($p in $printers) {
          $pName = $null
          $host  = $null
          $port  = 22
          try { $pName = [string]$p.name } catch {}
          try { $host  = [string]$p.host } catch {}
          try { if ($p.PSObject.Properties.Name -contains 'sshPort') { $port = [int]$p.sshPort } } catch {}

          if ([string]::IsNullOrWhiteSpace($pName)) { $pName = '(unnamed printer)' }

          if ([string]::IsNullOrWhiteSpace($host)) {
            Add-Result -Name ("Printer: {0}" -f $pName) -Status 'FAIL' -Details 'Missing host in config.'
            continue
          }

          $ok = Test-TcpConnect -Host $host -Port $port -TimeoutMs 1500
          if ($ok) {
            Add-Result -Name ("Printer SSH: {0}" -f $pName) -Status 'OK' -Details ("TCP OK to {0}:{1}" -f $host, $port)
          } else {
            Add-Result -Name ("Printer SSH: {0}" -f $pName) -Status 'WARN' -Details ("No TCP connect to {0}:{1}" -f $host, $port) -FixHint 'Check printer IP, network, and that SSH is enabled/reachable.'
          }
        }
      }
    }
  } catch {
    Add-Result -Name 'SSH connectivity tests' -Status 'WARN' -Details $_.Exception.Message
  }
}

# -----------------------------
# Filament-Sync material_database.json checks (optional)
# -----------------------------
try {
  if (-not [string]::IsNullOrWhiteSpace($MaterialDatabasePath)) {
    if (Test-Path -LiteralPath $MaterialDatabasePath) {
      $fi = Get-Item -LiteralPath $MaterialDatabasePath -ErrorAction Stop
      Add-Result -Name 'material_database.json' -Status 'OK' -Details ("Found ({0:n0} KB): {1}" -f ($fi.Length/1KB), $MaterialDatabasePath)

      try {
        $obj = Parse-JsonFile -Path $MaterialDatabasePath
        if ($null -ne $obj) {
          Add-Result -Name 'material_database.json parse' -Status 'OK' -Details 'Valid JSON.'
        }
      } catch {
        Add-Result -Name 'material_database.json parse' -Status 'WARN' -Details ("File exists but JSON parse failed: {0}" -f $_.Exception.Message) -FixHint 'If this is huge, try running Doctor under PowerShell 7.'
      }
    } else {
      Add-Result -Name 'material_database.json' -Status 'WARN' -Details ("Not found: {0}" -f $MaterialDatabasePath) -FixHint 'Run Filament-Sync to generate material_database.json, or point Doctor to the correct path.'
    }
  } else {
    Add-Result -Name 'material_database.json' -Status 'INFO' -Details 'Not checked (no -MaterialDatabasePath provided).'
  }
} catch {
  Add-Result -Name 'material_database.json' -Status 'WARN' -Details $_.Exception.Message
}

# -----------------------------
# Safe fix-ups
# -----------------------------
if ($Fix) {
  try {
    Ensure-Directory -Path $logsDir
    Add-Result -Name 'Fix: logs folder' -Status 'OK' -Details ("Ensured: {0}" -f $logsDir)
  } catch {
    Add-Result -Name 'Fix: logs folder' -Status 'WARN' -Details $_.Exception.Message
  }

  try {
    if ($null -ne $cfg -and ($cfg.PSObject.Properties.Name -contains 'statePath')) {
      $statePath = [string]$cfg.statePath
      if (-not [string]::IsNullOrWhiteSpace($statePath)) {
        $stateDir = Split-Path -Parent $statePath
        if (-not [string]::IsNullOrWhiteSpace($stateDir)) {
          Ensure-Directory -Path $stateDir
          Add-Result -Name 'Fix: statePath directory' -Status 'OK' -Details ("Ensured: {0}" -f $stateDir)
        }
      }
    }
  } catch {
    Add-Result -Name 'Fix: statePath directory' -Status 'WARN' -Details $_.Exception.Message
  }
}

# -----------------------------
# Output
# -----------------------------
try {
  $failCount = Get-Count ($script:Results | Where-Object { $_.Status -eq 'FAIL' })
  $warnCount = Get-Count ($script:Results | Where-Object { $_.Status -eq 'WARN' })
  $okCount   = Get-Count ($script:Results | Where-Object { $_.Status -eq 'OK' })
  $infoCount = Get-Count ($script:Results | Where-Object { $_.Status -eq 'INFO' })
  Add-Result -Name 'Summary' -Status 'INFO' -Details ("FAIL={0}, WARN={1}, OK={2}, INFO={3}" -f $failCount, $warnCount, $okCount, $infoCount)
} catch {}

try {
  $script:Results |
    Sort-Object @{Expression = { Get-Severity $_.Status }}, Name |
    Format-Table -AutoSize Name, Status, Details, FixHint |
    Out-String -Width 240 |
    Write-Host
} catch {
  $script:Results | ForEach-Object { Write-Host ("[{0}] {1}: {2}" -f $_.Status, $_.Name, $_.Details) }
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
  try {
    $rp = $ReportPath
    if ((Test-Path -LiteralPath $rp) -and (Get-Item -LiteralPath $rp).PSIsContainer) {
      $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
      $rp = Join-Path $rp ("doctor_report_{0}.json" -f $stamp)
    }

    $dir = Split-Path -Parent $rp
    if (-not [string]::IsNullOrWhiteSpace($dir)) { Ensure-Directory -Path $dir }

    $payload = [pscustomobject]@{
      generatedAt = (Get-Date).ToString('o')
      computer    = $env:COMPUTERNAME
      user        = $env:USERNAME
      psVersion   = $PSVersionTable.PSVersion.ToString()
      psEdition   = $PSVersionTable.PSEdition
      repoRoot    = $RepoRoot
      results     = $script:Results
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rp -Encoding UTF8
    Write-Host ("[INFO] Report written: {0}" -f $rp)
  } catch {
    Write-Warning ("Failed to write report: {0}" -f $_.Exception.Message)
  }
}

$hasFail = (Get-Count ($script:Results | Where-Object { $_.Status -eq 'FAIL' })) -gt 0
$hasWarn = (Get-Count ($script:Results | Where-Object { $_.Status -eq 'WARN' })) -gt 0

if ($hasFail) { exit 2 }
if ($hasWarn) { exit 1 }
exit 0
