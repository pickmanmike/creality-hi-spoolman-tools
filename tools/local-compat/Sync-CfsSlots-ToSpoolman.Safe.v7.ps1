#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$UpdateRemainingWeight,
    [switch]$ShowSlots,
    [string]$TrustedRfidValue = '2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ObjPropValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory=$true)][string[]]$Names,
        [AllowNull()][object]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) {
            return $p.Value
        }
    }
    return $Default
}

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

function To-IntOrNull($Value) {
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s -match '^\d+$') { return [int]$s }
    return $null
}

function Read-MaterialBoxInfo {
    param(
        [Parameter(Mandatory=$true)][string]$SshUser,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][string]$KeyPath,
        [Parameter(Mandatory=$true)][int]$SshPort,
        [Parameter(Mandatory=$true)][string]$RemotePath
    )
    $args = @('-i', $KeyPath, '-p', [string]$SshPort, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', ("{0}@{1}" -f $SshUser, $TargetHost), ("cat {0}" -f $RemotePath))
    $raw = & ssh @args
    if ($LASTEXITCODE -ne 0) {
        throw ("SSH read failed for {0}@{1}:{2}" -f $SshUser, $TargetHost, $RemotePath)
    }
    try {
        return ($raw | ConvertFrom-Json -Depth 40)
    }
    catch {
        throw ("SSH JSON parse failed for {0}@{1}:{2}`n{3}" -f $SshUser, $TargetHost, $RemotePath, $_.Exception.Message)
    }
}

