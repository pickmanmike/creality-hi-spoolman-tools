#requires -Version 5.1
<#
.SYNOPSIS
  Migrate legacy [CFS-RFID] comment metadata into Spoolman spool.extra fields.

.DESCRIPTION
  - Scans spools in Spoolman for legacy [CFS-RFID] comment lines with key=value pairs.
  - Writes parsed values into spool.extra using GET -> merge -> PATCH (extra replaces, so we merge first).
  - Default is DryRun. Use -Apply to perform updates.

.PARAMETER ConfigPath
  Path to a JSON config file with spoolmanUrl and optional spoolmanHeaders.

.PARAMETER Apply
  Actually PATCH spools. If omitted, runs in DryRun mode.

.PARAMETER SpoolIds
  Optional list of spool IDs to process. If omitted, all spools are scanned.

.EXAMPLE
  pwsh ./tools/migrate-creality-comment-to-extra.ps1 -ConfigPath ./config/cfs-spoolman-bridge.json

.EXAMPLE
  pwsh ./tools/migrate-creality-comment-to-extra.ps1 -ConfigPath ./config/cfs-spoolman-bridge.json -Apply
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,

  [switch]$Apply,

  [int[]]$SpoolIds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host "[INFO] $msg" }
function Write-Warn([string]$msg) { Write-Warning $msg }

function ConvertFrom-JsonSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [int]$Depth = 40,
    [switch]$AsHashtable
  )

  $t = $Text
  if ($null -eq $t) { throw "JSON text was null" }
  if ($t.Length -gt 0 -and [int]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }

  $cmd = Get-Command ConvertFrom-Json -ErrorAction Stop
  $supportsAsHashtable = $cmd.Parameters.ContainsKey("AsHashtable")

  if ($AsHashtable -and $supportsAsHashtable) {
    return ($t | ConvertFrom-Json -Depth $Depth -AsHashtable)
  }
  return ($t | ConvertFrom-Json -Depth $Depth)
}

function Resolve-SpoolmanApiBase([string]$url) {
  $u = ([string]$url).TrimEnd("/")
  if ($u -match "/api/v\d+$") { return $u }
  return ($u + "/api/v1")
}

