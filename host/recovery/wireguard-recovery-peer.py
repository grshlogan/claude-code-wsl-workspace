"""Fixed-target OS recovery helper streamed through WSL/SSH stdin.

Check is read-only. Restart requires explicit confirmation and a live deadline.
Never print command output, keys, configuration, or journal messages.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import stat
import time

WG_UNIT = "wg-quick@wg-claude.service"
FORWARD_UNIT = "wg-claude-forward.service"


class RecoveryError(Exception):
    pass


def command(arguments, timeout=8):
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, timeout=timeout,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C", "HOME": "/root"},
        )
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError:
        return 127, ""


def unit_state(unit):
    code, output = command([
        "systemctl", "show", unit,
        "--property=ActiveState,SubState,Result,NRestarts,ActiveEnterTimestampMonotonic",
    ])
    if code:
        return {}
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def snapshot(role):
    cli = "/usr/sbin/claude-wg-peer" if role == "Server" else "/usr/sbin/claude-wg-client"
    record = {"epoch": time.time(), "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}
    units = [WG_UNIT, FORWARD_UNIT if role == "Server" else "claude-guard.service"]
    record["services"] = {unit: unit_state(unit) for unit in units}
    fields = ["verify"] if role == "Server" else ["check-files", "check-guard"]
    record["checks"] = {field: command([cli, field])[0] for field in fields}
    if role == "Server":
        code, output = command([cli, "status", "--json"])
        try:
            status = json.loads(output) if code == 0 else {}
        except ValueError:
            status = {}
        # Whitelist the package's secret-free status fields.
        record["peer"] = {field: status.get(field) for field in (
            "package", "interface_state", "wg_service", "forward_service", "listen_port",
            "allowed_ip", "latest_handshake_epoch", "transfer_bytes", "ipv4_forwarding",
        )}
    return record


def require_contract(role, record):
    if any(value != 0 for value in record["checks"].values()):
        raise RecoveryError("contract-check-failed")
    required = [WG_UNIT, "claude-guard.service"] if role == "Client" else [WG_UNIT, FORWARD_UNIT]
    if any(record["services"][unit].get("ActiveState") != "active" for unit in required):
        raise RecoveryError("required-service-inactive")
    if role == "Server":
        peer = record["peer"]
        if (peer.get("listen_port") != 51820 or peer.get("allowed_ip") != "10.77.42.2/32"
                or peer.get("ipv4_forwarding") != 1):
            raise RecoveryError("server-contract-mismatch")


def require_deadline(deadline, budget):
    if deadline is None or time.time() + budget >= deadline:
        raise RecoveryError("maintenance-window-expired-or-too-short")


def recovery_lock():
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open("/run/lock/claude-wg-recovery.lock", flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
            raise RecoveryError("unsafe-linux-recovery-lock")
        lock = os.fdopen(descriptor, "a", encoding="ascii")
    except Exception:
        os.close(descriptor)
        raise
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        lock.close()
        raise RecoveryError("linux-recovery-busy") from exc
    except Exception:
        lock.close()
        raise
    return lock


def execute(role, action, confirmed=False, deadline=None):
    result = {"schema": 1, "role": role, "action": action, "ok": False, "steps": []}
    lock = None
    try:
        if os.geteuid() != 0:
            raise RecoveryError("root-required")
        if action == "Restart":
            if not confirmed:
                raise RecoveryError("restart-not-confirmed")
            require_deadline(deadline, 60)
            # Serialize this tool on each Linux host. Check never creates a lock file.
            lock = recovery_lock()
        result["before"] = snapshot(role)
        require_contract(role, result["before"])
        if action == "Restart":
            units = [WG_UNIT, FORWARD_UNIT] if role == "Server" else [WG_UNIT]
            for unit in units:
                require_deadline(deadline, 25)
                step = {"unit": unit, "operation": "restart", "attempted_epoch": time.time()}
                result["steps"].append(step)
                code, _ = command(["systemctl", "restart", unit], timeout=20)
                step["exit"] = code
                if code:
                    # systemd may still finish a job after a timed-out client.
                    raise RecoveryError("restart-timeout-state-unknown" if code == 124 else "restart-failed")
            result["after"] = snapshot(role)
            require_contract(role, result["after"])
            if result["after"]["services"][WG_UNIT].get("ActiveState") != "active":
                raise RecoveryError("wireguard-not-active-after-restart")
        result["ok"] = True
    except RecoveryError as exc:
        result["error_code"] = str(exc)
    except Exception as exc:
        result["error_code"] = "helper-error"
        result["error_type"] = type(exc).__name__
    finally:
        if lock is not None:
            lock.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("role", choices=("Client", "Server"))
    parser.add_argument("action", choices=("Check", "Restart"))
    parser.add_argument("--confirmed-restart", action="store_true")
    parser.add_argument("--deadline", type=int)
    options = parser.parse_args()
    result = execute(options.role, options.action, options.confirmed_restart, options.deadline)
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
