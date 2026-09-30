#!/usr/bin/env python3
"""Private JSON RPC executor for the three cn-egress nodes (stdlib only).

This program is transported over SSH and runs as root.  It never evaluates a
request as shell text.  Only ``inspect`` exports existing private configuration,
so a controller must keep that response in private storage and out of logs.
"""
import base64
import binascii
import contextlib
import datetime
import fcntl
import grp
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path("/")  # Also permits isolated filesystem tests; never request-controlled.
ROLES = {"hk", "sh", "exit"}
NS = "cn-egress-relay"
MANIFEST = "/etc/cn-egress/oneclick-manifest.json"
CLIENTS = "/etc/cn-egress/oneclick-clients.json"
NODE = "/etc/cn-egress/oneclick-node.py"
ENTRY = "/usr/local/sbin/cn-egress"
BINARY = "/opt/cn-egress/wstunnel-11.0.0/wstunnel"
COMMON_FILES = {
    "/usr/local/sbin/cn-egress-net", "/usr/local/sbin/cn-egress-obfs", ENTRY, NODE,
    "/etc/systemd/system/cn-egress.service",
    "/etc/systemd/system/cn-egress-obfs.service",
    "/etc/systemd/system/cn-egress.service.d/obfs.conf",
    "/etc/cn-egress/firewall.nft", "/etc/cn-egress-wss/role",
    "/etc/cn-egress-wss/node.crt", "/etc/cn-egress-wss/node.key",
    "/etc/cn-egress-wss/ca.crt", "/etc/cn-egress-wss/sh-host",
    "/etc/cn-egress-wss/port", BINARY,
}
ROLE_FILES = {
    "hk": {"/etc/wireguard/cne-users.conf", "/etc/wireguard/cne-cn.conf"},
    "sh": {"/etc/wireguard/cne-cn.conf", "/etc/wireguard/cne-exit.conf",
           "/etc/cn-egress-wss/restrictions.yaml", "/etc/cn-egress-wss/guard.nft"},
    "exit": {"/etc/wireguard/cne-exit.conf", "/etc/cn-egress/wan-interface",
             "/etc/cn-egress/dnsmasq.conf",
             "/etc/systemd/system/cn-egress-dns.service",
             "/etc/sysctl.d/90-cn-egress.conf"},
}
PACKAGE_TOOLS = {"ip": "iproute2", "wg": "wireguard-tools",
                 "wg-quick": "wireguard-tools", "nft": "nftables",
                 "iptables": "iptables", "sysctl": "procps",
                 "ping": "iputils-ping", "dnsmasq": "dnsmasq-base"}
SNAPSHOTS = {
    "routes4": ["ip", "route", "show", "table", "all"],
    "routes6": ["ip", "-6", "route", "show", "table", "all"],
    "rules4": ["ip", "rule", "show"], "rules6": ["ip", "-6", "rule", "show"],
    "firewall": ["nft", "list", "ruleset"],
    "iptables": ["iptables-save"],
    "forwarding": ["sysctl", "net.ipv4.ip_forward", "net.ipv6.conf.all.forwarding"],
}
SECRET_LINE = re.compile(r"(?im)^.*(?:PrivateKey|PresharedKey|PRIVATE KEY|password\s*[=:]).*$")
WG_KEY = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/])")


class NodeError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def redact(text):
    """Operational logs never return WG keys, password lines or PEM bodies."""
    text = re.sub(r"(?s)-----BEGIN .*?PRIVATE KEY-----.*?-----END .*?PRIVATE KEY-----",
                  "[private key redacted]", str(text))
    return WG_KEY.sub("[key redacted]", SECRET_LINE.sub("[secret redacted]", text))


