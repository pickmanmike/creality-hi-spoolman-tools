#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SpoolmanUrl = "http://127.0.0.1:7912",
    [switch]$Apply,
    [int[]]$SpoolIds,
    [switch]$SkipTagUid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ApiBase([string]$Url) {
    $u = ([string]$Url).TrimEnd('/')
    if ($u -match '/api/v\d+$') { return $u }
    return "$u/api/v1"
}

function Invoke-SpoolmanRest {
    param(
        [Parameter(Mandatory=$true)][string]$ApiBase,
        [Parameter(Mandatory=$true)][ValidateSet('GET','PATCH')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][object]$Body = $null,
        [int]$TimeoutSec = 30
    )
    $uri = ($ApiBase.TrimEnd('/') + $Path)
    $params = @{ Method = $Method; Uri = $uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
    if ($Method -eq 'PATCH') {
        $params.ContentType = 'application/json'
        if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 15 -Compress) }
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $msg += "`nResponse:`n$($_.ErrorDetails.Message)"
        }
        throw "Spoolman API call failed: $Method $uri`n$msg"
    }
}

function Get-ResponseItems([object]$Response) {
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Array]) { return @($Response) }
    foreach ($p in 'result','items','data') {
        if ($Response.PSObject.Properties.Name -contains $p) {
            $v = $Response.$p
            if ($v -is [System.Array]) { return @($v) }
            return @($v)
        }
    }
    return @($Response)
}

function Get-Spools([string]$ApiBase) {
    $resp = Invoke-SpoolmanRest -ApiBase $ApiBase -Method GET -Path '/spool?allow_archived=true'
    return (Get-ResponseItems $resp)
}

function Get-SpoolFieldDefs([string]$ApiBase) {
    $resp = Invoke-SpoolmanRest -ApiBase $ApiBase -Method GET -Path '/field/spool'
    $map = @{}
    foreach ($row in (Get-ResponseItems $resp)) {
        if ($row -and $row.key) {
            $map[[string]$row.key] = @{
                field_type = [string]$row.field_type
                name       = [string]$row.name
            }
        }
    }
    return $map
}

function Parse-CrealityComment([string]$Comment,[switch]$SkipTagUid) {
    if ([string]::IsNullOrWhiteSpace($Comment)) { return $null }
    if ($Comment -notmatch '\[CFS-RFID\]') { return $null }

    $result = [ordered]@{}
    $uids = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($Comment -split "`r?`n")) {
        if ($line -match 'creality_id=([^;\r\n]+)')              { $result['crealitycreality_id'] = [string]$Matches[1].Trim() }
        if ($line -match 'color=([^;\r\n]+)')                    { $result['crealitycolor'] = [string]$Matches[1].Trim() }
        if ($line -match 'color_hex=([^;\r\n]+)')                { $result['crealitycolor_hex'] = [string]$Matches[1].Trim() }
        if ($line -match 'filament_article=([^;\r\n]+)')         { $result['crealityfilament_article'] = [string]$Matches[1].Trim() }
        if ($line -match 'printer_type=([^;\r\n]+)')             { $result['crealityprinter_type'] = [string]$Matches[1].Trim() }
        elseif ($line -match 'printer=([^;\r\n]+)')              { $result['crealityprinter_type'] = [string]$Matches[1].Trim() }
        if ($line -match 'serial=([^;\r\n]+)') {
            $s = [string]$Matches[1].Trim()
            if ($s -match '^\d+$' -and $s.Length -le 6) { $s = $s.PadLeft(6,'0') }
            $result['crealityserial_num'] = $s
        }
        if (-not $SkipTagUid -and $line -match 'tag_uid=([^;\r\n]+)') {
            $uid = [string]$Matches[1].Trim().ToUpperInvariant()
            if ($uid -and -not $uids.Contains($uid)) { [void]$uids.Add($uid) }
        }
    }

    if (-not $SkipTagUid -and $uids.Count -gt 0) {
        $result['crealitytag_uid'] = ($uids -join ',')
    }

    if ($result.Count -eq 0) { return $null }
    return $result
}

