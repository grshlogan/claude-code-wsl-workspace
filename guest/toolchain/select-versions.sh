#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
AUDIT="$HOME/.local/state/claude-toolchain/audit"
install -d -m 700 "$AUDIT"
fetch() {
    curl --noproxy '*' -4 --proto '=https' --tlsv1.2 --fail --silent --show-error \
        --location --retry 2 --connect-timeout 15 --max-time 120 "$1" -o "$2"
}
fetch https://api.github.com/repos/astral-sh/uv/releases/latest "$AUDIT/uv-release.json"
fetch https://nodejs.org/dist/index.json "$AUDIT/node-index.json"
fetch https://static.rust-lang.org/dist/channel-rust-stable.toml "$AUDIT/rust-stable.toml"
fetch https://static.rust-lang.org/rustup/release-stable.toml "$AUDIT/rustup-stable.toml"
UV_VERSION=$(jq -er '.tag_name | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$AUDIT/uv-release.json")
NODE_VERSION=$(jq -er '[.[] | select(.lts != false and (.version | test("^v24\\.[0-9]+\\.[0-9]+$")))][0].version' "$AUDIT/node-index.json")
RUST_VERSION=$(/usr/bin/python3 -c 'import sys,tomllib; print(tomllib.load(sys.stdin.buffer)["pkg"]["rust"]["version"].split()[0])' < "$AUDIT/rust-stable.toml")
RUSTUP_VERSION=$(/usr/bin/python3 -c 'import sys,tomllib; print(tomllib.load(sys.stdin.buffer)["version"])' < "$AUDIT/rustup-stable.toml")
[[ $RUST_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $RUSTUP_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
printf 'UV_VERSION=%s\nNODE_VERSION=%s\nRUST_VERSION=%s\nRUSTUP_VERSION=%s\n' \
    "$UV_VERSION" "$NODE_VERSION" "$RUST_VERSION" "$RUSTUP_VERSION" | tee "$AUDIT/selected-versions.env"
