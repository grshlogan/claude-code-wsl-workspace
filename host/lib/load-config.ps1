# Shared config loader. Source this before using $WslDistro, $VpsEndpointIp, etc.
# Prefers the private config.ps1; falls back to the committed template so that
# read-only inspection works out of the box with documentation placeholders.
$configPath = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    . $configPath
}
else {
    . (Join-Path $PSScriptRoot 'config.example.ps1')
}
