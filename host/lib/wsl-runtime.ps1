# Shared bounded native execution and cooperative WSL lifecycle gate.
Set-StrictMode -Version Latest
# Runtime state lives at the host root, not inside lib/.
$RuntimeRoot = Split-Path -Parent $PSScriptRoot
$PausePath = Join-Path $RuntimeRoot 'runtime-state\wsl-paused'
$LifecycleMutexName = 'Local\ClaudeWSL-Lifecycle'

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-NativeBounded {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 10,
        [AllowNull()][string]$InputText = $null,
        [switch]$UnicodeOutput,
        [scriptblock]$OnStarted = $null
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = if ($UnicodeOutput) { [Text.Encoding]::Unicode } else { [Text.Encoding]::UTF8 }
    $info.StandardErrorEncoding = $info.StandardOutputEncoding
    $info.EnvironmentVariables.Remove('WSLENV')
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        # Some Windows terminal hosts export their own control-plane
        # variables through the environment and WSLENV. Such entries make WSL
        # try to translate Windows host paths that do not exist in the guest.
        if ([string]$key -match '_(CLI|BIN_DIR|PANE_ID|PANE_REMOTE)$') { $info.EnvironmentVariables.Remove($key) }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'native process did not start' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $OnStarted) { & $OnStarted }
        if ($null -ne $InputText) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($InputText)
            $write = $process.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
            if (-not $write.Wait([int][Math]::Max(0, $TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))) {
                $process.Kill()
                [void]$process.WaitForExit(2000)
                return [pscustomobject]@{ ExitCode = 124; Text = ''; ErrorText = 'native input timeout' }
            }
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit([int][Math]::Max(0, $TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))) {
            $process.Kill()
            [void]$process.WaitForExit(2000)
            return [pscustomobject]@{ ExitCode = 124; Text = ''; ErrorText = 'native timeout' }
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 2000)) {
            return [pscustomobject]@{ ExitCode = 124; Text = ''; ErrorText = 'native output timeout' }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Text = $stdout.GetAwaiter().GetResult().Trim([char]0).Trim()
            ErrorText = $stderr.GetAwaiter().GetResult().Trim([char]0).Trim()
        }
    }
    finally { $process.Dispose() }
}

function Test-ClaudeDistroRunning {
    # Non-waking probe: `--list --running` only enumerates. Invocations like
    # `wsl -d <distro> -e ...` would auto-start a stopped distribution and are
    # forbidden here (watchers must stay passive while the guest is stopped).
    # Instance name is owner-configured; no literal fallback. Callers must
    # dot-source lib/load-config.ps1 before wsl-runtime.ps1.
    $distroName = $WslDistro
    if (Get-Variable -Name 'WslDistro' -ErrorAction SilentlyContinue) { $distroName = $WslDistro }
    $result = Invoke-NativeBounded -FilePath 'wsl.exe' -Arguments @('--list', '--running', '--quiet') -UnicodeOutput
    if ($result.ExitCode -ne 0) { return $false }
    return @($result.Text.Replace([string][char]0, '') -split '\r?\n' | ForEach-Object { $_.Trim() }) -contains $distroName
}

function Enter-ClaudeLifecycle {
    param([int]$TimeoutMilliseconds = 0)
    $mutex = New-Object Threading.Mutex($false, $LifecycleMutexName)
    try {
        $held = $false
        try { $held = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { $mutex.Dispose(); return $null }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-ClaudeLifecycle {
    param($Mutex)
    if ($null -ne $Mutex) { $Mutex.ReleaseMutex(); $Mutex.Dispose() }
}
