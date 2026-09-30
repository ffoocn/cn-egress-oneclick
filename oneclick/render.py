"""Render isolated WireGuard/WSS nodes; prepare verified software and private PKI.

This module does not connect to nodes or change a running deployment. Payload
contents are Base64 encoded for the remote installer, never suitable for logs.
"""
from __future__ import annotations

import base64
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tarfile
import urllib.request
import warnings

VERSION = "11.0.0"
AMD64_ARCHIVE_SHA256 = "9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e"
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
_DOMAIN = re.compile(r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\Z")


def _host(value: str) -> str:
    if not isinstance(value, str) or value != value.strip():
        raise ValueError("Node host must be an IPv4 address or DNS hostname")
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        if not _DOMAIN.fullmatch(value) or re.fullmatch(r"[0-9.]+", value):
            raise ValueError("Invalid DNS hostname") from None
        return value.lower()
    if address.version != 4:
        raise ValueError("This version supports IPv4 or DNS transport hosts")
    return str(address)


def _port(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535:
        raise ValueError("Port must be an integer from 1 to 65535")
    return value


def _key(value: str) -> str:
    try:
        raw = base64.b64decode(value, validate=True)
    except (TypeError, ValueError):
        raise ValueError("Invalid WireGuard key material") from None
    if len(raw) != 32:
        raise ValueError("WireGuard keys must encode exactly 32 bytes")
    if base64.b64encode(raw).decode() != value:
        raise ValueError("WireGuard key material must use canonical Base64")
    return value


def _client_address(value: int | str) -> tuple[int, str]:
    if isinstance(value, bool):
        raise ValueError("Invalid client address")
    if isinstance(value, int) or (isinstance(value, str) and value.isdecimal()):
        number = int(value)
    elif isinstance(value, str):
        fields = [part.strip() for part in value.split(",")]
        if not 1 <= len(fields) <= 2:
            raise ValueError("Invalid client address")
        try:
            ipv4 = ipaddress.IPv4Interface(fields[0])
        except ValueError:
            raise ValueError("Invalid client IPv4 address") from None
        if ipv4.ip not in ipaddress.IPv4Network("10.77.10.0/24") or ipv4.network.prefixlen != 32:
            raise ValueError("Client IPv4 address must be in 10.77.10.0/24 with /32")
        number = int(str(ipv4.ip).rsplit(".", 1)[1])
        if len(fields) == 2:
            try:
                ipv6 = ipaddress.IPv6Interface(fields[1])
            except ValueError:
                raise ValueError("Invalid client IPv6 address") from None
            expected = ipaddress.IPv6Interface(f"fd77:77:10::{number}/128")
            if ipv6 != expected:
                raise ValueError("Client IPv6 address does not match the assigned address")
    else:
        raise ValueError("Invalid client address")
    if not 2 <= number <= 254:
        raise ValueError("Client addresses must be from 2 to 254")
    return number, f"10.77.10.{number}/32, fd77:77:10::{number}/128"


def client_profile(name: str, address: int | str, private: str, server_public: str,
                   psk: str, hk_host: str, user_port: int = 51820) -> str:
    """Return an ordinary WireGuard profile; server-to-server WSS is transparent."""
    if not _NAME.fullmatch(name):
        raise ValueError("Invalid client name")
    number, addresses = _client_address(address)
    if number > 249 and not (name == "us_test" and number == 250):
        raise ValueError("New client addresses must be from 2 to 249")
    return (
        f"[Interface]\nPrivateKey = {_key(private)}\nAddress = {addresses}\n"
        "DNS = 10.77.30.2\nMTU = 1380\n\n[Peer]\n"
        f"PublicKey = {_key(server_public)}\nPresharedKey = {_key(psk)}\n"
        "AllowedIPs = 0.0.0.0/0, ::/0\n"
        f"Endpoint = {_host(hk_host)}:{_port(user_port)}\nPersistentKeepalive = 25\n"
    )


def _clients(keys: dict) -> list[dict]:
    if "clients" in keys:
        if not isinstance(keys["clients"], dict):
            raise ValueError("clients must be a mapping of names to client records")
        entries = [{**record, "name": name} for name, record in keys["clients"].items()]
    else:
        entries = [
            {"name": name, "address": address, "public": keys[name]["public"],
             "psk": keys["psks"][name]}
            for name, address in (("iphone", 10), ("android", 20), ("windows", 30), ("us_test", 250))
            if name in keys
        ]
    occupied = set()
    public_keys = set()
    server_public = _key(keys["hk_users"]["public"])
    for record in entries:
        if not _NAME.fullmatch(record["name"]):
            raise ValueError("Invalid client name")
        number, _ = _client_address(record["address"])
        if number > 249 and not (record["name"] == "us_test" and number == 250):
            raise ValueError("New client addresses must be from 2 to 249")
        if number in occupied:
            raise ValueError("Client addresses must be unique")
        occupied.add(number)
        record["number"] = number
        public = _key(record["public"])
        if public in public_keys or public == server_public:
            raise ValueError("Each client must have a unique public key, separate from the server")
        public_keys.add(public)
        _key(record["psk"])
    return sorted(entries, key=lambda record: record["number"])


def _interface(keys: dict, name: str, addresses: str, port: int | None = None) -> str:
    value = (f"[Interface]\nPrivateKey = {_key(keys[name]['private'])}\n"
             f"Address = {addresses}\nMTU = 1380\nTable = off\n")
    if port is not None:
        value += f"ListenPort = {_port(port)}\n"
    return value


def _peer(public: str, psk: str, allowed: str, endpoint: str | None = None) -> str:
    value = f"\n[Peer]\nPublicKey = {_key(public)}\nPresharedKey = {_key(psk)}\nAllowedIPs = {allowed}\n"
    if endpoint is not None:
        value += f"Endpoint = {endpoint}\nPersistentKeepalive = 25\n"
    return value


def _relay_firewall(incoming: str, outgoing: str) -> str:
    return f'''table inet cn_egress {{
  chain input_guard {{
    type filter hook input priority -5; policy accept;
    iifname {{ "{incoming}", "{outgoing}" }} meta l4proto {{ icmp, ipv6-icmp }} accept
    iifname {{ "{incoming}", "{outgoing}" }} counter drop
  }}
  chain forward_guard {{
    type filter hook forward priority -5; policy accept;
    iifname "{incoming}" meta nfproto ipv4 ip saddr != 10.77.10.0/24 counter drop
    iifname "{incoming}" meta nfproto ipv6 ip6 saddr != fd77:77:10::/64 counter drop
    iifname "{incoming}" oifname "{outgoing}" counter accept
    iifname "{outgoing}" oifname "{incoming}" ct state established,related counter accept
    iifname {{ "{incoming}", "{outgoing}" }} counter drop
    oifname {{ "{incoming}", "{outgoing}" }} counter drop
  }}
}}
'''


_EXIT_FIREWALL = '''table inet cn_egress {
  chain input_guard {
    type filter hook input priority -5; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 udp dport 5354 counter accept
    iifname "cne-exit" ip saddr 10.77.10.0/24 tcp dport 5354 counter accept
    iifname "cne-exit" meta l4proto { icmp, ipv6-icmp } accept
    iifname "cne-exit" counter drop
  }
  chain forward_guard {
    type filter hook forward priority -5; policy accept;
    iifname "cne-exit" meta nfproto ipv6 counter reject with icmpv6 type admin-prohibited
    iifname "cne-exit" ip saddr != 10.77.10.0/24 counter drop
    iifname "cne-exit" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } counter reject with icmp type admin-prohibited
    iifname "cne-exit" oifname "__WAN__" counter accept
    oifname "cne-exit" ct state established,related counter accept
    iifname "cne-exit" counter drop
    oifname "cne-exit" counter drop
  }
  chain nat_out {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 oifname "__WAN__" counter masquerade
  }
  chain dns_redirect {
    type nat hook prerouting priority dstnat - 5; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 ip daddr 10.77.30.2 udp dport 53 counter redirect to :5354
    iifname "cne-exit" ip saddr 10.77.10.0/24 ip daddr 10.77.30.2 tcp dport 53 counter redirect to :5354
  }
}
'''

_DNS_CONFIG = '''interface=cne-exit
listen-address=10.77.30.2
bind-dynamic
port=5354
cache-size=1000
domain-needed
bogus-priv
filter-AAAA
user=nobody
group=nogroup
pid-file=
'''

_DNS_SERVICE = '''[Unit]
Description=DNS for domestic egress VPN clients
Requires=cn-egress.service
After=cn-egress.service
PartOf=cn-egress.service

[Service]
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/cn-egress/dnsmasq.conf
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
'''

_WRAPPER = '''#!/usr/bin/python3
"""Authenticated WSS transport; never changes host routes."""
import ipaddress
import os
from pathlib import Path
import re

config = Path('/etc/cn-egress-wss')
role = (config / 'role').read_text().strip()
if role not in ('hk', 'sh', 'exit'):
    raise SystemExit('Invalid transport role')
host = (config / 'sh-host').read_text().strip()
try:
    if ipaddress.ip_address(host).version != 4:
        raise ValueError()
except ValueError:
    if not re.fullmatch(r'(?=.{1,253}\\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', host) or re.fullmatch(r'[0-9.]+', host):
        raise SystemExit('Invalid server host')
port = int((config / 'port').read_text().strip())
if not 1 <= port <= 65535:
    raise SystemExit('Invalid WSS port')
binary = '/opt/cn-egress/wstunnel-11.0.0/wstunnel'
args = [binary, 'server' if role == 'sh' else 'client',
        '--no-color', '--log-lvl', 'INFO', '--nb-worker-threads', '2',
        '--tls-certificate', str(config / 'node.crt'),
        '--tls-private-key', str(config / 'node.key')]
if role == 'sh':
    args += ['--tls-client-ca-certs', str(config / 'ca.crt'),
             '--restrict-config', str(config / 'restrictions.yaml'),
             f'wss://0.0.0.0:{port}']
else:
    os.environ['SSL_CERT_FILE'] = str(config / 'ca.crt')
    os.environ['SSL_CERT_DIR'] = str(config / 'empty-ca')
    local_port, remote_port = (51831, 51821) if role == 'hk' else (51832, 51822)
    args += ['--tls-verify-certificate', '-L',
             f'udp://127.0.0.1:{local_port}:127.0.0.1:{remote_port}?timeout_sec=0',
             f'wss://{host}:{port}']
for variable in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
                 'http_proxy', 'https_proxy', 'all_proxy'):
    os.environ.pop(variable, None)
os.execv(binary, args)
'''

_WSS_GUARD = '''table inet cne_wss_input {
  chain input_guard {
    type filter hook input priority -10; policy accept;
    iifname != "lo" udp dport { 51821, 51822 } counter drop
  }
}
'''


def _service(role: str) -> str:
    after = "network-online.target docker.service" if role == "exit" else "network-online.target"
    return f'''[Unit]
Description=Domestic egress VPN ({role})
Wants=network-online.target
After={after}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cn-egress-net start {role}
ExecStop=/usr/local/sbin/cn-egress-net stop {role}
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
'''


def _obfs_service(role: str) -> str:
    capabilities = ("AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n"
                    if role == "sh" else "CapabilityBoundingSet=\n")
    return '''[Unit]
Description=Authenticated WSS transport for domestic egress
Wants=network-online.target
After=network-online.target
PartOf=cn-egress.service

[Service]
Type=simple
User=cn-egress-wss
Group=cn-egress-wss
ExecStart=/usr/local/sbin/cn-egress-obfs
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
''' + capabilities + '''
[Install]
WantedBy=multi-user.target
'''


def make_plan(topology: dict, key_material: dict, tls_material: dict,
              assets_dir: Path, binary: bytes) -> dict:
    """Return role -> absolute path -> {content: Base64, mode: int, sha256: str}.

    Exactly one mainland node uses the logical role ``sh``, regardless of city.
    ``key_material.clients`` may override legacy named clients; each record has
    ``address`` (2..249), ``public`` and ``psk``. Private client keys stay local.
    The historical us_test peer at 250 is accepted only by that reserved name.
    The installer must create cn-egress-wss, root:cn-egress-wss config ownership,
    /etc/cn-egress-wss mode 0750 and its empty-ca directory mode 0750.
    """
    if topology.get("transport", "wss") != "wss":
        raise ValueError("Only authenticated WSS transport is supported")
    if "bj" in topology or "beijing" in topology:
        raise ValueError("Use exactly one mainland node in the sh role")
    hk_host = _host(topology["hk"]["host"])
    sh_host = _host(topology["sh"]["host"])
    _host(topology["exit"]["host"])
    wan = topology["exit"]["wan"]
    if not isinstance(wan, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", wan):
        raise ValueError("Invalid exit WAN interface")
    user_port = _port(topology.get("user_port", 51820))
    wss_port = _port(topology.get("wss_port", 443))
    if not isinstance(binary, bytes) or not binary:
        raise ValueError("Verified wstunnel binary is required")
    # Read only the deployed namespace manager and policy; importing the legacy
    # builder would execute its argv-driven secret payload generation.
    assets_dir = Path(assets_dir)
    manager = (assets_dir / "cn-egress-net.sh").read_bytes()
    restrictions = (assets_dir / "cn-egress-wss-restrictions.yaml").read_bytes()
    keys = key_material
    clients = _clients(keys)
    node_public_keys = [_key(keys[name]["public"]) for name in ("hk_users", "hk_cn", "sh_cn", "sh_exit", "exit")]
    if len(set(node_public_keys)) != len(node_public_keys):
        raise ValueError("Each server interface must have its own WireGuard key pair")
    used_psks = [_key(keys["psks"][name]) for name in ("hk_sh", "sh_exit")]
    used_psks += [record["psk"] for record in clients]
    if len(set(used_psks)) != len(used_psks):
        raise ValueError("Each WireGuard peer link must have its own preshared key")
    users = _interface(keys, "hk_users", "10.77.10.1/24, fd77:77:10::1/64", user_port)
    for record in clients:
        number = record["number"]
        users += _peer(record["public"], record["psk"],
                       f"10.77.10.{number}/32, fd77:77:10::{number}/128")
    hk_cn = _interface(keys, "hk_cn", "10.77.20.1/30, fd77:77:20::1/64")
    hk_cn += _peer(keys["sh_cn"]["public"], keys["psks"]["hk_sh"], "0.0.0.0/0, ::/0", "127.0.0.1:51831")
    sh_cn = _interface(keys, "sh_cn", "10.77.20.2/30, fd77:77:20::2/64", 51821)
    sh_cn += _peer(keys["hk_cn"]["public"], keys["psks"]["hk_sh"],
                   "10.77.20.1/32, fd77:77:20::1/128, 10.77.10.0/24, fd77:77:10::/64")
    sh_exit = _interface(keys, "sh_exit", "10.77.30.1/30, fd77:77:30::1/64", 51822)
    sh_exit += _peer(keys["exit"]["public"], keys["psks"]["sh_exit"], "0.0.0.0/0, ::/0")
    exit_wg = _interface(keys, "exit", "10.77.30.2/30, fd77:77:30::2/64")
    exit_wg += _peer(keys["sh_exit"]["public"], keys["psks"]["sh_exit"],
                     "10.77.30.1/32, fd77:77:30::1/128, 10.77.10.0/24, fd77:77:10::/64", "127.0.0.1:51832")
    role_configs = {"hk": {"cne-users": users, "cne-cn": hk_cn},
                    "sh": {"cne-cn": sh_cn, "cne-exit": sh_exit},
                    "exit": {"cne-exit": exit_wg}}
    plan = {}
    for role in ("hk", "sh", "exit"):
        files = {}

        def add(path: str, content: str | bytes, mode: int) -> None:
            value = content.encode() if isinstance(content, str) else content
            files[path] = {"content": base64.b64encode(value).decode(), "mode": mode,
                           "sha256": hashlib.sha256(value).hexdigest()}

        add("/usr/local/sbin/cn-egress-net", manager, 0o700)
        add("/usr/local/sbin/cn-egress-obfs", _WRAPPER, 0o755)
        add("/opt/cn-egress/wstunnel-11.0.0/wstunnel", binary, 0o755)
        add("/etc/systemd/system/cn-egress.service", _service(role), 0o644)
        add("/etc/systemd/system/cn-egress-obfs.service", _obfs_service(role), 0o644)
        add("/etc/systemd/system/cn-egress.service.d/obfs.conf",
            "[Unit]\nWants=cn-egress-obfs.service\nAfter=cn-egress-obfs.service\n", 0o644)
        for path, text in (("role", role + "\n"), ("sh-host", sh_host + "\n"), ("port", str(wss_port) + "\n"),
                           ("node.crt", tls_material[role]["cert"]), ("node.key", tls_material[role]["key"]),
                           ("ca.crt", tls_material["ca"])):
            add("/etc/cn-egress-wss/" + path, text, 0o640)
        for name, config in role_configs[role].items():
            add(f"/etc/wireguard/{name}.conf", config, 0o600)
        if role == "sh":
            add("/etc/cn-egress-wss/restrictions.yaml", restrictions, 0o640)
            add("/etc/cn-egress-wss/guard.nft", _WSS_GUARD, 0o600)
        if role == "exit":
            add("/etc/cn-egress/firewall.nft", _EXIT_FIREWALL.replace("__WAN__", wan), 0o600)
            add("/etc/cn-egress/wan-interface", wan + "\n", 0o600)
            add("/etc/cn-egress/dnsmasq.conf", _DNS_CONFIG, 0o600)
            add("/etc/systemd/system/cn-egress-dns.service", _DNS_SERVICE, 0o644)
        else:
            incoming, outgoing = (("cne-users", "cne-cn") if role == "hk" else ("cne-cn", "cne-exit"))
            add("/etc/cn-egress/firewall.nft", _relay_firewall(incoming, outgoing), 0o600)
        plan[role] = files
    return plan


def generate_pki(topology: dict, directory: Path) -> dict:
    """Generate a private CA and two-year mTLS certificates with openssl.

    Return {'ca': PEM, role: {'key': PEM, 'cert': PEM}}. The CA signing key stays
    only in ``directory/ca.key`` mode 0600, never in a node's rendered payload.
    Use a fresh private directory per rotation; existing keys are never replaced.
    """
    host = _host(topology["sh"]["host"])
    if shutil.which("openssl") is None:
        raise RuntimeError("openssl is required to generate deployment certificates")
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError("PKI directory must not be a symlink")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    for filename in ("ca.key", "ca.crt", "hk.key", "sh.key", "exit.key"):
        if (directory / filename).exists() or (directory / filename).is_symlink():
            raise FileExistsError("PKI directory already contains key material; choose a fresh directory")

    def run(*args: str) -> None:
        result = subprocess.run(["openssl", *args], capture_output=True, text=True)
        if result.returncode:
            # Errors contain paths/algorithms, never PEM values or passwords.
            raise RuntimeError("openssl certificate operation failed: " + result.stderr.strip())

    def private_key(path: Path) -> None:
        # Precreate under 0600 so openssl never briefly writes a world-readable key.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(path))
        os.chmod(path, 0o600)

    ca_key, ca_cert = directory / "ca.key", directory / "ca.crt"
    ca_config = directory / "ca.cnf"
    ca_config.write_text('''[req]
distinguished_name = subject
prompt = no
x509_extensions = ca
[subject]
CN = cn-egress-private-ca
[ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
''')
    private_key(ca_key)
    run("req", "-new", "-x509", "-sha256", "-days", "3650", "-key", str(ca_key),
        "-out", str(ca_cert), "-config", str(ca_config), "-extensions", "ca")
    result = {"ca": ca_cert.read_text()}
    scratch = [ca_config]
    try:
        for role in ("hk", "sh", "exit"):
            key, cert = directory / f"{role}.key", directory / f"{role}.crt"
            csr, extension = directory / f"{role}.csr", directory / f"{role}.cnf"
            scratch.extend((csr, extension))
            private_key(key)
            run("req", "-new", "-sha256", "-key", str(key), "-out", str(csr),
                "-subj", f"/CN=cn-egress-{role}")
            text = ("basicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature\n"
                    "subjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid,issuer\n"
                    f"extendedKeyUsage = {'serverAuth' if role == 'sh' else 'clientAuth'}\n")
            if role == "sh":
                try:
                    ipaddress.IPv4Address(host)
                    san = "IP:" + host
                except ValueError:
                    san = "DNS:" + host
                text += "subjectAltName = " + san + "\n"
            extension.write_text(text)
            run("x509", "-req", "-sha256", "-days", "730", "-in", str(csr),
                "-CA", str(ca_cert), "-CAkey", str(ca_key), "-set_serial", str(secrets.randbits(159) or 1),
                "-extfile", str(extension), "-out", str(cert))
            os.chmod(cert, 0o644)
            result[role] = {"key": key.read_text(), "cert": cert.read_text()}
    finally:
        for path in scratch:
            path.unlink(missing_ok=True)
    warnings.warn(f"Securely back up {directory} including ca.key (mode 0600); it is needed for certificate rotation. Never publish this directory.",
                  UserWarning, stacklevel=2)
    return result


def _download(url: str, maximum: int = 80 * 1024 * 1024) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "cn-egress-oneclick/1", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(maximum + 1)
    if len(data) > maximum:
        raise RuntimeError("wstunnel download exceeded the size limit")
    return data


def fetch_wstunnel(cache_dir: Path, arch: str = "amd64") -> bytes:
    """Return the ELF binary from official v11.0.0 after archive SHA256 checks.

    Completed downloads are reusable offline. The amd64 archive has an embedded
    known digest; arm64 obtains its digest from the pinned GitHub release API.
    No checksum failure falls back to unverified software or another version.
    """
    if arch not in ("amd64", "arm64"):
        raise ValueError("Supported wstunnel architectures: amd64, arm64")
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    name = f"wstunnel_{VERSION}_linux_{arch}.tar.gz"
    archive_path = cache_dir / name
    metadata_path = cache_dir / f"wstunnel-{VERSION}-release.json"
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text())
    else:
        metadata_bytes = _download(f"https://api.github.com/repos/erebe/wstunnel/releases/tags/v{VERSION}", 2 * 1024 * 1024)
        metadata = json.loads(metadata_bytes)
    if metadata.get("tag_name") != "v" + VERSION:
        raise RuntimeError("GitHub release metadata does not match the pinned version")
    asset = next((entry for entry in metadata.get("assets", []) if entry.get("name") == name), None)
    digest = asset.get("digest", "") if asset else ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise RuntimeError("Official release asset has no valid SHA256 digest")
    expected = digest.removeprefix("sha256:")
    if arch == "amd64" and expected != AMD64_ARCHIVE_SHA256:
        raise RuntimeError("GitHub digest differs from the pinned amd64 checksum")
    downloaded = not archive_path.exists()
    archive = (_download(f"https://github.com/erebe/wstunnel/releases/download/v{VERSION}/{name}")
               if downloaded else archive_path.read_bytes())
    if hashlib.sha256(archive).hexdigest() != expected:
        raise RuntimeError("wstunnel archive SHA256 mismatch; refusing installation")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
        members = [member for member in package.getmembers() if member.name in ("wstunnel", "./wstunnel")]
        if len(members) != 1 or not members[0].isfile() or members[0].size > 100 * 1024 * 1024:
            raise RuntimeError("Official archive has no unique regular wstunnel binary")
        stream = package.extractfile(members[0])
        if stream is None:
            raise RuntimeError("Cannot read wstunnel archive binary")
        binary = stream.read()
    if len(binary) < 20 or binary[:4] != b"\x7fELF" or binary[5] not in (1, 2):
        raise RuntimeError("Downloaded wstunnel is not an ELF binary")
    machine = int.from_bytes(binary[18:20], "little" if binary[5] == 1 else "big")
    if machine != {"amd64": 62, "arm64": 183}[arch]:
        raise RuntimeError("wstunnel binary architecture does not match the selected asset")
    # Persist only after both archive and executable have passed verification.
    if downloaded:
        temporary = archive_path.with_suffix(".tmp")
        temporary.write_bytes(archive)
        os.replace(temporary, archive_path)
    if not metadata_path.exists():
        temporary = metadata_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(metadata))
        os.replace(temporary, metadata_path)
    return binary
