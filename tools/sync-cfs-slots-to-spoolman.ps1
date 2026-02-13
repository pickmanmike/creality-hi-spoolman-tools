#requires -Version 5.1
<#
.SYNOPSIS
  Sync Creality CFS slot state (material_box_info.json) into Spoolman by using the RFID tag reserve field as the Spoolman spool.id.

.DESCRIPTION
  - Reads /mnt/UDISK/creality/userdata/box/material_box_info.json from one or more printers over SSH (read-only).
  - For each slot with a non-zero reserve:
      * Decodes reserve -> spool_id (decimal by default, or hex if configured)
      * PATCHes Spoolman: /api/v1/spool/<spool_id> with {"location": "<prefix><printer>:<box><slot>"}
  - Optionally clears locations for spools that were previously seen but are no longer loaded.

.NOTES
  - Designed for Windows PowerShell 5.1+ and PowerShell 7+ (pwsh). Should also work on Linux/macOS (with ssh installed).
  - Requires an SSH client available as `ssh`.
  - By default this script only updates spool location. If you also want it to sync Spoolman remaining_weight from the printer's remainLen percent, use -UpdateRemainingWeight (or set updateRemainingWeight=true in config).
  - material_box_info.json entries without RFID data may omit fields like reserve/serialNum; this script tolerates that.

.CONFIG (cfs-spoolman-bridge.json)
  Required:
    spoolmanUrl:        "http://127.0.0.1:7912"      # or include /api/v1 (either works)
    printers: [ { name, host, sshUser?, sshAuth?, sshKey?, sshPassword?, materialBoxInfoPath? }, ... ]

  Optional:
    locationPrefix:     "CFS:"                       # location = "<prefix><printer>:<slotKey>"
    locationField:      "location"                   # what Spoolman field to PATCH on /spool/{id}
    reserveMode:        "auto" | "decimal" | "hex"   # if you wrote reserve as hex, set "hex" (auto is ambiguous for digit-only hex values)
    updateRemainingWeight: false                     # if true, sync Spoolman remaining_weight from Creality remainLen percent (requires filament.weight in Spoolman)
    missingLocation:    ""                           # value used when clearing missing spools (often empty string)
    statePath:          "C:/spoolman/data/cfs-spoolman-state.json"
    materialBoxInfoPath "/mnt/UDISK/creality/userdata/box/material_box_info.json"
    spoolmanHeaders:    { "X-Api-Key": "..." }       # merged into all Spoolman requests
    debugDumpDir:       "C:/spoolman/tools/debug"    # if set, dumps raw JSON on parse failure (and optionally when -VerboseSlots)
    sshAuth:          "auto" | "key" | "password"     # auto=use key if it exists, else password/prompt
    sshKey:           "C:/Users/<you>/.ssh/id_ed25519"    # optional; if missing, ignored unless sshAuth="key"
    sshPassword:      "<printer password>"                     # optional; used only if Posh-SSH is installed; otherwise ssh will prompt

.EXAMPLE
  pwsh ./sync-cfs-slots-to-spoolman.ps1 -ConfigPath ./cfs-spoolman-bridge.json -DryRun -VerboseSlots

  pwsh ./sync-cfs-slots-to-spoolman.ps1 -ConfigPath ./cfs-spoolman-bridge.json -ClearMissing

  # Keep going even if one printer is offline (NOTE: ClearMissing will be skipped unless all printers succeed)
  pwsh ./sync-cfs-slots-to-spoolman.ps1 -ConfigPath ./cfs-spoolman-bridge.json -ContinueOnPrinterError
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,

  [switch]$DryRun,

  # Print a table of parsed slots per printer
  [switch]$VerboseSlots,

  # Also sync Spoolman remaining_weight based on the Creality slot remainLen percent.
  # NOTE: Spoolman can only store remaining_weight if the filament has a non-null 'weight' configured.
  [switch]$UpdateRemainingWeight,

  # Clear location for spools previously seen but now missing
  [switch]$ClearMissing,

  # If a printer can't be reached / parsed, warn and continue instead of terminating.
  # Important: if any printer fails, ClearMissing is automatically skipped to prevent accidental clears.
  [switch]$ContinueOnPrinterError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------
# Helpers
# ----------------------------
function Write-Info([string]$msg) { Write-Host "[INFO] $msg" }
function Write-Warn([string]$msg) { Write-Warning $msg }

function Write-TextFileUtf8NoBom {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][string]$Value
  )

  # Use .NET directly so this works the same in Windows PowerShell 5.1 and PowerShell 7+.
  # -Encoding utf8NoBOM is not available in Windows PowerShell 5.1.
  $enc = New-Object System.Text.UTF8Encoding($false)
  if ($null -eq $Value) { $Value = "" }
  [System.IO.File]::WriteAllText($Path, $Value, $enc)
}


function Quote-PosixSingle {
  <#
    Wrap a string for safe use in a POSIX shell single-quoted context.

    Example:
      abc'def  ->  'abc'"'"'def'

    This is the most portable way to embed a single quote inside a single-quoted string in sh/ash/bash.
  #>
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) { return "''" }

  # PowerShell escaping note: backtick escapes a double quote inside a double-quoted string.
  # The replacement string below becomes: '"'"'
  $escaped = $Text.Replace("'", "'`"`'`"`'")
  return ("'" + $escaped + "'")
}


