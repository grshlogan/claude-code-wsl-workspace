#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
RUST_VERSION=1.99.0
RUSTUP_VERSION=1.29.1
AUDIT="$HOME/.local/state/claude-toolchain/audit"
[[ ! -e $HOME/.cargo && ! -e $HOME/.rustup ]]
for cmd in rustup rustc cargo rustdoc rustfmt cargo-fmt cargo-clippy clippy-driver; do
    [[ ! -e $HOME/.local/bin/$cmd ]]
done
STAGE=$(mktemp -d /tmp/claude-rust.XXXXXX)
trap 'rm -rf -- "$STAGE"' EXIT
fetch() {
    curl --noproxy '*' -4 --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 300 "$1" -o "$2"
}
BASE="https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu"
fetch "$BASE/rustup-init" "$STAGE/rustup-init"
fetch "$BASE/rustup-init.sha256" "$STAGE/rustup-init.sha256"
(cd "$STAGE" && sha256sum --check rustup-init.sha256)
(cd "$STAGE" && sha256sum rustup-init) | tee "$AUDIT/rustup-init.sha256"
chmod 700 "$STAGE/rustup-init"
"$STAGE/rustup-init" -y --no-modify-path --profile minimal \
    --default-host x86_64-unknown-linux-gnu --default-toolchain "$RUST_VERSION" \
    --component rustfmt --component clippy
mkdir -p "$HOME/.local/bin"
for cmd in rustup rustc cargo rustdoc rustfmt cargo-fmt cargo-clippy clippy-driver; do
    ln -s "$HOME/.cargo/bin/$cmd" "$HOME/.local/bin/$cmd"
done
export PATH="$HOME/.local/bin:$PATH"
rustup --version
rustc --version
cargo --version
rustup component list --installed | tee "$AUDIT/rust-components.txt"
printf 'RUST_INSTALL_OK\n'
