[CmdletBinding()]
param(
    [ValidateSet('Check', 'Client', 'Server', 'Both')][string]$Mode = 'Check',
    [switch]$ConfirmRestart,
    [switch]$ConfirmVpsMaintenance,
    [ValidatePattern('^([A-Za-z0-9_-]{1,64})?$')][string]$MaintenanceWindow,
    [string]$WindowEndsUtc,
    [string]$SshKeyPath = (Join-Path $env:USERPROFILE '.ssh\id_rsa.pem'),
    [switch]$FunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
# Reuse the deployed read-only host gate and guest collector, not startup (which can start WSL).
$RecoveryFunctionsOnly = $FunctionsOnly
. (Join-Path $PSScriptRoot '..\diagnostics\watch-network-health.ps1') -FunctionsOnly
$RecoveryLogPath = Join-Path $PSScriptRoot 'logs\wireguard-recovery.jsonl'
$RecoveryPeerPath = Join-Path $PSScriptRoot 'wireguard-recovery-peer.py'
# Endpoint and SSH host-key pin come from config.ps1 (git-ignored). The pin
# prevents connecting to any host other than the expected VPS.
$VpsHost = $VpsEndpointIp
$VpsFingerprint = $VpsSshFingerprint
$VpsHostKey = $VpsSshHostKey

function Write-RecoveryEvent {
    param([string]$EventName, $Data)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $RecoveryLogPath))
    if ((Test-Path -LiteralPath $RecoveryLogPath) -and (Get-Item -LiteralPath $RecoveryLogPath).Length -gt 2MB) {
        Move-Item -LiteralPath $RecoveryLogPath -Destination ($RecoveryLogPath + '.1') -Force
    }
    $record = [ordered]@{ schema = 1; time = [DateTimeOffset]::UtcNow.ToString('o');
        run_id = $script:RecoveryRunId; mode = $Mode; event = $EventName; data = $Data }
    Add-Content -LiteralPath $RecoveryLogPath -Value ($record | ConvertTo-Json -Depth 24 -Compress) -Encoding UTF8
}

function Assert-RecoveryPermission {
    if ($Mode -eq 'Check') { return }
    if (-not $ConfirmRestart) { throw 'restart-confirmation-required' }
    $script:RecoveryDeadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    if ($Mode -in @('Server', 'Both')) {
        if (-not $ConfirmVpsMaintenance -or [string]::IsNullOrWhiteSpace($MaintenanceWindow)) {
            throw 'named-vps-maintenance-approval-required'
        }
        $parsed = [DateTimeOffset]::MinValue
        if ($WindowEndsUtc -notmatch 'Z$' -or -not [DateTimeOffset]::TryParse($WindowEndsUtc, [ref]$parsed)) {
            throw 'utc-window-end-required'
        }
        $remaining = ($parsed - [DateTimeOffset]::UtcNow).TotalSeconds
        if ($remaining -lt 180 -or $remaining -gt 600) { throw 'window-must-have-3-to-10-minutes-remaining' }
        $script:RecoveryDeadline = $parsed
    }
}

function Assert-RecoveryAvailable {
    if (Test-Path -LiteralPath $PausePath) { throw 'guest-paused-use-guarded-start-first' }
    if (-not (Test-ClaudeDistroRunning)) { throw 'guest-stopped-use-guarded-start-first' }
}

function Assert-RecoveryHost {
    $evidence = Get-HostNetworkEvidence
    Write-RecoveryEvent 'host-gate' $evidence
    if (-not $evidence.host_gate_ok -or -not $evidence.wslconfig_ok) { throw 'host-gate-drift' }
    return $evidence
}

function Assert-RecoveryTime {
    param([int]$BudgetSeconds = 90)
    if (($script:RecoveryDeadline - [DateTimeOffset]::UtcNow).TotalSeconds -lt $BudgetSeconds) {
        throw 'maintenance-window-expired-or-too-short'
    }
}

function ConvertTo-SshFilePath {
    param([string]$Path, [bool]$Msys)
    $full = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($Msys -and $full -match '^([A-Za-z]):/(.*)$') { return '/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2] }
    return $full
}

function Get-RecoverySsh {
    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
    $msys = $ssh -match '[\\/]usr[\\/]bin[\\/]ssh\.exe$'
    if (-not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf)) { throw 'ssh-key-file-missing' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [Convert]::ToBase64String($hash.ComputeHash([Convert]::FromBase64String($VpsHostKey))).TrimEnd('=') }
    finally { $hash.Dispose() }
    if ($fingerprint -cne $VpsFingerprint) { throw 'embedded-host-key-fingerprint-mismatch' }
    $known = Join-Path $RuntimeRoot 'runtime-state\vps-recovery-known_hosts'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $known))
    [IO.File]::WriteAllText($known, ($VpsHost + ' ssh-ed25519 ' + $VpsHostKey + "`n"), [Text.Encoding]::ASCII)
    $nullPath = if ($msys) { '/dev/null' } else { 'NUL' }
    $arguments = @('-F', $nullPath, '-4', '-T', '-p', '22',
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
        '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519',
        '-o', ('UserKnownHostsFile=' + (ConvertTo-SshFilePath $known $msys)),
        '-o', ('GlobalKnownHostsFile=' + $nullPath), '-o', 'UpdateHostKeys=no',
        '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
        '-o', 'PreferredAuthentications=publickey', '-o', 'NumberOfPasswordPrompts=0',
        '-o', 'ProxyCommand=none', '-o', 'ProxyJump=none', '-o', 'ClearAllForwardings=yes',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ConnectionAttempts=1',
        '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=1',
        '-i', (ConvertTo-SshFilePath $SshKeyPath $msys), ('root@' + $VpsHost))
    return @{ FilePath = $ssh; Arguments = $arguments }
}

