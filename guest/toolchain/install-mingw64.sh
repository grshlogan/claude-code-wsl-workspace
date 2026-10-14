#!/usr/bin/env bash
# Windows x64 cross-compilers (MinGW-w64) for the Debian 12 WSL client.
# Run as root through WSL stdin; no Windows interop or repository changes.
set -euo pipefail
[[ $(id -u) == 0 ]]
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 ]]
/usr/sbin/claude-wg-client check-files
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
AUDIT="/root/claude-mingw64-$(date -u +%Y%m%dT%H%M%SZ)"
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
    apt-get clean
    printf '%s\n' "$status" > "$AUDIT/exit-status"
    exit "$status"
}
trap finish EXIT
export DEBIAN_FRONTEND=noninteractive
# Use only the existing signed Debian repositories and protected tunnel.
timeout 180 apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=1 \
    -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    -o APT::Update::Error-Mode=any update 2>&1 | tee "$AUDIT/apt-update.log"
packages=(binutils-mingw-w64-x86-64 gcc-mingw-w64-base
    gcc-mingw-w64-x86-64-posix gcc-mingw-w64-x86-64-posix-runtime
    g++-mingw-w64-x86-64-posix mingw-w64-common mingw-w64-x86-64-dev)
pinned=()
for package in "${packages[@]}"; do
    version=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')
    [[ -n $version && $version != '(none)' ]]
    pinned+=("$package=$version")
done
printf '%s\n' "${pinned[@]}" > "$AUDIT/selected-packages.txt"
apt-get --simulate --no-install-recommends --no-upgrade install "${pinned[@]}" \
    | tee "$AUDIT/apt-simulation.txt"
# Fail before downloading if APT proposes an existing package upgrade or removal.
if grep -Eq '^Remv |^Inst [^ ]+ \[' "$AUDIT/apt-simulation.txt"; then
    printf 'Refusing existing-package upgrade or removal.\n' >&2
    exit 1
fi
timeout 1800 apt-get -y --no-install-recommends --no-upgrade \
    -o Acquire::ForceIPv4=true -o Acquire::Retries=1 \
    -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    install "${pinned[@]}" 2>&1 | tee "$AUDIT/apt-install.log"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$AUDIT/packages-after.tsv"
sha256sum --check "$AUDIT/protected-before.sha256" > "$AUDIT/protected-check.txt"
/usr/sbin/claude-wg-client check-files
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
x86_64-w64-mingw32-gcc --version | head -n 1
x86_64-w64-mingw32-g++ --version | head -n 1
x86_64-w64-mingw32-windres --version | head -n 1
printf 'MINGW64_INSTALL_OK\n'