function Encode-ExtraValue([string]$FieldType, [AllowNull()][object]$Value) {
    $t = ([string]$FieldType).ToLowerInvariant()
    $s = if ($null -eq $Value) { '' } else { [string]$Value }

    switch ($t) {
        'text'     { return (ConvertTo-Json $s -Compress) }
        'choice'   { return (ConvertTo-Json $s -Compress) }
        'datetime' { return (ConvertTo-Json $s -Compress) }
        'boolean'  {
            $boolVal = $false
            if ($s -match '^(1|true|yes)$') { $boolVal = $true }
            elseif ($s -match '^(0|false|no)$') { $boolVal = $false }
            else { return (ConvertTo-Json $s -Compress) }
            return (ConvertTo-Json $boolVal -Compress)
        }
        'integer' {
            $tmp = 0
            if ([int]::TryParse($s, [ref]$tmp)) { return (ConvertTo-Json $tmp -Compress) }
            return (ConvertTo-Json $s -Compress)
        }
        'float' {
            $tmp = 0.0
            if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)) {
                return (ConvertTo-Json $tmp -Compress)
            }
            return (ConvertTo-Json $s -Compress)
        }
        default { return (ConvertTo-Json $s -Compress) }
    }
}

$apiBase = Resolve-ApiBase $SpoolmanUrl
$dryRun  = -not $Apply.IsPresent
if ($dryRun) { Write-Host '[INFO] DryRun: enabled (use -Apply to PATCH)' }

$fieldDefs = Get-SpoolFieldDefs -ApiBase $apiBase
$requiredKeys = @('crealitycreality_id','crealitycolor','crealitycolor_hex','crealityfilament_article','crealityserial_num','crealityprinter_type')
if (-not $SkipTagUid) { $requiredKeys += 'crealitytag_uid' }

$missingFieldKeys = @($requiredKeys | Where-Object { -not $fieldDefs.ContainsKey($_) })
if ($missingFieldKeys.Count -gt 0) {
    throw "Required Spoolman spool extra fields are missing: $($missingFieldKeys -join ', '). Run Ensure-Spoolman-CrealityExtraFields.Local.v6.ps1 -Apply first."
}

$targets = if ($SpoolIds -and $SpoolIds.Count -gt 0) {
    @($SpoolIds | ForEach-Object { @{ id = $_ } })
}
else {
    Get-Spools -ApiBase $apiBase
}

$scanned = 0
$matched = 0
$updated = 0
$failed = 0
$drySkipped = 0

foreach ($spoolStub in $targets) {
    $id = [int]$spoolStub.id
    $scanned++

    try {
        $spool = Invoke-SpoolmanRest -ApiBase $apiBase -Method GET -Path "/spool/$id"
    }
    catch {
        $failed++
        Write-Warning ("Failed to fetch spool {0}: {1}" -f $id, $_.Exception.Message)
        continue
    }

    $parsed = Parse-CrealityComment -Comment ([string]$spool.comment) -SkipTagUid:$SkipTagUid
    if ($null -eq $parsed) { continue }
    $matched++

    $mergedEncoded = @{}

    if ($spool.extra) {
        foreach ($p in $spool.extra.PSObject.Properties) {
            $k = [string]$p.Name
            $fieldType = if ($fieldDefs.ContainsKey($k)) { [string]$fieldDefs[$k].field_type } else { 'text' }
            $mergedEncoded[$k] = Encode-ExtraValue -FieldType $fieldType -Value $p.Value
        }
    }

    foreach ($k in $parsed.Keys) {
        $fieldType = if ($fieldDefs.ContainsKey($k)) { [string]$fieldDefs[$k].field_type } else { 'text' }
        $mergedEncoded[$k] = Encode-ExtraValue -FieldType $fieldType -Value $parsed[$k]
    }

    if ($dryRun) {
        $drySkipped++
        Write-Host ("[DryRun] spool {0}: extra keys -> {1}" -f $id, ($parsed.Keys -join ', '))
        continue
    }

    try {
        $body = @{ extra = $mergedEncoded }
        $null = Invoke-SpoolmanRest -ApiBase $apiBase -Method PATCH -Path "/spool/$id" -Body $body
        $updated++
        Write-Host ("[Apply] spool {0}: updated extra keys -> {1}" -f $id, ($parsed.Keys -join ', '))
    }
    catch {
        $failed++
        Write-Warning ("Failed to update spool {0}: {1}" -f $id, $_.Exception.Message)
    }
}

Write-Host ""
Write-Host ("[INFO] Summary: scanned={0}, matched={1}, updated={2}, dryrun_skipped={3}, failed={4}" -f $scanned, $matched, $updated, $drySkipped, $failed)
