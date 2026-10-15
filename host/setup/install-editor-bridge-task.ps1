[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Logon + hourly idempotent self-heal for the editor bridge so guest Ctrl+G
# keeps reaching the host editor even when sessions are opened directly via
# `wsl -d ... -u claude` without start-claude-session. -Ensure exits quietly
# when a watcher is already alive, so repeated invocations are free.

$name = 'Claude Editor Bridge Ensure'
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    throw 'Bridge ensure task already exists. Inspect it instead of overwriting its settings.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $PSScriptRoot '..\daily\claude-editor-bridge.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "bridge script not found: $script"
}

$action = New-ScheduledTaskAction -Execute $executable -Argument (
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Ensure' -f $script)

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$hourlyTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
$repetition = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
$hourlyTrigger.Repetition = $repetition.Repetition

$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $name -Action $action -Trigger $logonTrigger, $hourlyTrigger `
    -Principal $principal -Settings $settings `
    -Description 'Idempotent self-heal for the guest Ctrl+G editor bridge (-Ensure exits when a watcher is alive).' | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output 'EDITOR_BRIDGE_TASK_INSTALLED: logon + hourly -Ensure; hidden; exits instantly when already running.'
