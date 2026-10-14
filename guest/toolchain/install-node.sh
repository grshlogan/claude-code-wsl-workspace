#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
NODE_VERSION=v24.21.0
AUDIT="$HOME/.local/state/claude-toolchain/audit"
NAME="node-$NODE_VERSION-linux-x64"
DEST="$HOME/.local/opt/$NAME"
[[ ! -e $DEST ]]
for cmd in node npm npx corepack; do
    [[ ! -e $HOME/.local/bin/$cmd ]]
done
STAGE=$(mktemp -d /tmp/claude-node.XXXXXX)
trap 'rm -rf -- "$STAGE"' EXIT
fetch() {
    curl --noproxy '*' -4 --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 600 "$1" -o "$2"
}
BASE="https://nodejs.org/dist/$NODE_VERSION"
fetch https://raw.githubusercontent.com/nodejs/release-keys/HEAD/gpg/pubring.kbx "$STAGE/nodejs-keyring.kbx"
fetch "$BASE/SHASUMS256.txt.asc" "$STAGE/SHASUMS256.txt.asc"
fetch "$BASE/$NAME.tar.xz" "$STAGE/$NAME.tar.xz"
install -d -m 700 "$STAGE/gnupg"
gpgv --homedir "$STAGE/gnupg" --keyring "$STAGE/nodejs-keyring.kbx" \
    --status-fd 1 --output "$STAGE/SHASUMS256.txt" < "$STAGE/SHASUMS256.txt.asc" \
    | tee "$AUDIT/node-signature.txt"
(cd "$STAGE" && sha256sum --check --ignore-missing SHASUMS256.txt)
(cd "$STAGE" && sha256sum "$NAME.tar.xz") | tee "$AUDIT/node-archive.sha256"
install -d "$HOME/.local/opt"
mkdir -p "$HOME/.local/bin"
tar -xJf "$STAGE/$NAME.tar.xz" -C "$HOME/.local/opt"
for cmd in node npm npx corepack; do
    if [[ -e $DEST/bin/$cmd ]]; then
        ln -s "$DEST/bin/$cmd" "$HOME/.local/bin/$cmd"
    fi
done
export PATH="$HOME/.local/bin:$PATH"
node --version
npm --version
npx --version
printf 'NODE_INSTALL_OK\n'
