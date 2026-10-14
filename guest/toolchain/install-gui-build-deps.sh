#!/usr/bin/env bash
# GUI development build dependencies for the Debian 12 WSL client.
set -euo pipefail
[[ $(id -u) == 0 ]]
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 ]]
/usr/sbin/claude-wg-client check-files
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
AUDIT="/root/claude-gui-build-deps-$(date -u +%Y%m%dT%H%M%SZ)"
[[ ! -e $AUDIT ]]
install -d -m 700 "$AUDIT"
printf 'AUDIT=%s\n' "$AUDIT"
protected=(/etc/wireguard/wg-claude.conf /etc/wireguard/claude.key
    /etc/wsl.conf /etc/resolv.conf /etc/nftables.d/claude-guard-loopback.nft
    /etc/systemd/system/claude-guard.service.d/20-loopback.conf
    /usr/lib/systemd/system/wg-quick@wg-claude.service.d/10-claude-client.conf
    /usr/bin/claude /home/claude/.claude/settings.json
    /home/claude/.local/bin/claude-windows-editor)
while IFS= read -r -d '' source; do protected+=("$source"); done < <(
    find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \) -print0)
sha256sum "${protected[@]}" > "$AUDIT/protected-before.sha256"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$AUDIT/packages-before.tsv"
finish() {
    status=$?
    trap - EXIT
    # Keep partial downloads on failure so a reviewed retry can resume.
    if [[ $status == 0 ]]; then apt-get clean; fi
    printf '%s\n' "$status" > "$AUDIT/exit-status"
    exit "$status"
}
trap finish EXIT
export DEBIAN_FRONTEND=noninteractive
timeout 240 apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=1 \
    -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    -o APT::Update::Error-Mode=any update 2>&1 | tee "$AUDIT/apt-update.log"
packages=(g++ cmake ninja-build libgl1-mesa-dev libx11-dev libxrandr-dev
    libxinerama-dev libxcursor-dev libxi-dev libxext-dev libcurl4-openssl-dev
    libglib2.0-dev gdb ccache)
pinned=()
for package in "${packages[@]}"; do
    version=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')
    [[ -n $version && $version != '(none)' ]]
    pinned+=("$package=$version")
done
printf '%s\n' "${pinned[@]}" > "$AUDIT/selected-packages.txt"
apt-get --simulate --no-install-recommends install "${pinned[@]}" | tee "$AUDIT/apt-simulation.txt"
# The reviewed transaction may update only these dependency-matched components.
python3 -I - "$AUDIT/apt-simulation.txt" <<'PY'
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text()
allowed = {'libpcre2-8-0', 'libpython3.11-minimal', 'libpython3.11-stdlib',
           'python3.11', 'python3.11-minimal', 'python3.11-venv'}
assert not re.search(r'^Remv ', text, re.M), 'Refusing package removal'
changed = set(re.findall(r'^Inst (\S+) \[', text, re.M))
assert changed <= allowed, 'Unexpected upgrades: ' + str(changed - allowed)
print('DEPENDENCY_UPGRADE_SCOPE_OK: ' + ', '.join(sorted(changed)))
PY
timeout 1800 apt-get -y --no-install-recommends \
    -o Acquire::ForceIPv4=true -o Acquire::Retries=1 \
    -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    install "${pinned[@]}" 2>&1 | tee "$AUDIT/apt-install.log"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$AUDIT/packages-after.tsv"
sha256sum --check "$AUDIT/protected-before.sha256" > "$AUDIT/protected-check.txt"
dpkg --audit > "$AUDIT/dpkg-audit.txt"
[[ ! -s $AUDIT/dpkg-audit.txt ]]
/usr/sbin/claude-wg-client check-files
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
printf 'GUI_BUILD_DEPS_INSTALL_OK\n'
