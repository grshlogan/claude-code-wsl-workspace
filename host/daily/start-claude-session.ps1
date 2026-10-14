[CmdletBinding()]
param(
    [switch]$CheckOnly
)

# Guarded interactive launcher for the active Debian WSL client.
# Run this file through powershell.exe from either Windows Terminal or another
# terminal host.
# Keeping the wsl.exe invocation inside PowerShell avoids MSYS/Git-Bash
# conversion of Linux paths such as /home/claude.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# Central config provides $WslDistro, $LinuxUser, $LinuxHome and $VpsEndpointIp.
. (Join-Path $ScriptRoot '..\lib\load-config.ps1')
$Distro = $WslDistro
$ExpectedExit = $VpsEndpointIp
$MaxHandshakeAgeSeconds = 900

$Verifier = Join-Path $ScriptRoot '..\setup\verify-wsl-guard.ps1'
. (Join-Path $ScriptRoot '..\lib\wsl-runtime.ps1')

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    if ($Passed) {
        Write-Host (('[PASS] {0}: {1}' -f $Name, $Detail)) -ForegroundColor Green
    }
    else {
        Write-Host (('[FAIL] {0}: {1}' -f $Name, $Detail)) -ForegroundColor Red
    }
}

function Write-NotTested {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        Write-Host (('[NOT_TESTED] {0}: blocked by an earlier failed gate' -f $name)) -ForegroundColor Yellow
    }
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    try {
        return Invoke-NativeBounded -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds 30
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 9009
            Text = $_.Exception.Message
        }
    }
}

function Invoke-WslCaptured {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    return Invoke-Captured -FilePath $script:WslPath -Arguments $Arguments
}

try {
    $wslCommand = Get-Command wsl.exe -ErrorAction Stop
    $WslPath = $wslCommand.Source
}
catch {
    Write-Host '[FAIL] WSL: wsl.exe was not found in PATH.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Verifier -PathType Leaf)) {
    Write-Host (('[FAIL] HOST_GATE: verifier not found at {0}' -f $Verifier)) -ForegroundColor Red
    exit 1
}

# This is intentionally the first operational check. Do not start WSL before it.
$hostGate = Invoke-Captured -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @(
    '-NoProfile',
    '-File',
    $Verifier
)

$configPass = $false
$configDetail = ''
$configPath = Join-Path $env:USERPROFILE '.wslconfig'
try {
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
    $requiredSettings = [ordered]@{
        'networkingMode' = 'nat'
        'dnsTunneling' = 'false'
        'autoProxy' = 'false'
        'localhostForwarding' = 'false'
        'firewall' = 'true'
    }
    $missing = @()
    foreach ($key in $requiredSettings.Keys) {
        $value = $requiredSettings[$key]
        $pattern = '(?im)^\s*' + [regex]::Escape($key) + '\s*=\s*' + [regex]::Escape($value) + '\s*$'
        if ($config -notmatch $pattern) {
            $missing += ('{0}={1}' -f $key, $value)
        }
    }
    $configPass = ($missing.Count -eq 0)
    if ($configPass) {
        $configDetail = '.wslconfig NAT/fail-closed settings match'
    }
    else {
        $configDetail = ('missing or drifted: {0}' -f ($missing -join ', '))
    }
}
catch {
    $configDetail = ('could not read {0}: {1}' -f $configPath, $_.Exception.Message)
}

$hostPass = ($hostGate.ExitCode -eq 0 -and $hostGate.Text -match 'HOST_GATE_STATIC_OK' -and $configPass)
if ($hostPass) {
    Write-Status 'HOST_GATE' $true $configDetail
}
else {
    $detailParts = @()
    if ($hostGate.ExitCode -ne 0 -or $hostGate.Text -notmatch 'HOST_GATE_STATIC_OK') {
        $detailParts += 'verify-wsl-guard.ps1 did not return HOST_GATE_STATIC_OK'
    }
    if (-not $configPass) {
        $detailParts += $configDetail
    }
    Write-Status 'HOST_GATE' $false ($detailParts -join '; ')
    Write-NotTested @('GUEST_SERVICES', 'WIREGUARD', 'ROUTE_AND_EXIT')
    exit 1
}

# All WSL calls below are made by PowerShell. This is the path-conversion fix
# for MSYS/Git-Bash-style terminal hosts: /home/claude is passed as a literal
# WSL argument. Such hosts may also export their Windows CLI path through
# WSLENV (for example TOOL_CLI/p). WSL then tries to translate a Windows host
# path into a Linux path, which fails because that host path is not a guest
# file. Remove only the terminal control-plane variables before calling WSL.
function Remove-TerminalWslEnv {
    $pattern = '_(CLI|BIN_DIR|PANE_ID|PANE_REMOTE)$'

    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if ($name -match $pattern) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
    }

    $wslEnvValue = [Environment]::GetEnvironmentVariable('WSLENV', 'Process')
    if ([string]::IsNullOrWhiteSpace($wslEnvValue)) {
        return
    }

    $keptEntries = @()
    foreach ($entry in ($wslEnvValue -split ':')) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        $baseName = ($entry -split '/', 2)[0]
        if ($baseName -match '_(CLI|BIN_DIR|PANE_ID|PANE_REMOTE)$') {
            continue
        }
        $keptEntries += $entry
    }

    if ($keptEntries.Count -eq 0) {
        Remove-Item -LiteralPath 'Env:WSLENV' -ErrorAction SilentlyContinue
    }
    else {
        $env:WSLENV = $keptEntries -join ':'
    }
}

