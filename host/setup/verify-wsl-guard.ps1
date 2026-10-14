# Read-only static audit; a successful result is not a live leak test.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
$id = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$setting = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $id
if ($setting.Enabled -ne 'True' -or $setting.DefaultInboundAction -ne 'Block' -or
    $setting.DefaultOutboundAction -ne 'Block' -or $setting.LoopbackEnabled -ne 'False' -or
    $setting.AllowHostPolicyMerge -ne 'False') {
    throw 'Effective WSL Hyper-V firewall settings are not the expected fail-closed policy.'
}
$profiles = @(Get-NetFirewallHyperVProfile -PolicyStore ActiveStore)
if ($profiles.Count -ne 3 -or @($profiles | Where-Object {
    $_.Enabled -ne 'True' -or $_.DefaultInboundAction -ne 'Block' -or
    $_.DefaultOutboundAction -ne 'Block' -or $_.AllowLocalFirewallRules -ne 'True'
}).Count -ne 0) { throw 'One or more effective WSL profiles do not enforce local inbound/outbound rules.' }

# Expected rules are derived from the same configuration as apply-wsl-guard.ps1.
function ConvertTo-IPv4UInt32 {
    param([Parameter(Mandatory = $true)][string]$Address)
    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    if ($bytes.Length -ne 4) { throw "Endpoint must be an IPv4 address: $Address" }
    return [BitConverter]::ToUInt32([byte[]]($bytes[3..0]), 0)
}
function ConvertFrom-IPv4UInt32 {
    param([Parameter(Mandatory = $true)][uint32]$Value)
    $bytes = [BitConverter]::GetBytes([uint32]$Value)
    return '{0}.{1}.{2}.{3}' -f $bytes[3], $bytes[2], $bytes[1], $bytes[0]
}
$endpointValue = ConvertTo-IPv4UInt32 $VpsEndpointIp
$blockIpv4Low = '0.0.0.0-{0}' -f (ConvertFrom-IPv4UInt32 ([uint32]($endpointValue - 1)))
$blockIpv4High = '{0}-255.255.255.255' -f (ConvertFrom-IPv4UInt32 ([uint32]($endpointValue + 1)))

$expected = @(
    @{ Name = 'ClaudeWSL-BlockIPv4-Low';  Action = 'Block'; Protocol = 'Any'; Address = $blockIpv4Low; Port = 'Any' },
    @{ Name = 'ClaudeWSL-BlockIPv4-High'; Action = 'Block'; Protocol = 'Any'; Address = $blockIpv4High; Port = 'Any' },
    @{ Name = 'ClaudeWSL-BlockIPv6-Low';  Action = 'Block'; Protocol = 'Any'; Address = '::/1'; Port = 'Any' },
    @{ Name = 'ClaudeWSL-BlockIPv6-High'; Action = 'Block'; Protocol = 'Any'; Address = '8000::/1'; Port = 'Any' },
    @{ Name = 'ClaudeWSL-AllowWG';         Action = 'Allow'; Protocol = 'UDP'; Address = $VpsEndpointIp; Port = $VpsWgPort }
)
foreach ($item in $expected) {
    $rule = Get-NetFirewallHyperVRule -PolicyStore ActiveStore -Name $item.Name -ErrorAction Stop
    if ($rule.VMCreatorId -ne $id -or $rule.Direction -ne 'Outbound' -or
        $rule.Action -ne $item.Action -or $rule.Protocol -ne $item.Protocol -or
        (@($rule.RemoteAddresses) -join ',') -ne $item.Address -or
        (@($rule.RemotePorts) -join ',') -ne $item.Port -or $rule.RulePriority -ne 0 -or
        $rule.Enabled -ne 'True' -or $rule.Profiles -ne 'Any') {
        throw "Effective rule $($item.Name) is missing or differs from the expected scope."
    }
}
$otherWSLAllows = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -Direction Outbound -Action Allow -Enabled True |
    Where-Object { $_.VMCreatorId -eq $id -and $_.Name -ne 'ClaudeWSL-AllowWG' })
if ($otherWSLAllows.Count -ne 0) { throw 'Unexpected WSL-specific outbound Allow rule exists.' }
$otherWSLInboundAllows = @(Get-NetFirewallHyperVRule -PolicyStore ActiveStore -Direction Inbound -Action Allow -Enabled True |
    Where-Object { $_.VMCreatorId -eq $id -and $_.Name -notlike 'WslCore-Allow-Inbound-*' })
if ($otherWSLInboundAllows.Count -ne 0) { throw 'Unexpected WSL-specific inbound Allow rule exists.' }
Write-Output 'HOST_GATE_STATIC_OK: WSL only, default inbound/outbound block, host loopback off, no custom inbound allows, four explicit outbound blocks and one endpoint allow.'
