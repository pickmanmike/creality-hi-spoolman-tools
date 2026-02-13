#requires -Version 5.1
<#
.SYNOPSIS
  Import Creality filament profiles into Spoolman as MASTER filaments (vendor + filament templates).

.DESCRIPTION
  - Reads a Creality-style material_database.json (commonly root.result.list).
  - Creates/updates Spoolman Vendors.
  - Creates/updates Spoolman Filaments as colorless MASTER templates (print parameters only):
      - external_id: "creality-profile:<profileId>" (if supported by your Spoolman version)
      - article_number: "Creality:<profileId>" (backwards-compatible fallback join key)
      - name suffix: " (MASTER)"
      - template color: MasterTemplateColorHex (default 808080)
  - Does NOT create per-color filaments; RFID for CFS will create color variants on demand.
  - Supports -DryRun and -ShowJsonDiscovery for debugging.

NOTES
  - Spoolman filament creation requires density + diameter. 
  - StrictMode turns missing properties into terminating errors, so we avoid unsafe .Count usage. 
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$MaterialDatabasePath,

  [Parameter(Mandatory = $true)]
  [string]$SpoolmanUrl,

  [switch]$DryRun,

  [switch]$ShowJsonDiscovery,

  # Default to what your file demonstrably contains
  [string]$JsonPointer = "/result/list",

  [int]$DiscoveryDepth = 6,
  [int]$DiscoverySampleSize = 5,

  [int]$PageSize = 200,

  # Prefix used for Spoolman filament.article_number
  [string]$CrealityArticlePrefix = "Creality:",

  # --- MASTER filament import strategy ---
  # Creality profiles are treated as "colorless masters" (print parameters only).
  # RFID for CFS will create color variants on demand.
  [string]$FilamentExternalIdPrefix = "creality-profile:",
  [string]$VendorExternalIdPrefix   = "creality-vendor:",
  [string]$MasterNameSuffix         = " (MASTER)",
  # Template color for MASTER filaments. Set to "" to omit color_hex (Spoolman will show white).
  [string]$MasterTemplateColorHex   = "808080",
  # If set, do NOT send external_id to Spoolman (fall back to article_number matching).
  [switch]$DisableExternalId,

  # By default: don't overwrite non-script comments
  [switch]$ForceUpdateComments,

  # Safer behavior: only PATCH existing filaments if explicitly enabled
  [switch]$UpdateExistingFilaments,

  # Safety: when matching by article_number (fallback), require the existing filament's name
  # to match the Creality profile name (or its MASTER form). This prevents accidental matches
  # if a color-variant filament copied the master article_number.
  [switch]$AllowUnsafeArticleNumberMatches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:SyncTag = "Filament-Sync"
$script:EntriesSourcePath = $null
$script:EntriesSourceKind = $null
$script:ExternalIdRuntimeDisabled = $false

# ----------------------------
# Output helpers
# ----------------------------
function Write-Info([string]$msg) { Write-Host $msg }
function Write-Warn([string]$msg) { Write-Warning $msg }

# StrictMode-safe count:
# - returns 0 for $null
# - returns 1 for a scalar
# - returns N for an array / enumerable output
function Count-Of([AllowNull()][object]$x) { return @($x).Count }

function Normalize-Whitespace([AllowNull()][string]$s) {
  if ($null -eq $s) { return $null }
  $t = ($s -replace "\s+", " ").Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $null }
  return $t
}

function Is-NullishString([AllowNull()][string]$s) {
  if ($null -eq $s) { return $true }
  $t = $s.Trim()
  return ([string]::IsNullOrWhiteSpace($t) -or $t -ieq "nil" -or $t -ieq "null" -or $t -ieq "none" -or $t -ieq '""')
}

function Normalize-Key([AllowNull()][string]$s) {
  $t = Normalize-Whitespace $s
  if ($null -eq $t) { return $null }
  return $t.ToLowerInvariant()
}

function Trunc([AllowNull()][string]$s, [int]$maxLen) {
  if ($null -eq $s) { return $null }
  if ($s.Length -le $maxLen) { return $s }
  return $s.Substring(0, $maxLen)
}


function Name-MatchesProfileOrMaster {
  param(
    [AllowNull()][string]$ExistingName,
    [AllowNull()][string]$ProfileName
  )

  $existing = Normalize-Whitespace $ExistingName
  $profile  = Normalize-Whitespace $ProfileName
  if ($null -eq $existing -or $null -eq $profile) { return $false }

  # Spoolman filament.name max length is 64 characters (truncate for fair comparison)
  $base = Trunc $profile 64

  $master = $base
  if (-not $master.EndsWith($MasterNameSuffix)) { $master = $master + $MasterNameSuffix }
  $master = Trunc $master 64

  $e = Normalize-Key $existing
  $b = Normalize-Key $base
  $m = Normalize-Key $master

  return ($e -eq $b -or $e -eq $m)
}


function Coalesce([AllowNull()]$value, $fallback) {
  if ($null -eq $value) { return $fallback }
  $sv = $null
  try { $sv = [string]$value } catch { $sv = $null }
  if ($null -ne $sv -and -not (Is-NullishString $sv)) { return $value }
  return $fallback
}

