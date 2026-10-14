#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]]
AUDIT=/root/claude-toolchain-audit
restore_needed=0
trap 'status=$?; if [[ $restore_needed == 1 ]]; then systemctl start wg-quick@wg-claude; fi; exit "$status"' EXIT
exec > >(tee "$AUDIT/network-acceptance.txt") 2>&1
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
sha256sum --check --status "$AUDIT/protected-before.sha256"
EXPECTED=203.0.113.10
EXIT_IP=$(curl --noproxy '*' -4 -fsS --connect-timeout 10 --max-time 25 https://api.ipify.org)
[[ $EXIT_IP == "$EXPECTED" ]]
printf 'VPS_EXIT_BEFORE_OK: %s\n' "$EXIT_IP"
curl --noproxy '*' -4 -fsS --connect-timeout 5 --max-time 15 \
    https://1.1.1.1/cdn-cgi/trace > "$AUDIT/tunneled-trace.txt"
getent ahostsv4 nodejs.org > "$AUDIT/dns-test.txt"
printf 'TUNNELED_HTTPS_DNS_OK\n'
expect_block() {
    local label=$1 status
    shift
    if "$@" > "$AUDIT/$label.stdout" 2> "$AUDIT/$label.stderr"; then
        printf 'UNEXPECTED_NETWORK_SUCCESS: %s\n' "$label" >&2
        return 1
    else
        status=$?
    fi
    [[ $status == 7 || $status == 28 ]]
    printf '%s: BLOCKED (curl exit %s)\n' "$label" "$status"
}
expect_block DIRECT_ETH0 curl --noproxy '*' --interface eth0 -4 -fsS \
    --connect-timeout 5 --max-time 6 https://1.1.1.1/cdn-cgi/trace
expect_block EXTERNAL_IPV6 curl --noproxy '*' -g -6 -fsS \
    --connect-timeout 5 --max-time 6 'https://[2606:4700:4700::1111]/cdn-cgi/trace'
restore_needed=1
systemctl stop wg-quick@wg-claude
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard
expect_block TUNNEL_DOWN_DEFAULT curl --noproxy '*' -4 -fsS \
    --connect-timeout 5 --max-time 6 https://1.1.1.1/cdn-cgi/trace
expect_block TUNNEL_DOWN_ETH0 curl --noproxy '*' --interface eth0 -4 -fsS \
    --connect-timeout 5 --max-time 6 https://1.1.1.1/cdn-cgi/trace
/usr/bin/python3 - <<'PY'
import socket
import threading

for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
    with socket.socket(family, socket.SOCK_STREAM) as server:
        server.settimeout(3)
        server.bind((address, 0))
        server.listen(1)
        received = []
        def receive():
            with server.accept()[0] as connection:
                connection.settimeout(3)
                received.append(connection.recv(4))
        worker = threading.Thread(target=receive, daemon=True)
        worker.start()
        with socket.socket(family, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect((address, server.getsockname()[1]))
            client.sendall(b"test")
        worker.join(timeout=4)
        assert received == [b"test"], address
        print(f"TUNNEL_DOWN_LOOPBACK_OK: {address}", flush=True)
PY
systemctl start wg-quick@wg-claude
for attempt in {1..6}; do
    if EXIT_IP=$(curl --noproxy '*' -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org); then
        break
    fi
    sleep 2
done
[[ $EXIT_IP == "$EXPECTED" ]]
restore_needed=0
printf 'VPS_EXIT_RECOVERED_OK: %s\n' "$EXIT_IP"
/usr/sbin/claude-wg-client check-guard
systemctl is-active --quiet claude-guard wg-quick@wg-claude
sha256sum --check --status "$AUDIT/protected-before.sha256"
wg show wg-claude latest-handshakes | awk '{print "HANDSHAKE_AGE_SECONDS:", systime() - $2}'
printf 'NETWORK_ACCEPTANCE_OK\n'