function Resolve-SpoolId {
    param(
        [string]$Reserve,
        [string]$Serial,
        [string]$ReserveMode,
        [string]$Rfid,
        [string]$TrustedRfidValue
    )

    $reserveText = ([string]$Reserve).Trim()
    if ($reserveText -match '^\d{6}$' -and $reserveText -ne '000000') {
        return [int]$reserveText
    }
    if ($ReserveMode -eq 'hex' -and $reserveText -match '^[0-9A-Fa-f]{6}$' -and $reserveText -ne '000000') {
        return [Convert]::ToInt32($reserveText, 16)
    }

    $rfidText = ([string]$Rfid).Trim()
    if ($rfidText -ne ([string]$TrustedRfidValue)) {
        return $null
    }

    $serialText = ([string]$Serial).Trim()
    if ($serialText -match '^\d{6}$' -and $serialText -ne '000000') {
        return [int]$serialText
    }

    return $null
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -Depth 40
$apiBase = Resolve-ApiBase ([string](Get-ObjPropValue -Object $cfg -Names @('spoolmanUrl','spoolmanURL') -Default 'http://127.0.0.1:7912'))
$reserveMode = [string](Get-ObjPropValue -Object $cfg -Names @('reserveMode') -Default 'decimal')
$locationPrefix = [string](Get-ObjPropValue -Object $cfg -Names @('locationPrefix') -Default 'CFS')
$locationPrefix = $locationPrefix.TrimEnd(':')

$printers = @(Get-ObjPropValue -Object $cfg -Names @('printers') -Default @())
if ($printers.Count -lt 1) { throw "No printers[] entries found in config: $ConfigPath" }

$printer = $printers[0]
$keyPath = Get-ObjPropValue -Object $printer -Names @('sshKey','sshKeyPath') -Default $null
if ($null -eq $keyPath -or [string]::IsNullOrWhiteSpace([string]$keyPath)) {
    $keyPath = Get-ObjPropValue -Object $cfg -Names @('sshKeyPath','sshKey') -Default $null
}
if ($null -eq $keyPath -or [string]::IsNullOrWhiteSpace([string]$keyPath)) {
    throw "No ssh key path found in config (tried printer.sshKey / printer.sshKeyPath / cfg.sshKeyPath / cfg.sshKey)."
}
$keyPath = [Environment]::ExpandEnvironmentVariables([string]$keyPath)

$sshUser = [string](Get-ObjPropValue -Object $printer -Names @('sshUser','user') -Default 'root')
$sshPort = [int](Get-ObjPropValue -Object $printer -Names @('sshPort','port') -Default 22)
$printerHost = [string](Get-ObjPropValue -Object $printer -Names @('host','ip','hostname') -Default '')
if ([string]::IsNullOrWhiteSpace($printerHost)) { throw "Printer host/ip missing in config." }

$materialBoxInfoPath = [string](Get-ObjPropValue -Object $printer -Names @('materialBoxInfoPath') -Default (Get-ObjPropValue -Object $cfg -Names @('materialBoxInfoPath') -Default '/mnt/UDISK/creality/userdata/box/material_box_info.json'))
$printerName = [string](Get-ObjPropValue -Object $printer -Names @('name') -Default 'CrealityHi')
$locationName = [string](Get-ObjPropValue -Object $printer -Names @('locationName') -Default $printerName)

if (-not (Test-Path $keyPath)) {
    throw "sshKey not found: $keyPath"
}

Write-Host ("[INFO] Remaining sync: {0}" -f $(if ($UpdateRemainingWeight) { 'enabled' } else { 'disabled' }))
Write-Host ("[INFO] Spoolman API base: {0}" -f $apiBase)
Write-Host ("[INFO] Reading {0} ({1}): {2}" -f $printerName, $printerHost, $materialBoxInfoPath)
Write-Host ("[INFO] Serial fallback trusted only when rfid={0}" -f $TrustedRfidValue)

$data = Read-MaterialBoxInfo -SshUser $sshUser -TargetHost $printerHost -KeyPath $keyPath -SshPort $sshPort -RemotePath $materialBoxInfoPath

$material = Get-ObjPropValue -Object $data -Names @('Material','material') -Default $null
if ($null -eq $material) { throw "material_box_info.json did not contain a Material/material object." }

$boxes = @(Get-ObjPropValue -Object $material -Names @('info','Info') -Default @())
if ($boxes.Count -eq 0) { Write-Warning "No boxes found in material_box_info.json" }

$slots = @()
foreach ($box in $boxes) {
    $boxId = [string](Get-ObjPropValue -Object $box -Names @('boxID','boxId') -Default '')
    $list  = @(Get-ObjPropValue -Object $box -Names @('list','List') -Default @())
    foreach ($slot in $list) {
        $slotKey = "{0}{1}" -f $boxId, ([string](Get-ObjPropValue -Object $slot -Names @('materialId') -Default ''))
        $reserve = [string](Get-ObjPropValue -Object $slot -Names @('reserve') -Default '')
        $serial  = [string](Get-ObjPropValue -Object $slot -Names @('serialNum','serial') -Default '')
        $rfid    = [string](Get-ObjPropValue -Object $slot -Names @('rfid') -Default '')
        $remain  = To-IntOrNull (Get-ObjPropValue -Object $slot -Names @('remainLen') -Default $null)

        $spoolId = Resolve-SpoolId -Reserve $reserve -Serial $serial -ReserveMode $reserveMode -Rfid $rfid -TrustedRfidValue $TrustedRfidValue

        $slots += [pscustomobject]@{
            slotKey    = $slotKey
            reserve    = $reserve
            serial     = $serial
            rfid       = $rfid
            spoolId    = $spoolId
            remain     = $remain
            filamentId = [string](Get-ObjPropValue -Object $slot -Names @('filamentId') -Default '')
            color      = [string](Get-ObjPropValue -Object $slot -Names @('color') -Default '')
            brand      = [string](Get-ObjPropValue -Object $slot -Names @('brand') -Default '')
            name       = [string](Get-ObjPropValue -Object $slot -Names @('name') -Default '')
        }
    }
}

if ($ShowSlots) {
    $slots | Format-Table slotKey,reserve,serial,rfid,spoolId,remain,filamentId,color,brand,name -AutoSize
}

$valid = @()
$skippedUnknown = 0
foreach ($row in $slots) {
    if ($null -eq $row.spoolId) { continue }

    $spool = $null
    try {
        $spool = Invoke-SpoolmanRest -ApiBase $apiBase -Method GET -Path ("/spool/{0}" -f $row.spoolId)
    }
    catch {
        $spool = $null
    }

    if ($null -eq $spool) {
        $skippedUnknown++
        Write-Warning ("Skipping {0}: resolved spool id {1} does not exist in Spoolman" -f $row.slotKey, $row.spoolId)
        continue
    }

    $baseWeight = $null
    if ($null -ne $spool.initial_weight) {
        $baseWeight = [double]$spool.initial_weight
    }
    elseif ($spool.filament -and $null -ne $spool.filament.weight) {
        $baseWeight = [double]$spool.filament.weight
    }

    $remainingWeight = $null
    if ($UpdateRemainingWeight -and $null -ne $row.remain -and $row.remain -ge 0 -and $row.remain -le 100 -and $null -ne $baseWeight) {
        $remainingWeight = [Math]::Round(($baseWeight * ($row.remain / 100.0)), 1)
    }

    $valid += [pscustomobject]@{
        slotKey         = $row.slotKey
        spoolId         = $row.spoolId
        location        = ("{0}:{1}:{2}" -f $locationPrefix, $locationName, $row.slotKey)
        remainingWeight = $remainingWeight
    }
}

$groups = $valid | Group-Object spoolId
$final = @()
$skippedDuplicateGroups = 0
foreach ($g in $groups) {
    if ($g.Count -gt 1) {
        $skippedDuplicateGroups++
        Write-Warning ("Skipping duplicate spool id {0} seen in slots: {1}" -f $g.Name, (($g.Group.slotKey) -join ', '))
        continue
    }
    $final += $g.Group[0]
}

$appliedCount = 0
$unchangedCount = 0

foreach ($row in $final) {
    $current = Invoke-SpoolmanRest -ApiBase $apiBase -Method GET -Path ("/spool/{0}" -f $row.spoolId)

    $body = @{ location = $row.location }
    if ($UpdateRemainingWeight -and $null -ne $row.remainingWeight) {
        $body.remaining_weight = $row.remainingWeight
    }

    $sameLocation = ([string](Get-ObjPropValue -Object $current -Names @('location') -Default '')) -eq ([string]$row.location)
    $sameRemaining = $true
    if ($body.ContainsKey('remaining_weight')) {
        $curRem = Get-ObjPropValue -Object $current -Names @('remaining_weight') -Default $null
        $sameRemaining = ($null -ne $curRem) -and ([double]$curRem -eq [double]$row.remainingWeight)
    }

    if ($sameLocation -and $sameRemaining) {
        $unchangedCount++
        if (-not $Apply) {
            Write-Host ("[DryRun] SKIP /spool/{0} unchanged" -f $row.spoolId)
        }
        continue
    }

    if (-not $Apply) {
        Write-Host ("[DryRun] PATCH /spool/{0} {1}" -f $row.spoolId, ($body | ConvertTo-Json -Compress))
        continue
    }

    $null = Invoke-SpoolmanRest -ApiBase $apiBase -Method PATCH -Path ("/spool/{0}" -f $row.spoolId) -Body $body
    $appliedCount++
    Write-Host ("[Apply] spool {0} -> {1}" -f $row.spoolId, $row.location)
}

$dryRun = -not $Apply
Write-Host ""
Write-Host ("[INFO] Summary: candidates={0}, valid={1}, skippedUnknown={2}, skippedDuplicateGroups={3}, unchanged={4}, applied={5}, dryrun={6}" -f $slots.Count, $final.Count, $skippedUnknown, $skippedDuplicateGroups, $unchangedCount, $appliedCount, $dryRun)