function Get-Prop {
  param(
    [AllowNull()][object]$Obj,
    [Parameter(Mandatory = $true)][string]$Name
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

function Get-FirstString([AllowNull()][object]$Value) {
  if ($null -eq $Value) { return $null }

  if ($Value -is [string]) {
    $s = Normalize-Whitespace $Value
    if (Is-NullishString $s) { return $null }
    return $s
  }

  if ($Value -is [System.Array]) {
    foreach ($v in $Value) {
      $s = Get-FirstString $v
      if ($null -ne $s) { return $s }
    }
    return $null
  }

  try {
    $s2 = Normalize-Whitespace ([string]$Value)
    if (Is-NullishString $s2) { return $null }
    return $s2
  } catch { return $null }
}

function First-NonEmptyString([AllowNull()][object[]]$Candidates) {
  foreach ($c in $Candidates) {
    $s = Get-FirstString $c
    if ($null -ne $s) { return $s }
  }
  return $null
}

function Try-ParseDouble([AllowNull()][object]$Value) {
  $s = Get-FirstString $Value
  if ($null -eq $s) { return $null }
  $tmp = 0.0
  if ([double]::TryParse($s, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)) { return $tmp }
  if ([double]::TryParse($s, [ref]$tmp)) { return $tmp }
  return $null
}

function Try-ParseInt([AllowNull()][object]$Value) {
  $s = Get-FirstString $Value
  if ($null -eq $s) { return $null }
  $tmp = 0
  if ([int]::TryParse($s, [ref]$tmp)) { return $tmp }
  return $null
}

function Normalize-HexColor([AllowNull()][object]$Value) {
  $s = Get-FirstString $Value
  if ($null -eq $s) { return $null }
  $t = $s.Trim()
  if ($t.StartsWith("#")) { $t = $t.Substring(1) }
  if ($t.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) { $t = $t.Substring(2) }
  $t = ($t -replace "[^0-9a-fA-F]", "")
  if ($t.Length -lt 6) { return $null }
  if ($t.Length -gt 8) { $t = $t.Substring(0, 8) }
  if ($t.Length -ne 6 -and $t.Length -ne 8) {
    if ($t.Length -gt 6) { $t = $t.Substring(0, 6) } else { return $null }
  }
  return $t.ToUpperInvariant()
}

function Is-JsonObject([AllowNull()][object]$x) {
  if ($null -eq $x) { return $false }
  if ($x -is [System.Collections.IDictionary]) { return $true }
  if ($x -is [System.Management.Automation.PSCustomObject]) { return $true }
  try { return ($x.PSObject.Properties.Count -gt 0) } catch { return $false }
}

# ----------------------------
# JSON Pointer
# ----------------------------
function Unescape-JsonPointerSegment([string]$seg) { return ($seg -replace "~1", "/" -replace "~0", "~") }
function Escape-JsonPointerSegment([string]$seg)   { return ($seg -replace "~", "~0" -replace "/", "~1") }

function Normalize-JsonPointer([AllowNull()][string]$ptr) {
  if ($null -eq $ptr) { return $null }
  $p = $ptr.Trim()
  if ($p -eq "") { return "/" }
  if (-not $p.StartsWith("/")) { $p = "/" + $p }
  return $p
}

function Get-ByJsonPointer([AllowNull()][object]$Root, [Parameter(Mandatory = $true)][string]$Pointer) {
  if ($null -eq $Root) { return $null }
  $ptr = Normalize-JsonPointer $Pointer
  if ($ptr -eq "/") { return $Root }

  $cur = $Root
  $segs = $ptr.Trim("/").Split("/")

  foreach ($rawSeg in $segs) {
    $seg = Unescape-JsonPointerSegment $rawSeg
    if ($null -eq $cur) { return $null }

    if ($cur -is [System.Array]) {
      $idx = 0
      if (-not [int]::TryParse($seg, [ref]$idx)) { return $null }
      $count = @($cur).Count
      if ($idx -lt 0 -or $idx -ge $count) { return $null }
      $cur = $cur[$idx]
      continue
    }

    $cur = Get-Prop $cur $seg
  }

  return $cur
}

# ----------------------------
# JSON discovery (optional)
# ----------------------------
function Get-FilamentEntryScore([AllowNull()][object]$Entry) {
  if (-not (Is-JsonObject $Entry)) { return 0 }
  $base = Get-Prop $Entry "base"
  $kv   = Get-Prop $Entry "kvParam"

  $vendor = First-NonEmptyString @((Get-Prop $kv "filament_vendor"), (Get-Prop $base "brand"), (Get-Prop $Entry "vendor"), (Get-Prop $Entry "brand"))
  $name   = First-NonEmptyString @((Get-Prop $base "name"), (Get-Prop $Entry "name"), (Get-Prop $Entry "display_name"))
  $mat    = First-NonEmptyString @((Get-Prop $kv "filament_type"), (Get-Prop $base "meterialType"), (Get-Prop $base "materialType"), (Get-Prop $Entry "material"))
  $dens   = Try-ParseDouble (First-NonEmptyString @((Get-Prop $kv "filament_density"), (Get-Prop $base "density"), (Get-Prop $Entry "density")))
  $dia    = Try-ParseDouble (First-NonEmptyString @((Get-Prop $kv "filament_diameter"), (Get-Prop $base "diameter"), (Get-Prop $Entry "diameter")))

  $score = 0
  if ($vendor) { $score += 2 }
  if ($name)   { $score += 2 }
  if ($mat)    { $score += 2 }
  if ($dens -and $dens -gt 0) { $score += 2 }
  if ($dia  -and $dia  -gt 0) { $score += 2 }
  if (Is-JsonObject $base) { $score += 1 }
  if (Is-JsonObject $kv)   { $score += 1 }
  return $score
}

function Score-EntryCollection([AllowNull()][object]$Collection, [int]$SampleSize) {
  $items = @($Collection)
  $take = [Math]::Min($SampleSize, $items.Count)

  $sum = 0
  $considered = 0

  for ($i = 0; $i -lt $take; $i++) {
    $e = $items[$i]
    if (-not (Is-JsonObject $e)) { continue }
    $sum += (Get-FilamentEntryScore $e)
    $considered++
  }

  $avg = 0
  if ($considered -gt 0) { $avg = [Math]::Round(($sum / $considered), 2) }
  return $avg
}

function Find-ArrayCandidates([AllowNull()][object]$Node, [string]$Path, [int]$Depth, [int]$MaxDepth, [int]$SampleSize, [ref]$OutList) {
  if ($Depth -gt $MaxDepth) { return }
  if ($null -eq $Node) { return }

  if ($Node -is [System.Array]) {
    $cnt = @($Node).Count
    if ($cnt -gt 0) {
      $avg = Score-EntryCollection -Collection $Node -SampleSize $SampleSize
      $OutList.Value += [pscustomobject]@{ Path = $Path; Kind = "Array"; Count = $cnt; AvgScore = $avg }
    }

    $inspect = [Math]::Min(3, @($Node).Count)
    for ($i = 0; $i -lt $inspect; $i++) {
      Find-ArrayCandidates -Node $Node[$i] -Path ($Path + "/" + $i) -Depth ($Depth + 1) -MaxDepth $MaxDepth -SampleSize $SampleSize -OutList $OutList
    }
    return
  }

  if (Is-JsonObject $Node) {
    foreach ($p in $Node.PSObject.Properties) {
      $seg = Escape-JsonPointerSegment $p.Name
      Find-ArrayCandidates -Node $p.Value -Path ($Path + "/" + $seg) -Depth ($Depth + 1) -MaxDepth $MaxDepth -SampleSize $SampleSize -OutList $OutList
    }
  }
}

function Show-JsonRootSummary([AllowNull()][object]$Root) {
  Write-Host ""
  Write-Host "JSON root summary:"
  if ($null -eq $Root) { Write-Host "  Root is null"; return }

  if ($Root -is [System.Array]) {
    Write-Host ("  Root is Array (Count={0})" -f (Count-Of $Root))
    return
  }

  if (Is-JsonObject $Root) {
    $names = @($Root.PSObject.Properties | ForEach-Object { $_.Name })
    $preview = ($names | Select-Object -First 12) -join ", "
    Write-Host ("  Root is Object (props={0}): {1}" -f (Count-Of $names), $preview)
    return
  }

  Write-Host ("  Root is {0}" -f $Root.GetType().FullName)
}

function Get-EntryList([AllowNull()][object]$Root, [AllowNull()][string]$Pointer, [switch]$ShowDiscovery, [int]$MaxDepth, [int]$SampleSize) {
  $ptr = Normalize-JsonPointer $Pointer

  $tryPointers = @()
  if ($ptr) { $tryPointers += $ptr }

  foreach ($p in @("/result/list", "/result/materials", "/materials", "/list", "/entries")) {
    if ($tryPointers -notcontains $p) { $tryPointers += $p }
  }

  foreach ($p in $tryPointers) {
    $node = Get-ByJsonPointer -Root $Root -Pointer $p
    if ($node -is [System.Array]) {
      $script:EntriesSourcePath = $p
      $script:EntriesSourceKind = "Array"
      $result = @(@($node) | Where-Object { Is-JsonObject $_ })
      return ,$result
    }
  }

  # Discovery fallback
  $cands = @()
  Find-ArrayCandidates -Node $Root -Path "" -Depth 0 -MaxDepth $MaxDepth -SampleSize $SampleSize -OutList ([ref]$cands)

  if ((Count-Of $cands) -eq 0) {
    throw "Could not locate an entries array inside the JSON. Try specifying -JsonPointer (example: /result/list)."
  }

  $sorted = $cands | Sort-Object -Property @{Expression="AvgScore";Descending=$true}, @{Expression="Count";Descending=$true}

  if ($ShowDiscovery) {
    Write-Host ""
    Write-Host "JSON discovery candidates (Path | Kind | Count | AvgScore):"
    foreach ($c in ($sorted | Select-Object -First 10)) {
      $p = $c.Path
      if ([string]::IsNullOrEmpty($p)) { $p = "/" }
      Write-Host ("  {0} | {1} | {2} | {3}" -f $p, $c.Kind, $c.Count, $c.AvgScore)
    }
  }

  $best = $sorted | Select-Object -First 1
  $path = $best.Path
  if ([string]::IsNullOrEmpty($path)) { $path = "/" }

  $script:EntriesSourcePath = $path
  $script:EntriesSourceKind = $best.Kind

  $node2 = Get-ByJsonPointer -Root $Root -Pointer $path
  if ($node2 -isnot [System.Array]) {
    throw "Discovery chose $path but it isn't an array at runtime. Specify -JsonPointer explicitly."
  }

  $result2 = @(@($node2) | Where-Object { Is-JsonObject $_ })
  return ,$result2
}

# ----------------------------
# Creality entry parsing
# ----------------------------
function Build-CrealityRecord([AllowNull()][object]$Entry) {
  if (-not (Is-JsonObject $Entry)) { return $null }

  $base = Get-Prop $Entry "base"
  $kv   = Get-Prop $Entry "kvParam"

  $crealityId = First-NonEmptyString @((Get-Prop $base "id"), (Get-Prop $Entry "id"))
  $vendorName = First-NonEmptyString @((Get-Prop $kv "filament_vendor"), (Get-Prop $base "brand"), (Get-Prop $Entry "vendor"), (Get-Prop $Entry "brand"))
  $material   = First-NonEmptyString @((Get-Prop $kv "filament_type"), (Get-Prop $base "meterialType"), (Get-Prop $base "materialType"), (Get-Prop $Entry "material"), (Get-Prop $Entry "type"))
  $name       = First-NonEmptyString @((Get-Prop $base "name"), (Get-Prop $Entry "name"), (Get-Prop $Entry "display_name"))

  # Creality filament profiles are treated as colorless "MASTER" templates.
  # Color variants are created on-demand when you create actual spools.
  $colorHex = Normalize-HexColor $MasterTemplateColorHex


  $density  = Try-ParseDouble (First-NonEmptyString @((Get-Prop $kv "filament_density"), (Get-Prop $base "density"), (Get-Prop $Entry "density")))
  $diameter = Try-ParseDouble (First-NonEmptyString @((Get-Prop $kv "filament_diameter"), (Get-Prop $base "diameter"), (Get-Prop $Entry "diameter")))

  $extruderTemp = Try-ParseInt (First-NonEmptyString @((Get-Prop $kv "nozzle_temperature"), (Get-Prop $kv "nozzle_temperature_initial_layer"), (Get-Prop $kv "nozzle_temp")))
  $bedTemp      = Try-ParseInt (First-NonEmptyString @((Get-Prop $kv "cool_plate_temp"), (Get-Prop $kv "hot_plate_temp"), (Get-Prop $kv "textured_plate_temp"), (Get-Prop $kv "eng_plate_temp")))
  $price        = Try-ParseDouble (First-NonEmptyString @((Get-Prop $kv "filament_cost"), (Get-Prop $Entry "price")))

  $inherits = Get-FirstString (Get-Prop $kv "inherits")
  $printer  = Get-FirstString (Get-Prop $Entry "printerIntName")

  $parts = @()
  if ($crealityId) { $parts += ("creality_id={0}" -f $crealityId) }
  if ($printer)    { $parts += ("printer={0}" -f $printer) }
  if ($inherits)   { $parts += ("inherits={0}" -f $inherits) }

  $commentBody = $null
  if ($parts.Count -gt 0) { $commentBody = ($parts -join "; ") } else { $commentBody = "synced from material_database.json" }
  $comment = Trunc ("[$script:SyncTag] " + $commentBody) 1024

  if (-not $vendorName -and -not $name -and -not $material) { return $null }

  return [pscustomobject]@{
    CrealityId   = $crealityId
    VendorName   = $vendorName
    Material     = $material
    Name         = $name
    ColorHex     = $colorHex
    Density      = $density
    Diameter     = $diameter
    ExtruderTemp = $extruderTemp
    BedTemp      = $bedTemp
    Price        = $price
    Comment      = $comment
  }
}

function Build-ArticleNumber([AllowNull()][string]$crealityId) {
  if (-not $crealityId) { return $null }
  return Trunc ("{0}{1}" -f $CrealityArticlePrefix, $crealityId) 64
}

function Build-FilamentExternalId([AllowNull()][string]$crealityId) {
  if ($DisableExternalId -or $script:ExternalIdRuntimeDisabled) { return $null }
  if (-not $crealityId) { return $null }
  return Trunc ("{0}{1}" -f $FilamentExternalIdPrefix, $crealityId) 64
}

function Build-VendorExternalId([AllowNull()][string]$vendorName) {
  if ($DisableExternalId -or $script:ExternalIdRuntimeDisabled) { return $null }
  $n = Normalize-Whitespace $vendorName
  if (-not $n) { return $null }

  # slugify so the external_id is stable and URL-safe-ish
  $slug = $n.ToLowerInvariant()
  $slug = ($slug -replace "\s+", "-")
  $slug = ($slug -replace "[^a-z0-9\-_\.]", "")
  if (-not $slug) { return $null }

  return Trunc ("{0}{1}" -f $VendorExternalIdPrefix, $slug) 64
}

function Is-VariantExternalId([AllowNull()][string]$externalId) {
  if (-not $externalId) { return $false }
  $e = $externalId.ToLowerInvariant()
  return ($e.Contains("|color:") -or $e.Contains("|multi:"))
}


# ----------------------------
# Spoolman API
# ----------------------------
function Resolve-SpoolmanApiBase([string]$url) {
  $u = $url.TrimEnd("/")
  if ($u -match "/api/v\d+$") { return $u }
  return ($u + "/api/v1")
}

function Invoke-SpoolmanRest {
  param(
    [Parameter(Mandatory=$true)][string]$ApiBase,
    [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","DELETE")][string]$Method,
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][object]$Body,
    [AllowNull()][hashtable]$Query
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
    TimeoutSec  = 60
  }

  # WinPS 5.1 compatibility
  if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }

  if ($Method -eq "POST" -or $Method -eq "PATCH") {
    $json = $null
    if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 10) }
    $params.ContentType = "application/json"
    $params.Body = $json
  }

  try {
    return Invoke-RestMethod @params
  }
  catch {
    $msg = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + "`nResponse: " + $_.ErrorDetails.Message }
    throw ("Spoolman API call failed: {0} {1}`n{2}" -f $Method, $uri, $msg)
  }
}


