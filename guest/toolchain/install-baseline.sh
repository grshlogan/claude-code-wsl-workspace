#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]]
AUDIT=/root/claude-toolchain-audit
[[ -f $AUDIT/protected-before.sha256 ]]
sha256sum --check --status "$AUDIT/protected-before.sha256"
/usr/sbin/claude-wg-client check-guard
trap 'apt-get clean' EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=2 \
    -o Dpkg::Options::=--force-confold \
    --yes --no-install-recommends --no-upgrade install \
    ca-certificates curl gnupg git jq ripgrep file unzip zip xz-utils \
    gcc libc6-dev binutils make pkg-config python3 python3-venv \
    | tee "$AUDIT/apt-install.txt"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$AUDIT/packages-after-baseline.tsv"
sha256sum --check --status "$AUDIT/protected-before.sha256"
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
python3 --version
gcc --version | head -n 1
git --version
printf 'BASELINE_INSTALL_OK\n'
