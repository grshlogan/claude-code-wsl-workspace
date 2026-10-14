# Central host-side configuration for the claude-code-wsl-workspace.
#
# Copy this file to config.ps1 (same lib/ directory) and edit the values.
# config.ps1 is git-ignored; real endpoints, SSH pins and paths never enter Git.
#
# All host scripts load config.ps1 through lib/load-config.ps1 when present,
# and fall back to this template (with the RFC 5737 documentation IP)
# otherwise, so the scripts are runnable out of the box for dry-run inspection.

# WSL2 distribution name of the Debian 12 client.
$WslDistro = 'claude-debian12'

# Unprivileged Linux user inside the client and its home directory.
$LinuxUser = 'claude'
$LinuxHome = '/home/claude'

# VPS public IPv4 address and the WireGuard UDP port pinned by the design.
# 203.0.113.10 is the RFC 5737 documentation address; replace it with your VPS.
$VpsEndpointIp = '203.0.113.10'
$VpsWgPort     = '51820'

# SSH host-key pin for recover-wireguard.ps1 (optional but recommended).
# Base64 ed25519 host key of the VPS and its SHA-256 fingerprint (no padding,
# computed as: base64(sha256(base64decode($VpsSshHostKey)))). Leave empty to
# skip the recover helper's SSH stage.
$VpsSshHostKey = ''
$VpsSshFingerprint = ''

# Optional Windows-side helper that stop-wsl-session.ps1 should stop first
# (for example a local model-API bridge). Leave empty if you have none.
$BridgeStopScript = ''

# VS Code executable used by the prompt-only editor bridge (optional feature).
# The bridge only edits temporary Claude prompt files inside the guest; it is
# not a remote development service.
$VsCodePath = 'C:\Program Files\Microsoft VS Code\Code.exe'

# .wslconfig resource settings used by the network-test watchdog when it must
# restore the offline bootstrap state. Adjust to your hardware.
$WslMemory     = '24GB'
$WslProcessors = 24
