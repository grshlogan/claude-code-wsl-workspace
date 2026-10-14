"""Secret-free, read-only snapshot for the protected Debian client.

Executed via root WSL Python stdin; network probes run as unprivileged claude.
Never read private keys, wg configuration, Claude state, or process arguments.
"""
import ipaddress
import json
import os
from pathlib import Path
import pwd
import subprocess
import time

# Expected public exit is the configured VPS endpoint (NAT'ed source address).
EXPECTED_EXIT = os.environ.get("CLAUDE_VPS_ENDPOINT_IP", "203.0.113.10")


def run(arguments, timeout=5, unprivileged=False):
    def drop_privileges():
        account = pwd.getpwnam("claude")
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)

    started = time.monotonic()
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, timeout=timeout,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/home/claude", "LANG": "C"},
            preexec_fn=drop_privileges if unprivileged else None,
        )
        return result.returncode, result.stdout[:32768], round(time.monotonic() - started, 3)
    except subprocess.TimeoutExpired:
        return 124, "", round(time.monotonic() - started, 3)
    except OSError:
        return 127, "", round(time.monotonic() - started, 3)


def structured(arguments):
    code, output, _ = run(arguments)
    try:
        return json.loads(output) if code == 0 else None
    except ValueError:
        return None


def wg_status():
    status = {}
    for field in ("latest-handshakes", "transfer"):
        code, output, _ = run(["wg", "show", "wg-claude", field])
        # The first column is a public key. Never publish or store it.
        rows = [line.split()[1:] for line in output.splitlines()]
        numeric = [[int(value) for value in row] for row in rows if row and all(value.isdigit() for value in row)]
        if field == "latest-handshakes":
            epochs = [row[0] for row in numeric if row[0]]
            status["handshake_epoch"] = max(epochs) if code == 0 and epochs else None
        else:
            status["received_bytes"] = sum(row[0] for row in numeric if len(row) == 2) if code == 0 else None
            status["sent_bytes"] = sum(row[1] for row in numeric if len(row) == 2) if code == 0 else None
    epoch = status["handshake_epoch"]
    status["handshake_age_seconds"] = int(time.time()) - epoch if epoch else None
    return status


def service_metadata():
    result = {}
    fields = ["ActiveState", "SubState", "Result", "ExecMainStatus", "ActiveEnterTimestampMonotonic", "NRestarts"]
    for unit in ("claude-guard.service", "wg-quick@wg-claude.service"):
        code, output, _ = run(["systemctl", "show", unit, "--property=" + ",".join(fields)])
        result[unit] = dict(line.split("=", 1) for line in output.splitlines() if "=" in line) if code == 0 else {}
    return result


def curl_probe(url, exit_body=False):
    args = ["curl", "--disable", "--noproxy", "*", "-4", "--connect-timeout", "3", "--max-time", "8", "--silent"]
    if not exit_body:
        args += ["--output", "/dev/null", "--write-out", "%{http_code} %{remote_ip}"]
    code, output, elapsed = run(args + [url], timeout=10, unprivileged=True)
    record = {"curl_exit": code, "elapsed_seconds": elapsed}
    if exit_body:
        try:
            record["public_ipv4"] = str(ipaddress.IPv4Address(output.strip()))
        except ipaddress.AddressValueError:
            record["public_ipv4"] = None
    else:
        parts = output.split()
        record["http_status"] = int(parts[0]) if parts and parts[0].isdigit() else None
        try:
            record["remote_ipv4"] = str(ipaddress.IPv4Address(parts[1]))
        except (IndexError, ipaddress.AddressValueError):
            record["remote_ipv4"] = None
    return record


