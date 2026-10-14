# Run elevated while the global WSL networkingMode is none.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
$id = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$config = Get-Content -LiteralPath "$env:USERPROFILE\.wslconfig" -Raw
if ($config -notmatch '(?im)^\s*networkingMode\s*=\s*none\s*$') {
    throw 'Refusing to change the WSL host gate outside networkingMode=none.'
}

# Split the IPv4 space around the pinned endpoint: everything below and above
# is blocked at priority 0; only the endpoint itself receives an explicit Allow.
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
if ($endpointValue -le [uint32]::MinValue -or $endpointValue -ge [uint32]::MaxValue) { throw 'Endpoint at the edge of the IPv4 range is not supported.' }
$blockIpv4Low = '0.0.0.0-{0}' -f (ConvertFrom-IPv4UInt32 ([uint32]($endpointValue - 1)))
$blockIpv4High = '{0}-255.255.255.255' -f (ConvertFrom-IPv4UInt32 ([uint32]($endpointValue + 1)))

$rules = @(
    @{ Name = 'ClaudeWSL-BlockIPv4-Low';  Action = 'Block'; Protocol = 'Any'; RemoteAddresses = $blockIpv4Low },
    @{ Name = 'ClaudeWSL-BlockIPv4-High'; Action = 'Block'; Protocol = 'Any'; RemoteAddresses = $blockIpv4High },
    @{ Name = 'ClaudeWSL-BlockIPv6-Low';  Action = 'Block'; Protocol = 'Any'; RemoteAddresses = '::/1' },
    @{ Name = 'ClaudeWSL-BlockIPv6-High'; Action = 'Block'; Protocol = 'Any'; RemoteAddresses = '8000::/1' },
    @{ Name = 'ClaudeWSL-AllowWG';         Action = 'Allow'; Protocol = 'UDP'; RemoteAddresses = $VpsEndpointIp; RemotePorts = $VpsWgPort }
)

# Build the blocking rules before the sole allow rule. Priority 0 precedes
# ordinary priorities; disjoint IPv4 address ranges never block the endpoint.
foreach ($rule in $rules) {
    $existing = Get-NetFirewallHyperVRule -Name $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
        $expectedPort = if ($rule.ContainsKey('RemotePorts')) { $rule.RemotePorts } else { 'Any' }
        if ($existing.VMCreatorId -ne $id -or $existing.Direction -ne 'Outbound' -or
            $existing.Action -ne $rule.Action -or $existing.Protocol -ne $rule.Protocol -or
            (@($existing.RemoteAddresses) -join ',') -ne $rule.RemoteAddresses -or
            (@($existing.RemotePorts) -join ',') -ne $expectedPort -or
            $existing.RulePriority -ne 0 -or $existing.Enabled -ne 'True') {
            throw "Rule $($rule.Name) exists with unexpected settings; inspect before proceeding."
        }
        continue
    }
    $params = @{
        Name = $rule.Name; DisplayName = $rule.Name; Direction = 'Outbound'
        VMCreatorId = $id; Action = $rule.Action; Protocol = $rule.Protocol
        RemoteAddresses = $rule.RemoteAddresses; RulePriority = 0; Profiles = 'Any'
    }
    if ($rule.ContainsKey('RemotePorts')) { $params.RemotePorts = $rule.RemotePorts }
    New-NetFirewallHyperVRule @params | Out-Null
}
Set-NetFirewallHyperVVMSetting -Name $id -Enabled True -DefaultOutboundAction Block -LoopbackEnabled False -AllowHostPolicyMerge False

$effective = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $id
if ($effective.Enabled -ne 'True' -or $effective.DefaultOutboundAction -ne 'Block' -or
    $effective.LoopbackEnabled -ne 'False' -or $effective.AllowHostPolicyMerge -ne 'False') {
    throw "The WSL effective settings are not fail-closed: $($effective | Out-String)"
}
Get-NetFirewallHyperVRule -PolicyStore ActiveStore | Where-Object { $_.Name -like 'ClaudeWSL-*' } |
    Select-Object Name,VMCreatorId,Direction,Action,Protocol,RemoteAddresses,RemotePorts,RulePriority,Enabled |
    Format-Table -AutoSize
$effective | Select-Object Name,Enabled,DefaultOutboundAction,LoopbackEnabled,AllowHostPolicyMerge | Format-List
& (Join-Path $PSScriptRoot 'verify-wsl-guard.ps1')
