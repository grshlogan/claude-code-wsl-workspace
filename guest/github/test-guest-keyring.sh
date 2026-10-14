#!/usr/bin/env bash
# Isolated integration tests: private HOME, user bus, and dummy credentials only.
set -euo pipefail
set +x
ulimit -c 0
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export KEYRING_TEST_LIBRARY="$SCRIPT_DIR/guest-keyring.sh"
if [[ "${1:-}" != --private-session ]]; then
  scratch=$(mktemp -d /tmp/claude-keyring-test.XXXXXX)
  trap 'rm -rf -- "$scratch"' EXIT
  export HOME="$scratch/home"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_RUNTIME_DIR="$scratch/run"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR/keyring"
  unset DBUS_SESSION_BUS_ADDRESS GNOME_KEYRING_CONTROL
  timeout --kill-after=2s 45s dbus-run-session -- bash "$0" --private-session
  exit $?
fi

source "$KEYRING_TEST_LIBRARY"
export KEYRING_OPERATION_TIMEOUT=2
stop_private_daemons() {
  local pid
  # Only terminate processes whose HOME is this disposable test directory.
  for pid in $(pgrep -u "$(id -u)" -x gnome-keyring-d || true); do
    if [[ -r "/proc/$pid/environ" ]] &&
        tr '\0' '\n' < "/proc/$pid/environ" | grep -Fxq "HOME=$HOME"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap stop_private_daemons EXIT

keyring_unlock < <(printf '%s' 'public-dummy-fixture-password')
keyring_require_unlocked
keyring_probe
printf '%s\n' 'PASS: first-time encrypted collection initialization and probe'
[[ -f "$HOME/.local/share/keyrings/login.keyring" ]]
[[ "$(stat -c '%a' "$HOME/.local/share/keyrings/login.keyring")" == 600 ]]

# Replace the daemon without a password, as happens after a new WSL session.
keyring_run gnome-keyring-daemon --replace --components=secrets \
  --control-directory="$XDG_RUNTIME_DIR/keyring" >/dev/null
[[ "$(keyring_wait_state)" == 'b true' ]]
if keyring_probe >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: a locked keyring must fail before a storage probe' >&2
  exit 1
fi
printf '%s\n' 'PASS: restarted keyring fails closed before a storage probe'

started=$SECONDS
if keyring_unlock < <(printf '%s' 'incorrect-public-fixture-password') >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: an incorrect password must not pass unlock verification' >&2
  exit 1
fi
(( SECONDS - started < 8 ))
printf '%s\n' 'PASS: incorrect password is rejected without a graphical prompt'

# Production uses a pipeline: test that exact call pattern for an existing keyring.
printf '%s' 'public-dummy-fixture-password' | keyring_unlock
keyring_probe
printf '%s\n' 'PASS: existing keyring unlock and probe after daemon replacement'

if keyring_unlock </dev/null >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: an empty password must be rejected' >&2
  exit 1
fi
printf '%s\n' 'PASS: empty password fails closed'

# Simulate a stalled Secret Service store while retaining the production timeout.
keyring_run() {
  if [[ "${KEYRING_STALL_STORE:-0}" == 1 && "$1" == secret-tool && "$2" == store ]]; then
    timeout --kill-after=2s "${KEYRING_OPERATION_TIMEOUT}s" sleep 20
  else
    timeout --kill-after=2s "${KEYRING_OPERATION_TIMEOUT}s" "$@"
  fi
}
KEYRING_STALL_STORE=1
started=$SECONDS
if keyring_probe >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: a stalled storage probe must report failure' >&2
  exit 1
fi
(( SECONDS - started < 8 ))
printf '%s\n' 'PASS: storage timeout exits instead of hanging'
KEYRING_STALL_STORE=0
keyring_probe
printf '%s\n' 'KEYRING_REGRESSION_OK'