def run(args, *, check=False, input=None, timeout=30):
    try:
        result = subprocess.run(args, input=input, capture_output=True, text=True,
                                timeout=timeout, env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise NodeError("COMMAND_FAILED", f"{args[0]}: {type(exc).__name__}") from exc
    if check and result.returncode:
        detail = redact(result.stderr).strip()[-1200:]
        raise NodeError("COMMAND_FAILED", f"{args[0]} failed ({result.returncode}): {detail}")
    return result


def fs(path):
    if not isinstance(path, str) or not path.startswith("/") or "\x00" in path:
        raise NodeError("INVALID_PATH", "Only fixed absolute file paths are accepted")
    if str(Path(path)) != path or ".." in Path(path).parts:
        raise NodeError("INVALID_PATH", "Non-canonical path")
    return ROOT / path.lstrip("/")


def safe_path(path):
    """Reject symlinks at every existing level, including target files."""
    target = fs(path)
    for part in [target, *target.parents]:
        if part == ROOT.parent and ROOT != Path("/"):
            break
        if part.is_symlink():
            raise NodeError("UNSAFE_PATH", "Refusing to follow a symlink: " + path)
        if part == ROOT:
            break
    if target.exists() and not target.is_file():
        raise NodeError("UNSAFE_PATH", "Expected a regular file: " + path)
    return target


def read(path, default=""):
    target = safe_path(path)
    return target.read_text() if target.exists() else default


def atomic_write(path, data, mode=0o600):
    target = safe_path(path)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".cn-egress-", dir=target.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data if isinstance(data, bytes) else data.encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def json_read(path, default=None):
    body = read(path)
    try:
        return json.loads(body) if body else default
    except ValueError as exc:
        raise NodeError("INVALID_METADATA", "Invalid metadata file: " + path) from exc


def json_write(path, data):
    atomic_write(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def allowed_files(role):
    return COMMON_FILES | ROLE_FILES[role]


def os_info():
    values = {}
    # Debian's /etc/os-release normally points to this fixed read-only file.
    release = fs("/etc/os-release")
    body = read("/usr/lib/os-release") if release.is_symlink() else read("/etc/os-release")
    for line in body.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip('"')
    return {key: values.get(key, "") for key in ("ID", "ID_LIKE", "VERSION_ID", "PRETTY_NAME")}


def systemd_available():
    return bool(shutil.which("systemctl")) and fs("/run/systemd/system").is_dir()


def existing_role():
    role = read("/etc/cn-egress-wss/role").strip()
    if role:
        if role not in ROLES:
            raise NodeError("ROLE_MISMATCH", "Existing WSS role is invalid")
        return role
    body = read("/etc/systemd/system/cn-egress.service")
    found = re.search(r"(?m)^ExecStart=/usr/local/sbin/cn-egress-net start (hk|sh|exit)\s*$", body)
    if found:
        return found.group(1)
    configs = {name for name in ("cne-users", "cne-cn", "cne-exit")
               if safe_path(f"/etc/wireguard/{name}.conf").exists()}
    return ({frozenset({"cne-users", "cne-cn"}): "hk",
             frozenset({"cne-cn", "cne-exit"}): "sh",
             frozenset({"cne-exit"}): "exit"}.get(frozenset(configs)))


def deployment_exists():
    wireguard = fs("/etc/wireguard")
    if wireguard.exists() and any(wireguard.glob("cne-*.conf")):
        return True
    if any(fs(name).exists() for name in ("/etc/systemd/system/cn-egress.service",
                                          "/etc/systemd/system/cn-egress-obfs.service",
                                          "/etc/systemd/system/cn-egress-dns.service",
                                          "/etc/cn-egress-wss/role", MANIFEST)):
        return True
    if shutil.which("ip"):
        if NS in run(["ip", "netns", "list"]).stdout.split():
            return True
        for interface in ("cne-users", "cne-cn", "cne-exit"):
            if run(["ip", "link", "show", "dev", interface]).returncode == 0:
                return True
    return False


def require_role(role, *, managed=False):
    actual = existing_role()
    manifest = json_read(MANIFEST, {})
    if actual != role or (manifest and manifest.get("role") != role):
        raise NodeError("ROLE_MISMATCH", f"Requested {role}, existing role is {actual or 'unknown'}")
    if managed and not manifest:
        raise NodeError("NOT_MANAGED", "Adopt this existing deployment before managing it")
    if managed and manifest.get("machine_id") != read("/etc/machine-id").strip():
        raise NodeError("HOST_MISMATCH", "Management metadata belongs to a different machine")
    return manifest


def forwarding():
    result = {}
    for key, path in (("ipv4", "/proc/sys/net/ipv4/ip_forward"),
                      ("ipv6", "/proc/sys/net/ipv6/conf/all/forwarding")):
        value = read(path).strip()
        result[key] = int(value) if value in {"0", "1"} else None
    return result


def wan_interface():
    if not shutil.which("ip"):
        return None
    route = run(["ip", "-j", "route", "show", "default"])
    try:
        interfaces = [entry["dev"] for entry in json.loads(route.stdout or "[]")
                      if "dev" in entry and entry.get("type", "unicast") == "unicast"]
    except (ValueError, TypeError, KeyError):
        interfaces = re.findall(r"\bdev\s+([A-Za-z0-9_.:-]+)", route.stdout)
    return interfaces[0] if interfaces else None


def ports():
    if not shutil.which("ss"):
        return []
    output = run(["ss", "-H", "-lntu"]).stdout
    entries = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        address = fields[4]
        match = re.search(r":(\d+)$", address)
        if match:
            entries.append({"proto": "tcp" if fields[0].startswith("tcp") else "udp",
                            "port": int(match.group(1)), "address": address})
    return entries


def inspect(role, request):
    actual = existing_role()
    installed = deployment_exists()
    if installed and actual != role:
        raise NodeError("ROLE_MISMATCH", "Existing deployment has a different or unknown role")
    data = {"installed": installed, "existing_role": actual,
            "managed": bool(json_read(MANIFEST, {})), "arch": platform.machine(),
            "os_release": os_info(), "systemd": systemd_available(),
            "tools": {tool: shutil.which(tool) for tool in PACKAGE_TOOLS},
            "forwarding": forwarding(), "wan_interface": wan_interface(),
            "ports": ports(), "utc_time": int(time.time()),
            "manifest": json_read(MANIFEST, {})}
    data["wg_peers"] = public_peers(role)
    data["configured_peers"] = configured_peers(role)
    data["server_public"] = None
    if role == "hk" and shutil.which("wg"):
        current = run(net_command(role, ["wg", "show", "cne-users", "public-key"]))
        if current.returncode == 0 and current.stdout.strip():
            data["server_public"] = current.stdout.strip()
        else:
            found = re.search(r"(?mi)^PrivateKey\s*=\s*(\S+)\s*$", read("/etc/wireguard/cne-users.conf"))
            if found:
                data["server_public"] = run(["wg", "pubkey"], input=key(found.group(1)) + "\n", check=True).stdout.strip()
    if request.get("include_private") is True:
        private = {}
        for path in sorted(allowed_files(role) - {BINARY, ENTRY, NODE}):
            target = safe_path(path)
            if target.exists():
                private[path] = {"content": base64.b64encode(target.read_bytes()).decode(),
                                 "mode": stat.S_IMODE(target.stat().st_mode)}
        data["private_files"] = private
    return data


def configured_peers(role):
    result = []
    for path in sorted(ROLE_FILES[role]):
        if path.startswith("/etc/wireguard/"):
            peers = [{"public_key": fields["PublicKey"],
                      "allowed_ips": [value.strip() for value in fields["AllowedIPs"].split(",")]}
                     for _, fields in peer_blocks(read(path)) if fields]
            result.append({"interface": Path(path).stem, "peers": peers})
    return result


def service_states(role):
    services = ["cn-egress.service", "cn-egress-obfs.service"]
    if role == "exit":
        services.append("cn-egress-dns.service")
    if not shutil.which("systemctl"):
        return {unit: {"active": "unavailable", "enabled": "unavailable"} for unit in services}
    return {unit: {"active": run(["systemctl", "is-active", unit]).stdout.strip(),
                   "enabled": run(["systemctl", "is-enabled", unit]).stdout.strip()}
            for unit in services}


def net_command(role, args):
    return ["ip", "netns", "exec", NS, *args] if role in {"hk", "sh"} else args


def public_peers(role):
    interfaces = {"hk": ["cne-users", "cne-cn"], "sh": ["cne-cn", "cne-exit"],
                  "exit": ["cne-exit"]}[role]
    output = []
    if not shutil.which("wg") or not shutil.which("ip"):
        return output
    for interface in interfaces:
        peers = {}
        for field in ("endpoints", "latest-handshakes", "transfer", "allowed-ips"):
            result = run(net_command(role, ["wg", "show", interface, field]))
            if result.returncode:
                continue
            for line in result.stdout.splitlines():
                parts = line.split()
                if not parts:
                    continue
                peer = peers.setdefault(parts[0], {"public_key": parts[0]})
                if field == "transfer" and len(parts) == 3:
                    peer["received_bytes"], peer["sent_bytes"] = map(int, parts[1:])
                elif field == "latest-handshakes" and len(parts) == 2:
                    peer["latest_handshake"] = int(parts[1])
                elif field == "endpoints" and len(parts) == 2:
                    peer["endpoint"] = parts[1]
                elif field == "allowed-ips":
                    peer["allowed_ips"] = parts[1:]
        output.append({"interface": interface, "peers": list(peers.values())})
    return output


def status(role):
    require_role(role)
    return {"services": service_states(role), "peers": public_peers(role),
            "forwarding": forwarding(), "wan_interface": wan_interface(),
            "managed": bool(json_read(MANIFEST, {})), "ports": ports()}


def doctor(role):
    data = status(role)
    issues = []
    for unit, state in data["services"].items():
        if state["active"] != "active":
            issues.append(f"{unit}: {state['active']}")
    if role in {"hk", "sh"}:
        namespace = run(["ip", "netns", "list"]).stdout.split()
        if NS not in namespace:
            issues.append("Relay namespace is missing")
    if role == "sh" and run(["nft", "list", "table", "inet", "cne_wss_input"]).returncode:
        issues.append("Owned WSS UDP guard is missing")
    role_interface = {"hk": "cne-cn", "exit": "cne-exit"}.get(role)
    if role_interface:
        config = read(f"/etc/wireguard/{role_interface}.conf")
        port = 51831 if role == "hk" else 51832
        if not re.search(rf"(?m)^Endpoint\s*=\s*127\.0\.0\.1:{port}\s*$", config):
            issues.append("WireGuard endpoint is not the protected local WSS helper")
    certificates = {}
    if shutil.which("openssl"):
        for name in ("node.crt", "ca.crt"):
            path = "/etc/cn-egress-wss/" + name
            expiry = run(["openssl", "x509", "-in", path, "-noout", "-enddate"])
            if expiry.returncode:
                certificates[name] = {"parsed": False}
                issues.append(name + ": cannot parse certificate")
                continue
            soon = run(["openssl", "x509", "-in", path, "-noout", "-checkend", "2592000"])
            certificates[name] = {"parsed": True, "expiry": expiry.stdout.strip(),
                                  "valid_for_30_days": soon.returncode == 0}
            if soon.returncode:
                issues.append(name + ": expires within 30 days or is expired")
    else:
        certificates["check"] = "skipped: openssl unavailable"
    data["certificates"] = certificates
    data["issues"] = issues
    data["healthy"] = not issues
    data["scope"] = "Local checks only; verify domestic exit with a real WireGuard client. Certificate checks parse dates only, not trust validation."
    return data


def logs(role, request):
    require_role(role)
    try:
        count = min(100, max(1, int(request.get("lines", 50))))
    except (ValueError, TypeError):
        raise NodeError("INVALID_REQUEST", "lines must be an integer")
    args = ["journalctl", "--no-pager", "-o", "short-iso", "-n", str(count),
            "-u", "cn-egress.service", "-u", "cn-egress-obfs.service"]
    if role == "exit":
        args += ["-u", "cn-egress-dns.service"]
    return {"lines": redact(run(args, timeout=20).stdout).splitlines()[-count:]}


def backup(role, label="manual"):
    path = fs("/root") / ("cn-egress-oneclick-backup-" +
                         datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S") +
                         "-" + uuid.uuid4().hex[:8])
    path.mkdir(mode=0o700, parents=True)
    os.chmod(path, 0o700)
    entries = []
    for filename in sorted(allowed_files(role) | {MANIFEST, CLIENTS}):
        target = safe_path(filename)
        entry = {"path": filename, "existed": target.exists()}
        if target.exists():
            body = target.read_bytes()
            saved = path / "files" / filename.lstrip("/")
            saved.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            saved.write_bytes(body)
            os.chmod(saved, 0o600)
            entry.update({"mode": stat.S_IMODE(target.stat().st_mode),
                          "uid": target.stat().st_uid, "gid": target.stat().st_gid,
                          "sha256": hashlib.sha256(body).hexdigest()})
        entries.append(entry)
    for label_name, command in SNAPSHOTS.items():
        if shutil.which(command[0]):
            result = run(command)
            (path / (label_name + ".txt")).write_text(result.stdout)
            os.chmod(path / (label_name + ".txt"), 0o600)
    data = {"role": role, "reason": label, "files": entries,
            "forwarding": forwarding(), "services": service_states(role)}
    (path / "backup.json").write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(path / "backup.json", 0o600)
    return str(path), data


def validate_files(role, files, *, adopt=False):
    if not isinstance(files, dict):
        raise NodeError("INVALID_REQUEST", "files must be a mapping")
    permitted = {ENTRY, NODE} if adopt else allowed_files(role)
    result = {}
    for path, spec in files.items():
        if path not in permitted:
            raise NodeError("INVALID_PATH", "File is outside this role's allowlist: " + str(path))
        safe_path(path)
        if not isinstance(spec, dict) or not isinstance(spec.get("content"), str):
            raise NodeError("INVALID_REQUEST", "File content must be base64 text")
        try:
            content = base64.b64decode(spec["content"], validate=True)
        except (ValueError, binascii.Error) as exc:
            raise NodeError("INVALID_REQUEST", "Invalid base64 file content") from exc
        mode = spec.get("mode", 0o600)
        if type(mode) is not int or mode not in {0o600, 0o640, 0o644, 0o700, 0o750, 0o755}:
            raise NodeError("INVALID_MODE", "Unsupported file permission")
        if path.endswith(".key") or path.startswith("/etc/wireguard/"):
            if mode not in {0o600, 0o640} or (path.startswith("/etc/wireguard/") and mode != 0o600):
                raise NodeError("INVALID_MODE", "Private configuration permissions are too broad")
        if len(content) > (24 * 1024 * 1024 if path == BINARY else 2 * 1024 * 1024):
            raise NodeError("INVALID_REQUEST", "File is too large")
        if path == BINARY:
            expected = spec.get("sha256", "")
            if not re.fullmatch(r"[a-f0-9]{64}", expected) or hashlib.sha256(content).hexdigest() != expected:
                raise NodeError("DIGEST_MISMATCH", "wstunnel binary SHA256 did not match")
            if mode != 0o755:
                raise NodeError("INVALID_MODE", "wstunnel must be mode 0755")
        result[path] = {"content": content, "mode": mode}
    if not adopt:
        if "/etc/sysctl.d/90-cn-egress.conf" in result:
            raise NodeError("UNSAFE_CONFIG", "Fresh installation cannot change host forwarding sysctl")
        required = allowed_files(role) - {ENTRY, NODE, "/etc/sysctl.d/90-cn-egress.conf",
                                         "/etc/cn-egress-wss/sh-host", "/etc/cn-egress-wss/port"}
        if not required <= result.keys():
            raise NodeError("MISSING_FILES", "Incomplete install files: " + ", ".join(sorted(required - result.keys())))
        if result["/etc/cn-egress-wss/role"]["content"].decode().strip() != role:
            raise NodeError("ROLE_MISMATCH", "Payload WSS role does not match node role")
        if "/etc/cn-egress-wss/port" in result:
            port = result["/etc/cn-egress-wss/port"]["content"].decode().strip()
            if not port.isdigit() or not 1 <= int(port) <= 65535:
                raise NodeError("INVALID_PORT", "WSS port must be in 1–65535")
        if "/etc/cn-egress-wss/sh-host" in result:
            host = result["/etc/cn-egress-wss/sh-host"]["content"].decode().strip()
            try:
                if ipaddress.ip_address(host).version != 4:
                    raise ValueError()
            except ValueError as exc:
                raise NodeError("INVALID_HOST", "WSS mainland host must be an IPv4 address") from exc
        for path in ROLE_FILES[role]:
            if path.startswith("/etc/wireguard/"):
                body = result[path]["content"].decode()
                tables = re.findall(r"(?mi)^\s*Table\s*=\s*(.*?)\s*$", body)
                if tables != ["off"]:
                    raise NodeError("UNSAFE_CONFIG", "WireGuard host routing must use Table = off")
                if re.search(r"(?mi)^\s*(PreUp|PostUp|PreDown|PostDown|SaveConfig|DNS)\s*=", body):
                    raise NodeError("UNSAFE_CONFIG", "WireGuard hook commands are forbidden")
                expected_address = {
                    ("hk", "cne-users"): "10.77.10.1/24, fd77:77:10::1/64",
                    ("hk", "cne-cn"): "10.77.20.1/30, fd77:77:20::1/64",
                    ("sh", "cne-cn"): "10.77.20.2/30, fd77:77:20::2/64",
                    ("sh", "cne-exit"): "10.77.30.1/30, fd77:77:30::1/64",
                    ("exit", "cne-exit"): "10.77.30.2/30, fd77:77:30::2/64",
                }[(role, Path(path).stem)]
                addresses = re.findall(r"(?mi)^\s*Address\s*=\s*(.*?)\s*$", body)
                if len(addresses) != 1 or {part.strip() for part in addresses[0].split(",")} != {part.strip() for part in expected_address.split(",")}:
                    raise NodeError("UNSAFE_CONFIG", "Unexpected WireGuard addresses")
        if role in {"hk", "exit"}:
            interface = "cne-cn" if role == "hk" else "cne-exit"
            local = 51831 if role == "hk" else 51832
            body = result[f"/etc/wireguard/{interface}.conf"]["content"].decode()
            if not re.search(rf"(?mi)^Endpoint\s*=\s*127\.0\.0\.1:{local}\s*$", body):
                raise NodeError("UNSAFE_CONFIG", "Server transport must use the local WSS helper")
    return result


def preflight(role, files):
    if platform.system() != "Linux" or platform.machine() not in {"x86_64", "amd64"}:
        raise NodeError("UNSUPPORTED_HOST", "This payload supports Linux x86_64 only")
    if not systemd_available():
        raise NodeError("UNSUPPORTED_HOST", "A running systemd is required")
    if deployment_exists():
        raise NodeError("ALREADY_INSTALLED", "Existing deployment detected; use adopt, never overwrite install")
    conflicts = [path for path in allowed_files(role) - {BINARY, ENTRY, NODE, "/etc/sysctl.d/90-cn-egress.conf"}
                 if safe_path(path).exists()]
    if conflicts:
        raise NodeError("OWNER_CONFLICT", "Reserved deployment files already exist; use adopt or recover them first")
    if role == "exit" and forwarding()["ipv4"] != 1:
        raise NodeError("FORWARDING_BLOCKED", "Exit must already have IPv4 forwarding enabled; automatic changes to host settings are refused")
    for namespace in (None, NS):
        prefix = ["ip", "netns", "exec", namespace] if namespace else []
        if namespace and (not shutil.which("ip") or NS not in run(["ip", "netns", "list"]).stdout.split()):
            continue
        for table in ("cn_egress", "cne_wss_input"):
            if shutil.which("nft") and run([*prefix, "nft", "list", "table", "inet", table]).returncode == 0:
                raise NodeError("OWNER_CONFLICT", "A reserved nftables table already exists")
    if shutil.which("iptables") and run(["iptables", "-S", "CNE_VPN"]).returncode == 0:
        raise NodeError("OWNER_CONFLICT", "A reserved Docker integration chain already exists")
    occupied = ports()
    wss_port = int(files.get("/etc/cn-egress-wss/port", {"content": b"443"})["content"].decode().strip())
    user_port = 51820
    if role == "hk":
        match = re.search(r"(?mi)^ListenPort\s*=\s*(\d+)\s*$", files["/etc/wireguard/cne-users.conf"]["content"].decode())
        user_port = int(match.group(1)) if match else 0
        if not 1 <= user_port <= 65535 or user_port == 51831:
            raise NodeError("INVALID_PORT", "HK user port must be distinct from the local WSS helper")
    needed = {"hk": [("udp", user_port), ("udp", 51831)],
              "sh": [("tcp", wss_port), ("udp", 51821), ("udp", 51822)],
              "exit": [("udp", 51832), ("udp", 5354), ("tcp", 5354)]}[role]
    if any((port["proto"], port["port"]) in needed for port in occupied):
        raise NodeError("PORT_IN_USE", "A required VPN/transport port is already occupied")
    if role == "exit":
        wan = files["/etc/cn-egress/wan-interface"]["content"].decode().strip()
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", wan) or wan != wan_interface():
            raise NodeError("INVALID_WAN", "WAN interface must match the existing default route")
        if shutil.which("ip"):
            for ipv6, subnets in ((False, ["10.77.10.0/24", "10.77.30.0/30"]),
                                  (True, ["fd77:77:10::/64", "fd77:77:30::/64"])):
                routes = run(["ip", *(["-6"] if ipv6 else []), "-j", "route", "show", "table", "all"])
                try:
                    entries = json.loads(routes.stdout or "[]")
                    for entry in entries:
                        if entry.get("dst", "default") == "default":
                            continue
                        network = ipaddress.ip_network(entry["dst"], strict=False)
                        if any(network.overlaps(ipaddress.ip_network(subnet)) for subnet in subnets):
                            raise NodeError("NETWORK_CONFLICT", "Existing host route overlaps the VPN client subnet")
                except (ValueError, TypeError, KeyError) as exc:
                    raise NodeError("PREFLIGHT_FAILED", "Cannot verify existing exit routes") from exc
    needed_tools = set(PACKAGE_TOOLS) - ({"dnsmasq", "iptables"} if role != "exit" else set())
    missing = [tool for tool in sorted(needed_tools) if not shutil.which(tool)]
    if missing:
        distro = os_info()
        if "debian" not in {distro["ID"], *distro["ID_LIKE"].split()} and distro["ID"] != "ubuntu":
            raise NodeError("DEPENDENCIES_BLOCKED", "Missing tools: " + ", ".join(missing))
        if not shutil.which("apt-get") or not shutil.which("dpkg"):
            raise NodeError("DEPENDENCIES_BLOCKED", "apt-get/dpkg unavailable; missing: " + ", ".join(missing))
        audit = run(["dpkg", "--audit"], timeout=15)
        if audit.returncode or audit.stdout.strip():
            raise NodeError("DEPENDENCIES_BLOCKED", "Existing dpkg state requires repair; no packages were changed. Missing: " + ", ".join(missing))
    # The package plan is checked before any files are changed.  It cannot remove
    # packages or configure an unrelated pending package.
    packages = sorted({PACKAGE_TOOLS[tool] for tool in missing})
    refresh = dependency_plan(packages, permit_missing_metadata=True) if packages else False
    return {"packages": packages, "metadata_refresh": refresh}


def dependency_plan(packages, *, permit_missing_metadata=False):
    plan = run(["apt-get", "-s", "--no-remove", "--no-install-recommends", "install", *packages], timeout=60)
    if re.search(r"(?m)^(?:Remv |Inst \S+ \[)", plan.stdout):
        raise NodeError("DEPENDENCIES_BLOCKED", "Dependency plan would upgrade or remove existing packages")
    if plan.returncode:
        diagnostics = plan.stdout + "\n" + plan.stderr
        missing = re.search(r"Unable to locate package|has no installation candidate", diagnostics, re.I)
        broken = re.search(r"unmet dependencies|held broken packages|not installable|Depends:|PreDepends:", diagnostics, re.I)
        if permit_missing_metadata and missing and not broken:
            return True
        raise NodeError("DEPENDENCIES_BLOCKED", "Minimal dependency install cannot proceed safely")
    return False


def prepare_dependencies(packages, *, metadata_refresh=False):
    """Only dependency installation refreshes empty package lists, never adopt."""
    if not packages:
        return
    audit = run(["dpkg", "--audit"], timeout=15)
    if audit.returncode or audit.stdout.strip():
        raise NodeError("DEPENDENCIES_BLOCKED", "Existing dpkg state is incomplete; no packages changed")
    if metadata_refresh:
        run(["apt-get", "update"], check=True, timeout=180)
    # Always repeat the plan immediately before applying it.  An index refresh
    # may make dependencies newer; no existing package upgrade is accepted.
    dependency_plan(packages)
    run(["apt-get", "-y", "--no-remove", "--no-install-recommends", "install", *packages],
        check=True, timeout=180)


def validate_existing(role):
    """Adoption writes only management files, but first proves its owner scope."""
    required = allowed_files(role) - {ENTRY, NODE, "/etc/sysctl.d/90-cn-egress.conf",
                                     "/etc/cn-egress-wss/sh-host", "/etc/cn-egress-wss/port"}
    missing = [path for path in sorted(required) if not safe_path(path).exists()]
    if missing:
        raise NodeError("INCOMPLETE_DEPLOYMENT", "Cannot adopt incomplete deployment: " + ", ".join(missing))
    service = read("/etc/systemd/system/cn-egress.service")
    if not re.search(rf"(?m)^ExecStart=/usr/local/sbin/cn-egress-net start {role}\s*$", service):
        raise NodeError("ROLE_MISMATCH", "Service role does not match the WSS role")
    for path in ROLE_FILES[role]:
        if path.startswith("/etc/wireguard/") and not re.search(r"(?mi)^Table\s*=\s*off\s*$", read(path)):
            raise NodeError("UNSAFE_CONFIG", "Existing WireGuard must use Table = off")
    if role in {"hk", "exit"}:
        interface = "cne-cn" if role == "hk" else "cne-exit"
        port = 51831 if role == "hk" else 51832
        if not re.search(rf"(?mi)^Endpoint\s*=\s*127\.0\.0\.1:{port}\s*$", read(f"/etc/wireguard/{interface}.conf")):
            raise NodeError("UNSAFE_CONFIG", "Existing server transport is not the protected WSS deployment")
    if role in {"hk", "sh"}:
        manager = read("/usr/local/sbin/cn-egress-net")
        if "cn-egress-relay" not in manager or "ip netns exec" not in manager:
            raise NodeError("UNSAFE_CONFIG", "Existing relay manager does not isolate host routes")
        validate_namespace_scope(role)


def validate_namespace_scope(role):
    if role not in {"hk", "sh"} or NS not in run(["ip", "netns", "list"]).stdout.split():
        return
    link_info = run(["ip", "-j", "-n", NS, "link", "show"])
    try:
        names = {entry["ifname"] for entry in json.loads(link_info.stdout or "[]")}
    except (ValueError, TypeError, KeyError) as exc:
        raise NodeError("OWNER_CONFLICT", "Cannot identify relay namespace devices") from exc
    expected = {"lo", "cne-cn", "cne-users" if role == "hk" else "cne-exit"}
    if not names <= expected:
        raise NodeError("OWNER_CONFLICT", "Relay namespace contains unrelated interfaces; operation refused")


def validate_registry(role, registry):
    if not isinstance(registry, list) or (role != "hk" and registry):
        raise NodeError("INVALID_REQUEST", "Initial client_registry is a list for the HK node only")
    if not registry:
        return []
    actual = {fields["PublicKey"]: fields["AllowedIPs"]
              for _, fields in peer_blocks(read("/etc/wireguard/cne-users.conf")) if fields}
    result = []
    names, addresses, public_keys = set(), set(), set()
    for item in registry:
        if not isinstance(item, dict):
            raise NodeError("INVALID_REQUEST", "Invalid initial client registry entry")
        public = key(item.get("public_key"))
        name, address = item.get("name"), item.get("address")
        if not isinstance(name, str) or not 1 <= len(name) <= 64 or any(not char.isprintable() for char in name):
            raise NodeError("INVALID_NAME", "Invalid initial client name")
        if not isinstance(address, str) or not re.fullmatch(r"10\.77\.10\.\d+/32", address):
            raise NodeError("INVALID_ADDRESS", "Initial clients need a 10.77.10.N/32 address")
        if address not in [part.strip() for part in actual.get(public, "").split(",")]:
            raise NodeError("CLIENT_NOT_FOUND", "Initial client must already exist in the supplied configuration")
        if name in names or address in addresses or public in public_keys:
            raise NodeError("CLIENT_EXISTS", "Duplicate initial client registry entry")
        names.add(name)
        addresses.add(address)
        public_keys.add(public)
        result.append({"name": name, "public_key": public, "address": address})
    return result


def keygen(role, request):
    if role != "hk":
        raise NodeError("WRONG_ROLE", "Generate keys on the HK node")
    if deployment_exists():
        require_role(role)
    count = request.get("count", 1)
    if type(count) is not int or not 1 <= count <= 32:
        raise NodeError("INVALID_REQUEST", "count must be an integer in 1–32")
    if not shutil.which("wg"):
        distro = os_info()
        if distro["ID"] not in {"debian", "ubuntu"} and "debian" not in distro["ID_LIKE"].split():
            raise NodeError("DEPENDENCIES_BLOCKED", "WireGuard tools are missing")
        if not shutil.which("apt-get") or not shutil.which("dpkg"):
            raise NodeError("DEPENDENCIES_BLOCKED", "Install wireguard-tools first")
        audit = run(["dpkg", "--audit"])
        if audit.returncode or audit.stdout.strip():
            raise NodeError("DEPENDENCIES_BLOCKED", "Existing dpkg state is incomplete; no packages changed")
        refresh = dependency_plan(["wireguard-tools"], permit_missing_metadata=True)
        prepare_dependencies(["wireguard-tools"], metadata_refresh=refresh)
    values = []
    for _ in range(count):
        private = key(run(["wg", "genkey"], check=True).stdout.strip())
        public = key(run(["wg", "pubkey"], input=private + "\n", check=True).stdout.strip())
        values.append({"private": private, "public": public})
    return {"keys": values}


def restore_files(backup_path, entries, paths):
    failures = []
    lookup = {item["path"]: item for item in entries}
    for path in paths:
        entry = lookup[path]
        try:
            if entry["existed"]:
                saved = Path(backup_path) / "files" / path.lstrip("/")
                atomic_write(path, saved.read_bytes(), entry["mode"])
                os.chown(fs(path), entry["uid"], entry["gid"])
            else:
                safe_path(path).unlink(missing_ok=True)
        except (OSError, NodeError) as exc:
            failures.append(path + ": " + type(exc).__name__)
    return failures


def setup_transport_user():
    if run(["getent", "group", "cn-egress-wss"]).returncode:
        run(["groupadd", "--system", "cn-egress-wss"], check=True)
    if run(["getent", "passwd", "cn-egress-wss"]).returncode:
        run(["useradd", "--system", "--gid", "cn-egress-wss", "--home-dir", "/nonexistent",
             "--shell", "/usr/sbin/nologin", "cn-egress-wss"], check=True)
    group = grp.getgrnam("cn-egress-wss").gr_gid
    account = pwd.getpwnam("cn-egress-wss")
    if account.pw_uid == 0 or account.pw_gid != group:
        raise NodeError("OWNER_CONFLICT", "Existing transport account is not the expected unprivileged user")
    return group


def route_baseline():
    return {name: run(command).stdout for name, command in SNAPSHOTS.items()
            if name in {"routes4", "routes6", "rules4", "rules6"}}


def preserved_routes(before, role):
    after = route_baseline()
    if role in {"hk", "sh"}:
        return after == before
    # Exit has only owned client return routes; its host rules/default routes
    # must remain unchanged, including source-routing used by NAS services.
    for name in ("rules4", "rules6"):
        if after[name] != before[name]:
            return False
    owned_destinations = {"10.77.10.0/24", "10.77.30.0/30", "10.77.30.0", "10.77.30.2", "10.77.30.3",
                          "fd77:77:10::/64", "fd77:77:30::/64", "fd77:77:30::2", "fe80::/64", "ff00::/8"}
    def owned(line):
        parts = line.split()
        if not parts or " dev cne-exit " not in (" " + line + " "):
            return False
        destination = parts[1] if parts[0] in {"local", "broadcast", "multicast"} and len(parts) > 1 else parts[0]
        return destination in owned_destinations
    for name in ("routes4", "routes6"):
        cleaned = "\n".join(line for line in after[name].splitlines() if not owned(line))
        previous = "\n".join(line for line in before[name].splitlines() if not owned(line))
        if set(cleaned.splitlines()) != set(previous.splitlines()):
            return False
    return True


def set_forwarding(values):
    for key, name in (("ipv4", "net.ipv4.ip_forward"), ("ipv6", "net.ipv6.conf.all.forwarding")):
        value = values.get(key)
        if value in {0, 1}:
            run(["sysctl", "-q", "-w", f"{name}={value}"], check=True)


def install(role, request):
    deployment_id = request.get("deployment_id")
    try:
        uuid.UUID(deployment_id)
    except (ValueError, TypeError, AttributeError) as exc:
        raise NodeError("INVALID_REQUEST", "install requires a UUID deployment_id") from exc
    files = validate_files(role, request.get("files"))
    plan = preflight(role, files)
    packages = plan["packages"]
    saved_path, saved = backup(role, "before-install")
    written = set()
    started = False
    try:
        prepare_dependencies(packages, metadata_refresh=plan["metadata_refresh"])
        # Missing ip/nft/iptables could have limited the initial inspection.
        # Repeat every owner/port/subnet check with the now available tools,
        # before writing any VPN configuration or creating network resources.
        rechecked = preflight(role, files)
        if rechecked["packages"]:
            raise NodeError("DEPENDENCIES_BLOCKED", "Required tools are still missing after minimal package installation")
        before = route_baseline()
        for label, command in SNAPSHOTS.items():
            saved_snapshot = Path(saved_path) / (label + ".txt")
            if not saved_snapshot.exists() and shutil.which(command[0]):
                saved_snapshot.write_text(run(command).stdout)
                os.chmod(saved_snapshot, 0o600)
        group = setup_transport_user()
        for path, spec in files.items():
            written.add(path)
            atomic_write(path, spec["content"], spec["mode"])
        for owned_directory in ("/opt/cn-egress", "/opt/cn-egress/wstunnel-11.0.0"):
            directory_path = fs(owned_directory)
            if directory_path.is_symlink():
                raise NodeError("UNSAFE_PATH", "Transport directory is a symlink")
            os.chmod(directory_path, 0o755)
        directory = fs("/etc/cn-egress-wss")
        os.chmod(directory, 0o750)
        os.chown(directory, 0, group)
        empty = directory / "empty-ca"
        empty.mkdir(mode=0o750, exist_ok=True)
        os.chown(empty, 0, group)
        for name in ("node.crt", "node.key", "ca.crt", "role", "restrictions.yaml", "sh-host", "port"):
            target = directory / name
            if target.exists():
                os.chmod(target, 0o640)
                os.chown(target, 0, group)
        manifest = {"version": 1, "role": role, "origin": "fresh-install",
                    "deployment_id": deployment_id,
                    "machine_id": read("/etc/machine-id").strip(),
                    "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "original_backup": saved_path,
                    "original_forwarding": saved["forwarding"],
                    "owned_files": sorted(set(files) | {MANIFEST, CLIENTS}),
                    "installed_packages": packages}
        registry = validate_registry(role, request.get("client_registry", []))
        written.add(MANIFEST)
        json_write(MANIFEST, manifest)
        written.add(CLIENTS)
        json_write(CLIENTS, {"version": 1, "clients": registry})
        run(["systemctl", "daemon-reload"], check=True)
        run(["systemctl", "enable", "cn-egress-obfs.service", "cn-egress.service"], check=True)
        started = True
        run(["systemctl", "start", "cn-egress.service"], check=True, timeout=70)
        if role == "exit":
            run(["systemctl", "enable", "cn-egress-dns.service"], check=True)
            run(["systemctl", "start", "cn-egress-dns.service"], check=True)
        active = service_states(role)
        if any(state["active"] != "active" for state in active.values()):
            raise NodeError("SERVICE_FAILED", "A required VPN/WSS/DNS service did not start")
        if not preserved_routes(before, role):
            raise NodeError("ROUTE_CHANGED", "Host routes or policy rules changed beyond owned VPN return routes")
        if role in {"hk", "sh"} and forwarding() != saved["forwarding"]:
            raise NodeError("FORWARDING_CHANGED", "Relay host forwarding unexpectedly changed")
        return {"installed": True, "backup": saved_path, "packages": packages,
                "services": service_states(role)}
    except Exception as exc:
        # Never restore a whole route/firewall snapshot: that would overwrite
        # unrelated concurrent changes.  Stop only the newly installed owner.
        if started:
            run(["systemctl", "stop", "cn-egress.service"], timeout=45)
            run(["systemctl", "stop", "cn-egress-obfs.service"], timeout=15)
            if role == "exit":
                run(["systemctl", "stop", "cn-egress-dns.service"], timeout=15)
        run(["systemctl", "disable", "cn-egress.service", "cn-egress-obfs.service"], timeout=15)
        if role == "exit":
            run(["systemctl", "disable", "cn-egress-dns.service"], timeout=15)
        failures = restore_files(saved_path, saved["files"], written)
        run(["systemctl", "daemon-reload"])
        detail = "Rollback backup: " + saved_path
        if failures:
            detail += "; files requiring manual recovery: " + ", ".join(failures)
        if isinstance(exc, NodeError):
            raise NodeError(exc.code, str(exc) + "; " + detail) from exc
        raise NodeError("INSTALL_FAILED", type(exc).__name__ + "; " + detail) from exc


def adopt(role, request):
    require_role(role)
    validate_existing(role)
    files = validate_files(role, request.get("files", {}), adopt=True)
    prior = json_read(MANIFEST, {})
    if prior:
        require_role(role, managed=True)
    saved_path, saved = backup(role, "before-adopt")
    before = route_baseline()
    written = set()
    try:
        for path, spec in files.items():
            written.add(path)
            atomic_write(path, spec["content"], spec["mode"])
        manifest = dict(prior) if prior else {
            "version": 1, "role": role, "origin": "adopted-existing",
            "machine_id": read("/etc/machine-id").strip(),
            "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "original_backup": None, "original_forwarding": None,
            # Historical install origins are deliberately not invented.
            "owned_files": sorted(allowed_files(role) - {BINARY} | {MANIFEST, CLIENTS}),
        }
        manifest["adoption_backup"] = saved_path
        written.add(MANIFEST)
        json_write(MANIFEST, manifest)
        if not fs(CLIENTS).exists():
            written.add(CLIENTS)
            json_write(CLIENTS, {"version": 1, "clients": []})
        if route_baseline() != before or forwarding() != saved["forwarding"]:
            raise NodeError("HOST_CHANGED", "Host state changed during read-only adoption")
        return {"adopted": True, "backup": saved_path, "services_restarted": False}
    except Exception:
        restore_files(saved_path, saved["files"], written)
        raise


def service_action(role, action):
    require_role(role, managed=True)
    validate_namespace_scope(role)
    original_forwarding = forwarding()
    if role == "exit" and action in {"start", "restart"} and original_forwarding["ipv4"] != 1:
        raise NodeError("FORWARDING_BLOCKED", "Exit forwarding is disabled; automatic host settings changes are refused")
    before = route_baseline()
    run(["systemctl", action, "cn-egress.service"], check=True, timeout=80)
    if role == "exit" and action in {"start", "restart"}:
        run(["systemctl", "start", "cn-egress-dns.service"], check=True)
    if not preserved_routes(before, role):
        raise NodeError("ROUTE_CHANGED", "Unexpected host route/rule change")
    if forwarding() != original_forwarding:
        raise NodeError("FORWARDING_CHANGED", "Host forwarding settings unexpectedly changed")
    return {"services": service_states(role)}


def uninstall(role, request):
    if request.get("confirm") is not True:
        raise NodeError("CONFIRM_REQUIRED", "Uninstall requires explicit confirm=true")
    manifest = require_role(role, managed=True)
    for request_field, manifest_field in (("deployment_id", "deployment_id"), ("expected_origin", "origin")):
        if request_field in request and request[request_field] != manifest.get(manifest_field):
            raise NodeError("OWNER_MISMATCH", "Uninstall target does not match the expected deployment")
    permitted = allowed_files(role) | {MANIFEST, CLIENTS}
    selected = set(manifest.get("owned_files", []))
    if not selected <= permitted:
        raise NodeError("INVALID_METADATA", "Manifest includes a path outside this role's allowlist")
    before_routes, before_forwarding = route_baseline(), forwarding()
    validate_existing(role)
    saved_path, _ = backup(role, "before-uninstall")
    run(["systemctl", "stop", "cn-egress.service"], check=True, timeout=50)
    run(["systemctl", "stop", "cn-egress-obfs.service"], timeout=20)
    run(["systemctl", "disable", "cn-egress.service", "cn-egress-obfs.service"], timeout=20)
    if role == "exit":
        run(["systemctl", "stop", "cn-egress-dns.service"], timeout=20)
        run(["systemctl", "disable", "cn-egress-dns.service"], timeout=20)
    # An inactive oneshot unit may leave manually created runtime resources.
    # The fixed owner cleanup runs while its configuration still exists.
    run(["/usr/local/sbin/cn-egress-net", "stop", role], check=True, timeout=40)
    if role in {"hk", "sh"}:
        if NS in run(["ip", "netns", "list"]).stdout.split():
            raise NodeError("UNINSTALL_INCOMPLETE", "Relay namespace remains; configuration retained. Backup: " + saved_path)
        if role == "sh" and run(["nft", "list", "table", "inet", "cne_wss_input"]).returncode == 0:
            raise NodeError("UNINSTALL_INCOMPLETE", "WSS guard remains; configuration retained. Backup: " + saved_path)
    else:
        if (run(["ip", "link", "show", "dev", "cne-exit"]).returncode == 0 or
                run(["nft", "list", "table", "inet", "cn_egress"]).returncode == 0 or
                run(["iptables", "-S", "CNE_VPN"]).returncode == 0):
            raise NodeError("UNINSTALL_INCOMPLETE", "Owned exit resources remain; configuration retained. Backup: " + saved_path)
    if not preserved_routes(before_routes, role) or forwarding() != before_forwarding:
        raise NodeError("HOST_CHANGED", "Host routes/settings changed beyond owned resources; configuration retained. Backup: " + saved_path)
    retained = []
    if manifest.get("origin") == "adopted-existing":
        # Existing helper origins and original sysctl were not known at adopt.
        selected -= {BINARY, "/etc/sysctl.d/90-cn-egress.conf"}
        retained = [path for path in (BINARY, "/etc/sysctl.d/90-cn-egress.conf") if fs(path).exists()]
    original = manifest.get("original_backup")
    original_entries = None
    if manifest.get("origin") == "fresh-install" and original:
        original_path = Path(original)
        if original_path.parent != fs("/root") or not original_path.name.startswith("cn-egress-oneclick-backup-"):
            raise NodeError("INVALID_METADATA", "Original backup is outside its allowlisted directory")
        original_entries = json.loads((original_path / "backup.json").read_text())["files"]
    if original_entries is not None:
        failures = restore_files(original, original_entries, selected)
        if failures:
            raise NodeError("UNINSTALL_INCOMPLETE", "Uninstall backup: " + saved_path + "; " + ", ".join(failures))
    else:
        for path in sorted(selected):
            safe_path(path).unlink(missing_ok=True)
    run(["systemctl", "daemon-reload"], check=True)
    # Dependencies and dedicated system account are kept: removing packages or
    # shared executables can affect services unrelated to this deployment.
    return {"uninstalled": True, "backup": saved_path, "retained_files": retained,
            "retained_dependencies": True, "retained_system_account": "cn-egress-wss"}


def key(value):
    if not isinstance(value, str):
        raise NodeError("INVALID_KEY", "WireGuard key must be base64")
    try:
        if len(base64.b64decode(value, validate=True)) != 32:
            raise ValueError()
    except (ValueError, binascii.Error) as exc:
        raise NodeError("INVALID_KEY", "WireGuard keys must decode to 32 bytes") from exc
    return value


def peer_blocks(body):
    """Preserve the complete interface stanza and other peers byte-for-byte."""
    chunks = re.split(r"(?mi)(?=^[ \t]*\[Peer\][ \t]*$)", body)
    result = []
    for index, chunk in enumerate(chunks):
        fields = {}
        if index:
            for field in ("PublicKey", "PresharedKey", "AllowedIPs"):
                found = re.search(rf"(?mi)^[ \t]*{field}[ \t]*=[ \t]*(.*?)[ \t]*$", chunk)
                fields[field] = found.group(1) if found else ""
        result.append((chunk, fields))
    return result


def client_list(role):
    require_role(role, managed=True)
    if role != "hk":
        raise NodeError("WRONG_ROLE", "Clients are managed only on Hong Kong")
    metadata = json_read(CLIENTS, {"clients": []})
    by_key = {item["public_key"]: item for item in metadata.get("clients", [])}
    clients = []
    networks = []
    for _, fields in peer_blocks(read("/etc/wireguard/cne-users.conf")):
        if not fields:
            continue
        addresses = [part.strip() for part in fields["AllowedIPs"].split(",")]
        ipv4 = next((part for part in addresses if re.fullmatch(r"10\.77\.10\.\d+/32", part)), None)
        number = int(ipv4.split(".")[-1].split("/")[0]) if ipv4 else None
        try:
            networks.extend(ipaddress.ip_network(part, strict=False) for part in addresses)
        except ValueError as exc:
            raise NodeError("UNSAFE_CONFIG", "Client configuration has invalid AllowedIPs") from exc
        known = by_key.get(fields["PublicKey"], {})
        default_name = {10: "iPhone", 20: "Android", 30: "Windows", 250: "US test"}.get(number, "Existing client")
        clients.append({"name": known.get("name", default_name), "public_key": fields["PublicKey"],
                        "address": ipv4, "allowed_ips": addresses,
                        "managed": bool(known)})
    def available(number):
        candidate4 = ipaddress.ip_address(f"10.77.10.{number}")
        candidate6 = ipaddress.ip_address(f"fd77:77:10::{number}")
        return not any((candidate4 if network.version == 4 else candidate6) in network for network in networks)
    free = next((number for number in range(2, 250) if number not in {10, 20, 30} and available(number)), None)
    return {"clients": clients, "next_address": f"10.77.10.{free}" if free else None,
            "server_public": inspect(role, {}).get("server_public")}


def wg_running():
    return run(["ip", "-n", NS, "link", "show", "dev", "cne-users"]).returncode == 0


def runtime_peer(fields, *, remove=False):
    public = key(fields["PublicKey"])
    args = ["wg", "set", "cne-users", "peer", public]
    if remove:
        run(net_command("hk", [*args, "remove"]), check=True)
        return
    allowed = [str(ipaddress.ip_network(part.strip(), strict=False))
               for part in fields["AllowedIPs"].split(",")]
    psk = fields.get("PresharedKey")
    if psk:
        key(psk)
        fd, path = tempfile.mkstemp(prefix=".cn-egress-psk-", dir=fs("/etc/cn-egress"))
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(psk + "\n")
            run(net_command("hk", [*args, "preshared-key", path, "allowed-ips", ",".join(allowed)]), check=True)
        finally:
            os.unlink(path)
    else:
        run(net_command("hk", [*args, "allowed-ips", ",".join(allowed)]), check=True)


def client_add(role, request):
    listing = client_list(role)
    public, psk = key(request.get("public_key")), key(request.get("preshared_key"))
    if public == listing.get("server_public"):
        raise NodeError("INVALID_KEY", "Client and server public keys must differ")
    name = request.get("name", "")
    if not isinstance(name, str) or not 1 <= len(name) <= 64 or any(not char.isprintable() for char in name):
        raise NodeError("INVALID_NAME", "Client name must contain 1–64 printable characters")
    if any(client["public_key"] == public or client["name"] == name for client in listing["clients"]):
        raise NodeError("CLIENT_EXISTS", "Client key or name already exists")
    address = request.get("address") or listing["next_address"]
    if not isinstance(address, str):
        raise NodeError("ADDRESS_EXHAUSTED", "No free client address")
    match = re.fullmatch(r"10\.77\.10\.(\d+)(?:/32)?", address)
    number = int(match.group(1)) if match else 0
    if not 2 <= number <= 249 or number in {10, 20, 30}:
        raise NodeError("INVALID_ADDRESS", "New clients use 10.77.10.2–249, excluding 10, 20, 30")
    for client in listing["clients"]:
        for allowed in client["allowed_ips"]:
            network = ipaddress.ip_network(allowed, strict=False)
            candidate = ipaddress.ip_address(f"10.77.10.{number}" if network.version == 4 else f"fd77:77:10::{number}")
            if candidate in network:
                raise NodeError("ADDRESS_IN_USE", "Client address overlaps existing AllowedIPs")
    body = read("/etc/wireguard/cne-users.conf")
    metadata = json_read(CLIENTS, {"version": 1, "clients": []})
    old_metadata = json.dumps(metadata)
    backup_path, _ = backup(role, "before-client-add")
    fields = {"PublicKey": public, "PresharedKey": psk,
              "AllowedIPs": f"10.77.10.{number}/32, fd77:77:10::{number}/128"}
    stanza = "\n[Peer]\n" + "".join(f"{field} = {value}\n" for field, value in fields.items())
    active = wg_running()
    try:
        atomic_write("/etc/wireguard/cne-users.conf", body.rstrip() + "\n" + stanza)
        if active:
            runtime_peer(fields)
        metadata["clients"].append({"name": name, "public_key": public, "address": f"10.77.10.{number}/32"})
        json_write(CLIENTS, metadata)
    except Exception:
        atomic_write("/etc/wireguard/cne-users.conf", body)
        atomic_write(CLIENTS, old_metadata + "\n")
        if active:
            with contextlib.suppress(NodeError):
                runtime_peer(fields, remove=True)
        raise
    return {"added": True, "name": name, "public_key": public, "address": f"10.77.10.{number}/32",
            "ipv6_address": f"fd77:77:10::{number}/128", "backup": backup_path,
            "applied_runtime": active}


def client_remove(role, request):
    listing = client_list(role)
    public = request.get("public_key")
    if public and request.get("name"):
        matches = [item for item in listing["clients"]
                   if item["public_key"] == public and item["name"] == request["name"]]
        if len(matches) != 1:
            raise NodeError("CLIENT_NOT_FOUND", "Client public key and name do not match")
    if not public:
        matches = [item for item in listing["clients"] if item["name"] == request.get("name")]
        if len(matches) != 1:
            raise NodeError("CLIENT_NOT_FOUND", "Specify an unambiguous client name or public key")
        public = matches[0]["public_key"]
    key(public)
    registry = json_read(CLIENTS, {"clients": []})
    if not any(item.get("public_key") == public for item in registry.get("clients", [])):
        raise NodeError("UNMANAGED_CLIENT", "Legacy client is not owned by this manager and is preserved")
    body = read("/etc/wireguard/cne-users.conf")
    chunks = peer_blocks(body)
    selected = [fields for _, fields in chunks if fields.get("PublicKey") == public]
    if len(selected) != 1:
        raise NodeError("CLIENT_NOT_FOUND", "Client is missing or duplicated in WireGuard configuration")
    replacement = "".join(chunk for chunk, fields in chunks if fields.get("PublicKey") != public)
    metadata = json_read(CLIENTS, {"version": 1, "clients": []})
    old_metadata = json.dumps(metadata)
    backup_path, _ = backup(role, "before-client-remove")
    active = wg_running()
    try:
        atomic_write("/etc/wireguard/cne-users.conf", replacement)
        if active:
            runtime_peer(selected[0], remove=True)
        metadata["clients"] = [client for client in metadata["clients"] if client["public_key"] != public]
        json_write(CLIENTS, metadata)
    except Exception:
        atomic_write("/etc/wireguard/cne-users.conf", body)
        atomic_write(CLIENTS, old_metadata + "\n")
        if active:
            with contextlib.suppress(NodeError):
                runtime_peer(selected[0])
        raise
    return {"removed": True, "public_key": public, "backup": backup_path, "applied_runtime": active}


@contextlib.contextmanager
def mutation_lock():
    target = safe_path("/run/lock/cn-egress-oneclick.lock")
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a+") as stream:
        os.fchmod(stream.fileno(), 0o600)
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise NodeError("NODE_BUSY", "Another management action is in progress") from exc
        try:
            yield
        finally:
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def preflight_action(role, request):
    files = validate_files(role, request.get("files"))
    plan = preflight(role, files)
    return {"ready": True, "dependency_packages": plan["packages"],
            "dependency_metadata_refresh": plan["metadata_refresh"], "host_forwarding": forwarding()}


def management_backup(role):
    require_role(role, managed=True)
    return {"backup": backup(role)[0]}


def dispatch(request):
    """No subprocess or private file is returned except the explicit inspect RPC."""
    action = request.get("action") if isinstance(request, dict) else None
    role = request.get("role") if isinstance(request, dict) else None
    response = {"ok": False, "action": action, "role": role}
    try:
        if os.geteuid() != 0:
            raise NodeError("ROOT_REQUIRED", "Run the node executor with sudo/root")
        if role not in ROLES:
            raise NodeError("INVALID_ROLE", "role must be hk, sh or exit")
        handlers = {"inspect": lambda: inspect(role, request), "status": lambda: status(role),
                    "doctor": lambda: doctor(role), "logs": lambda: logs(role, request),
                    "start": lambda: service_action(role, "start"),
                    "stop": lambda: service_action(role, "stop"),
                    "restart": lambda: service_action(role, "restart"),
                    "backup": lambda: management_backup(role),
                    "adopt": lambda: adopt(role, request),
                    "install": lambda: install(role, request),
                    "uninstall": lambda: uninstall(role, request),
                    "preflight": lambda: preflight_action(role, request),
                    "keygen": lambda: keygen(role, request),
                    "client_list": lambda: client_list(role),
                    "client_add": lambda: client_add(role, request),
                    "client_remove": lambda: client_remove(role, request)}
        if action not in handlers:
            raise NodeError("INVALID_ACTION", "Unsupported action")
        if action in {"install", "adopt", "uninstall", "start", "stop", "restart",
                      "backup", "client_add", "client_remove", "keygen"}:
            with mutation_lock():
                response.update(ok=True, data=handlers[action]())
        else:
            response.update(ok=True, data=handlers[action]())
    except NodeError as exc:
        response["error"] = {"code": exc.code, "message": redact(str(exc))}
    except Exception as exc:
        # A traceback could include input keys/configuration.  Keep diagnostics
        # private on the node and return only the exception class.
        response["error"] = {"code": "NODE_FAILED", "message": type(exc).__name__}
    return response


def local_cli(command="menu"):
    """A local root menu exposes safe operations without private inspect RPCs."""
    if os.geteuid() != 0:
        print("请用 sudo cn-egress 运行管理菜单。", file=sys.stderr)
        return 1
    manifest = json_read(MANIFEST, {})
    role = manifest.get("role") or existing_role()
    if role not in ROLES:
        print("此机器尚未部署；请使用中央一键脚本安装或接管。", file=sys.stderr)
        return 1
    choices = {"1": "status", "2": "doctor", "3": "start", "4": "stop",
               "5": "restart", "6": "logs", "7": "backup", "8": "uninstall"}
    permitted = set(choices.values())
    menu = command == "menu"
    while True:
        if menu:
            print(f"\n国内出口管理（{role}）\n1 状态  2 检查  3 启动  4 停止\n5 重启  6 日志  7 备份  8 卸载  0 退出")
            try:
                selected = input("选择：").strip()
            except (EOFError, KeyboardInterrupt):
                return 0
            if selected == "0":
                return 0
            command = choices.get(selected)
            if command is None:
                print("请输入菜单中的数字。")
                continue
        if command not in permitted:
            print("支持命令：menu/status/doctor/start/stop/restart/logs/backup/uninstall", file=sys.stderr)
            return 2
        request = {"action": command, "role": role}
        if command == "uninstall":
            try:
                confirmation = input("卸载将停止此节点 VPN。输入 UNINSTALL 确认：")
            except (EOFError, KeyboardInterrupt):
                confirmation = ""
            if confirmation != "UNINSTALL":
                print("已取消卸载。")
                if menu:
                    continue
                return 1
            request["confirm"] = True
        reply = dispatch(request)
        if reply["ok"] and command == "logs":
            print("\n".join(reply["data"]["lines"]))
        else:
            print(json.dumps(reply.get("data") if reply["ok"] else reply["error"], ensure_ascii=False, indent=2))
        if not menu or (command == "uninstall" and reply["ok"]):
            return 0 if reply["ok"] else 1


def read_request(content):
    """Accept JSON, or one unused sudo password line followed by JSON.

    sudo -S can leave its password line unread when authentication is cached or
    NOPASSWD applies.  Never echo that prefix and never discard multiple lines.
    """
    if not isinstance(content, bytes) or len(content) > 40 * 1024 * 1024:
        raise ValueError("request too large or invalid")
    try:
        value = json.loads(content)
    except (ValueError, UnicodeDecodeError):
        head, separator, tail = content.partition(b"\n")
        if not separator or not head.strip() or head.lstrip().startswith((b"{", b"[")):
            raise ValueError("invalid request framing")
        value = json.loads(tail)
    if not isinstance(value, dict):
        raise ValueError("request must be an object")
    return value


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--local":
    raise SystemExit(local_cli(sys.argv[2] if len(sys.argv) > 2 else "menu"))
elif __name__ == "__main__":
    try:
        content = sys.stdin.buffer.read(40 * 1024 * 1024 + 1)
        reply = dispatch(read_request(content))
    except Exception:
        reply = {"ok": False, "error": {"code": "INVALID_REQUEST", "message": "Expected one JSON request"}}
    sys.stdout.write(json.dumps(reply, ensure_ascii=False, separators=(",", ":")) + "\n")