function Disable-ExternalIdRuntime([string]$reason) {
  if (-not $script:ExternalIdRuntimeDisabled) {
    $script:ExternalIdRuntimeDisabled = $true
    Write-Warn ("Spoolman API rejected external_id; disabling external_id for this run. Details: {0}" -f $reason)
  }
}

function Invoke-SpoolmanRestSafe {
  param(
    [Parameter(Mandatory=$true)][string]$ApiBase,
    [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","DELETE")][string]$Method,
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][hashtable]$Body,
    [AllowNull()][hashtable]$Query
  )

  try {
    return Invoke-SpoolmanRest -ApiBase $ApiBase -Method $Method -Path $Path -Body $Body -Query $Query
  }
  catch {
    $msg = $_.Exception.Message
    $hasExternalId = $false
    if ($Body -and ($Body -is [hashtable]) -and $Body.ContainsKey("external_id")) { $hasExternalId = $true }

    if (-not $script:ExternalIdRuntimeDisabled -and -not $DisableExternalId -and $hasExternalId -and ($msg -match "external_id")) {
      Disable-ExternalIdRuntime $msg
      $Body.Remove("external_id") | Out-Null
      return Invoke-SpoolmanRest -ApiBase $ApiBase -Method $Method -Path $Path -Body $Body -Query $Query
    }

    throw
  }
}

