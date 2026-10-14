@echo off
setlocal
rem Convenience launcher: opens the dedicated Firefox ESR profile inside the
rem Debian WSL client. If you changed the distribution name in host/config.ps1,
rem update it here as well.

where wsl.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: wsl.exe was not found in PATH.
    exit /b 1
)

wsl.exe --distribution claude-debian12 --user claude -- /home/claude/.local/bin/claude-browser %*
set "EXITCODE=%ERRORLEVEL%"

endlocal & exit /b %EXITCODE%
