@echo off
setlocal

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: powershell.exe was not found in PATH.
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -File "%~dp0daily\start-claude-session.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

endlocal & exit /b %EXITCODE%
