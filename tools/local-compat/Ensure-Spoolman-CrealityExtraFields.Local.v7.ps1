#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SpoolmanUrl = "http://127.0.0.1:7912",
    [switch]$Apply
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
        [Parameter(Mandatory=$true)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][object]$Body = $null,
        [int]$TimeoutSec = 30
    )
    $uri = ($ApiBase.TrimEnd('/') + $Path)
    $params = @{ Method = $Method; Uri = $uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
    if ($Method -eq 'POST') {
        $params.ContentType = 'application/json'
        if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
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

function Norm([AllowNull()][object]$v) {
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

$apiBase = Resolve-ApiBase $SpoolmanUrl

$desired = @(
    @{ key='crealitycreality_id';      name='creality.creality_id';      field_type='text' },
    @{ key='crealitycolor';            name='creality.color';            field_type='text' },
    @{ key='crealitycolor_hex';        name='creality.color_hex';        field_type='text' },
    @{ key='crealityfilament_article'; name='creality.filament_article'; field_type='text' },
    @{ key='crealityserial_num';       name='creality.serial_num';       field_type='text' },
    @{ key='crealityprinter_type';     name='creality.printer_type';     field_type='text' },
    @{ key='crealitytag_uid';          name='creality.tag_uid';          field_type='text' }
)

$existingByKey = @{}
try {
    $resp = Invoke-SpoolmanRest -ApiBase $apiBase -Method GET -Path '/field/spool'
    foreach ($row in (Get-ResponseItems $resp)) {
        if ($row -and $row.key) { $existingByKey[[string]$row.key] = $row }
    }
}
catch {
    Write-Warning ("Could not read existing extra fields: {0}" -f $_.Exception.Message)
}

$missing = New-Object System.Collections.Generic.List[object]
$drifted = New-Object System.Collections.Generic.List[object]
$okCount = 0

foreach ($f in $desired) {
    if (-not $existingByKey.ContainsKey($f.key)) {
        [void]$missing.Add([pscustomobject]$f)
        Write-Host ("[MISS]  spool field missing: {0} (name='{1}', type='{2}')" -f $f.key, $f.name, $f.field_type)
        continue
    }

    $cur = $existingByKey[$f.key]
    $nameOk = (Norm $cur.name) -eq (Norm $f.name)
    $typeOk = (Norm $cur.field_type) -eq (Norm $f.field_type)

    if ($nameOk -and $typeOk) {
        $okCount++
        Write-Host ("[OK]    spool field exists: {0} (name='{1}', type='{2}')" -f $f.key, $cur.name, $cur.field_type)
    }
    else {
        [void]$drifted.Add([pscustomobject]@{
            key = $f.key
            current_name = [string]$cur.name
            current_type = [string]$cur.field_type
            desired_name = [string]$f.name
            desired_type = [string]$f.field_type
        })
        Write-Warning ("Field definition drift for {0}: current(name='{1}', type='{2}') desired(name='{3}', type='{4}')" -f $f.key, [string]$cur.name, [string]$cur.field_type, $f.name, $f.field_type)
    }
}

if (-not $Apply) {
    Write-Host ""
    $existingCount = ($desired.Count - $missing.Count)
    Write-Host ("DryRun: missing={0}, existing={1}, drifted={2}, ok={3}" -f $missing.Count, $existingCount, $drifted.Count, $okCount)
    if ($missing.Count -gt 0 -or $drifted.Count -gt 0) {
        Write-Host "Run again with -Apply to create missing fields and re-ensure drifted name/type definitions."
    }
    return
}

$toEnsure = @()
foreach ($f in $desired) {
    if (-not $existingByKey.ContainsKey($f.key)) {
        $toEnsure += $f
        continue
    }
    $cur = $existingByKey[$f.key]
    $nameOk = (Norm $cur.name) -eq (Norm $f.name)
    $typeOk = (Norm $cur.field_type) -eq (Norm $f.field_type)
    if (-not ($nameOk -and $typeOk)) {
        $toEnsure += $f
    }
}

foreach ($f in $toEnsure) {
    $body = @{
        name = $f.name
        field_type = $f.field_type
    }
    $null = Invoke-SpoolmanRest -ApiBase $apiBase -Method POST -Path ("/field/spool/{0}" -f $f.key) -Body $body
    Write-Host ("[APPLY] spool field ensured: {0} (name='{1}', type='{2}')" -f $f.key, $f.name, $f.field_type)
}

Write-Host ""
Write-Host ("Done. Spool extra-field definitions are ready. ensured={0}" -f $toEnsure.Count)
