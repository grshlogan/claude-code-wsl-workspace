#!/usr/bin/env python3
"""One-way VPS peer cutover (run manually after review). Accept ONLY a public key on stdin.

Run over a fingerprint-pinned SSH connection. Never copy this script's root-only
VPS backup to Windows, Git or a package. It does not install the VPS package.
"""
import base64
import datetime
import ipaddress
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

CONF = pathlib.Path('/etc/wireguard/wg-claude.conf')
BACKUP_BASE = pathlib.Path('/root/claude-peer-cutover-backups')
INTERFACE = 'wg-claude'
ALLOWED = '10.77.42.2/32'


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    require(os.geteuid() == 0, 'requires root')
    new_key = sys.stdin.readline().strip()
    require(sys.stdin.read().strip() == '', 'expected exactly one public-key line')
    try:
        raw = base64.b64decode(new_key, validate=True)
    except ValueError as exc:
        raise RuntimeError('invalid public key encoding') from exc
    require(len(raw) == 32 and len(new_key) == 44, 'invalid WireGuard public key length')
    require(CONF.is_file() and not CONF.is_symlink(), 'config missing or symlinked')
    require(CONF.stat().st_mode & 0o777 == 0o600, 'config must be root-only mode 0600')
    require(run('systemctl', 'is-active', 'wg-quick@wg-claude.service') == 'active', 'WireGuard service is not active')
    require(run('systemctl', 'is-active', 'wg-claude-forward.service') == 'active', 'forwarding service is not active')
    require(run('wg', 'show', INTERFACE, 'listen-port') == '51820', 'unexpected listen port')
    require(run('sysctl', '-n', 'net.ipv4.ip_forward') == '1', 'IPv4 forwarding is off')
    require('default ' in run('ip', '-4', 'route', 'show', 'default'), 'default route missing')
    require(run('ss', '-H', '-ltn', 'sport', '=', ':22') != '', 'SSH 22 not listening')
    run('nft', 'list', 'table', 'inet', 'wg_claude_forward')
    run('nft', 'list', 'table', 'ip', 'wg_claude_nat')
    allowed = run('wg', 'show', INTERFACE, 'allowed-ips').splitlines()
    require(len(allowed) == 1 and len(allowed[0].split()) == 2 and allowed[0].split()[1] == ALLOWED,
            'expected exactly one live protected peer')
    old_key = allowed[0].split()[0]
    require(new_key != old_key, 'new peer is already active')
    original = CONF.read_text()
    require(len(re.findall(r'^\[Peer\]\s*$', original, re.M)) == 1, 'expected exactly one config peer')
    keys = re.findall(r'^(PublicKey\s*=\s*)(\S+)(\s*)$', original, re.M)
    ips = re.findall(r'^AllowedIPs\s*=\s*([^#\r\n]+)', original, re.M)
    require(len(keys) == 1 and keys[0][1] == old_key, 'config peer differs from live peer')
    require(len(ips) == 1 and ips[0].strip() == ALLOWED, 'unexpected config AllowedIPs')
    require(len(re.findall(r'^ListenPort\s*=\s*51820\s*$', original, re.M)) == 1,
            'unexpected config listen port')
    # Do not print the config, key values, or hashes of private materials.
    candidate = re.sub(r'^(PublicKey\s*=\s*)\S+(\s*)$',
                       lambda match: match.group(1) + new_key + match.group(2),
                       original, count=1, flags=re.M)
    require(candidate != original, 'candidate not changed')
    BACKUP_BASE.mkdir(mode=0o700, exist_ok=True)
    os.chmod(BACKUP_BASE, 0o700)
    backup_dir = BACKUP_BASE / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + os.urandom(4).hex())
    backup_dir.mkdir(mode=0o700)
    backup = backup_dir / 'wg-claude.conf'
    shutil.copy2(CONF, backup)
    os.chmod(backup, 0o600)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=CONF.parent,
                                         prefix='.wg-claude-cutover-', delete=False) as output:
            temporary = pathlib.Path(output.name)
            os.chmod(temporary, 0o600)
            output.write(candidate)
            output.flush()
            os.fsync(output.fileno())
        require(CONF.read_text() == original, 'config changed concurrently before cutover')
        os.replace(temporary, CONF)
        temporary = None
        # Brief fail-closed interruption: remove old peer before adding new.
        subprocess.run(['wg', 'set', INTERFACE, 'peer', old_key, 'remove'], check=True)
        subprocess.run(['wg', 'set', INTERFACE, 'peer', new_key, 'allowed-ips', ALLOWED], check=True)
        peers = run('wg', 'show', INTERFACE, 'allowed-ips').splitlines()
        require(peers == [new_key + '\t' + ALLOWED] or
                (len(peers) == 1 and peers[0].split() == [new_key, ALLOWED]),
                'new live peer state differs')
        require(CONF.read_text() == candidate, 'persistent config differs after cutover')
        print('ONE_WAY_PEER_CUTOVER_OK; only the new /32 peer is live; root-only backup remains on VPS')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('ONE_WAY_PEER_CUTOVER_FAILED: ' + str(exc), file=sys.stderr)
        sys.exit(1)
