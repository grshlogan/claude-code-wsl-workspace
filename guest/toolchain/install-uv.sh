#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
UV_VERSION=0.12.22
AUDIT="$HOME/.local/state/claude-toolchain/audit"
DEST="$HOME/.local/opt/uv-$UV_VERSION"
[[ ! -e $DEST && ! -e $HOME/.local/bin/uv && ! -e $HOME/.local/bin/uvx ]]
STAGE=$(mktemp -d /tmp/claude-uv.XXXXXX)
trap 'rm -rf -- "$STAGE"' EXIT
fetch() {
    curl --noproxy '*' -4 --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 300 "$1" -o "$2"
}
ASSET=uv-x86_64-unknown-linux-gnu.tar.gz
BASE="https://github.com/astral-sh/uv/releases/download/$UV_VERSION"
fetch "$BASE/$ASSET" "$STAGE/$ASSET"
fetch "$BASE/$ASSET.sha256" "$STAGE/$ASSET.sha256"
(cd "$STAGE" && sha256sum --check "$ASSET.sha256")
(cd "$STAGE" && sha256sum "$ASSET") | tee "$AUDIT/uv-archive.sha256"
tar -xzf "$STAGE/$ASSET" -C "$STAGE"
install -d "$DEST"
mkdir -p "$HOME/.local/bin"
install -m 755 "$STAGE/uv-x86_64-unknown-linux-gnu/uv" "$DEST/uv"
install -m 755 "$STAGE/uv-x86_64-unknown-linux-gnu/uvx" "$DEST/uvx"
ln -s "$DEST/uv" "$HOME/.local/bin/uv"
ln -s "$DEST/uvx" "$HOME/.local/bin/uvx"
"$HOME/.local/bin/uv" --version
"$HOME/.local/bin/uvx" --version
printf 'UV_INSTALL_OK\n'
