[CmdletBinding()]
param([switch]$ConfirmCapture)
# 20-second endpoint-header capture. Run only during an approved diagnostics window.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
. (Join-Path $PSScriptRoot '..\lib\wsl-runtime.ps1')
if (-not $ConfirmCapture) { throw 'A separately approved capture window and -ConfirmCapture are required.' }
if (-not (Test-ClaudeDistroRunning) -or (Test-Path $PausePath)) { throw 'Guest must already be running and unpaused.' }
$existing = Invoke-NativeBounded pktmon.exe @('filter', 'list')
if ($existing.Text -match '(?m)^\s*\d+\s+') { throw 'Existing pktmon filters must not be changed.' }
$running = Invoke-NativeBounded logman.exe @('query', 'PktMon', '-ets')
if ($running.ExitCode -eq 0) { throw 'A pktmon session is already active; do not interfere with it.' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$folder = Join-Path $PSScriptRoot 'logs'
[void][IO.Directory]::CreateDirectory($folder)
$path = Join-Path $folder ('wg-header-' + $stamp + '.etl')
$filter = 'ClaudeWG-Diagnostic'
$added = $false
$started = $false
try {
    & pktmon.exe filter add $filter -t UDP -i $VpsEndpointIp -p $VpsWgPort
    if ($LASTEXITCODE -ne 0) { throw 'Pktmon filter failed.' }
    $added = $true
    & pktmon.exe start --capture --pkt-size 42 --file-size 8 --file-name $path
    if ($LASTEXITCODE -ne 0) { throw 'Pktmon start failed.' }
    $started = $true
    # Trigger only an ordinary tunnel request; payload is not retained by pktmon.
    $probe = Invoke-NativeBounded wsl.exe @('-d',$WslDistro,'-u','claude','--exec',
        'curl','--disable','--noproxy','*','-4','--connect-timeout','3','--max-time','5',
        '--silent','--output','/dev/null','https://1.1.1.1') -TimeoutSeconds 7
    Start-Sleep -Seconds 12
    & pktmon.exe counters
    & pktmon.exe stop
    $started = $false
    & pktmon.exe etl2txt $path --out ($path + '.txt')
    Write-Output ('WG_HEADER_CAPTURE: {0}; curl_exit={1}' -f $path, $probe.ExitCode)
}
finally {
    if ($started) { & pktmon.exe stop }
    if ($added) { & pktmon.exe filter remove $filter }
}
