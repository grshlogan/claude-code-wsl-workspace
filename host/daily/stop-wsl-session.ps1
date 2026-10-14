[CmdletBinding()]
param([switch]$ConfirmShutdown)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\wsl-runtime.ps1')
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
if (-not $ConfirmShutdown) {
    throw 'Save all WSL work and rerun with -ConfirmShutdown. This stops every WSL distribution.'
}
# Set before taking the mutex so new polls cannot enter while diagnostics drain.
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $PausePath))
Set-Content -LiteralPath $PausePath -Value ([DateTimeOffset]::UtcNow.ToString('o')) -Encoding ascii
$writer = New-Object Threading.Mutex($false, 'Local\ClaudeWSL-NetworkLog')
$writerHeld = $false
$mutex = $null
try {
    try { $writerHeld = $writer.WaitOne(110000) }
    catch [Threading.AbandonedMutexException] { $writerHeld = $true }
    if (-not $writerHeld) { throw 'Diagnostic collector busy; pause remains set. Shutdown was not executed.' }
    $mutex = Enter-ClaudeLifecycle -TimeoutMilliseconds 10000
    if ($null -eq $mutex) { throw 'Lifecycle busy; pause remains set. Shutdown was not executed.' }
    if ($BridgeStopScript -and (Test-Path -LiteralPath $BridgeStopScript)) {
        $stopped = Invoke-NativeBounded -FilePath 'python.exe' -Arguments @($BridgeStopScript, 'stop') -TimeoutSeconds 25
        if ($stopped.ExitCode -ne 0) { throw 'LLM bridge stop failed; shutdown not executed; pause remains set.' }
    }
    $shutdown = Invoke-NativeBounded -FilePath 'wsl.exe' -Arguments @('--shutdown') -TimeoutSeconds 45
    if ($shutdown.ExitCode -ne 0) { throw 'WSL shutdown failed; pause remains set.' }
    Write-Output 'WSL_PAUSED_AND_STOPPED: editor/network watchers remain alive but skip guest access.'
    Write-Output 'Other UNC views or third-party WSL reconnect tools must also be closed.'
}
finally {
    Exit-ClaudeLifecycle $mutex
    if ($writerHeld) { $writer.ReleaseMutex() }
    $writer.Dispose()
}
