#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == claude ]]
export PATH="$HOME/.local/bin:$PATH"
export UV_PYTHON_DOWNLOADS=never
export npm_config_update_notifier=false
ROOT="$HOME/projects/toolchain-smoke"
AUDIT="$HOME/.local/state/claude-toolchain/audit"
exec > >(tee "$AUDIT/python-node-c-smoke.txt") 2>&1
cd "$ROOT/c"
gcc -std=c17 -O2 -Wall -Wextra -Werror -pedantic smoke.c -o smoke
./smoke
cd "$ROOT/python"
uv add --python /usr/bin/python3 --group dev pytest ruff ty
uv sync --locked --python /usr/bin/python3
uv run python -c 'import sys; assert sys.prefix != sys.base_prefix; print("PYTHON_VENV_OK", sys.version.split()[0])'
uv run ruff check
uv run ruff format --check
uv run ty check
uv run pytest
cd "$ROOT/node"
npm install --save-dev --save-exact --ignore-scripts --no-audit --no-fund \
    typescript@7.0.2 @types/node@24
npm ci --ignore-scripts --no-audit --no-fund
npm exec -- tsc --version
npm test
printf 'C_PYTHON_NODE_TYPESCRIPT_OK\n'