function Resolve-LocalPath {
  <#
    Expand simple user-friendly path forms:
      - Environment variables (%USERPROFILE%, etc.)
      - Leading "~" (home directory)

    Returns $null if input is null/empty.
  #>
  param([AllowNull()][string]$Path)

  if ($null -eq $Path) { return $null }
  $p = [string]$Path
  if ($p.Trim().Length -eq 0) { return $null }

  # Expand %VARS%
  $p = [Environment]::ExpandEnvironmentVariables($p)

  # Expand ~
  if ($p.StartsWith("~")) {
    $home = $HOME
    if (-not $home) { $home = [Environment]::GetFolderPath("UserProfile") }
    $suffix = $p.Substring(1)
    $suffix = $suffix.TrimStart('/','\')
    if ($suffix.Length -gt 0) {
      $p = Join-Path $home $suffix
    } else {
      $p = $home
    }
  }

  return $p
}


function Resolve-SpoolmanApiBase([string]$url) {
  $u = ([string]$url).TrimEnd("/")
  if ($u -match "/api/v\d+$") { return $u }
  return ($u + "/api/v1")
}

function Get-Prop {
  <#
    StrictMode-safe property getter:
    - Works for PSCustomObject and IDictionary/hashtables
    - Case-insensitive
    - Returns $null if missing
  #>
  param(
    [AllowNull()][object]$Obj,
    [Parameter(Mandatory=$true)][string]$Name
  )
  if ($null -eq $Obj) { return $null }

  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { return $Obj[$Name] }
    foreach ($k in $Obj.Keys) {
      if ($k -is [string] -and $k.Equals($Name, [StringComparison]::OrdinalIgnoreCase)) {
        return $Obj[$k]
      }
    }
    return $null
  }

  try {
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }

    foreach ($pp in $Obj.PSObject.Properties) {
      if ($pp.Name.Equals($Name, [StringComparison]::OrdinalIgnoreCase)) { return $pp.Value }
    }
  } catch { return $null }

  return $null
}



function Get-FirstProp {
  <#
    Return the first non-empty string value among a list of possible property names.
    Useful for tolerating config schema drift (e.g. host vs ip, sshKey vs sshKeyPath).
  #>
  param(
    [AllowNull()][object]$Obj,
    [Parameter(Mandatory=$true)][string[]]$Names
  )
  foreach ($n in $Names) {
    if (-not $n) { continue }
    $v = Get-Prop -Obj $Obj -Name $n
    if ($null -eq $v) { continue }
    $s = [string]$v
    if ($s.Trim().Length -gt 0) { return $s }
  }
  return $null
}

function ConvertFrom-JsonSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [int]$Depth = 40,
    [switch]$AsHashtable
  )

  $t = $Text
  if ($null -eq $t) { throw "JSON text was null" }

  # Strip UTF-8 BOM if present
  if ($t.Length -gt 0 -and [int]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }

  $cmd = Get-Command ConvertFrom-Json -ErrorAction Stop
  $supportsAsHashtable = $cmd.Parameters.ContainsKey("AsHashtable")

  $tryParse = {
    param([string]$candidate)
    if ($AsHashtable -and $supportsAsHashtable) {
      return ($candidate | ConvertFrom-Json -Depth $Depth -AsHashtable)
    }
    return ($candidate | ConvertFrom-Json -Depth $Depth)
  }

  try {
    return & $tryParse $t
  } catch {
    # Try to salvage JSON if SSH banner / noise leaked into stdout.
    $firstBrace = $t.IndexOf('{')
    $firstBracket = $t.IndexOf('[')
    $start = -1
    if ($firstBrace -ge 0 -and $firstBracket -ge 0) { $start = [Math]::Min($firstBrace, $firstBracket) }
    elseif ($firstBrace -ge 0) { $start = $firstBrace }
    elseif ($firstBracket -ge 0) { $start = $firstBracket }

    if ($start -ge 0) {
      $endBrace = $t.LastIndexOf('}')
      $endBracket = $t.LastIndexOf(']')
      $end = [Math]::Max($endBrace, $endBracket)
      if ($end -gt $start) {
        $slice = $t.Substring($start, ($end - $start + 1))
        try {
          return & $tryParse $slice
        } catch { }
      }
    }

    $msg = $_.Exception.Message
    $preview = $t
    if ($preview.Length -gt 400) { $preview = $preview.Substring(0, 400) + "..." }
    throw ("Failed to parse JSON. Error: {0}`nOutput preview:`n{1}" -f $msg, $preview)
  }
}

function Invoke-SpoolmanRest {
  param(
    [Parameter(Mandatory=$true)][string]$ApiBase,
    [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","PUT","DELETE")][string]$Method,
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][object]$Body,
    [AllowNull()][hashtable]$Query,
    [AllowNull()][hashtable]$Headers,
    [int]$TimeoutSec = 30
  )

  $qs = ""
  if ($Query -and $Query.Count -gt 0) {
    $pairs = @()
    foreach ($k in $Query.Keys) {
      $v = $Query[$k]
      if ($null -eq $v) { continue }
      $pairs += ("{0}={1}" -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$v))
    }
    if ($pairs.Count -gt 0) { $qs = "?" + ($pairs -join "&") }
  }

  $uri = ($ApiBase.TrimEnd("/") + $Path + $qs)

  $params = @{
    Method      = $Method
    Uri         = $uri
    ErrorAction = "Stop"
    TimeoutSec  = $TimeoutSec
  }

  if ($Headers -and $Headers.Count -gt 0) { $params.Headers = $Headers }

  if ($Method -in @("POST","PATCH","PUT")) {
    $json = $null
    if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 10) }
    $params.ContentType = "application/json"
    if ($null -ne $json) { $params.Body = $json }
  }

  try {
    return Invoke-RestMethod @params
  }
  catch {
    $msg = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $msg = $msg + "`nResponse: " + $_.ErrorDetails.Message
    }
    throw ("Spoolman API call failed: {0} {1}`n{2}" -f $Method, $uri, $msg)
  }
}

