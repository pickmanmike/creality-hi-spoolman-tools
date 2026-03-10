#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SpoolmanUrl = "http://127.0.0.1:7912",
    [int[]]$SpoolIds = @(5,6,9,10)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ApiBase([string]$Url) {
    $u = ([string]$Url).TrimEnd('/')
    if ($u -match '/api/v\d+$') { return $u }
    return "$u/api/v1"
}

function Invoke-Spoolman {
    param(
        [string]$ApiBase,
        [ValidateSet('GET')] [string]$Method,
        [string]$Path
    )
    $uri = $ApiBase.TrimEnd('/') + $Path
    return Invoke-RestMethod -Method $Method -Uri $uri -ErrorAction Stop -TimeoutSec 30
}

function Decode-ExtraValue([object]$Value) {
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    try {
        # Spoolman custom field values are JSON-encoded in REST output.
        $decoded = $s | ConvertFrom-Json -ErrorAction Stop
        return $decoded
    }
    catch {
        return $s
    }
}

$apiBase = Resolve-ApiBase $SpoolmanUrl

foreach ($id in $SpoolIds) {
    $spool = Invoke-Spoolman -ApiBase $apiBase -Method GET -Path "/spool/$id"

    $decodedExtra = [ordered]@{}
    if ($spool.extra) {
        foreach ($p in $spool.extra.PSObject.Properties) {
            $decodedExtra[$p.Name] = Decode-ExtraValue $p.Value
        }
    }

    [pscustomobject]@{
        id = $spool.id
        location = $spool.location
        remaining_weight = $spool.remaining_weight
        raw_extra = $spool.extra
        decoded_extra = [pscustomobject]$decodedExtra
    } | ConvertTo-Json -Depth 20
}