def snapshot():
    record = {"guest_epoch": time.time(), "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
              "uptime_seconds": float(Path("/proc/uptime").read_text().split()[0]),
              "services": service_metadata(), "wg_before": wg_status()}
    record["addresses_v4"] = structured(["ip", "-j", "-4", "addr"])
    links = structured(["ip", "-s", "-j", "link"]) or []
    record["link_stats"] = [{key: link.get(key) for key in ("ifname", "operstate", "mtu", "stats64")} for link in links]
    neighbors = structured(["ip", "-j", "-4", "neigh"]) or []
    record["neighbors_v4"] = [{key: neighbor.get(key) for key in ("dst", "dev", "state")} for neighbor in neighbors]
    record["routes_v4"] = structured(["ip", "-j", "-4", "route", "show", "table", "all"])
    record["rules_v4"] = structured(["ip", "-j", "-4", "rule"])
    record["route_probe"] = structured(["ip", "-j", "-4", "route", "get", "1.1.1.1"])
    record["underlay_route"] = structured(["ip", "-j", "-4", "route", "get", EXPECTED_EXIT, "mark", "0xc1a0"])
    record["wg_fwmark"] = run(["wg", "show", "wg-claude", "fwmark"])[1].strip()
    nft = structured(["nft", "-j", "list", "table", "inet", "claude_guard"])
    chains, counters = [], []
    if nft:
        for item in nft.get("nftables", []):
            if "chain" in item:
                chain = item["chain"]
                chains.append({key: chain.get(key) for key in ("name", "hook", "prio", "policy")})
            if "rule" in item:
                for expression in item["rule"].get("expr", []):
                    if "counter" in expression:
                        counters.append({"handle": item["rule"].get("handle"), **expression["counter"]})
    record["guard_chains"] = chains
    record["guard_counters"] = counters
    record["guard_check_exit"] = run(["/usr/sbin/claude-wg-client", "check-guard"])[0]
    record["resolvers"] = []
    for line in Path("/etc/resolv.conf").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "nameserver":
            try:
                record["resolvers"].append(str(ipaddress.ip_address(parts[1])))
            except ValueError:
                pass
    guarded = (record["guard_check_exit"] == 0 and
               any(route.get("dev") == "wg-claude" for route in (record["route_probe"] or [])))
    if guarded:
        record["ip_https"] = curl_probe("https://1.1.1.1")
        dns_code, dns_output, elapsed = run(["getent", "ahostsv4", "downloads.claude.ai"], timeout=5, unprivileged=True)
        resolved = []
        for line in dns_output.splitlines():
            try:
                resolved.append(str(ipaddress.IPv4Address(line.split()[0])))
            except (IndexError, ipaddress.AddressValueError):
                pass
        record["dns"] = {"exit": dns_code, "seconds": elapsed, "addresses": sorted(set(resolved))}
        record["hostname_https"] = curl_probe("https://downloads.claude.ai")
        record["exit_probe"] = curl_probe("https://api.ipify.org", exit_body=True)
    record["wg_after"] = wg_status()
    if not guarded:
        record["classification"] = "guard-or-route-failure-probes-skipped"
    elif record["exit_probe"].get("public_ipv4") == EXPECTED_EXIT:
        wg_active = record["services"]["wg-quick@wg-claude.service"].get("ActiveState") == "active"
        https_ok = record["hostname_https"]["curl_exit"] == 0
        record["classification"] = (
            "healthy" if record["dns"]["addresses"] and https_ok and wg_active
            else "service-dns-or-endpoint-degraded"
        )
    elif record["exit_probe"].get("public_ipv4"):
        record["classification"] = "unexpected-public-exit"
    elif not record["dns"]["addresses"] and record["ip_https"]["curl_exit"] == 0:
        record["classification"] = "dns-failure-with-ip-reachable"
    elif record["wg_after"]["handshake_age_seconds"] is None or record["wg_after"]["handshake_age_seconds"] > 180:
        record["classification"] = "tunnel-or-underlay-or-peer-failure"
    else:
        record["classification"] = "https-or-dns-failure-with-fresh-handshake"
    # Journal metadata only: never retain arbitrary messages or shell output.
    code, output, _ = run(["journalctl", "-b", "-u", "claude-guard.service", "-u", "wg-quick@wg-claude.service",
                           "-n", "30", "-o", "json", "--no-pager"])
    record["journal_metadata"] = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
            record["journal_metadata"].append({key: event.get(key) for key in ("__REALTIME_TIMESTAMP", "_SYSTEMD_UNIT", "PRIORITY")})
        except ValueError:
            pass
    return record


if __name__ == "__main__":
    try:
        print(json.dumps(snapshot(), separators=(",", ":")))
    except Exception as exc:
        print(json.dumps({"classification": "collector-error", "error_type": type(exc).__name__}))
        raise SystemExit(1)
