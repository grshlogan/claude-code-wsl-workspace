[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Once,
    [ValidateRange(30, 3600)][int]$IntervalSeconds = 60,
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Tag = 'scheduled',
    [switch]$FunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
. (Join-Path $PSScriptRoot '..\lib\wsl-runtime.ps1')
$LogPath = Join-Path $PSScriptRoot 'logs\network-health.jsonl'

function Write-NetworkRecord {
    param($Record)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $LogPath))
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 8MB) {
        for ($i = 4; $i -ge 1; $i--) {
            $from = $LogPath + '.' + $i
            if (Test-Path -LiteralPath $from) { Move-Item -LiteralPath $from -Destination ($LogPath + '.' + ($i + 1)) -Force }
        }
        Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force
    }
    $line = $Record | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-HostNetworkEvidence {
    $result = [ordered]@{}
    $result.windows_boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $result.services = @(Get-Service WSLService, hns, vmcompute, MpsSvc | ForEach-Object {
        @{ name = $_.Name; state = [string]$_.Status }
    })
    $result.wsl_processes = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('wslhost.exe', 'wslservice.exe', 'wslrelay.exe') } |
        ForEach-Object { @{ name = $_.Name; pid = $_.ProcessId; parent_pid = $_.ParentProcessId; created = $_.CreationDate.ToUniversalTime().ToString('o') } })
    $result.host_ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { @{ interface = $_.InterfaceAlias; address = $_.IPAddress; prefix = $_.PrefixLength } })
    $result.host_routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ interface = $_.InterfaceAlias; next_hop = $_.NextHop; metric = $_.RouteMetric } })
    try {
        $setting = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
        $result.hyperv = @{ enabled = [string]$setting.Enabled; inbound = [string]$setting.DefaultInboundAction;
            outbound = [string]$setting.DefaultOutboundAction; loopback = [string]$setting.LoopbackEnabled;
            host_merge = [string]$setting.AllowHostPolicyMerge }
    }
    catch { $result.hyperv = @{ error = 'query-failed' } }
    $verification = Invoke-NativeBounded -FilePath 'powershell.exe' -TimeoutSeconds 15 -Arguments @(
        '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot '..\setup\verify-wsl-guard.ps1'))
    $result.host_gate_ok = ($verification.ExitCode -eq 0 -and $verification.Text -match 'HOST_GATE_STATIC_OK')
    $result.host_gate_exit = $verification.ExitCode
    $result.wslconfig_ok = $false
    $config = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.wslconfig') -Raw
    $requirements = @{ networkingMode = 'nat'; dnsTunneling = 'false'; autoProxy = 'false'; localhostForwarding = 'false'; firewall = 'true' }
    $result.wslconfig_ok = @($requirements.Keys | Where-Object {
        $config -notmatch ('(?im)^\s*' + $_ + '\s*=\s*' + $requirements[$_] + '\s*$')
    }).Count -eq 0
    return $result
}

function Get-FailureEventMetadata {
    $events = @()
    foreach ($log in @('Microsoft-Windows-Host-Network-Service-Admin', 'Microsoft-Windows-Hyper-V-Compute-Admin')) {
        try {
            $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = (Get-Date).AddMinutes(-10) } -MaxEvents 12 -ErrorAction Stop |
                ForEach-Object { @{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); id = $_.Id;
                    level = $_.Level; provider = $_.ProviderName } })
        }
        catch { }
    }
    return $events
}

function Invoke-NetworkSnapshot {
    # Serialize all diagnostic writers and cooperative shutdown. No UNC access.
    $writer = New-Object Threading.Mutex($false, 'Local\ClaudeWSL-NetworkLog')
    $held = $false
    try {
        try { $held = $writer.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return }
        $record = [ordered]@{ schema = 2; time = [DateTimeOffset]::UtcNow.ToString('o'); tag = $Tag }
        if (Test-Path -LiteralPath $PausePath) {
            $record.classification = 'paused-no-guest-access'
            Write-NetworkRecord $record
            return
        }
        $record.host = Get-HostNetworkEvidence
        $mutex = Enter-ClaudeLifecycle
        if ($null -eq $mutex) {
            $record.classification = 'lifecycle-busy-no-guest-access'
            Write-NetworkRecord $record
            return
        }
        $lease = @{ held = $true }
        try {
            if (-not (Test-ClaudeDistroRunning)) {
                $record.classification = 'guest-stopped-no-guest-access'
            }
            elseif (Test-Path -LiteralPath $PausePath) {
                $record.classification = 'paused-before-guest-access'
            }
            else {
                if (-not $record.host.host_gate_ok -or -not $record.host.wslconfig_ok) {
                    $record.classification = 'host-gate-drift-no-guest-probes'
                }
                elseif (-not (Test-ClaudeDistroRunning) -or (Test-Path -LiteralPath $PausePath)) {
                    $record.classification = 'guest-stopped-before-probe'
                }
                else {
                    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guest-network-snapshot.py') -Raw
                    # Release the lifecycle lock after process creation. The writer
                    # mutex still makes cooperative shutdown wait for this probe.
                    $probe = Invoke-NativeBounded -FilePath 'wsl.exe' -TimeoutSeconds 100 -InputText $source -OnStarted {
                        Exit-ClaudeLifecycle $mutex
                        $lease.held = $false
                    } -Arguments @(
                        '-d', $WslDistro, '-u', 'root', '--exec', 'python3', '-I', '-')
                    $record.guest_call_exit = $probe.ExitCode
                    try {
                        $record.guest = $probe.Text | ConvertFrom-Json
                        $record.classification = $record.guest.classification
                    }
                    catch { $record.classification = 'guest-snapshot-unavailable' }
                }
            }
            if ($record.classification -notin @('healthy', 'guest-stopped-no-guest-access', 'guest-stopped-before-probe', 'paused-before-guest-access')) {
                $record.host_events = @(Get-FailureEventMetadata)
                $hostProbe = Invoke-NativeBounded -FilePath 'curl.exe' -TimeoutSeconds 8 -Arguments @(
                    '--disable', '--noproxy', '*', '-4', '--connect-timeout', '3', '--max-time', '5',
                    '--silent', '--output', 'NUL', '--write-out', '%{http_code}', 'https://1.1.1.1')
                $record.host_ip_https = @{ curl_exit = $hostProbe.ExitCode;
                    http_status = $(if ($hostProbe.Text -match '^\d{3}$') { [int]$hostProbe.Text } else { $null }) }
            }
            Write-NetworkRecord $record
            Write-Output ('NETWORK_SNAPSHOT: {0}; log={1}' -f $record.classification, $LogPath)
        }
        finally { if ($lease.held) { Exit-ClaudeLifecycle $mutex } }
    }
    catch {
        if ($held) {
            Write-NetworkRecord @{ schema = 2; time = [DateTimeOffset]::UtcNow.ToString('o'); tag = $Tag;
                classification = 'host-collector-error'; error_type = $_.Exception.GetType().Name }
        }
        throw
    }
    finally {
        if ($held) { $writer.ReleaseMutex() }
        $writer.Dispose()
    }
}

if ($FunctionsOnly) { return }
if (-not $Watch -and -not $Once) { $Once = $true }
while ($true) {
    try { Invoke-NetworkSnapshot }
    catch { Write-Warning 'Network collector failed; inspect the classification in its local log.' }
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSeconds
}
