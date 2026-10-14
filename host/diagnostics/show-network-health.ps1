[CmdletBinding()]
param([ValidateRange(1, 200)][int]$Last = 30)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'logs\network-health.jsonl'
$records = @(Get-Content -LiteralPath $path -Encoding UTF8 -Tail $Last | ForEach-Object { $_ | ConvertFrom-Json })
$records | ForEach-Object {
    $age = $null; $rx = $null; $tx = $null
    if ($_.PSObject.Properties.Name -contains 'guest' -and $_.guest.PSObject.Properties.Name -contains 'wg_after') {
        $wg = $_.guest.wg_after
        $age = $wg.handshake_age_seconds
        if ($wg.PSObject.Properties.Name -contains 'received_bytes') { $rx = $wg.received_bytes; $tx = $wg.sent_bytes }
        elseif ($wg.PSObject.Properties.Name -contains 'transfer' -and $wg.transfer) { $rx = $wg.transfer[0][0]; $tx = $wg.transfer[0][1] }
    }
    [pscustomobject]@{ UtcTime = $_.time; State = $_.classification; HandshakeAge = $age; RxBytes = $rx; TxBytes = $tx }
} | Format-Table -AutoSize
