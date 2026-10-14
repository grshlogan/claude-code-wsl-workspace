#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
AUDIT="$HOME/.local/state/claude-toolchain/audit"
NAME=node-v24.21.0-linux-x64.tar.xz
STAGE=$(mktemp -d /tmp/claude-node-verify.XXXXXX)
trap 'rm -rf -- "$STAGE"' EXIT
fetch() {
    curl --noproxy '*' -4 --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 120 "$1" -o "$2"
}
fetch https://raw.githubusercontent.com/nodejs/release-keys/HEAD/gpg/pubring.kbx "$STAGE/nodejs-keyring.kbx"
fetch https://nodejs.org/dist/v24.21.0/SHASUMS256.txt.asc "$STAGE/SHASUMS256.txt.asc"
install -d -m 700 "$STAGE/gnupg"
gpgv --homedir "$STAGE/gnupg" --keyring "$STAGE/nodejs-keyring.kbx" \
    --status-fd 1 --output "$STAGE/verified-sums.txt" < "$STAGE/SHASUMS256.txt.asc" \
    | tee "$AUDIT/node-signature.txt"
EXPECTED=$(awk -v name="$NAME" '$2 == name {print $1}' "$STAGE/verified-sums.txt")
OBSERVED=$(awk '{print $1}' "$AUDIT/node-archive.sha256")
[[ $EXPECTED =~ ^[0-9a-f]{64}$ && $EXPECTED == "$OBSERVED" ]]
printf 'NODE_SIGNED_ARCHIVE_DIGEST_OK: %s\n' "$EXPECTED"