function Get-AllPaged {
  param(
    [Parameter(Mandatory=$true)][string]$ApiBase,
    [Parameter(Mandatory=$true)][string]$Path,
    [int]$Limit = 200
  )

  $all = @()
  $offset = 0
  $seenFirstId = $null
  $loops = 0

  while ($true) {
    $loops++
    if ($loops -gt 1000) { throw "Pagination safety-stop hit (1000 loops) for $Path." }

    $batch = Invoke-SpoolmanRest -ApiBase $ApiBase -Method "GET" -Path $Path -Body $null -Query @{ limit = $Limit; offset = $offset }
    $arr = @($batch)

    if ((Count-Of $arr) -eq 0) { break }

    $first = $arr | Select-Object -First 1
    $fid = Get-Prop $first "id"
    if ($null -ne $seenFirstId -and $fid -eq $seenFirstId) {
      Write-Warn "Pagination failsafe: API may be ignoring offset on $Path. Stopping after first page."
      break
    }
    if ($null -eq $seenFirstId) { $seenFirstId = $fid }

    $all += $arr
    if ((Count-Of $arr) -lt $Limit) { break }

    $offset += $Limit
  }

  # Return array object even if 0/1 items (avoid scalar unwrapping)
  return ,$all
}

function As-Int([AllowNull()][object]$x) { try { if ($null -eq $x) { return $null } return [int]$x } catch { return $null } }