function Read-RemoteFileOverSsh {
  param(
    # IMPORTANT: do not name this param "Host" because $Host is a built-in read-only automatic variable.
    # Using $Host as a param name causes a runtime error when PowerShell tries to bind the argument.
    [Parameter(Mandatory=$true)][string]$SshHost,
    [Parameter(Mandatory=$true)][string]$User,
    [Parameter(Mandatory=$true)][string]$RemotePath,
    [AllowNull()][string]$KeyPath,
    [AllowNull()][string]$Password,
    [ValidateSet("auto","key","password")][string]$AuthMode = "auto",
    [AllowNull()][string[]]$ExtraSshArgs,
    [int]$ConnectTimeoutSec = 5
  )

  $target = "$User@$SshHost"

  # Normalize auth mode
  $auth = [string]$AuthMode
  if ([string]::IsNullOrWhiteSpace($auth)) { $auth = "auto" }
  $auth = $auth.ToLowerInvariant()
  if ($auth -notin @("auto","key","password")) { $auth = "auto" }

  # Resolve key path (if any)
  $resolvedKey = Resolve-LocalPath $KeyPath
  $keyExists = $false
  if ($resolvedKey) {
    if (Test-Path -LiteralPath $resolvedKey) {
      $keyExists = $true
    } else {
      if ($auth -eq "key") {
        throw ("sshKey not found for {0}: {1}" -f $target, $resolvedKey)
      }
      Write-Warn ("sshKey not found for {0}: {1} (ignoring; will fall back to password/prompt)" -f $target, $resolvedKey)
      $resolvedKey = $null
    }
  }

  $useKey = $keyExists
  if ($auth -eq "password") { $useKey = $false }
  if ($auth -eq "key") { $useKey = $true } # keyExists enforced above

  $resolvedKeyForLog = [string]$resolvedKey
  Write-Verbose ("SSH read {0}: auth={1} useKey={2} key={3} passwordProvided={4} timeout={5}s" -f $target, $auth, $useKey, $resolvedKeyForLog, ([bool]$Password), $ConnectTimeoutSec)

  # If a password was provided and Posh-SSH is available, do non-interactive password SSH.
  # This avoids repeated interactive password prompts and works well for scheduled tasks.
  if (-not $useKey -and $Password) {
    $posh = Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue
    if ($posh) {
      try {
        Import-Module Posh-SSH -ErrorAction Stop | Out-Null

        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = [pscredential]::new($User, $sec)

        $newSessionCmd = Get-Command New-SSHSession -ErrorAction Stop
        $newSessionArgs = @{
          ComputerName      = $SshHost
          Credential        = $cred
          ErrorAction       = "Stop"
        }
        if ($newSessionCmd.Parameters.ContainsKey("ConnectionTimeout")) { $newSessionArgs.ConnectionTimeout = $ConnectTimeoutSec }
        if ($newSessionCmd.Parameters.ContainsKey("AcceptKey")) { $newSessionArgs.AcceptKey = $true }

        $session = New-SSHSession @newSessionArgs
        try {
          $result = Invoke-SSHCommand -SessionId $session.SessionId -Command ("cat " + (Quote-PosixSingle $RemotePath)) -ErrorAction Stop
          return (@($result.Output) -join "`n")
        }
        finally {
          try { Remove-SSHSession -SessionId $session.SessionId | Out-Null } catch {}
        }
      } catch {
        Write-Warn ("Posh-SSH password mode failed for {0}; falling back to ssh.exe prompt. Error: {1}" -f $target, $_.Exception.Message)
      }
    }
  }

  $sshArgs = @()
  if ($useKey -and $resolvedKey) {
    $sshArgs += "-i"; $sshArgs += $resolvedKey
  }

  # BatchMode:
  # - yes when using a key (good for scheduled tasks: no password prompts)
  # - no when not using a key (so ssh can prompt for password)
  $batchValue = if ($useKey) { "yes" } else { "no" }

  $sshArgs += @(
    "-o", ("BatchMode=" + $batchValue),
    "-o", "LogLevel=ERROR",
    "-o", ("ConnectTimeout=" + $ConnectTimeoutSec)
  )

  if ($ExtraSshArgs) { $sshArgs += $ExtraSshArgs }

  # BusyBox cat on OpenWrt doesn't always support GNU-style `--`, so keep it simple.
  $cmd = "cat $(Quote-PosixSingle $RemotePath)"

  $stderrText = ""
  $exit = 0

  if ($useKey) {
    # Non-interactive: capture stderr for error reporting without polluting stdout JSON.
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
      $out = & ssh @sshArgs $target $cmd 2> $tmpErr
      $exit = $LASTEXITCODE
      if (Test-Path -LiteralPath $tmpErr) {
        # Get-Content -Raw on a 0-byte file can yield $null in some environments.
        # Treat that as empty string so .Trim() never throws.
        $errRaw = ""
        try { $errRaw = Get-Content -LiteralPath $tmpErr -Raw -ErrorAction Stop } catch { $errRaw = "" }
        if ($null -eq $errRaw) { $errRaw = "" }
        $stderrText = $errRaw.Trim()
      }
    }
    finally {
      Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
    }
  } else {
    # Interactive/password prompt mode: DO NOT redirect stderr, or you won't see the password/host-key prompts.
    $out = & ssh @sshArgs $target $cmd
    $exit = $LASTEXITCODE
  }

  if ($exit -ne 0) {
    if ($stderrText) {
      throw "SSH failed ($target): $stderrText"
    }
    throw "SSH failed ($target) with exit code $exit."
  }

  if ($stderrText) {
    Write-Warn "SSH stderr ($target): $stderrText"
  }

  # Be careful: external commands may return a single string (scalar) OR an array of lines.
  # Using -join on a scalar string can behave unexpectedly (character-by-character). Wrap with @() to force an array.
  return (@($out) -join "`n")
}


