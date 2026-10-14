[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$name = 'Claude WSL Network Diagnostics'
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    throw 'Diagnostic task already exists. Inspect it instead of overwriting its settings.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $PSScriptRoot '..\diagnostics\watch-network-health.ps1'
$action = New-ScheduledTaskAction -Execute $executable -Argument (
    '-NoProfile -NonInteractive -WindowStyle Hidden -File "{0}" -Watch -IntervalSeconds 60' -f $script)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Read-only WSL network evidence; no guest access while paused/stopped, no automatic repair.' | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output 'NETWORK_DIAGNOSTICS_TASK_INSTALLED: 60-second interval; local rotating metadata log.'
