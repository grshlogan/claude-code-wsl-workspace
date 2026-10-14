#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]]
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 ]]
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
AUDIT=/root/claude-toolchain-audit
install -d -m 700 "$AUDIT"
if [[ -e $AUDIT/packages-before.tsv ]]; then
    printf 'Baseline already exists; refusing to overwrite it.\n' >&2
    exit 1
fi
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$AUDIT/packages-before.tsv"
sha256sum /etc/wireguard/wg-claude.conf /etc/wsl.conf /etc/resolv.conf \
    /etc/nftables.d/claude-guard-loopback.nft \
    /etc/systemd/system/claude-guard.service.d/20-loopback.conf \
    /etc/apt/sources.list /etc/apt/sources.list.d/claude-code.list \
    /usr/bin/claude > "$AUDIT/protected-before.sha256"
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=2 update
apt-get --simulate --no-install-recommends --no-upgrade install \
    ca-certificates curl gnupg git jq ripgrep file unzip zip xz-utils \
    gcc libc6-dev binutils make pkg-config python3 python3-venv \
    | tee "$AUDIT/apt-simulation.txt"