function Parse-ReserveToSpoolId {
  param(
    [AllowNull()][string]$Reserve,
    [ValidateSet("auto","decimal","hex")][string]$Mode = "auto"
  )

  if ($null -eq $Reserve) { return $null }
  $r = $Reserve.Trim()
  if ($r.Length -eq 0) { return $null }

  # Be tolerant: if firmware ever writes >6 chars, take the first 6.
  if ($r.Length -lt 6) { return $null }
  if ($r.Length -gt 6) { $r = $r.Substring(0, 6) }

  if ($r -match "^0{6}$") { return $null }

  # Allow only 6 hex chars; decimal is a subset.
  if ($r -notmatch "^[0-9A-Fa-f]{6}$") { return $null }

  $hasLetters = ($r -match "[A-Fa-f]")

  try {
    switch ($Mode) {
      "decimal" {
        if ($hasLetters) { return $null }
        return [int]$r
      }
      "hex" {
        return [Convert]::ToInt32($r, 16)
      }
      default {
        # auto (decimal unless letters are present)
        if ($hasLetters) {
          return [Convert]::ToInt32($r, 16)
        }
        return [int]$r
      }
    }
  } catch { return $null }
}


function Parse-RemainLenPercent {
  param([AllowNull()][object]$RemainLen)

  if ($null -eq $RemainLen) { return $null }

  $s = ([string]$RemainLen).Trim()
  if ($s.Length -eq 0) { return $null }

  [double]$val = 0
  if (-not [double]::TryParse($s, [ref]$val)) { return $null }

  # Creality sometimes uses -1 for "empty/unknown"
  if ($val -lt 0) { return $null }

  # If firmware ever reports 0-1 fractions, normalize to 0-100.
  if ($val -le 1 -and $s -match "^\d?(\.\d+)?$") {
    $val = $val * 100
  }

  if ($val -gt 100) { $val = 100 }
  if ($val -lt 0)   { $val = 0 }

  return [int][Math]::Round($val, 0)
}

function Get-CfsSlotsFromMaterialBoxInfo {
  param(
    [Parameter(Mandatory=$true)][object]$Root,
    [Parameter(Mandatory=$true)][string]$PrinterName
  )

  $slots = @()

  $material = Get-Prop -Obj $Root -Name "Material"
  if ($null -eq $material) { return ,$slots }

  $info = Get-Prop -Obj $material -Name "info"
  foreach ($box in @($info)) {
    if ($null -eq $box) { continue }

    $boxId = [string](Get-Prop $box "boxID")
    if (-not $boxId) { continue }

    $list = Get-Prop -Obj $box -Name "list"
    foreach ($s in @($list)) {
      if ($null -eq $s) { continue }

      $slotLetter = [string](Get-Prop $s "materialId")
      if (-not $slotLetter) { continue }

      $slots += [pscustomobject]@{
        printer      = $PrinterName
        boxID        = $boxId
        slot         = $slotLetter
        slotKey      = ("{0}{1}" -f $boxId, $slotLetter)   # e.g. T1D

        # Optional / may be missing when rfid != 2:
        rfid         = (Get-Prop $s "rfid")
        reserve      = [string](Get-Prop $s "reserve")
        serialNum    = [string](Get-Prop $s "serialNum")

        # Useful context (mostly for -VerboseSlots)
        filamentId   = [string](Get-Prop $s "filamentId")
        color        = [string](Get-Prop $s "color")
        remainLen    = [string](Get-Prop $s "remainLen")
        brand        = [string](Get-Prop $s "brand")
        name         = [string](Get-Prop $s "name")
        materialType = [string](Get-Prop $s "materialType")
      }
    }
  }

  return ,$slots
}

function Load-State([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return @{ locations = @{}; remain = @{} }
  }
  try {
    $txt = Get-Content -LiteralPath $Path -Raw

    # Use hashtables when supported to avoid StrictMode "missing property" failures.
    $obj = ConvertFrom-JsonSafe -Text $txt -Depth 20 -AsHashtable

    $loc = @{}
    $locObj = Get-Prop -Obj $obj -Name "locations"
    if ($locObj) {
      if ($locObj -is [System.Collections.IDictionary]) {
        foreach ($k in $locObj.Keys) {
          $loc[[string]$k] = [string]$locObj[$k]
        }
      } else {
        foreach ($p in $locObj.PSObject.Properties) {
          $loc[$p.Name] = [string]$p.Value
        }
      }
    }
    $remain = @{}
    $remainObj = Get-Prop -Obj $obj -Name "remain"
    if ($remainObj) {
      if ($remainObj -is [System.Collections.IDictionary]) {
        foreach ($k in $remainObj.Keys) {
          try { $remain[[string]$k] = [int]$remainObj[$k] } catch { $remain[[string]$k] = [string]$remainObj[$k] }
        }
      } else {
        foreach ($p in $remainObj.PSObject.Properties) {
          try { $remain[$p.Name] = [int]$p.Value } catch { $remain[$p.Name] = [string]$p.Value }
        }
      }
    }

    return @{ locations = $loc; remain = $remain }
  } catch {
    Write-Warn "State file unreadable; starting fresh: $Path"
    return @{ locations = @{}; remain = @{} }
  }
}


