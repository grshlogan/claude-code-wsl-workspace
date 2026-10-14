# Independently restore global WSL offline mode if this short test is not explicitly committed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\load-config.ps1')
$marker = Join-Path $PSScriptRoot 'network-test-approved.flag'
Start-Sleep -Seconds 600
if (Test-Path -LiteralPath $marker) { exit 0 }
$config = Join-Path $env:USERPROFILE '.wslconfig'
$offline = "[wsl2]`r`nnetworkingMode=none`r`ndnsTunneling=false`r`nautoProxy=false`r`nmemory=$WslMemory`r`nprocessors=$WslProcessors`r`nswap=0`r`n"
[System.IO.File]::WriteAllText($config, $offline, [System.Text.UTF8Encoding]::new($false))
& wsl.exe --shutdown