$lifecycle = Enter-ClaudeLifecycle -TimeoutMilliseconds 10000
if ($null -eq $lifecycle) {
    Write-Host '[FAIL] LIFECYCLE: another start/stop operation is in progress.' -ForegroundColor Red
    exit 1
}
try {
Remove-TerminalWslEnv
$guardService = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', 'root',
    '--', 'systemctl', 'is-active', 'claude-guard.service'
)
$wgService = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', 'root',
    '--', 'systemctl', 'is-active', 'wg-quick@wg-claude.service'
)
$homeCheck = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', 'root',
    '--', 'test', '-d', $LinuxHome
)

$servicesPass = (
    $guardService.ExitCode -eq 0 -and $guardService.Text -eq 'active' -and
    $wgService.ExitCode -eq 0 -and $wgService.Text -eq 'active' -and
    $homeCheck.ExitCode -eq 0
)
$servicesDetail = ('claude-guard={0}; wg-quick={1}; home={2}' -f $guardService.Text, $wgService.Text, $LinuxHome)
Write-Status 'GUEST_SERVICES' $servicesPass $servicesDetail
if (-not $servicesPass) {
    Write-NotTested @('WIREGUARD', 'ROUTE_AND_EXIT')
    exit 1
}

# Project only non-sensitive WireGuard status fields. The public key is never
# printed or retained: cut -f2 / cut -f2-3 return only time and byte counters.
$handshake = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', 'root',
    '--', 'sh', '-lc', 'wg show wg-claude latest-handshakes | cut -f2'
)
$transfer = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', 'root',
    '--', 'sh', '-lc', 'wg show wg-claude transfer | cut -f2-3'
)

$handshakeEpoch = [long]0
$handshakeParsed = [long]::TryParse($handshake.Text, [ref]$handshakeEpoch)
$handshakeAge = [long]::MaxValue
if ($handshakeParsed) {
    $handshakeAge = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $handshakeEpoch
}
$transferPresent = ($transfer.ExitCode -eq 0 -and $transfer.Text -match '^\s*\d+\s+\d+\s*$')
$wireguardPass = (
    $handshake.ExitCode -eq 0 -and $handshakeParsed -and
    $handshakeAge -ge 0 -and $handshakeAge -le $MaxHandshakeAgeSeconds -and
    $transferPresent
)
if ($wireguardPass) {
    $wireguardDetail = ('latest handshake age={0}s; transfer counters present' -f $handshakeAge)
}
else {
    $wireguardDetail = ('handshake age={0}s; transfer={1}; threshold={2}s' -f $handshakeAge, $transferPresent, $MaxHandshakeAgeSeconds)
}
Write-Status 'WIREGUARD' $wireguardPass $wireguardDetail
if (-not $wireguardPass) {
    Write-NotTested @('ROUTE_AND_EXIT')
    exit 1
}

$route = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', 'root',
    '--', 'ip', '-4', 'route', 'get', '1.1.1.1'
)
# Execute curl directly: WSL's default-shell mode expands '*' in root's cwd,
# turning --noproxy '*' into directory names and treating them as hostnames.
# --disable is curl's first argument so user curlrc cannot alter this gate.
$exitIp = Invoke-WslCaptured @(
    '--distribution', $Distro,
    '--user', $LinuxUser,
    '--exec', 'curl', '--disable', '--noproxy', '*', '-4', '--connect-timeout', '5', '--max-time', '15', '--fail', '--silent', '--show-error', 'https://api.ipify.org'
)
$routePass = ($route.ExitCode -eq 0 -and $route.Text -match '(?m)\bdev\s+wg-claude\b')
$exitPass = ($exitIp.ExitCode -eq 0 -and $exitIp.Text -eq $ExpectedExit)
$routeExitPass = ($routePass -and $exitPass)
$routeExitDetail = ('route-via-wg={0}; exit={1}' -f $routePass, $exitIp.Text)
Write-Status 'ROUTE_AND_EXIT' $routeExitPass $routeExitDetail
if (-not $routeExitPass) {
    exit 1
}

# A successful deliberate start resumes watchers, including after global shutdown.
Remove-Item -LiteralPath $PausePath -Force -ErrorAction SilentlyContinue
Write-Host '[PASS] All startup gates passed.' -ForegroundColor Green
}
finally { Exit-ClaudeLifecycle $lifecycle }
if ($CheckOnly) {
    Write-Host '[INFO] CheckOnly requested; the interactive WSL shell was not opened.'
    exit 0
}

Write-Host ('[INFO] Opening {0} as Linux user {1}. Type "claude" manually when ready.' -f $Distro, $LinuxUser)
Write-Host '[INFO] This launcher does not start Firefox, Claude Code, or any other application automatically.'

# Direct invocation keeps the interactive TTY attached. Because this is inside
# PowerShell, /home/claude is not rewritten by Git Bash/MSYS.
$interactiveArgs = @(
    '--distribution', $Distro,
    '--user', $LinuxUser,
    '--cd', $LinuxHome,
    '--', '/bin/bash', '-l'
)
& $WslPath @interactiveArgs
$interactiveExitCode = $LASTEXITCODE
exit $interactiveExitCode
