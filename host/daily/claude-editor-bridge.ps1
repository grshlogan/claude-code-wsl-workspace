[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Once,
    [int]$PollMilliseconds = 1000,
    [switch]$Ensure,
    [switch]$FunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
. (Join-Path $PSScriptRoot '..\lib\wsl-runtime.ps1')

$Queue = ('\\wsl.localhost\{0}\tmp\claude-editor-requests' -f $WslDistro)
$GuestRoot = ('\\wsl.localhost\{0}' -f $WslDistro)
# Editor is configurable (config.ps1): any editor that either supports a blocking
# launch flag or runs as its own process per invocation. Defaults below match the
# historical VS Code behavior when $EditorPath/$EditorArgs are not configured.
$EditorExecutable = if (Get-Variable -Name 'EditorPath' -ErrorAction SilentlyContinue) { $EditorPath } else { $VsCodePath }
$EditorSwitches = if (Get-Variable -Name 'EditorArgs' -ErrorAction SilentlyContinue) { @($EditorArgs) } else { @('--wait', '--new-window', '--disable-extensions') }
$AllowedGuestPrefix = '/tmp/claude-1000/claude-prompt-'
$AllowedGuestSuffix = '.md'

function Write-EditorEvent {
    param([string]$EventName)
    $directory = Join-Path $PSScriptRoot 'logs'
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory 'editor-lifecycle.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) {
        Move-Item -LiteralPath $path -Destination ($path + '.1') -Force
    }
    $line = @{ time = [DateTimeOffset]::UtcNow.ToString('o'); event = $EventName } | ConvertTo-Json -Compress
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

function Test-EditorGuestAvailable {
    # Never inspect a guest UNC path to determine whether WSL is running.
    if (Test-Path -LiteralPath $PausePath) { return $false }
    return Test-ClaudeDistroRunning
}

function Resolve-PromptPath {
    param([string]$GuestPath)
    if (-not ($GuestPath.StartsWith($AllowedGuestPrefix, [StringComparison]::Ordinal) -and
              $GuestPath.EndsWith($AllowedGuestSuffix, [StringComparison]::Ordinal)) -or
        $GuestPath.Contains('..') -or $GuestPath.Contains('\') -or
        $GuestPath.Substring($AllowedGuestPrefix.Length).Contains('/')) {
        throw 'request path is outside the prompt-file boundary'
    }
    $relative = $GuestPath.TrimStart('/').Replace('/', '\')
    return Join-Path $GuestRoot $relative
}

function Invoke-EditorRequest {
    param([string]$ReadyPath)
    $activePath = [IO.Path]::ChangeExtension($ReadyPath, '.active')
    $work = $null
    $claimed = $false
    $completed = $false
    $originalHash = $null
    $writebackSucceeded = $false
    $localPath = $null
    $promptPath = $null
    $mutex = Enter-ClaudeLifecycle -TimeoutMilliseconds 1000
    if ($null -eq $mutex) { return }
    try {
        if (-not (Test-EditorGuestAvailable)) { return }
        if (-not (Test-Path -LiteralPath $ReadyPath -PathType Leaf)) { return }
        Move-Item -LiteralPath $ReadyPath -Destination $activePath
        $claimed = $true
        $request = Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $request.id -or $request.id -notmatch '^[A-Za-z0-9_-]+$' -or
            $request.path -isnot [string]) { throw 'invalid request' }
        $promptPath = Resolve-PromptPath $request.path
        if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) { throw 'prompt missing' }
        if ((Get-Item -LiteralPath $promptPath).Length -gt 1MB) { throw 'prompt too large' }
        if (-not (Test-Path -LiteralPath $EditorExecutable -PathType Leaf)) { throw 'editor missing' }
        $originalHash = (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash
        $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-prompt-edit-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($work)
        $localPath = Join-Path $work 'prompt.md'
        Copy-Item -LiteralPath $promptPath -Destination $localPath
        if ((Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash -ne $originalHash) {
            throw 'prompt changed while copying'
        }
        Write-EditorEvent 'request-claimed'
    }
    catch {
        if ($claimed -and (Test-EditorGuestAvailable)) {
            Set-Content -LiteralPath ([IO.Path]::ChangeExtension($activePath, '.error')) -Value 'editor bridge failed' -NoNewline -Encoding ascii
            Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
        }
        if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        Write-EditorEvent 'request-rejected'
        return
    }
    finally { Exit-ClaudeLifecycle $mutex }

    if (-not $claimed) { return }
    try {
        # The editor sees a Windows-local copy, so it cannot wake WSL via UNC watches.
        # Editors with exit-code semantics (e.g. Zed) report non-zero when closed
        # without saving; $completed then stays false and nothing is written back.
        $arguments = @($EditorSwitches) + $localPath
        $argumentLine = (@($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
        $process = Start-Process -FilePath $EditorExecutable -ArgumentList $argumentLine -PassThru
        try { $process.WaitForExit(); $completed = ($process.ExitCode -eq 0) }
        finally { $process.Dispose() }
    }
    catch { Write-EditorEvent 'editor-failed' }

    $mutex = Enter-ClaudeLifecycle -TimeoutMilliseconds 300000
    try {
        # The active marker belongs to this request. After shutdown, /tmp and the
        # guest request process may be gone; do not start WSL to acknowledge it.
        if ($null -ne $mutex -and (Test-EditorGuestAvailable) -and
            (Test-Path -LiteralPath $activePath -PathType Leaf)) {
            try {
                if (-not $completed -or (Get-Item -LiteralPath $localPath).Length -gt 1MB -or
                    (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash -ne $originalHash) {
                    throw 'editor failed or original changed'
                }
                $temporaryId = [guid]::NewGuid().ToString('N')
                $temporaryGuest = $promptPath + '.editor-' + $temporaryId
                try {
                    Copy-Item -LiteralPath $localPath -Destination $temporaryGuest
                    $permissions = Invoke-NativeBounded -FilePath 'wsl.exe' -TimeoutSeconds 10 -Arguments @(
                        '-d', $WslDistro, '-u', 'claude', '--exec', 'chmod', '600', '--',
                        ($request.path + '.editor-' + $temporaryId))
                    if ($permissions.ExitCode -ne 0) { throw 'prompt permissions could not be restricted' }
                    Move-Item -LiteralPath $temporaryGuest -Destination $promptPath -Force
                }
                finally { Remove-Item -LiteralPath $temporaryGuest -Force -ErrorAction SilentlyContinue }
                $writebackSucceeded = $true
                Set-Content -LiteralPath ([IO.Path]::ChangeExtension($activePath, '.done')) -Value 'exit_code=0' -NoNewline -Encoding ascii
                Write-EditorEvent 'request-completed'
            }
            catch {
                Set-Content -LiteralPath ([IO.Path]::ChangeExtension($activePath, '.error')) -Value 'editor bridge failed' -NoNewline -Encoding ascii
                Write-EditorEvent 'request-writeback-failed'
            }
            finally { Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue }
        }
        else { Write-EditorEvent 'request-cancelled-guest-unavailable' }
    }
    finally {
        Exit-ClaudeLifecycle $mutex
        if ($work) {
            $removeWork = $writebackSucceeded
            if (-not $removeWork -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                $removeWork = ((Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash -eq $originalHash)
            }
            if ($removeWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
            else { Write-EditorEvent 'edited-local-copy-retained-in-windows-temp' }
        }
    }
}

function Invoke-EditorPoll {
    $mutex = Enter-ClaudeLifecycle
    if ($null -eq $mutex) { return 'busy' }
    $requests = @()
    try {
        if (-not (Test-EditorGuestAvailable)) { return 'waiting-for-guest' }
        if (Test-Path -LiteralPath $Queue -PathType Container) {
            $requests = @(Get-ChildItem -LiteralPath $Queue -Filter '*.ready' -File -ErrorAction SilentlyContinue |
                Sort-Object Name | Select-Object -First 16)
        }
    }
    finally { Exit-ClaudeLifecycle $mutex }
    foreach ($request in $requests) { Invoke-EditorRequest -ReadyPath $request.FullName }
    return 'guest-running'
}

if ($FunctionsOnly) { return }

# Design constraint carried over from the beellama-node bridge: this watcher
# must NEVER wake a stopped distribution. Every guest probe is therefore
# either pure Win32 or `wsl --list --running` enumeration (non-waking), and
# UNC queue reads happen only after the distro is confirmed running.

if ($Ensure) {
    # Idempotent self-heal: exit when a watcher is already alive, otherwise
    # spawn one detached. Called from start-claude-session and the logon task
    # so Ctrl+G never falls back to guest nano after a bridge death.
    $self = $PSCommandPath
    $others = @(Get-CimInstance Win32_Process -Filter "name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and
                       $_.CommandLine -like ('*{0}*' -f $self) -and
                       $_.CommandLine -like '*-Watch*' })
    if ($others.Count -gt 0) { exit 0 }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $self, '-Watch')
    exit 0
}

if (-not $Watch -and -not $Once) { $Once = $true }
$previousState = ''
$waitingSleepMs = 500
while ($true) {
    try { $state = Invoke-EditorPoll }
    catch { $state = 'poll-error' }
    if ($state -ne $previousState) { Write-EditorEvent $state; $previousState = $state; $waitingSleepMs = 500 }
    if ($Once) { break }
    if ($state -eq 'waiting-for-guest') {
        # Stopped guest: back off exponentially (cap 15s). Enumeration is
        # non-waking, but there is no reason to churn wsl.exe every second
        # while nobody is using the distribution.
        $waitingSleepMs = [Math]::Min($waitingSleepMs * 2, 15000)
        Start-Sleep -Milliseconds $waitingSleepMs
    }
    else {
        Start-Sleep -Milliseconds ([Math]::Max(500, $PollMilliseconds))
    }
}
