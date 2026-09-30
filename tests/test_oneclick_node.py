"""Owner-scope and rollback tests; no test executes commands on real hosts."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid


SOURCE = Path(__file__).resolve().parents[1] / "oneclick" / "node.py"
SPEC = importlib.util.spec_from_file_location("oneclick_test_node", SOURCE)
node = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(node)


def public(seed):
    return base64.b64encode(bytes([seed]) * 32).decode()


SERVER, OLD, NEW, PSK = public(1), public(2), public(3), public(4)


class FakeSystem:
    def __init__(self):
        self.calls = []
        self.running = False
        self.fail_command = None
        self.fail_once = False
        self.broken_dpkg = False
        self.apt_plan = ""
        self.apt_missing_metadata = False
        self.route_overlap = False
        self.occupied_ports = ""
        self.logs = "normal log\nPrivateKey = " + PSK + "\nPresharedKey = " + NEW + "\n"
        self.namespace = ""
        self.foreign_namespace = False

    def run(self, args, *, check=False, input=None, timeout=30):
        self.calls.append((list(args), input))
        code, output, error = 0, "", ""
        if self.fail_command and args == self.fail_command:
            code, error = 1, "simulated failure"
            if self.fail_once:
                self.fail_command = None
        elif args[:3] == ["systemctl", "is-active", args[-1]]:
            output = "active\n"
        elif args[:2] == ["systemctl", "is-enabled"]:
            output = "enabled\n"
        elif args == ["ip", "netns", "list"]:
            output = self.namespace
        elif args[:4] == ["ip", "-j", "-n", node.NS]:
            names = ["lo", "cne-cn", "cne-users"] + (["foreign0"] if self.foreign_namespace else [])
            output = json.dumps([{"ifname": name} for name in names])
        elif args[:3] == ["ip", "link", "show"]:
            code = 1
        elif args[:3] == ["ip", "-n", node.NS] and "link" in args:
            code = 0 if self.running else 1
        elif args[:3] == ["nft", "list", "table"] or args == ["iptables", "-S", "CNE_VPN"]:
            code = 1
        elif args == ["ip", "-j", "route", "show", "default"]:
            output = '[{"dst":"default","gateway":"10.0.0.1","dev":"eth0"}]'
        elif args[:2] == ["ip", "-j"] or args[:3] == ["ip", "-6", "-j"]:
            output = '[{"dst":"10.77.30.0/30","dev":"office0"}]' if self.route_overlap else "[]"
        elif args in node.SNAPSHOTS.values():
            output = "default via 10.0.0.1 dev eth0\n" if "route" in args else "original-state\n"
        elif args[:2] == ["ss", "-H"]:
            output = self.occupied_ports
        elif args[:2] == ["dpkg", "--audit"]:
            output = "unconfigured unrelated AI package" if self.broken_dpkg else ""
        elif args[:2] == ["apt-get", "-s"]:
            if self.apt_missing_metadata:
                code, error = 100, "E: Unable to locate package wireguard-tools"
            else:
                output = self.apt_plan
        elif args == ["apt-get", "update"]:
            self.apt_missing_metadata = False
        elif args[:2] == ["wg", "genkey"]:
            output = NEW + "\n"
        elif args[:2] == ["wg", "pubkey"]:
            output = SERVER + "\n"
        elif args[:4] == ["ip", "netns", "exec", node.NS] and "wg" in args:
            if "public-key" in args:
                output = SERVER + "\n"
            elif args[-1] == "endpoints":
                output = OLD + "\t203.0.113.4:40000\n"
            elif args[-1] == "latest-handshakes":
                output = OLD + "\t1234567890\n"
            elif args[-1] == "transfer":
                output = OLD + "\t1000\t2000\n"
            elif args[-1] == "allowed-ips":
                output = OLD + "\t10.77.10.10/32\tfd77:77:10::10/128\n"
        elif args[0] == "journalctl":
            output = self.logs
        result = subprocess.CompletedProcess(args, code, output, error)
        if check and code:
            raise node.NodeError("COMMAND_FAILED", error)
        return result


class NodeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cn-egress-node-test-")
        self.root = Path(self.directory.name)
        self.system = FakeSystem()
        self.patches = [patch.object(node, "ROOT", self.root),
                        patch.object(node, "run", self.system.run),
                        patch.object(node.os, "geteuid", return_value=0),
                        patch.object(node.os, "chown"),
                        patch.object(node.shutil, "which", side_effect=lambda command: "/mock/" + command),
                        patch.object(node.platform, "system", return_value="Linux"),
                        patch.object(node.platform, "machine", return_value="x86_64"),
                        patch.object(node, "setup_transport_user", return_value=os.getgid())]
        for item in self.patches:
            item.start()
        self.write("/etc/os-release", 'ID=debian\nVERSION_ID="12"\n')
        self.write("/etc/machine-id", "test-host-id\n")
        self.write("/proc/sys/net/ipv4/ip_forward", "1\n")
        self.write("/proc/sys/net/ipv6/conf/all/forwarding", "0\n")
        (self.root / "run/systemd/system").mkdir(parents=True)

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.directory.cleanup()

    def write(self, path, body):
        target = self.root / path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body if isinstance(body, bytes) else body.encode())
        return target

    def payload(self, role):
        addresses = {("hk", "cne-users"): "10.77.10.1/24, fd77:77:10::1/64",
                     ("hk", "cne-cn"): "10.77.20.1/30, fd77:77:20::1/64",
                     ("sh", "cne-cn"): "10.77.20.2/30, fd77:77:20::2/64",
                     ("sh", "cne-exit"): "10.77.30.1/30, fd77:77:30::1/64",
                     ("exit", "cne-exit"): "10.77.30.2/30, fd77:77:30::2/64"}
        files = {}
        for path in node.allowed_files(role) - {"/etc/sysctl.d/90-cn-egress.conf"}:
            body, mode = b"deployment-content\n", 0o600
            if path == node.BINARY:
                body, mode = b"\x7fELFmockofficialbinary", 0o755
            elif path.startswith("/etc/wireguard/"):
                interface = Path(path).stem
                body = f"[Interface]\nPrivateKey = {PSK}\nAddress = {addresses[(role, interface)]}\nTable = off\n"
                if interface == "cne-users":
                    body += "ListenPort = 51820\n"
                    body += f"\n[Peer]\nPublicKey = {OLD}\nPresharedKey = {PSK}\nAllowedIPs = 10.77.10.10/32, fd77:77:10::10/128\n"
                elif role in {"hk", "exit"}:
                    body += f"\n[Peer]\nPublicKey = {OLD}\nPresharedKey = {PSK}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 127.0.0.1:{51831 if role == 'hk' else 51832}\n"
                body = body.encode()
            elif path == "/etc/cn-egress-wss/role":
                body = (role + "\n").encode()
            elif path == "/etc/cn-egress/wan-interface":
                body = b"eth0\n"
            elif path == "/etc/cn-egress-wss/sh-host":
                body = b"198.51.100.20\n"
            elif path == "/etc/cn-egress-wss/port":
                body = b"443\n"
            elif path == "/etc/systemd/system/cn-egress.service":
                body = f"[Service]\nExecStart=/usr/local/sbin/cn-egress-net start {role}\n".encode()
            elif path == "/usr/local/sbin/cn-egress-net":
                body = b"# cn-egress-relay; ip netns exec\n"
            files[path] = {"content": base64.b64encode(body).decode(), "mode": mode}
            if path == node.BINARY:
                files[path]["sha256"] = hashlib.sha256(body).hexdigest()
        return files

    def existing(self, role="hk", managed=True):
        files = self.payload(role)
        for path, spec in files.items():
            self.write(path, base64.b64decode(spec["content"]))
        if managed:
            self.write(node.MANIFEST, json.dumps({"version": 1, "role": role,
                                                "machine_id": "test-host-id", "origin": "adopted-existing",
                                                "owned_files": sorted(node.allowed_files(role) | {node.MANIFEST, node.CLIENTS})}))
            self.write(node.CLIENTS, '{"version":1,"clients":[]}')
        return files

    def rpc(self, action, role="hk", **kwargs):
        return node.dispatch({"action": action, "role": role, **kwargs})

    def test_inspect_is_public_by_default_and_private_only_on_opt_in(self):
        self.existing()
        reply = self.rpc("inspect")
        self.assertTrue(reply["ok"], reply)
        self.assertNotIn("private_files", reply["data"])
        self.assertNotIn(PSK, json.dumps(reply))
        self.assertEqual(SERVER, reply["data"]["server_public"])
        private = self.rpc("inspect", include_private=True)
        self.assertIn("/etc/wireguard/cne-users.conf", private["data"]["private_files"])

    def test_standard_os_release_symlink_is_read_only_supported(self):
        self.write("/usr/lib/os-release", "ID=debian\nVERSION_ID=12\n")
        (self.root / "etc/os-release").unlink()
        (self.root / "etc/os-release").symlink_to("../usr/lib/os-release")
        self.assertEqual("debian", self.rpc("inspect")["data"]["os_release"]["ID"])

    def test_role_mismatch_and_nonroot_are_rejected_before_mutation(self):
        self.existing()
        self.assertEqual("ROLE_MISMATCH", self.rpc("inspect", role="sh")["error"]["code"])
        with patch.object(node.os, "geteuid", return_value=501):
            self.assertEqual("ROOT_REQUIRED", self.rpc("stop")["error"]["code"])

    def test_adopt_preserves_keys_routes_and_never_restarts_services(self):
        self.existing(managed=False)
        original = (self.root / "etc/wireguard/cne-users.conf").read_bytes()
        response = self.rpc("adopt", files={node.ENTRY: {"content": base64.b64encode(b"#!/bin/sh\n").decode(), "mode": 0o755}})
        self.assertTrue(response["ok"], response)
        self.assertEqual(original, (self.root / "etc/wireguard/cne-users.conf").read_bytes())
        self.assertFalse(any(command[0] == "systemctl" and command[1] in {"start", "stop", "restart", "daemon-reload"}
                             for command, _ in self.system.calls))
        manifest = json.loads((self.root / node.MANIFEST.lstrip("/")).read_text())
        self.assertIsNone(manifest["original_forwarding"])
        self.assertEqual("adopted-existing", manifest["origin"])

    def test_adopt_does_not_accept_network_or_secret_overrides(self):
        self.existing()
        response = self.rpc("adopt", files={"/etc/wireguard/cne-users.conf": {"content": "", "mode": 0o600}})
        self.assertEqual("INVALID_PATH", response["error"]["code"])

    def test_file_traversal_wrong_role_symlink_and_binary_digest_fail(self):
        for path in ("/etc/passwd", "/etc/wireguard/cne-exit.conf", "/etc/cn-egress/../passwd"):
            with self.assertRaises(node.NodeError):
                node.validate_files("hk", {path: {"content": "", "mode": 0o600}}, adopt=True)
        self.write("/etc/cn-egress-wss/node.key", "secret")
        keypath = self.root / "etc/cn-egress-wss/node.key"
        keypath.unlink()
        keypath.symlink_to(self.root / "etc/machine-id")
        with self.assertRaises(node.NodeError):
            node.safe_path("/etc/cn-egress-wss/node.key")
        files = self.payload("hk")
        files[node.BINARY]["sha256"] = "0" * 64
        keypath.unlink()
        with self.assertRaisesRegex(node.NodeError, "SHA256"):
            node.validate_files("hk", files)

    def test_fresh_preflight_refuses_existing_deployment_and_exit_forwarding_change(self):
        self.existing()
        response = self.rpc("preflight", files=self.payload("hk"))
        self.assertEqual("ALREADY_INSTALLED", response["error"]["code"])
        # Use a separate empty owner scope for exit checks.
        with tempfile.TemporaryDirectory() as other, patch.object(node, "ROOT", Path(other)):
            for path, body in (("/etc/os-release", "ID=debian\n"), ("/proc/sys/net/ipv4/ip_forward", "0\n"), ("/proc/sys/net/ipv6/conf/all/forwarding", "0\n")):
                target = Path(other) / path.lstrip("/")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body)
            (Path(other) / "run/systemd/system").mkdir(parents=True)
            response = self.rpc("preflight", role="exit", files=self.payload("exit"))
            self.assertEqual("FORWARDING_BLOCKED", response["error"]["code"])
        self.assertFalse(any(command[:2] == ["sysctl", "-q"] for command, _ in self.system.calls))

    def test_preflight_refuses_transit_subnet_overlap_and_occupied_port(self):
        self.system.route_overlap = True
        response = self.rpc("preflight", role="exit", files=self.payload("exit"))
        self.assertEqual("NETWORK_CONFLICT", response["error"]["code"])
        self.system.route_overlap = False
        self.system.occupied_ports = "tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n"
        response = self.rpc("preflight", role="sh", files=self.payload("sh"))
        self.assertEqual("PORT_IN_USE", response["error"]["code"])

    def test_broken_package_manager_is_not_repaired(self):
        self.system.broken_dpkg = True
        with patch.object(node.shutil, "which", side_effect=lambda tool: None if tool == "wg" else "/mock/" + tool):
            response = self.rpc("preflight", files=self.payload("hk"))
        self.assertEqual("DEPENDENCIES_BLOCKED", response["error"]["code"])
        self.assertFalse(any(command[0] == "apt-get" and "-y" in command for command, _ in self.system.calls))

    def test_minimal_dependency_plan_distinguishes_architecture_from_upgrade(self):
        self.system.apt_plan = "Inst wireguard-tools (1.0 Debian:stable [amd64])\n"
        with patch.object(node.shutil, "which", side_effect=lambda tool: None if tool == "wg" else "/mock/" + tool):
            response = self.rpc("preflight", files=self.payload("hk"))
        self.assertTrue(response["ok"], response)
        self.assertEqual(["wireguard-tools"], response["data"]["dependency_packages"])
        self.system.apt_plan = "Inst libc6 [2.31] (2.36 Debian:stable [amd64])\n"
        with patch.object(node.shutil, "which", side_effect=lambda tool: None if tool == "wg" else "/mock/" + tool):
            response = self.rpc("preflight", files=self.payload("hk"))
        self.assertEqual("DEPENDENCIES_BLOCKED", response["error"]["code"])

    def test_empty_apt_lists_are_refreshed_only_during_dependency_install(self):
        self.system.apt_missing_metadata = True
        self.system.apt_plan = "Inst wireguard-tools (1.0 Debian:stable [amd64])\n"
        with patch.object(node.shutil, "which", side_effect=lambda tool: None if tool == "wg" else "/mock/" + tool):
            planned = self.rpc("preflight", files=self.payload("hk"))
            self.assertTrue(planned["ok"], planned)
            self.assertTrue(planned["data"]["dependency_metadata_refresh"])
            self.assertFalse(any(command == ["apt-get", "update"] for command, _ in self.system.calls))
            generated = self.rpc("keygen", count=1)
        self.assertTrue(generated["ok"], generated)
        commands = [command for command, _ in self.system.calls]
        self.assertEqual(1, commands.count(["apt-get", "update"]))
        install = [command for command in commands if command[:2] == ["apt-get", "-y"]]
        self.assertEqual(1, len(install))
        self.assertEqual("wireguard-tools", install[0][-1])

    def test_exit_route_audit_allows_owned_links_but_rejects_vpn_host_default(self):
        before = {key: "default via 10.0.0.1 dev eth0\n" if key.startswith("routes") else "rules\n"
                  for key in ("routes4", "routes6", "rules4", "rules6")}
        after = dict(before)
        after["routes4"] += "10.77.30.0/30 dev cne-exit proto kernel scope link src 10.77.30.2\n"
        after["routes6"] += "ff00::/8 dev cne-exit table local metric 256\n"
        with patch.object(node, "route_baseline", return_value=after):
            self.assertTrue(node.preserved_routes(before, "exit"))
        after["routes4"] += "default dev cne-exit metric 1\n"
        with patch.object(node, "route_baseline", return_value=after):
            self.assertFalse(node.preserved_routes(before, "exit"))

    def test_duplicate_table_or_server_dns_hook_cannot_mutate_host_routes(self):
        for unsafe in ("Table = off\nTable = auto\n", "Table = off\nDNS = 1.1.1.1\n"):
            files = self.payload("exit")
            path = "/etc/wireguard/cne-exit.conf"
            body = base64.b64decode(files[path]["content"]).decode().replace("Table = off\n", unsafe)
            files[path]["content"] = base64.b64encode(body.encode()).decode()
            response = self.rpc("preflight", role="exit", files=files)
            self.assertEqual("UNSAFE_CONFIG", response["error"]["code"])

    def test_fresh_install_registers_clients_binary_traversable_and_no_host_sysctl(self):
        response = self.rpc("install", files=self.payload("hk"), deployment_id=str(uuid.uuid4()),
                            client_registry=[{"name": "iPhone", "public_key": OLD, "address": "10.77.10.10/32"}])
        self.assertTrue(response["ok"], response)
        manifest = json.loads((self.root / node.MANIFEST.lstrip("/")).read_text())
        self.assertEqual("fresh-install", manifest["origin"])
        registry = json.loads((self.root / node.CLIENTS.lstrip("/")).read_text())
        self.assertEqual(OLD, registry["clients"][0]["public_key"])
        for path in ("opt/cn-egress", "opt/cn-egress/wstunnel-11.0.0"):
            self.assertEqual(0o755, stat.S_IMODE((self.root / path).stat().st_mode))
        self.assertFalse(any(command[0] == "sysctl" and "-w" in command for command, _ in self.system.calls))

    def test_failed_install_rolls_back_only_owned_files_and_keeps_backup(self):
        original = self.write("/etc/unrelated-service.conf", "keep me\n")
        self.system.fail_command = ["systemctl", "start", "cn-egress.service"]
        self.system.fail_once = True
        response = self.rpc("install", files=self.payload("hk"), deployment_id=str(uuid.uuid4()))
        self.assertFalse(response["ok"])
        self.assertFalse((self.root / node.MANIFEST.lstrip("/")).exists())
        self.assertFalse((self.root / "etc/wireguard/cne-users.conf").exists())
        self.assertEqual("keep me\n", original.read_text())
        self.assertTrue(list((self.root / "root").glob("cn-egress-oneclick-backup-*")))
        self.assertFalse(any("flush" in command or command[:3] == ["nft", "flush", "ruleset"] for command, _ in self.system.calls))

    def test_invalid_initial_registry_cannot_leave_manifest_after_rollback(self):
        response = self.rpc("install", files=self.payload("hk"), deployment_id=str(uuid.uuid4()),
                            client_registry=[{"name": "wrong", "public_key": NEW, "address": "10.77.10.10/32"}])
        self.assertEqual("CLIENT_NOT_FOUND", response["error"]["code"])
        self.assertFalse((self.root / node.MANIFEST.lstrip("/")).exists())

    def test_add_remove_manage_only_target_and_preserve_legacy_peer(self):
        self.existing()
        self.system.running = True
        before = (self.root / "etc/wireguard/cne-users.conf").read_text()
        added = self.rpc("client_add", name="测试手机", public_key=NEW, preshared_key=PSK)
        self.assertTrue(added["ok"], added)
        self.assertEqual("10.77.10.2/32", added["data"]["address"])
        body = (self.root / "etc/wireguard/cne-users.conf").read_text()
        self.assertTrue(body.startswith(before.rstrip()))
        self.assertNotIn(PSK, json.dumps(added))
        removed = self.rpc("client_remove", name="测试手机", public_key=NEW)
        self.assertTrue(removed["ok"], removed)
        body = (self.root / "etc/wireguard/cne-users.conf").read_text()
        self.assertIn(OLD, body)
        self.assertNotIn(NEW, body)
        commands = [command for command, _ in self.system.calls]
        self.assertFalse(any("setconf" in command or "syncconf" in command for command in commands))
        self.assertFalse(any("remove" in command and OLD in command for command in commands))

    def test_add_revalidates_overlapping_actual_allowedips(self):
        self.existing()
        config = self.root / "etc/wireguard/cne-users.conf"
        config.write_text(config.read_text().replace("10.77.10.10/32", "10.77.10.0/28"))
        response = self.rpc("client_add", name="another", public_key=NEW, preshared_key=PSK, address="10.77.10.2")
        self.assertEqual("ADDRESS_IN_USE", response["error"]["code"])
        self.assertEqual("10.77.10.16", self.rpc("client_list")["data"]["next_address"])

    def test_remove_rejects_unmanaged_and_name_key_mismatch(self):
        self.existing()
        response = self.rpc("client_remove", public_key=OLD)
        self.assertEqual("UNMANAGED_CLIENT", response["error"]["code"])
        response = self.rpc("client_remove", name="other", public_key=OLD)
        self.assertEqual("CLIENT_NOT_FOUND", response["error"]["code"])

    def test_runtime_client_failure_restores_config_and_registry(self):
        self.existing()
        self.system.running = True
        before = (self.root / "etc/wireguard/cne-users.conf").read_bytes()
        original_run = self.system.run
        def fail_peer(args, **kwargs):
            if "preshared-key" in args:
                raise node.NodeError("COMMAND_FAILED", "simulated wg failure")
            return original_run(args, **kwargs)
        with patch.object(node, "run", side_effect=fail_peer):
            response = self.rpc("client_add", name="fail", public_key=NEW, preshared_key=PSK)
        self.assertFalse(response["ok"])
        self.assertEqual(before, (self.root / "etc/wireguard/cne-users.conf").read_bytes())
        self.assertEqual([], json.loads((self.root / node.CLIENTS.lstrip("/")).read_text())["clients"])

    def test_logs_limit_and_redact_secrets_and_status_avoids_dump(self):
        self.existing()
        self.system.logs += "-----BEGIN PRIVATE KEY-----\nVERYSECRETTLS\n-----END PRIVATE KEY-----\n"
        response = self.rpc("logs", lines=10000)
        self.assertTrue(response["ok"])
        serialized = json.dumps(response)
        self.assertNotIn(PSK, serialized)
        self.assertNotIn(NEW, serialized)
        self.assertNotIn("VERYSECRETTLS", serialized)
        self.assertLessEqual(len(response["data"]["lines"]), 100)
        self.assertTrue(self.rpc("status")["ok"])
        self.assertFalse(any("dump" in command or "showconf" in command for command, _ in self.system.calls))

    def test_uninstall_is_explicit_owner_bound_and_preserves_original_forwarding(self):
        self.existing("exit")
        self.write("/etc/sysctl.d/90-cn-egress.conf", "net.ipv4.ip_forward = 1\n")
        self.assertEqual("CONFIRM_REQUIRED", self.rpc("uninstall", role="exit")["error"]["code"])
        self.assertEqual("OWNER_MISMATCH", self.rpc("uninstall", role="exit", confirm=True, deployment_id="wrong")["error"]["code"])
        response = self.rpc("uninstall", role="exit", confirm=True)
        self.assertTrue(response["ok"], response)
        self.assertTrue((self.root / node.BINARY.lstrip("/")).exists())
        self.assertTrue((self.root / "etc/sysctl.d/90-cn-egress.conf").exists())
        self.assertEqual("1\n", (self.root / "proc/sys/net/ipv4/ip_forward").read_text())
        self.assertFalse(any(command[0] == "sysctl" and "-w" in command for command, _ in self.system.calls))

    def test_uninstall_refuses_foreign_namespace_and_keeps_config(self):
        self.existing()
        self.system.namespace = node.NS + "\n"
        self.system.foreign_namespace = True
        response = self.rpc("uninstall", confirm=True)
        self.assertEqual("OWNER_CONFLICT", response["error"]["code"])
        self.assertTrue((self.root / "etc/wireguard/cne-users.conf").exists())

    def test_fresh_uninstall_restores_preexisting_entry_and_removes_only_new_files(self):
        original_entry = self.write(node.ENTRY, "original administrator entry\n")
        unrelated = self.write("/etc/service-original.conf", "original service\n")
        installed = self.rpc("install", files=self.payload("hk"), deployment_id=str(uuid.uuid4()))
        self.assertTrue(installed["ok"], installed)
        removed = self.rpc("uninstall", confirm=True, expected_origin="fresh-install")
        self.assertTrue(removed["ok"], removed)
        self.assertEqual("original administrator entry\n", original_entry.read_text())
        self.assertEqual("original service\n", unrelated.read_text())
        self.assertFalse((self.root / "etc/wireguard/cne-users.conf").exists())
        self.assertFalse((self.root / node.BINARY.lstrip("/")).exists())

    def test_foreign_management_marker_cannot_be_re_adopted(self):
        self.existing()
        marker = self.root / node.MANIFEST.lstrip("/")
        body = json.loads(marker.read_text())
        body["machine_id"] = "another-machine"
        marker.write_text(json.dumps(body))
        self.assertEqual("HOST_MISMATCH", self.rpc("adopt", files={})["error"]["code"])

    def test_keygen_is_private_explicit_and_bounded(self):
        response = self.rpc("keygen", count=2)
        self.assertEqual([{"private": NEW, "public": SERVER}] * 2, response["data"]["keys"])
        self.assertEqual("INVALID_REQUEST", self.rpc("keygen", count=33)["error"]["code"])
        self.assertEqual("WRONG_ROLE", self.rpc("keygen", role="exit")["error"]["code"])

    def test_lock_prevents_concurrent_changes(self):
        with node.mutation_lock():
            response = self.rpc("keygen")
        self.assertEqual("NODE_BUSY", response["error"]["code"])

    def test_local_uninstall_requires_literal_confirmation(self):
        self.existing()
        with patch("builtins.input", return_value="no"), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, node.local_cli("uninstall"))
        self.assertTrue((self.root / node.MANIFEST.lstrip("/")).exists())

    def test_request_framing_handles_cached_sudo_without_echoing_password(self):
        request = {"action": "status", "role": "hk"}
        content = json.dumps(request).encode()
        self.assertEqual(request, node.read_request(content))
        self.assertEqual(request, node.read_request(b"secret-pass\n" + content))
        self.assertEqual(request, node.read_request(b"\n" + content))
        for invalid in (b"secret-pass\nsecond-prefix\n" + content,
                        b'{"bad-json":\n' + content, b"[]", b"secret-pass\n"):
            with self.assertRaises(ValueError):
                node.read_request(invalid)


if __name__ == "__main__":
    unittest.main()
