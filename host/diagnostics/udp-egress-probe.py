"""Bounded IPv4 STUN acceptance helper; no configuration changes or raw sockets.

Run through isolated system Python stdin in WSL. Only metadata runs as root;
resolve/probe require UID 1000. No packet payloads or unexpected public IPs logged.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import secrets
import socket
import struct
import subprocess
import time
from pathlib import Path

COOKIE = 0x2112A442
# Expected public exit is the configured VPS endpoint (NAT'ed source address).
EXPECTED_EXIT = os.environ.get("CLAUDE_VPS_ENDPOINT_IP", "203.0.113.10")
SERVERS = (
    ("google", "stun.l.google.com", 19302),
    ("cloudflare", "stun.cloudflare.com", 3478),
)
MODES = ("normal", "device", "device-source", "source")


def command(argv):
    result = subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"},
    )
    return result.stdout


def match(left, right):
    return {"match": {"op": "==", "left": left, "right": right}}


def meta(key, value):
    return match({"meta": {"key": key}}, value)


def payload(protocol, field, value):
    return match({"payload": {"protocol": protocol, "field": field}}, value)


def expected_rules():
    return [
        [
            meta("oifname", "lo"),
            payload("ip", "daddr", {"prefix": {"addr": "127.0.0.0", "len": 8}}),
            {"accept": None},
        ],
        [meta("oifname", "lo"), payload("ip6", "daddr", "::1"), {"accept": None}],
        [meta("nfproto", "ipv4"), meta("oifname", "wg-claude"), {"accept": None}],
        [
            meta("mark", 49568),
            payload("ip", "daddr", EXPECTED_EXIT),
            payload("udp", "dport", 51820),
            {"accept": None},
        ],
        [meta("nfproto", "ipv6"), {"drop": None}],
        [{"drop": None}],
    ]


def metadata():
    if os.getuid() != 0:
        raise ValueError("metadata requires root")
    data = json.loads(
        command(["/usr/sbin/nft", "-j", "list", "table", "inet", "claude_guard"])
    )
    rules, counters, chains = [], [], []
    for item in data["nftables"]:
        if "chain" in item:
            chain = item["chain"]
            chains.append(
                {
                    key: chain.get(key)
                    for key in ("name", "type", "hook", "prio", "policy")
                }
            )
        if "rule" in item:
            rule = item["rule"]
            if rule["chain"] != "output":
                raise ValueError("unexpected chain")
            rules.append([expr for expr in rule["expr"] if "counter" not in expr])
            cs = [expr["counter"] for expr in rule["expr"] if "counter" in expr]
            if len(cs) != 1:
                raise ValueError("missing counter")
            counters.append(cs[0])
    expected_chain = [
        {
            "name": "output",
            "type": "filter",
            "hook": "output",
            "prio": -300,
            "policy": "drop",
        }
    ]
    addresses = json.loads(
        command(["/usr/sbin/ip", "-j", "-4", "addr", "show", "dev", "eth0"])
    )
    local = [
        a["local"]
        for link in addresses
        for a in link["addr_info"]
        if a["scope"] == "global"
    ]
    if len(local) != 1:
        raise ValueError("ambiguous eth0 address")
    services = {}
    for unit in ("claude-guard.service", "wg-quick@wg-claude.service"):
        output = command(
            [
                "/usr/bin/systemctl",
                "show",
                unit,
                "--property=ActiveState,ActiveEnterTimestampMonotonic",
            ]
        )
        services[unit] = dict(
            line.split("=", 1) for line in output.splitlines() if "=" in line
        )
    fwmark = command(["/usr/bin/wg", "show", "wg-claude", "fwmark"]).strip()
    handshake = command(["/usr/bin/wg", "show", "wg-claude", "latest-handshakes"])
    epochs = [int(line.split()[1]) for line in handshake.splitlines()]
    return {
        "policy_ok": chains == expected_chain and rules == expected_rules(),
        "policy_digest": hashlib.sha256(
            json.dumps([chains, rules], sort_keys=True).encode()
        ).hexdigest(),
        "counters": counters,
        "eth0_ipv4": local[0],
        "fwmark": fwmark,
        "services": services,
        "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "handshake_age_seconds": int(time.time()) - max(epochs),
    }


def ordinary_user():
    if os.getuid() != 1000:
        raise ValueError("network probes require UID 1000")


def resolve():
    ordinary_user()
    targets = []
    for label, hostname, port in SERVERS:
        try:
            output = command(["/usr/bin/getent", "ahostsv4", hostname])
            addresses = sorted(
                {
                    str(ipaddress.IPv4Address(line.split()[0]))
                    for line in output.splitlines()
                }
            )
            addresses = [
                a
                for a in addresses
                if ipaddress.IPv4Address(a).is_global and a != EXPECTED_EXIT
            ]
            if not addresses:
                raise ValueError("no global IPv4")
            targets.append(
                {
                    "label": label,
                    "hostname": hostname,
                    "ipv4": addresses[0],
                    "port": port,
                    "status": "resolved",
                }
            )
        except (ValueError, OSError, subprocess.SubprocessError) as exc:
            targets.append(
                {
                    "label": label,
                    "hostname": hostname,
                    "port": port,
                    "status": "resolution-blocked",
                    "error_type": type(exc).__name__,
                }
            )
    return {"uid": os.getuid(), "targets": targets}


def parse_binding(data, transaction):
    if len(data) < 20:
        raise ValueError("short header")
    kind, length, cookie = struct.unpack("!HHI", data[:8])
    if (
        kind != 0x0101
        or cookie != COOKIE
        or data[8:20] != transaction
        or length % 4
        or len(data) != 20 + length
    ):
        raise ValueError("invalid response header")
    found = {}
    offset = 20
    while offset < len(data):
        if offset + 4 > len(data):
            raise ValueError("short attribute")
        attr, size = struct.unpack("!HH", data[offset : offset + 4])
        offset += 4
        end = offset + size
        padded = offset + ((size + 3) & ~3)
        if end > len(data) or padded > len(data):
            raise ValueError("truncated attribute")
        value = data[offset:end]
        offset = padded
        if attr not in (0x0001, 0x0020):
            continue
        if size != 8 or value[0] != 0 or value[1] != 1 or attr in found:
            raise ValueError("invalid IPv4 mapping")
        port = struct.unpack("!H", value[2:4])[0]
        number = struct.unpack("!I", value[4:8])[0]
        if attr == 0x0020:
            port ^= COOKIE >> 16
            number ^= COOKIE
        if not port:
            raise ValueError("zero mapped port")
        found[attr] = str(ipaddress.IPv4Address(number))
    if not found:
        raise ValueError("no IPv4 mapping")
    if len(set(found.values())) != 1:
        raise ValueError("conflicting mappings")
    return found.get(0x0020, found.get(0x0001))


def mapping_record(address):
    return {
        "mapped_expected": address == EXPECTED_EXIT,
        "mapped_ipv4": address
        if address == EXPECTED_EXIT
        else "<unexpected-address-redacted>",
    }


def probe(ipv4, port, mode, local):
    ordinary_user()
    address = ipaddress.IPv4Address(ipv4)
    if (
        not address.is_global
        or ipv4 == EXPECTED_EXIT
        or port not in (19302, 3478)
        or mode not in MODES
    ):
        raise ValueError("invalid target or mode")
    if not ipaddress.IPv4Address(local).is_private:
        raise ValueError("invalid guest address")
    result = {
        "uid": os.getuid(),
        "mode": mode,
        "target_ipv4": ipv4,
        "port": port,
        "datagrams_sent": 0,
        "invalid_responses": 0,
        "device_bound": False,
        "source_bound": False,
    }
    started = time.monotonic()
    stage = "setup"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            if mode in ("device", "device-source"):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"eth0\0")
                result["device_bound"] = True
                if (
                    sock.getsockopt(
                        socket.SOL_SOCKET, socket.SO_BINDTODEVICE, 16
                    ).rstrip(b"\0")
                    != b"eth0"
                ):
                    raise ValueError("binding not retained")
            if mode in ("source", "device-source"):
                sock.bind((local, 0))
                result["source_bound"] = True
            transaction = secrets.token_bytes(12)
            packet = struct.pack("!HHI", 0x0001, 0, COOKIE) + transaction
            stage = "connect"
            sock.connect((ipv4, port))
            result["socket_local_ipv4"] = sock.getsockname()[0]
            stage = "send"
            if sock.send(packet) != len(packet):
                raise ValueError("short send")
            result["datagrams_sent"] = 1
            stage = "receive"
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                sock.settimeout(max(0.001, deadline - time.monotonic()))
                data = sock.recv(2048)
                try:
                    mapped = parse_binding(data, transaction)
                except ValueError:
                    result["invalid_responses"] += 1
                    if result["invalid_responses"] >= 8:
                        result["status"] = "invalid-response-limit"
                        break
                    continue
                result.update(mapping_record(mapped))
                result["status"] = "binding-response"
                break
            else:
                result["status"] = "timeout"
    except TimeoutError:
        result["status"] = "timeout"
    except (OSError, ValueError) as exc:
        result.update(
            status="socket-error",
            stage=stage,
            error_type=type(exc).__name__,
            errno=getattr(exc, "errno", None),
        )
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("metadata", "resolve", "probe"))
    parser.add_argument("--ipv4")
    parser.add_argument("--port", type=int)
    parser.add_argument("--mode", choices=MODES)
    parser.add_argument("--local")
    args = parser.parse_args()
    try:
        if args.action == "metadata":
            record = metadata()
        elif args.action == "resolve":
            record = resolve()
        else:
            record = probe(args.ipv4, args.port, args.mode, args.local)
        print(json.dumps(record, separators=(",", ":")))
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        KeyError,
        TypeError,
    ) as exc:
        print(
            json.dumps({"status": "helper-blocked", "error_type": type(exc).__name__})
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