function Get-RecoveryPeer {
    param([ValidateSet('Client', 'Server')][string]$Role, [ValidateSet('Check', 'Restart')][string]$Action = 'Check')
    if ($Action -eq 'Restart') { Assert-RecoveryTime; Assert-RecoveryAvailable }
    $source = Get-Content -LiteralPath $RecoveryPeerPath -Raw
    $helperArguments = @($Role, $Action)
    if ($Action -eq 'Restart') {
        $helperArguments += @('--confirmed-restart', '--deadline', [string]$script:RecoveryDeadline.ToUnixTimeSeconds())
        Write-RecoveryEvent 'restart-requested' @{ role = $Role; deadline_epoch = $script:RecoveryDeadline.ToUnixTimeSeconds() }
    }
    if ($Role -eq 'Client') {
        Assert-RecoveryAvailable
        $call = Invoke-NativeBounded -FilePath 'wsl.exe' -TimeoutSeconds 100 -InputText $source -Arguments (
            @('-d', $WslDistro, '-u', 'root', '--exec', 'python3', '-I', '-') + $helperArguments)
    }
    else {
        $ssh = Get-RecoverySsh
        # All remote arguments are fixed enums/integers. No arbitrary remote command or endpoint.
        $remote = 'python3 -I - ' + ($helperArguments -join ' ')
        $call = Invoke-NativeBounded -FilePath $ssh.FilePath -TimeoutSeconds 100 -InputText $source -Arguments ($ssh.Arguments + @($remote))
    }
    try {
        $peer = $call.Text | ConvertFrom-Json
        if ($peer.schema -ne 1 -or $peer.role -cne $Role -or $peer.action -cne $Action) { throw 'protocol' }
        $data = @{ transport_exit = $call.ExitCode; peer = $peer }
    }
    catch {
        $data = @{ transport_exit = $call.ExitCode; peer = @{ ok = $false; error_code = 'peer-response-unavailable' } }
    }
    # Never retain raw stdout/stderr: an SSH or command error may contain sensitive context.
    Write-RecoveryEvent ('peer-' + $Role.ToLowerInvariant() + '-' + $Action.ToLowerInvariant()) $data
    if ($call.ExitCode -ne 0 -or -not $data.peer.ok) { throw ('peer-' + $Role.ToLowerInvariant() + '-' + $Action.ToLowerInvariant() + '-failed') }
    return $data.peer
}

function Get-RecoveryGuest {
    Assert-RecoveryAvailable
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\diagnostics\guest-network-snapshot.py') -Raw
    $call = Invoke-NativeBounded -FilePath 'wsl.exe' -TimeoutSeconds 100 -InputText $source -Arguments @(
        '-d', $WslDistro, '-u', 'root', '--exec', 'python3', '-I', '-')
    try { $guest = $call.Text | ConvertFrom-Json }
    catch { throw 'guest-snapshot-unavailable' }
    Write-RecoveryEvent 'guest-snapshot' @{ transport_exit = $call.ExitCode; guest = $guest }
    if ($call.ExitCode -ne 0 -or $guest.classification -eq 'collector-error') { throw 'guest-snapshot-failed' }
    return $guest
}

function Assert-RecoveryGuestBoundary {
    param($Guest)
    if ($Guest.guard_check_exit -ne 0 -or $Guest.services.'claude-guard.service'.ActiveState -ne 'active') {
        throw 'guest-guard-failed'
    }
    if ($Guest.classification -eq 'unexpected-public-exit') { throw 'unexpected-public-exit' }
}

function Assert-RecoveryConnectivity {
    param($Guest, [long]$PreviousHandshake = 0, [switch]$RequireNewHandshake)
    Assert-RecoveryGuestBoundary $Guest
    $wg = $Guest.wg_after
    $pass = ($Guest.classification -eq 'healthy' -and $Guest.ip_https.curl_exit -eq 0 -and
        $Guest.exit_probe.curl_exit -eq 0 -and $Guest.exit_probe.public_ipv4 -eq $VpsHost -and
        $Guest.dns.exit -eq 0 -and @($Guest.dns.addresses).Count -gt 0 -and
        $wg.handshake_age_seconds -ge 0 -and $wg.handshake_age_seconds -le 180 -and
        $null -ne $wg.received_bytes -and $null -ne $wg.sent_bytes)
    if ($RequireNewHandshake) { $pass = $pass -and [long]$wg.handshake_epoch -gt $PreviousHandshake }
    if (-not $pass) { throw 'connectivity-not-verified' }
}