function Get-Prop {
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

function Invoke-SpoolmanRest {
  param(
    [Parameter(Mandatory=$true)][string]$ApiBase,
    [Parameter(Mandatory=$true)][ValidateSet("GET","PATCH")][string]$Method,
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][object]$Body,
    [AllowNull()][hashtable]$Headers,
    [int]$TimeoutSec = 30
  )

  $uri = ($ApiBase.TrimEnd("/") + $Path)
  $params = @{
    Method      = $Method
    Uri         = $uri
    ErrorAction = "Stop"
    TimeoutSec  = $TimeoutSec
  }

  if ($Headers -and $Headers.Count -gt 0) { $params.Headers = $Headers }

  if ($Method -in @("PATCH")) {
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

function Get-ExtraHashtable {
  param([AllowNull()][object]$ExtraObj)
  $ht = @{}
  if ($null -eq $ExtraObj) { return $ht }
  if ($ExtraObj -is [System.Collections.IDictionary]) {
    foreach ($k in $ExtraObj.Keys) { $ht[[string]$k] = $ExtraObj[$k] }
    return $ht
  }
  foreach ($p in $ExtraObj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
  return $ht
}

function Merge-Extra {
  param(
    [Parameter(Mandatory=$true)][hashtable]$Existing,
    [Parameter(Mandatory=$true)][hashtable]$Desired
  )

  $merged = @{}
  foreach ($k in $Existing.Keys) { $merged[$k] = $Existing[$k] }
  foreach ($k in $Desired.Keys) { $merged[$k] = $Desired[$k] }
  return $merged
}

function Add-TagUid {
  param(
    [Parameter(Mandatory=$true)][hashtable]$Extra,
    [Parameter(Mandatory=$true)][string]$Uid
  )

  $key = "creality.tag_uid"
  $uid = $Uid.Trim().ToUpperInvariant()
  if (-not $uid) { return }

  if (-not $Extra.ContainsKey($key) -or $null -eq $Extra[$key]) {
    $Extra[$key] = $uid
    return
  }

  $existing = $Extra[$key]
  if ($existing -is [System.Collections.IEnumerable] -and -not ($existing -is [string])) {
    $list = @()
    foreach ($v in $existing) { if ($v) { $list += ([string]$v).Trim().ToUpperInvariant() } }
    if ($list -notcontains $uid) { $list += $uid }
    $Extra[$key] = $list
    return
  }

  $prev = ([string]$existing).Trim().ToUpperInvariant()
  if ($prev -eq $uid) {
    $Extra[$key] = $prev
    return
  }

  $Extra[$key] = @($prev, $uid)
}

function Parse-CfsRfidComment {
  param([AllowNull()][string]$Comment)

  if ($null -eq $Comment) { return @{} }
  if ($Comment.IndexOf("[CFS-RFID]", [StringComparison]::OrdinalIgnoreCase) -lt 0) { return @{} }

  $kv = @{}
  $regex = [regex]'(?i)([a-z0-9_]+)\s*=\s*([^;\r\n]+)'
  foreach ($m in $regex.Matches($Comment)) {
    $key = $m.Groups[1].Value.Trim().ToLowerInvariant()
    $val = $m.Groups[2].Value.Trim()
    if (-not $key -or -not $val) { continue }
    $kv[$key] = $val
  }

  return $kv
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "ConfigPath not found: $ConfigPath"
}

$cfgText = Get-Content -LiteralPath $ConfigPath -Raw
$config = ConvertFrom-JsonSafe -Text $cfgText -Depth 40 -AsHashtable

$spoolmanUrl = Get-Prop -Obj $config -Name "spoolmanUrl"
if (-not $spoolmanUrl) { throw "Config missing spoolmanUrl" }
$apiBase = Resolve-SpoolmanApiBase $spoolmanUrl

$spoolmanHeaders = @{}
$hdrObj = Get-Prop -Obj $config -Name "spoolmanHeaders"
if ($hdrObj) {
  if ($hdrObj -is [System.Collections.IDictionary]) {
    foreach ($k in $hdrObj.Keys) { $spoolmanHeaders[[string]$k] = [string]$hdrObj[$k] }
  } else {
    foreach ($p in $hdrObj.PSObject.Properties) { $spoolmanHeaders[$p.Name] = [string]$p.Value }
  }
}

$dryRun = -not $Apply.IsPresent
if ($dryRun) { Write-Info "DryRun: enabled (use -Apply to PATCH)" }

$stats = [ordered]@{
  spools_scanned = 0
  spools_matched = 0
  spools_updated = 0
  spools_skipped = 0
  spools_failed  = 0
}

function Get-SpoolList {
  param([string]$ApiBase, [hashtable]$Headers)

  $resp = Invoke-SpoolmanRest -ApiBase $ApiBase -Method "GET" -Path "/spool" -Body $null -Headers $Headers
  if ($resp -is [System.Collections.IEnumerable] -and -not ($resp -is [string])) {
    return @($resp)
  }

  $candidates = @("items","results","data","spools")
  foreach ($k in $candidates) {
    $v = Get-Prop -Obj $resp -Name $k
    if ($v -and ($v -is [System.Collections.IEnumerable])) { return @($v) }
  }

  return @()
}

$targets = @()
if ($SpoolIds -and $SpoolIds.Count -gt 0) {
  foreach ($id in $SpoolIds) { $targets += [pscustomobject]@{ id = $id } }
} else {
  $targets = Get-SpoolList -ApiBase $apiBase -Headers $spoolmanHeaders
}

if ($targets.Count -eq 0) {
  Write-Warn "No spools found to scan."
}

$keyMap = @{
  "creality_id"      = "creality.creality_id"
  "tag_uid"          = "creality.tag_uid"
  "serial"           = "creality.serial_num"
  "serial_num"       = "creality.serial_num"
  "color"            = "creality.color"
  "color_hex"        = "creality.color_hex"
  "filament_article" = "creality.filament_article"
  "printer"          = "creality.printer_type"
  "printer_type"     = "creality.printer_type"
}

foreach ($t in $targets) {
  $id = Get-Prop -Obj $t -Name "id"
  if (-not $id) { continue }
  $stats.spools_scanned++

  $spool = $null
  try {
    $spool = Invoke-SpoolmanRest -ApiBase $apiBase -Method "GET" -Path ("/spool/{0}" -f $id) -Body $null -Headers $spoolmanHeaders
  } catch {
    $stats.spools_failed++
    Write-Warn ("Failed to fetch spool {0}: {1}" -f $id, $_.Exception.Message)
    continue
  }

  $comment = [string](Get-Prop -Obj $spool -Name "comment")
  $kv = Parse-CfsRfidComment -Comment $comment
  if ($kv.Count -eq 0) { continue }
  $stats.spools_matched++

  $desired = @{}
  foreach ($k in $kv.Keys) {
    if (-not $keyMap.ContainsKey($k)) { continue }
    $targetKey = $keyMap[$k]
    $val = $kv[$k]
    if ($targetKey -eq "creality.serial_num") {
      if ($val -match "^\d+$" -and $val.Length -le 6) {
        $val = $val.PadLeft(6, '0')
      }
    }
    if ($targetKey -eq "creality.tag_uid") {
      Add-TagUid -Extra $desired -Uid $val
    } else {
      $desired[$targetKey] = $val
    }
  }

  if ($desired.Count -eq 0) { continue }

  $existingExtra = Get-ExtraHashtable (Get-Prop -Obj $spool -Name "extra")
  $merged = Merge-Extra -Existing $existingExtra -Desired $desired

  if ($dryRun) {
    $stats.spools_skipped++
    Write-Host ("[DryRun] spool {0}: extra keys -> {1}" -f $id, ($desired.Keys -join ", "))
    continue
  }

  try {
    $patchBody = @{ extra = $merged }
    $null = Invoke-SpoolmanRest -ApiBase $apiBase -Method "PATCH" -Path ("/spool/{0}" -f $id) -Body $patchBody -Headers $spoolmanHeaders
    $stats.spools_updated++
    Write-Host ("Updated spool {0}: extra keys -> {1}" -f $id, ($desired.Keys -join ", "))
  } catch {
    $stats.spools_failed++
    Write-Warn ("Failed to update spool {0}: {1}" -f $id, $_.Exception.Message)
  }
}

Write-Host ""
Write-Info ("Summary: scanned={0}, matched={1}, updated={2}, dryrun_skipped={3}, failed={4}" -f `
  $stats.spools_scanned, $stats.spools_matched, $stats.spools_updated, $stats.spools_skipped, $stats.spools_failed)