function Save-State([string]$Path, [hashtable]$State) {
  $obj = [pscustomobject]@{ locations = $State.locations; remain = $State.remain }
  $json = $obj | ConvertTo-Json -Depth 10

  $dir = Split-Path -Parent $Path
  if (-not $dir) { $dir = "." }
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  # Atomic-ish write: write to temp file in same directory, then move into place.
  $tmp = Join-Path $dir (".tmp_cfs_spoolman_state_{0}.json" -f ([Guid]::NewGuid().ToString("N")))
  try {
    Write-TextFileUtf8NoBom -Path $tmp -Value $json
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  }
  finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-Directory([AllowNull()][string]$Path) {
  if (-not $Path) { return }
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

# ----------------------------
# Main
# ----------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "ConfigPath not found: $ConfigPath"
}

Get-Command ssh -ErrorAction Stop | Out-Null

$configText = Get-Content -LiteralPath $ConfigPath -Raw

# Use hashtables (when supported) to avoid StrictMode "missing property" crashes on optional config keys.
$config = ConvertFrom-JsonSafe -Text $configText -Depth 40 -AsHashtable

$spoolmanUrl = Get-FirstProp -Obj $config -Names @("spoolmanUrl","spoolmanURL","spoolman_base","spoolmanBaseUrl","spoolmanBaseURL")
if (-not $spoolmanUrl) { throw "Config missing spoolmanUrl" }
$apiBase = Resolve-SpoolmanApiBase $spoolmanUrl

$statePath = [string](Get-Prop -Obj $config -Name "statePath")
if (-not $statePath) {
  $statePath = Join-Path $PSScriptRoot "cfs-spoolman-state.json"
}

$locationPrefix = [string](Get-Prop -Obj $config -Name "locationPrefix")
if (-not $locationPrefix) { $locationPrefix = "CFS:" }

$locationField = [string](Get-Prop -Obj $config -Name "locationField")
if (-not $locationField) { $locationField = "location" }

$updateRemainingWeightEnabled = $UpdateRemainingWeight.IsPresent
if (-not $updateRemainingWeightEnabled) {
  $cfgUpdateRemaining = Get-Prop -Obj $config -Name "updateRemainingWeight"
  if ($null -ne $cfgUpdateRemaining) {
    try { $updateRemainingWeightEnabled = [bool]$cfgUpdateRemaining } catch {}
  }
}
if ($updateRemainingWeightEnabled) {
  Write-Info "Remaining sync: enabled (printer remainLen -> Spoolman remaining_weight; base=spool.initial_weight then filament.weight)"
}


$reserveMode = [string](Get-Prop -Obj $config -Name "reserveMode")
if (-not $reserveMode) { $reserveMode = "auto" }
$reserveMode = $reserveMode.ToLowerInvariant()
if ($reserveMode -notin @("auto","decimal","hex")) {
  throw "Invalid reserveMode '$reserveMode' (expected auto|decimal|hex)"
}

$remotePathDefault = [string](Get-Prop -Obj $config -Name "materialBoxInfoPath")
if (-not $remotePathDefault) { $remotePathDefault = "/mnt/UDISK/creality/userdata/box/material_box_info.json" }

$missingLocationRaw = Get-Prop -Obj $config -Name "missingLocation"
$missingLocation = if ($null -eq $missingLocationRaw) { "" } else { [string]$missingLocationRaw }

$sshAuthDefault = Get-FirstProp -Obj $config -Names @("sshAuth","sshAuthMode","sshMode","sshAuthType")
if (-not $sshAuthDefault) { $sshAuthDefault = "auto" }
$sshAuthDefault = $sshAuthDefault.ToLowerInvariant()
if ($sshAuthDefault -notin @("auto","key","password")) {
  throw "Invalid sshAuth '$sshAuthDefault' (expected auto|key|password)"
}

$sshKeyDefault = Get-FirstProp -Obj $config -Names @("sshKey","sshKeyPath","keyPath","identityFile")

# Optional: password for SSH (useful only if Posh-SSH is installed; otherwise ssh.exe will prompt)
$sshPasswordDefault = Get-FirstProp -Obj $config -Names @("sshPassword","sshPass","password","sshPw")
if (-not $sshPasswordDefault) { $sshPasswordDefault = $env:CFS_SSH_PASSWORD }

$sshConnectTimeoutSecDefault = Get-Prop -Obj $config -Name "sshConnectTimeoutSec"
if (-not $sshConnectTimeoutSecDefault) { $sshConnectTimeoutSecDefault = 5 }
try { $sshConnectTimeoutSecDefault = [int]$sshConnectTimeoutSecDefault } catch { $sshConnectTimeoutSecDefault = 5 }


$sshExtraArgs = @()
$extra = Get-Prop -Obj $config -Name "sshExtraArgs"
if ($extra) { $sshExtraArgs = @($extra) }

$spoolmanHeaders = @{}
$hdrObj = Get-Prop -Obj $config -Name "spoolmanHeaders"
if ($hdrObj) {
  if ($hdrObj -is [System.Collections.IDictionary]) {
    foreach ($k in $hdrObj.Keys) {
      $spoolmanHeaders[[string]$k] = [string]$hdrObj[$k]
    }
  } else {
    foreach ($p in $hdrObj.PSObject.Properties) {
      $spoolmanHeaders[$p.Name] = [string]$p.Value
    }
  }
}

$debugDumpDir = [string](Get-Prop -Obj $config -Name "debugDumpDir")
if ($debugDumpDir) { Ensure-Directory $debugDumpDir }

$printers = @((Get-Prop -Obj $config -Name "printers"))
if ($printers.Count -eq 0) { throw "Config has no printers[]" }

Write-Info "Spoolman API base: $apiBase"
Write-Info ("Printers in config: {0}" -f $printers.Count)

# Sanity check Spoolman reachability.
# Spoolman REST API is typically served under /api/v1 and exposes /health and /info.
# Some reverse-proxy setups may expose these at the root instead; try both.
$reachabilityOk = $false
$lastErr = $null

$probePaths = @("/health", "/info")
$probeBases = @($apiBase, ($spoolmanUrl.TrimEnd("/")))

foreach ($base in $probeBases) {
  foreach ($path in $probePaths) {
    try {
      $null = Invoke-SpoolmanRest -ApiBase $base -Method "GET" -Path $path -Body $null -Query $null -Headers $spoolmanHeaders
      $reachabilityOk = $true
      break
    } catch {
      $lastErr = $_
    }
  }
  if ($reachabilityOk) { break }
}

if (-not $reachabilityOk) {
  throw $lastErr
}

# Optional state-file lock (prevents overlapping scheduled runs from clobbering the state file)
$lockStream = $null
if (-not $DryRun) {
  $lockPath = $statePath + ".lock"
  $lockDir = Split-Path -Parent $lockPath
  if ($lockDir -and -not (Test-Path -LiteralPath $lockDir)) {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
  }
  try {
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  } catch {
    throw "Another instance appears to be running (could not acquire lock): $lockPath"
  }
}

$stats = [ordered]@{
  printers_total = $printers.Count
  printers_ok    = 0
  printers_failed= 0
  slots_seen     = 0
  spools_seen    = 0
  spools_updated = 0
  spools_updated_remaining = 0
  spools_skipped = 0
  spools_cleared = 0
}

$allPrintersSucceeded = $true

try {
  $state = Load-State $statePath
  $seenThisRun = @{}
  $spoolCache = @{}

  foreach ($p in $printers) {
    $pName = Get-FirstProp -Obj $p -Names @("name","printer","printerName")
    $pHost = Get-FirstProp -Obj $p -Names @("host","ip","address")
    if (-not $pName -or -not $pHost) {
      Write-Warn "Skipping printer entry missing name/host"
      $allPrintersSucceeded = $false
      $stats.printers_failed++
      if (-not $ContinueOnPrinterError) { throw "Printer entry missing name/host in config." }
      continue
    }

    $pUser = Get-FirstProp -Obj $p -Names @("sshUser","user","username")
    if (-not $pUser) { $pUser = "root" }

    $pKey = Get-FirstProp -Obj $p -Names @("sshKey","sshKeyPath","keyPath","identityFile")
    if (-not $pKey) { $pKey = $sshKeyDefault }

    $pAuth = Get-FirstProp -Obj $p -Names @("sshAuth","sshAuthMode","sshMode","auth")
    if (-not $pAuth) { $pAuth = $sshAuthDefault }
    $pAuth = $pAuth.ToLowerInvariant()

    $pPass = Get-FirstProp -Obj $p -Names @("sshPassword","sshPass","password","sshPw")
    if (-not $pPass) { $pPass = $sshPasswordDefault }

    $pTimeoutRaw = Get-Prop -Obj $p -Name "sshConnectTimeoutSec"
    $pTimeout = $sshConnectTimeoutSecDefault
    if ($pTimeoutRaw) {
      try { $pTimeout = [int]$pTimeoutRaw } catch { $pTimeout = $sshConnectTimeoutSecDefault }
    }


    $remotePath = Get-FirstProp -Obj $p -Names @("materialBoxInfoPath","material_box_info_path","boxInfoPath","path")
    if (-not $remotePath) { $remotePath = $remotePathDefault }

    # Merge global + per-printer SSH args (per-printer can override/extend, e.g. sshPort).
    $mergedSshArgs = @()
    if ($sshExtraArgs) { $mergedSshArgs += $sshExtraArgs }

    $pPort = Get-Prop -Obj $p -Name "sshPort"
    if ($pPort) {
      $mergedSshArgs += "-p"
      $mergedSshArgs += [string]$pPort
    }

    $pExtra = Get-Prop -Obj $p -Name "sshExtraArgs"
    if ($pExtra) { $mergedSshArgs += @($pExtra) }

    Write-Info ("Reading {0} ({1}): {2}" -f $pName, $pHost, $remotePath)


    $jsonText = $null
    try {
      $jsonText = Read-RemoteFileOverSsh -SshHost $pHost -User $pUser -RemotePath $remotePath -KeyPath $pKey -Password $pPass -AuthMode $pAuth -ExtraSshArgs $mergedSshArgs -ConnectTimeoutSec $pTimeout

      $dumpPath = $null
      if ($debugDumpDir -and $VerboseSlots) {
        $dumpPath = Join-Path $debugDumpDir ("material_box_info.{0}.json" -f ($pName -replace "[^A-Za-z0-9_\-]", "_"))
        Write-TextFileUtf8NoBom -Path $dumpPath -Value $jsonText
      }

      # Use hashtables when supported to avoid StrictMode property-missing errors.
      $root = ConvertFrom-JsonSafe -Text $jsonText -Depth 60 -AsHashtable

      $slots = Get-CfsSlotsFromMaterialBoxInfo -Root $root -PrinterName $pName
      $stats.printers_ok++
    } catch {
      $stats.printers_failed++
      $allPrintersSucceeded = $false

      if ($debugDumpDir) {
        try {
          $dumpPath = Join-Path $debugDumpDir ("material_box_info.{0}.failed.txt" -f ($pName -replace "[^A-Za-z0-9_\-]", "_"))
          Write-TextFileUtf8NoBom -Path $dumpPath -Value ($_.Exception.Message)
          if ($jsonText) {
            try {
              $dumpPath = Join-Path $debugDumpDir ("material_box_info.{0}.failed.raw.txt" -f ($pName -replace "[^A-Za-z0-9_\-]", "_"))
              Write-TextFileUtf8NoBom -Path $dumpPath -Value $jsonText
            } catch { }
          }

        } catch { }
      }

      Write-Warn ("Failed processing printer {0} ({1}): {2}" -f $pName, $pHost, $_.Exception.Message)
      if (-not $ContinueOnPrinterError) { throw }
      continue
    }

    $stats.slots_seen += @($slots).Count

    if ($VerboseSlots) {
      Write-Host ""
      Write-Host ("Slots for {0}:" -f $pName) -ForegroundColor Cyan
      $slots | Sort-Object slotKey | Select-Object slotKey, reserve, rfid, remainLen, filamentId, color, brand, name | Format-Table -AutoSize | Out-Host
    }

    foreach ($s in $slots) {
      $spoolId = Parse-ReserveToSpoolId -Reserve $s.reserve -Mode $reserveMode
      if ($null -eq $spoolId) { continue }

      $stats.spools_seen++
      $loc = ("{0}{1}:{2}" -f $locationPrefix, $pName, $s.slotKey)

      if ($seenThisRun.ContainsKey("$spoolId") -and $seenThisRun["$spoolId"] -ne $loc) {
        Write-Warn ("Duplicate spool id {0} seen in multiple slots this run: '{1}' and '{2}' (last wins)" -f $spoolId, $seenThisRun["$spoolId"], $loc)
      }
      $seenThisRun["$spoolId"] = $loc

      $prevLoc = $null
      if ($state.locations.ContainsKey("$spoolId")) { $prevLoc = [string]$state.locations["$spoolId"] }

      # Decide if we need to update location, remaining_weight, or both.
      $needLocUpdate = ($prevLoc -ne $loc)

      $wantPercent = $null
      $prevPercent = $null
      $needRemainUpdate = $false
      $remainWeight = $null

      if ($updateRemainingWeightEnabled) {
        $wantPercent = Parse-RemainLenPercent -RemainLen $s.remainLen
        if ($null -ne $wantPercent) {
          if ($state.remain.ContainsKey("$spoolId")) {
            try { $prevPercent = [int]$state.remain["$spoolId"] } catch { $prevPercent = $null }
          }
          if ($null -eq $prevPercent -or $prevPercent -ne $wantPercent) {
            $needRemainUpdate = $true
          }
        }
      }

      if (-not $needLocUpdate -and -not $needRemainUpdate) { continue }

      # Compute remaining_weight from percent.
      # Spoolman has evolved across releases:
      #   - some setups rely on filament.weight (filament-level default),
      #   - newer setups expose per-spool initial_weight (spool-level override).
      # We prefer spool.initial_weight and fall back to filament.weight.
      if ($needRemainUpdate) {
        try {
          $spool = $null
          if ($spoolCache.ContainsKey("$spoolId")) {
            $spool = $spoolCache["$spoolId"]
          } else {
            $spool = Invoke-SpoolmanRest -ApiBase $apiBase -Method "GET" -Path ("/spool/{0}" -f $spoolId) -Body $null -Query $null -Headers $spoolmanHeaders
            $spoolCache["$spoolId"] = $spool
          }

          [double]$fullWeight = 0
          $fullSource = $null

          # Prefer spool.initial_weight if present
          $fullSpool = Get-Prop -Obj $spool -Name "initial_weight"
          if ($null -ne $fullSpool) {
            try { $fullWeight = [double]$fullSpool } catch { $fullWeight = 0 }
            if ($fullWeight -gt 0) { $fullSource = "spool.initial_weight" }
          }

          # Fall back to filament.weight (older model / defaults)
          if ($fullWeight -le 0) {
            $fil = Get-Prop -Obj $spool -Name "filament"
            $fullFil = Get-Prop -Obj $fil -Name "weight"
            if ($null -ne $fullFil) {
              try { $fullWeight = [double]$fullFil } catch { $fullWeight = 0 }
              if ($fullWeight -gt 0) { $fullSource = "filament.weight" }
            }
          }

          if ($fullWeight -le 0) {
            Write-Warn ("Skipping remaining_weight for spool {0}: no usable base weight found (spool.initial_weight and filament.weight are empty). Set initial weight on the spool (preferred) or weight on the filament." -f $spoolId)
            $needRemainUpdate = $false
          } else {
            $remainWeight = [Math]::Round(($fullWeight * ($wantPercent / 100.0)), 1)
            if ($remainWeight -lt 0) { $remainWeight = 0 }
            if ($remainWeight -gt $fullWeight) { $remainWeight = $fullWeight }
            Write-Verbose ("Computed remaining_weight for spool {0}: base={1}g ({2}), percent={3} -> remaining={4}g" -f $spoolId, $fullWeight, $fullSource, $wantPercent, $remainWeight)
          }
        } catch {
          Write-Warn ("Failed to compute remaining_weight for spool {0}: {1}" -f $spoolId, $_.Exception.Message)
          $needRemainUpdate = $false
        }
      }

      if (-not $needLocUpdate -and -not $needRemainUpdate) { continue }

      $body = @{}
      if ($needLocUpdate)   { $body[$locationField] = $loc }
      if ($needRemainUpdate){ $body["remaining_weight"] = $remainWeight }

      if ($DryRun) {
        $pairs = @()
        foreach ($k in ($body.Keys | Sort-Object)) { $pairs += ("{0}={1}" -f $k, $body[$k]) }
        Write-Host ("[DryRun] PATCH /spool/{0} {1}" -f $spoolId, ($pairs -join ", "))

        if ($needLocUpdate)    { $state.locations["$spoolId"] = $loc }
        if ($needRemainUpdate) { $state.remain["$spoolId"] = $wantPercent }
        continue
      }

      try {
        $null = Invoke-SpoolmanRest -ApiBase $apiBase -Method "PATCH" -Path ("/spool/{0}" -f $spoolId) -Body $body -Query $null -Headers $spoolmanHeaders

        $changed = @()
        if ($needLocUpdate)    { $changed += $locationField }
        if ($needRemainUpdate) { $changed += "remaining_weight" }

        Write-Host ("Updated Spoolman spool {0}: {1}" -f $spoolId, ($changed -join ", "))

        $stats.spools_updated++
        if ($needRemainUpdate) { $stats.spools_updated_remaining++ }

        if ($needLocUpdate)    { $state.locations["$spoolId"] = $loc }
        if ($needRemainUpdate) { $state.remain["$spoolId"] = $wantPercent }
      } catch {
        $stats.spools_skipped++
        Write-Warn ("Failed to update spool {0} (reserve='{1}', {2}='{3}', remainLen='{4}'): {5}" -f $spoolId, $s.reserve, $locationField, $loc, $s.remainLen, $_.Exception.Message)
        # Do NOT update state on failed PATCH.
        continue
      }
    }

  }

  if ($ClearMissing) {
    if (-not $allPrintersSucceeded) {
      Write-Warn "ClearMissing requested, but at least one printer failed or was skipped. Skipping ClearMissing to avoid clearing spools that might still be loaded on an unreachable printer."
    } else {
      $toClear = @()
      foreach ($k in @($state.locations.Keys)) {
        if (-not $seenThisRun.ContainsKey($k)) {
          $toClear += $k
        }
      }

      foreach ($k in $toClear) {
        $priorLoc = [string]$state.locations[$k]

        if ($DryRun) {
          Write-Host ("[DryRun] CLEAR /spool/{0} {1} -> '{2}'" -f $k, $locationField, $missingLocation)
          $null = $state.locations.Remove($k)
          $null = $state.remain.Remove($k)
          continue
        }

        # Safety: only clear if the spool's current field still matches what *we* last set.
        try {
          $spool = Invoke-SpoolmanRest -ApiBase $apiBase -Method "GET" -Path ("/spool/{0}" -f $k) -Body $null -Query $null -Headers $spoolmanHeaders
          $currentLoc = [string](Get-Prop $spool $locationField)
          if ($currentLoc -ne $priorLoc) {
            Write-Warn ("Skip clearing spool {0}: {1} changed from '{2}' to '{3}'" -f $k, $locationField, $priorLoc, $currentLoc)
            $null = $state.locations.Remove($k)
            $null = $state.remain.Remove($k)
            continue
          }
        } catch {
          Write-Warn "Failed to fetch spool $k before clearing; removing from state: $($_.Exception.Message)"
          $null = $state.locations.Remove($k)
          $null = $state.remain.Remove($k)
          continue
        }

        try {
          $body = @{}
          $body[$locationField] = $missingLocation
          $null = Invoke-SpoolmanRest -ApiBase $apiBase -Method "PATCH" -Path ("/spool/{0}" -f $k) -Body $body -Query $null -Headers $spoolmanHeaders
          Write-Host ("Cleared Spoolman spool {0} {1}" -f $k, $locationField)
          $stats.spools_cleared++
        } catch {
          Write-Warn ("Failed to clear spool {0}: {1}" -f $k, $_.Exception.Message)
        }

        # Remove from state regardless; we'll re-add when seen.
        $null = $state.locations.Remove($k)
        $null = $state.remain.Remove($k)
      }
    }
  }

  if (-not $DryRun) {
    Save-State -Path $statePath -State $state
    Write-Info "Saved state: $statePath"
  } else {
    Write-Info "DryRun: not saving state"
  }

  # Summary
  Write-Host ""
  Write-Info ("Run summary: printers ok={0}/{1}, failed={2}, slots={3}, spools seen={4}, updated={5}, remainingUpdated={6}, cleared={7}, skipped={8}" -f `
    $stats.printers_ok, $stats.printers_total, $stats.printers_failed, $stats.slots_seen, $stats.spools_seen, $stats.spools_updated, $stats.spools_updated_remaining, $stats.spools_cleared, $stats.spools_skipped)
}
finally {
  if ($lockStream) {
    try { $lockStream.Dispose() } catch {}
  }
}