function Test-RecoveryDenial {
    $results = @()
    foreach ($probe in @(
        @{ name = 'direct-eth0'; arguments = @('-4', '--interface', 'eth0', 'https://1.1.1.1') },
        @{ name = 'external-ipv6'; arguments = @('-6', 'https://[2606:4700:4700::1111]') }
    )) {
        Assert-RecoveryAvailable
        $call = Invoke-NativeBounded -FilePath 'wsl.exe' -TimeoutSeconds 8 -Arguments (
            @('-d', $WslDistro, '-u', 'claude', '--exec', 'curl', '--disable', '--noproxy', '*',
                '--connect-timeout', '2', '--max-time', '3', '--silent', '--output', '/dev/null', '--write-out', '%{http_code}') + $probe.arguments)
        $results += @{ name = $probe.name; curl_exit = $call.ExitCode; http_status = $call.Text;
            denied = ($call.ExitCode -in @(7, 28) -and $call.Text -eq '000') }
    }
    Write-RecoveryEvent 'direct-denial-probes' $results
    if (@($results | Where-Object { -not $_.denied }).Count -gt 0) { throw 'direct-denial-not-verified' }
}

function Invoke-WireGuardRecovery {
    Assert-RecoveryPermission
    $script:RecoveryRunId = [guid]::NewGuid().ToString('N')
    $writer = New-Object Threading.Mutex($false, 'Local\ClaudeWSL-NetworkLog')
    $writerHeld = $false
    $lifecycle = $null
    try {
        try { $writerHeld = $writer.WaitOne(110000) }
        catch [Threading.AbandonedMutexException] { $writerHeld = $true }
        if (-not $writerHeld) { throw 'diagnostic-writer-busy' }
        $lifecycle = Enter-ClaudeLifecycle -TimeoutMilliseconds 10000
        if ($null -eq $lifecycle) { throw 'lifecycle-busy' }
        Write-RecoveryEvent 'begin' @{ maintenance_window = $MaintenanceWindow; window_end_utc = $WindowEndsUtc }
        [void](Assert-RecoveryHost)
        Assert-RecoveryAvailable
        $before = Get-RecoveryGuest
        Assert-RecoveryGuestBoundary $before
        [void](Get-RecoveryPeer 'Client')
        # VPS reachability is recorded but is not a dependency of a client-only repair.
        $serverAvailable = $false
        try { [void](Get-RecoveryPeer 'Server'); $serverAvailable = $true }
        catch { Write-RecoveryEvent 'vps-preflight-unavailable' @{ reason = 'pinned-ssh-or-server-contract-failed' } }
        if ($Mode -eq 'Check') {
            Assert-RecoveryConnectivity $before
            Test-RecoveryDenial
            if (-not $serverAvailable) { throw 'vps-check-not-verified' }
        }
        else {
            if ($Mode -in @('Server', 'Both') -and -not $serverAvailable) { throw 'vps-preflight-required' }
            # Recheck the host boundary immediately before any destructive step.
            [void](Assert-RecoveryHost)
            Assert-RecoveryAvailable
            Test-RecoveryDenial
            if ($Mode -in @('Server', 'Both')) { [void](Get-RecoveryPeer 'Server' 'Restart') }
            if ($Mode -in @('Client', 'Both')) {
                # Both must finish and verify its server phase before touching the client.
                [void](Assert-RecoveryHost)
                [void](Get-RecoveryPeer 'Client' 'Restart')
            }
            Start-Sleep -Seconds 3
            $after = Get-RecoveryGuest
            Assert-RecoveryConnectivity $after -PreviousHandshake ([long]$before.wg_after.handshake_epoch) -RequireNewHandshake
            Test-RecoveryDenial
            if ($Mode -in @('Server', 'Both')) { [void](Get-RecoveryPeer 'Server') }
        }
        [void](Assert-RecoveryHost)
        Write-RecoveryEvent 'verified' @{ result = 'host-guard-fresh-handshake-dns-exit-and-denial-passed' }
        Write-Host ('WIREGUARD_RECOVERY_VERIFIED: mode={0}; run={1}; log={2}' -f $Mode, $script:RecoveryRunId, $RecoveryLogPath)
        return 0
    }
    catch {
        if ($writerHeld) {
            Write-RecoveryEvent 'failed' @{ error_type = $_.Exception.GetType().Name;
                reason = $(if ($_.Exception.Message -match '^[a-z][a-z0-9-]+$') { $_.Exception.Message } else { 'recovery-error-see-stage-records' }) }
        }
        Write-Warning 'Recovery/check not verified. No automatic retry, escalation or rollback was attempted. Inspect the recovery log before continuing.'
        return 1
    }
    finally {
        Exit-ClaudeLifecycle $lifecycle
        if ($writerHeld) { $writer.ReleaseMutex() }
        $writer.Dispose()
    }
}

if ($RecoveryFunctionsOnly) { return }
try { exit (Invoke-WireGuardRecovery) }
catch { Write-Error $_.Exception.Message; exit 1 }
