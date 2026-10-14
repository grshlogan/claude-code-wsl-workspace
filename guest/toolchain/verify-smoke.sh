#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
export PATH="$HOME/.local/bin:$PATH"
export UV_PYTHON_DOWNLOADS=never
ROOT="$HOME/projects/toolchain-smoke"
AUDIT="$HOME/.local/state/claude-toolchain/audit"
exec > >(tee "$AUDIT/offline-smoke.txt") 2>&1
cd "$ROOT/c"
gcc -std=c17 -O2 -Wall -Wextra -Werror -pedantic smoke.c -o smoke
./smoke
cd "$ROOT/python"
uv sync --locked --offline
uv run --offline ruff check
uv run --offline ruff format --check
uv run --offline ty check
uv run --offline pytest
cd "$ROOT/node"
npm ci --offline --ignore-scripts --no-audit --no-fund
npm test
cd "$ROOT/rust"
cargo fmt --check
cargo clippy --locked --offline -- -D warnings
cargo test --locked --offline
cargo build --release --locked --offline
cargo run --quiet --locked --offline
printf 'ALL_LANGUAGE_OFFLINE_SMOKE_OK\n'
