#!/bin/sh
# Write the real VPS endpoint and server public key into the client package
# templates. Run BEFORE building the .deb.
#
# Usage:   ./configure-endpoint.sh <VPS_IPV4> <SERVER_PUBLIC_KEY>
# Example: ./configure-endpoint.sh 203.0.113.10 "AbCd...x8="
#
# The repository ships templates with the RFC 5737 documentation IP
# 203.0.113.10 and an all-zero placeholder key. This script replaces them.
# The UDP port stays 51820: it is pinned by both the client and server
# packages and is not configurable here.
#
# Idempotent: safe to re-run with a corrected endpoint.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pkg="$here/package"

fail() { printf 'configure-endpoint: ERROR: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 2 ] || fail "usage: $0 <VPS_IPV4> <SERVER_PUBLIC_KEY>"
[ -d "$pkg/DEBIAN" ] || fail "package directory not found next to this script"

ip=$1
key=$2

# Validate IPv4 (four dot-separated octets 0-255).
printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    || fail "not an IPv4 address: $ip"
printf '%s' "$ip" | awk -F. '{ for (i = 1; i <= 4; i++) if ($i > 255 || $i !~ /^[0-9]+$/) exit 1 }' \
    || fail "invalid IPv4 octets: $ip"
[ "$ip" != "203.0.113.10" ] || fail "refusing to configure the documentation IP"

# Validate the server public key: 44 base64 chars decoding to 32 bytes.
printf '%s' "$key" | grep -Eq '^[A-Za-z0-9+/]{43}=$' \
    || fail "server public key must be 44 base64 characters ending with '='"
printf '%s' "$key" | base64 -d 2>/dev/null | wc -c | grep -qx 32 \
    || fail "server public key does not decode to 32 bytes"

conf="$pkg/usr/lib/claude-wg-client/wg-claude.conf"
nft="$pkg/usr/lib/claude-wg-client/claude-guard.nft"
cli="$pkg/usr/sbin/claude-wg-client"

for f in "$conf" "$nft" "$cli"; do
    [ -f "$f" ] || fail "missing package file: $f"
done

# Replace any previously configured endpoint/key (or the shipped placeholders).
sed -i -E "s|^Endpoint = [0-9.]+:51820$|Endpoint = ${ip}:51820|" "$conf"
sed -i -E "s|^PublicKey = [A-Za-z0-9+/]+=|PublicKey = ${key}|" "$conf"
sed -i -E "s|ip daddr [0-9.]+ udp dport 51820|ip daddr ${ip} udp dport 51820|" "$nft"
sed -i -E "s|ip daddr [0-9.]+ udp dport 51820|ip daddr ${ip} udp dport 51820|" "$cli"

# Verify the result so a typo cannot slip through.
grep -Fq "Endpoint = ${ip}:51820" "$conf" || fail "endpoint replacement failed in wg-claude.conf"
grep -Fq "PublicKey = ${key}" "$conf" || fail "key replacement failed in wg-claude.conf"
grep -Fq "ip daddr ${ip} udp dport 51820" "$nft" || fail "endpoint replacement failed in claude-guard.nft"
grep -Fq "ip daddr ${ip} udp dport 51820" "$cli" || fail "endpoint replacement failed in claude-wg-client"
! grep -Rq '203\.0\.113\.10' "$pkg" || fail "documentation IP still present in package; inspect manually"
! grep -q 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$conf" \
    || fail "placeholder key still present; inspect manually"

printf 'configure-endpoint: OK — endpoint %s:51820 written into package templates\n' "$ip"
printf 'configure-endpoint: next: dpkg-deb --build package && dpkg -i <built.deb>\n'
