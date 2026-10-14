#!/usr/bin/env bash
# Shared guest-only Secret Service operations. Never trace password handling.

keyring_run() {
  timeout --kill-after=2s "${KEYRING_OPERATION_TIMEOUT:-10}s" "$@"
}

keyring_fail() {
  printf 'Keyring error: %s\n' "$1" >&2
  return 1
}

keyring_prepare() {
  local uid unit state
  uid=$(id -u)
  export XDG_RUNTIME_DIR="/run/user/$uid"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  unset GNOME_KEYRING_CONTROL
  [[ -S "$XDG_RUNTIME_DIR/bus" ]] || {
    keyring_fail 'The systemd user D-Bus socket is unavailable.'; return 1;
  }
  for unit in gnome-keyring-daemon.service gnome-keyring-daemon.socket; do
    state=$(keyring_run systemctl --user is-enabled "$unit") || true
    [[ "$state" == masked ]] || {
      keyring_fail 'The conflicting systemd keyring startup is not masked for this user.'; return 1;
    }
  done
  mkdir -p "$XDG_RUNTIME_DIR/keyring"
  chmod 700 "$XDG_RUNTIME_DIR/keyring"
}

keyring_state() {
  keyring_run busctl --user get-property org.freedesktop.secrets \
    /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked 2>/dev/null
}

keyring_wait_state() {
  local state result attempt
  for attempt in {1..20}; do
    # Check ownership through D-Bus itself, without autoactivating another daemon
    # while the password-initialized instance is still starting.
    if keyring_run busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus GetNameOwner s org.freedesktop.secrets >/dev/null 2>&1; then
      if state=$(keyring_state); then
        printf '%s\n' "$state"
        return 0
      else
        result=$?
        [[ "$result" == 1 ]] || return "$result"
      fi
    else
      result=$?
      [[ "$result" == 1 ]] || return "$result"
    fi
    sleep 0.1
  done
  return 1
}

keyring_require_unlocked() {
  local state
  state=$(keyring_state) || {
    keyring_fail 'The login collection is not available. Run the keyring initialization step.'; return 1;
  }
  [[ "$state" == 'b false' ]] || {
    keyring_fail 'The login keyring is locked. Unlock it locally before continuing.'; return 1;
  }
}

keyring_unlock() {
  local password='' state
  # Read EOF-terminated input from a pipe; never put the password in argv/files.
  IFS= read -r -d '' password || true
  if [[ -z "$password" ]]; then
    keyring_fail 'An empty keyring password is not allowed.'; return 1
  fi
  # --unlock alone starts another daemon. Replace the old instance and load the
  # encrypted login collection before advertising the new Secret Service.
  if ! printf '%s' "$password" | keyring_run gnome-keyring-daemon --replace --unlock \
      --components=secrets --control-directory="$XDG_RUNTIME_DIR/keyring" >/dev/null; then
    unset password
    keyring_fail 'Unlocking failed or timed out.'; return 1
  fi
  unset password
  state=$(keyring_wait_state) || {
    keyring_fail 'The password-initialized Secret Service did not become ready.'; return 1;
  }
  [[ "$state" == 'b false' ]] || {
    keyring_fail 'The login keyring is still locked. Check the password and retry.'; return 1;
  }
}

keyring_remove_probe() {
  keyring_run secret-tool clear service claude-keyring-setup-probe username "$1" >/dev/null
}

keyring_probe() {
  local probe_user value result
  keyring_require_unlocked || return 1
  probe_user="probe-$(date +%s)-$$-$RANDOM"
  if ! printf '%s' 'probe-value' | keyring_run secret-tool store --collection=login \
      --label='temporary Claude keyring setup probe' service claude-keyring-setup-probe username "$probe_user"; then
    keyring_remove_probe "$probe_user" || true
    keyring_fail 'Writing the temporary probe failed or timed out. OAuth was not started.'; return 1
  fi
  if ! value=$(keyring_run secret-tool lookup service claude-keyring-setup-probe username "$probe_user"); then
    keyring_remove_probe "$probe_user" || true
    keyring_fail 'Reading the temporary probe failed or timed out.'; return 1
  fi
  if [[ "$value" != probe-value ]]; then
    keyring_remove_probe "$probe_user" || true
    keyring_fail 'The temporary probe did not round-trip correctly.'; return 1
  fi
  keyring_remove_probe "$probe_user" || {
    keyring_fail 'Removing the temporary probe failed or timed out.'; return 1;
  }
  if keyring_run secret-tool lookup service claude-keyring-setup-probe username "$probe_user" >/dev/null; then
    keyring_fail 'The temporary probe remains in the keyring.'; return 1
  else
    result=$?
    [[ "$result" == 1 ]] || {
      keyring_fail 'Verifying probe removal failed or timed out.'; return 1;
    }
  fi
  printf '%s\n' 'KEYRING_PROBE_OK'
}