function Are-EqualString([AllowNull()][string]$a, [AllowNull()][string]$b) {
  $na = Normalize-Whitespace $a
  $nb = Normalize-Whitespace $b
  if ($null -eq $na -and $null -eq $nb) { return $true }
  if ($null -eq $na -or $null -eq $nb) { return $false }
  return $na.Equals($nb, [StringComparison]::OrdinalIgnoreCase)
}

function Are-EqualNumber([AllowNull()][double]$a, [AllowNull()][double]$b, [double]$eps = 0.0001) {
  if ($null -eq $a -and $null -eq $b) { return $true }
  if ($null -eq $a -or $null -eq $b) { return $false }
  return ([Math]::Abs($a - $b) -le $eps)
}

function Should-UpdateComment([AllowNull()][string]$existing, [AllowNull()][string]$desired) {
  if ($ForceUpdateComments) { return $true }
  if (-not $desired) { return $false }

  $e = Normalize-Whitespace $existing
  if (-not $e) { return $true }

  return ($e.IndexOf("[$script:SyncTag]", [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Compute-FilamentKey([int]$vendorId, [AllowNull()][string]$name, [AllowNull()][string]$material, [AllowNull()][string]$colorHex) {
  $n = Normalize-Key $name
  $m = Normalize-Key $material
  $c = Normalize-Key $colorHex
  return ("{0}|{1}|{2}|{3}" -f $vendorId, $m, $n, $c)
}

function Build-DesiredFilamentPayload([pscustomobject]$rec, [int]$vendorId) {
  # IMPORTANT FIX:
  # Use a plain Hashtable, not [ordered] (OrderedDictionary), so .ContainsKey() exists.
  # OrderedDictionary uses .Contains(), not .ContainsKey(). 
  $payload = @{}

  $payload['vendor_id'] = $vendorId
  if ($rec.Name) {
    $n = Normalize-Whitespace $rec.Name
    if ($n -and $MasterNameSuffix -and -not $n.EndsWith($MasterNameSuffix, [StringComparison]::OrdinalIgnoreCase)) {
      $n = $n + $MasterNameSuffix
    }
    if ($n) { $payload['name'] = (Trunc $n 64) }
  }
  if ($rec.Material) { $payload['material'] = (Trunc $rec.Material 64) }

  # Required by Spoolman on filament create 
  if ($rec.Density  -and $rec.Density  -gt 0) { $payload['density']  = [double]$rec.Density }
  if ($rec.Diameter -and $rec.Diameter -gt 0) { $payload['diameter'] = [double]$rec.Diameter }

  if ($rec.ColorHex) { $payload['color_hex'] = (Trunc $rec.ColorHex 8) }
  if ($rec.ExtruderTemp -ne $null) { $payload['settings_extruder_temp'] = [int]$rec.ExtruderTemp }
  if ($rec.BedTemp      -ne $null) { $payload['settings_bed_temp']      = [int]$rec.BedTemp }
  if ($rec.Price        -ne $null) { $payload['price'] = [double]$rec.Price }

  $eid = Build-FilamentExternalId $rec.CrealityId
  if ($eid) { $payload['external_id'] = $eid }

  $article = Build-ArticleNumber $rec.CrealityId
  if ($article) { $payload['article_number'] = $article }

  if (Should-UpdateComment -existing $null -desired $rec.Comment) {
    if ($rec.Comment) { $payload['comment'] = $rec.Comment }
  }

  return $payload
}

function Diff-Filament([object]$existing, [hashtable]$desired) {
  $update = @{}

  $exVend = As-Int (Get-Prop (Get-Prop $existing "vendor") "id")
  $desVend = As-Int ($desired['vendor_id'])
  if ($null -ne $desVend -and $exVend -ne $desVend) { $update['vendor_id'] = $desVend }

  foreach ($k in @("name","material","color_hex","article_number","external_id")) {
    if ($desired.ContainsKey($k)) {
      $ex = Get-FirstString (Get-Prop $existing $k)
      $de = Get-FirstString $desired[$k]
      if (-not (Are-EqualString $ex $de)) { $update[$k] = $desired[$k] }
    }
  }

  foreach ($k in @("density","diameter","price")) {
    if ($desired.ContainsKey($k)) {
      $exNum = $null
      try { $exNum = [double](Get-Prop $existing $k) } catch { $exNum = $null }
      $deNum = $null
      try { $deNum = [double]$desired[$k] } catch { $deNum = $null }
      if (-not (Are-EqualNumber $exNum $deNum)) { $update[$k] = $desired[$k] }
    }
  }

  foreach ($k in @("settings_extruder_temp","settings_bed_temp")) {
    if ($desired.ContainsKey($k)) {
      $exI = As-Int (Get-Prop $existing $k)
      $deI = As-Int $desired[$k]
      if ($null -ne $deI -and $exI -ne $deI) { $update[$k] = $deI }
    }
  }

  if ($desired.ContainsKey("comment")) {
    $exC = Get-FirstString (Get-Prop $existing "comment")
    $deC = Get-FirstString $desired["comment"]
    if (Should-UpdateComment -existing $exC -desired $deC) {
      if (-not (Are-EqualString $exC $deC)) { $update["comment"] = $desired["comment"] }
    }
  }

  return $update
}

# ----------------------------
# Main
# ----------------------------
Write-Info ("PowerShell: {0}" -f $PSVersionTable.PSVersion.ToString())

if (-not (Test-Path -LiteralPath $MaterialDatabasePath)) {
  throw "MaterialDatabasePath not found: $MaterialDatabasePath"
}

$jsonText = Get-Content -LiteralPath $MaterialDatabasePath -Raw
$root = $jsonText | ConvertFrom-Json

if ($ShowJsonDiscovery) { Show-JsonRootSummary -Root $root }

$entries = Get-EntryList -Root $root -Pointer $JsonPointer -ShowDiscovery:$ShowJsonDiscovery -MaxDepth $DiscoveryDepth -SampleSize $DiscoverySampleSize

Write-Host ("Source entries discovered: {0}" -f (Count-Of $entries))
Write-Host ("Entries source: {0} ({1})" -f $script:EntriesSourcePath, $script:EntriesSourceKind)

$records = @()
$skipped = 0
foreach ($e in $entries) {
  $r = Build-CrealityRecord $e
  if ($null -ne $r) { $records += $r } else { $skipped++ }
}
Write-Host ("Parsed filament records: {0} (skipped {1})" -f (Count-Of $records), $skipped)

if ($ShowJsonDiscovery -and (Count-Of $records) -gt 0) {
  Write-Host ""
  Write-Host "First 3 parsed records:"
  $records | Select-Object -First 3 | ForEach-Object {
    $id = Coalesce $_.CrealityId "-"
    $vn = Coalesce $_.VendorName "-"
    $mt = Coalesce $_.Material "-"
    $nm = Coalesce $_.Name "-"
    $cx = Coalesce $_.ColorHex "-"
    $dn = Coalesce $_.Density "-"
    $di = Coalesce $_.Diameter "-"
    Write-Host ("  id={0} vendor={1} material={2} name={3} color={4} density={5} dia={6}" -f $id,$vn,$mt,$nm,$cx,$dn,$di)
  }
}

$apiBase = Resolve-SpoolmanApiBase $SpoolmanUrl
Write-Info ("Spoolman API base: {0}" -f $apiBase)

$null = Invoke-SpoolmanRest -ApiBase $apiBase -Method "GET" -Path "/health" -Body $null -Query $null
$info = Invoke-SpoolmanRest -ApiBase $apiBase -Method "GET" -Path "/info" -Body $null -Query $null
$ver  = Get-FirstString (Get-Prop $info "version")
if ($ver) { Write-Host ("Spoolman version: {0}" -f $ver) }

$vendors   = Get-AllPaged -ApiBase $apiBase -Path "/vendor"   -Limit $PageSize
$filaments = Get-AllPaged -ApiBase $apiBase -Path "/filament" -Limit $PageSize

Write-Host ("Cached vendors:   {0}" -f (Count-Of $vendors))
Write-Host ("Cached filaments: {0}" -f (Count-Of $filaments))

# Index vendors by normalized name
$vendorByName = @{}
$dryRunVendorId = -1000

foreach ($v in $vendors) {
  $n = Get-FirstString (Get-Prop $v "name")
  if ($n) {
    $k = Normalize-Key $n
    if ($k) { $vendorByName[$k] = $v }
  }
}

# Index filaments (external_id + article_number). We treat Creality profiles as MASTER filaments.
$filamentByExternalId = @{}
$filamentByArticle = @{}
$filamentByKey = @{}

foreach ($f in $filaments) {
  $an = Get-FirstString (Get-Prop $f "article_number")
  if ($an) {
    $ak = Normalize-Key $an
    if ($ak) { $filamentByArticle[$ak] = $f }
  }
  $eid = Get-FirstString (Get-Prop $f "external_id")
  if ($eid) {
    $ek = Normalize-Key $eid
    if ($ek) { $filamentByExternalId[$ek] = $f }
  }


  $vendId = As-Int (Get-Prop (Get-Prop $f "vendor") "id")
  $key = Compute-FilamentKey -vendorId $vendId -name (Get-FirstString (Get-Prop $f "name")) -material (Get-FirstString (Get-Prop $f "material")) -colorHex (Get-FirstString (Get-Prop $f "color_hex"))
  if ($key) { $filamentByKey[$key] = $f }
}

$createdVendors = 0
$createdFilaments = 0
$updatedFilaments = 0
$skippedFilaments = 0

foreach ($rec in $records) {
  $vName = $rec.VendorName
  if (-not $vName) {
    Write-Warn ("Skipping record with no vendor name (creality_id={0}, name={1})" -f (Coalesce $rec.CrealityId "-"), (Coalesce $rec.Name "-"))
    $skippedFilaments++
    continue
  }

  $vk = Normalize-Key $vName
  if (-not $vk) { $skippedFilaments++; continue }

  if (-not $vendorByName.ContainsKey($vk)) {
    $payload = @{ name = (Trunc $vName 64); comment = (Trunc ("[$script:SyncTag] created by sync script") 1024) }
    $veid = Build-VendorExternalId $vName
    if ($veid) { $payload['external_id'] = $veid }


    if ($DryRun) {
      Write-Host ("[DryRun] Would create vendor: {0}" -f $payload.name)
      $vendorByName[$vk] = [pscustomobject]@{ id = $dryRunVendorId; name = $payload.name }
      $dryRunVendorId--
      $createdVendors++
    } else {
      $newVendor = Invoke-SpoolmanRestSafe -ApiBase $apiBase -Method "POST" -Path "/vendor" -Body $payload -Query $null
      $vendorByName[$vk] = $newVendor
      $createdVendors++
      Write-Host ("Created vendor: {0} (id={1})" -f (Get-FirstString (Get-Prop $newVendor "name")), (Get-Prop $newVendor "id"))
    }
  }

  $vendor = $vendorByName[$vk]
  $vendorId = As-Int (Get-Prop $vendor "id")

  $desired = Build-DesiredFilamentPayload -rec $rec -vendorId $vendorId

  # Validate required Spoolman fields 
  if (-not $desired.ContainsKey("density") -or -not $desired.ContainsKey("diameter")) {
    Write-Warn ("Skipping filament missing density/diameter (vendor={0}, name={1}, material={2}, creality_id={3})" -f
      $rec.VendorName, (Coalesce $rec.Name "-"), (Coalesce $rec.Material "-"), (Coalesce $rec.CrealityId "-"))
    $skippedFilaments++
    continue
  }

  # Find existing filament (masters only: external_id -> article_number fallback)
  $existing = $null
  $matchedOn = $null

  $eid = $null
  if ($desired.ContainsKey("external_id")) { $eid = Get-FirstString $desired["external_id"] }
  if ($eid) {
    $ek = Normalize-Key $eid
    if ($ek -and $filamentByExternalId.ContainsKey($ek)) { $existing = $filamentByExternalId[$ek]; $matchedOn = "external_id" }
  }

  if ($null -eq $existing) {
    $article = $null
    if ($desired.ContainsKey("article_number")) { $article = Get-FirstString $desired["article_number"] }
    if ($article) {
      $ak = Normalize-Key $article
      if ($ak -and $filamentByArticle.ContainsKey($ak)) { $existing = $filamentByArticle[$ak]; $matchedOn = "article_number" }
    }
  }

  if ($existing) {
    $existingEid = Get-FirstString (Get-Prop $existing "external_id")
    if (Is-VariantExternalId $existingEid) {
      Write-Warn ("Matched a color-variant filament (external_id={0}). This sync script only manages MASTER filaments, so skipping it. (creality_id={1})" -f $existingEid, (Coalesce $rec.CrealityId "-"))
      $skippedFilaments++
      continue
    }


    # Additional safety when we had to fall back to article_number matching.
    # This can happen if your Spoolman version doesn't support external_id, or if older masters were created
    # before external_id existed. To avoid accidentally matching a color variant that copied the master article_number,
    # we require the existing filament name to match the Creality profile name (or its MASTER form),
    # unless -AllowUnsafeArticleNumberMatches is set.
    if ($matchedOn -eq "article_number" -and -not $AllowUnsafeArticleNumberMatches) {
      $existingName = Get-FirstString (Get-Prop $existing "name")
      if (-not (Name-MatchesProfileOrMaster -ExistingName $existingName -ProfileName $rec.Name)) {
        $fid = Get-Prop $existing "id"
        Write-Warn ("Matched by article_number but the existing filament's name doesn't match the Creality profile name. This could be a color variant that copied the master article_number. Skipping for safety. (creality_id={0}, filament_id={1}, existing_name={2})" -f (Coalesce $rec.CrealityId "-"), $fid, (Coalesce $existingName "-"))
        $skippedFilaments++
        continue
      }
    }

    # If we matched by article_number but the existing filament already has an external_id that doesn't match
    # the expected master external_id, skip. This prevents clobbering other integrations.
    if ($matchedOn -eq "article_number") {
      $expectedEid = $null
      if ($eid) { $expectedEid = $eid }
      else { $expectedEid = Build-FilamentExternalId $rec.CrealityId }
      if ($expectedEid -and $existingEid -and ($existingEid -ne $expectedEid)) {
        $fid = Get-Prop $existing "id"
        Write-Warn ("Matched by article_number but existing external_id={0} does not match expected master external_id={1}. Skipping. (creality_id={2}, filament_id={3})" -f $existingEid, $expectedEid, (Coalesce $rec.CrealityId "-"), $fid)
        $skippedFilaments++
        continue
      }
    }

    $diff = Diff-Filament -existing $existing -desired $desired

    if ($diff.Count -gt 0) {
      $fid = Get-Prop $existing "id"

      if (-not $UpdateExistingFilaments) {
        Write-Host ("Exists filament id={0} (updates disabled). Would change: {1}" -f $fid, (($diff.Keys | Sort-Object) -join ", "))
      }
      elseif ($DryRun) {
        Write-Host ("[DryRun] Would update filament id={0}: {1}" -f $fid, (($diff.Keys | Sort-Object) -join ", "))
        $updatedFilaments++
      }
      else {
        $updated = Invoke-SpoolmanRestSafe -ApiBase $apiBase -Method "PATCH" -Path ("/filament/{0}" -f $fid) -Body $diff -Query $null
        $updatedFilaments++
        Write-Host ("Updated filament id={0}" -f $fid)

        # refresh indexes
        $an2 = Get-FirstString (Get-Prop $updated "article_number")
        if ($an2) {
          $ak2 = Normalize-Key $an2
          if ($ak2) { $filamentByArticle[$ak2] = $updated }
        }
        $eid2 = Get-FirstString (Get-Prop $updated "external_id")
        if ($eid2) {
          $ek2 = Normalize-Key $eid2
          if ($ek2) { $filamentByExternalId[$ek2] = $updated }
        }

        $vend2 = As-Int (Get-Prop (Get-Prop $updated "vendor") "id")
        $k2 = Compute-FilamentKey -vendorId $vend2 -name (Get-FirstString (Get-Prop $updated "name")) -material (Get-FirstString (Get-Prop $updated "material")) -colorHex (Get-FirstString (Get-Prop $updated "color_hex"))
        if ($k2) { $filamentByKey[$k2] = $updated }
      }
    }
  }
  else {
    if ($DryRun) {
      Write-Host ("[DryRun] Would create filament: vendor={0} name={1} material={2} color={3} article={4} external_id={5}" -f
        $rec.VendorName,
        (Coalesce $desired["name"] "-"),
        (Coalesce $desired["material"] "-"),
        (Coalesce $desired["color_hex"] "-"),
        (Coalesce $desired["article_number"] "-"),
        (Coalesce $desired["external_id"] "-"))
      $createdFilaments++
    } else {
      $created = Invoke-SpoolmanRestSafe -ApiBase $apiBase -Method "POST" -Path "/filament" -Body $desired -Query $null
      $createdFilaments++
      $fid2 = Get-Prop $created "id"
      Write-Host ("Created filament id={0}: {1}" -f $fid2, (Get-FirstString (Get-Prop $created "name")))

      $an3 = Get-FirstString (Get-Prop $created "article_number")
      if ($an3) {
        $ak3 = Normalize-Key $an3
        if ($ak3) { $filamentByArticle[$ak3] = $created }
      }
      $eid3 = Get-FirstString (Get-Prop $created "external_id")
      if ($eid3) {
        $ek3 = Normalize-Key $eid3
        if ($ek3) { $filamentByExternalId[$ek3] = $created }
      }

      $vend3 = As-Int (Get-Prop (Get-Prop $created "vendor") "id")
      $k3 = Compute-FilamentKey -vendorId $vend3 -name (Get-FirstString (Get-Prop $created "name")) -material (Get-FirstString (Get-Prop $created "material")) -colorHex (Get-FirstString (Get-Prop $created "color_hex"))
      if ($k3) { $filamentByKey[$k3] = $created }
    }
  }
}

Write-Host ""
Write-Host "Summary:"
Write-Host ("  Vendors created (or would create):   {0}" -f $createdVendors)
Write-Host ("  Filaments created (or would create): {0}" -f $createdFilaments)
Write-Host ("  Filaments updated (or would update): {0}" -f $updatedFilaments)
Write-Host ("  Filaments skipped:                   {0}" -f $skippedFilaments)
Write-Host ("  DryRun:                              {0}" -f $DryRun)
Write-Host ("  UpdateExisting:                      {0}" -f $UpdateExistingFilaments)
