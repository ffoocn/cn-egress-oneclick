"""Tests for route isolation, per-peer credentials, PKI and verified downloads."""
import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import ssl
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from oneclick import render

ASSETS = Path(__file__).resolve().parents[1] / "oneclick" / "assets"


def keys():
    def key(number):
        return base64.b64encode(bytes([number]) * 32).decode()
    result = {
        name: {"private": key(2 * number + 1), "public": key(2 * number + 2)}
        for number, name in enumerate(("hk_users", "hk_cn", "sh_cn", "sh_exit", "exit", "iphone", "android", "windows", "us_test"))
    }
    result["psks"] = {name: key(number + 100) for number, name in enumerate(("hk_sh", "sh_exit", "iphone", "android", "windows", "us_test"))}
    return result


def topology(host="198.51.100.20"):
    return {"hk": {"host": "203.0.113.10"}, "sh": {"host": host},
            "exit": {"host": "192.168.1.2", "wan": "eth0"},
            "transport": "wss", "wss_port": 443, "user_port": 51820}


def text(files, path):
    record = files[path]
    raw = base64.b64decode(record["content"], validate=True)
    if hashlib.sha256(raw).hexdigest() != record["sha256"]:
        raise AssertionError("Payload digest mismatch")
    return raw.decode()


class RenderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.pki_path = Path(cls.temp.name)
        with unittest.TestCase().assertWarns(UserWarning):
            cls.pki = render.generate_pki(topology(), cls.pki_path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def plan(self, nodes=None, material=None):
        return render.make_plan(nodes or topology(), material or keys(), self.pki, ASSETS, b"verified binary")

    def test_server_payload_preserves_host_route_design(self):
        plan = self.plan()
        self.assertEqual(set(plan), {"hk", "sh", "exit"})
        for role, configs in {"hk": ("cne-cn", "cne-users"), "sh": ("cne-cn", "cne-exit"), "exit": ("cne-exit",)}.items():
            for interface in configs:
                wg = text(plan[role], f"/etc/wireguard/{interface}.conf")
                self.assertIn("Table = off\n", wg)
                self.assertNotIn("PostUp", wg)
                self.assertEqual(plan[role][f"/etc/wireguard/{interface}.conf"]["mode"], 0o600)
            self.assertFalse(any(path.startswith("/etc/sysctl.d/") for path in plan[role]))
        for role in ("hk", "sh"):
            manager = text(plan[role], "/usr/local/sbin/cn-egress-net")
            self.assertIn('ip link set "$interface" netns "$relay_ns"', manager)
            self.assertIn("net sysctl -q -w net.ipv4.ip_forward=1", manager)
            self.assertIn('iif "$incoming" lookup "$table"', manager)
            self.assertIn("unreachable default metric", manager)
        self.assertIn("Endpoint = 127.0.0.1:51831\n", text(plan["hk"], "/etc/wireguard/cne-cn.conf"))
        self.assertIn("Endpoint = 127.0.0.1:51832\n", text(plan["exit"], "/etc/wireguard/cne-exit.conf"))
        exit_firewall = text(plan["exit"], "/etc/cn-egress/firewall.nft")
        self.assertIn('iifname "cne-exit" ip saddr 10.77.10.0/24 oifname "eth0" counter masquerade', exit_firewall)
        self.assertIn('iifname "cne-exit" meta nfproto ipv6 counter reject', exit_firewall)

    def test_mtls_restricts_each_identity_to_owned_loopback_port(self):
        plan = self.plan()
        restrictions = text(plan["sh"], "/etc/cn-egress-wss/restrictions.yaml")
        self.assertIn('!PathPrefix "^cn-egress-hk$"', restrictions)
        self.assertIn('!PathPrefix "^cn-egress-exit$"', restrictions)
        self.assertEqual(restrictions.count('cidr: ["127.0.0.1/32"]'), 2)
        self.assertNotIn("ReverseTunnel", restrictions)
        self.assertIn('port: ["51821"]', restrictions)
        self.assertIn('port: ["51822"]', restrictions)
        self.assertIn('iifname != "lo" udp dport { 51821, 51822 } counter drop', text(plan["sh"], "/etc/cn-egress-wss/guard.nft"))
        for role in plan:
            self.assertNotIn("/etc/cn-egress-wss/ca.key", plan[role])
            self.assertEqual(plan[role]["/etc/cn-egress-wss/node.key"]["mode"], 0o640)
            self.assertEqual(text(plan[role], "/etc/cn-egress-wss/node.key"), self.pki[role]["key"])
            unit = text(plan[role], "/etc/systemd/system/cn-egress-obfs.service")
            self.assertIn("User=cn-egress-wss\n", unit)
            self.assertIn("PartOf=cn-egress.service\n", unit)
            self.assertEqual("AmbientCapabilities=CAP_NET_BIND_SERVICE" in unit, role == "sh")

    def test_transport_uses_configured_hostname_and_validates_certificates(self):
        plan = self.plan(topology("cn-relay.example.com"))
        wrapper = text(plan["hk"], "/usr/local/sbin/cn-egress-obfs")
        compile(wrapper, "generated-wrapper", "exec")
        self.assertIn("--tls-verify-certificate", wrapper)
        self.assertIn("--tls-client-ca-certs", wrapper)
        self.assertIn("SSL_CERT_FILE", wrapper)
        self.assertNotIn("198.51.100.20", wrapper)
        self.assertEqual(text(plan["hk"], "/etc/cn-egress-wss/sh-host"), "cn-relay.example.com\n")
        plan = self.plan({**topology(), "wss_port": 8443, "user_port": 51830})
        self.assertEqual(text(plan["hk"], "/etc/cn-egress-wss/port"), "8443\n")
        self.assertIn("ListenPort = 51830", text(plan["hk"], "/etc/wireguard/cne-users.conf"))

    def test_new_clients_require_unique_address_public_key_and_psk(self):
        material = keys()
        material["clients"] = {"alice": {"address": 40, "public": material["iphone"]["public"], "psk": material["psks"]["iphone"]}}
        plan = self.plan(material=material)
        users = text(plan["hk"], "/etc/wireguard/cne-users.conf")
        self.assertEqual(users.count("[Peer]"), 1)
        self.assertIn("10.77.10.40/32", users)
        for field, value in (("address", 40), ("public", material["iphone"]["public"]), ("psk", material["psks"]["iphone"])):
            bad = copy.deepcopy(material)
            bad["clients"]["bob"] = {"address": 41, "public": material["android"]["public"], "psk": material["psks"]["android"]}
            bad["clients"]["bob"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.plan(material=bad)
        for bad_public in (material["hk_users"]["public"],):
            bad = copy.deepcopy(material)
            bad["clients"]["alice"]["public"] = bad_public
            with self.assertRaises(ValueError):
                self.plan(material=bad)

    def test_invalid_address_host_port_and_wan_cannot_reach_payload(self):
        for host in ("198.51.100.20\n--skip", "https://example.com", "example.com;id", "999.1.1.1", "::1"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                self.plan(topology(host))
        for wan in ("eth0\nflush ruleset", "eth0\"", "", "a" * 16):
            bad = topology()
            bad["exit"]["wan"] = wan
            with self.subTest(wan=wan), self.assertRaises(ValueError):
                self.plan(bad)
        for number in (1, 250, 251, 255):
            with self.subTest(number=number), self.assertRaises(ValueError):
                render.client_profile("new-phone", number, keys()["iphone"]["private"], keys()["hk_users"]["public"], keys()["psks"]["iphone"], "203.0.113.10")
        with self.assertRaises(ValueError):
            self.plan({**topology(), "bj": {"host": "192.0.2.30"}})

    def test_pki_real_chain_eku_san_and_private_permissions(self):
        for role, purpose in (("sh", "sslserver"), ("hk", "sslclient"), ("exit", "sslclient")):
            verify = subprocess.run(["openssl", "verify", "-CAfile", str(self.pki_path / "ca.crt"), "-purpose", purpose, str(self.pki_path / f"{role}.crt")], capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)
            wrong_purpose = "sslclient" if role == "sh" else "sslserver"
            rejected = subprocess.run(["openssl", "verify", "-CAfile", str(self.pki_path / "ca.crt"), "-purpose", wrong_purpose, str(self.pki_path / f"{role}.crt")], capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(stat.S_IMODE((self.pki_path / f"{role}.key").stat().st_mode), 0o600)
            decoded = ssl._ssl._test_decode_cert(str(self.pki_path / f"{role}.crt"))
            self.assertIn((("commonName", "cn-egress-" + role),), decoded["subject"])
            if role == "sh":
                ssl.match_hostname(decoded, "198.51.100.20")
                with self.assertRaises(ssl.CertificateError):
                    ssl.match_hostname(decoded, "192.0.2.30")
        self.assertEqual(stat.S_IMODE(self.pki_path.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.pki_path / "ca.key").stat().st_mode), 0o600)
        sh = ssl._ssl._test_decode_cert(str(self.pki_path / "sh.crt"))
        self.assertEqual(ssl.cert_time_to_seconds(sh["notAfter"]) - ssl.cert_time_to_seconds(sh["notBefore"]), 730 * 86400)
        with self.assertRaises(FileExistsError):
            render.generate_pki(topology(), self.pki_path)

    def test_dns_san_and_no_private_ca_in_result(self):
        with tempfile.TemporaryDirectory() as work:
            with self.assertWarns(UserWarning):
                pki = render.generate_pki(topology("cn-relay.example.com"), Path(work))
            cert = ssl._ssl._test_decode_cert(str(Path(work) / "sh.crt"))
            ssl.match_hostname(cert, "cn-relay.example.com")
            with self.assertRaises(ssl.CertificateError):
                ssl.match_hostname(cert, "203.0.113.10")
            self.assertNotIn((Path(work) / "ca.key").read_text(), json.dumps(pki))


class SoftwareTests(unittest.TestCase):
    def archive(self, machine=183):
        binary = bytearray(64)
        binary[:4] = b"\x7fELF"
        binary[5] = 1
        binary[18:20] = machine.to_bytes(2, "little")
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as package:
            member = tarfile.TarInfo("wstunnel")
            member.size = len(binary)
            package.addfile(member, io.BytesIO(binary))
        return output.getvalue(), bytes(binary)

    def metadata(self, archive, arch="arm64"):
        return json.dumps({"tag_name": "v11.0.0", "assets": [{"name": f"wstunnel_11.0.0_linux_{arch}.tar.gz", "digest": "sha256:" + hashlib.sha256(archive).hexdigest()}]}).encode()

    def test_archive_verified_and_reusable_offline(self):
        archive, expected_binary = self.archive()
        with tempfile.TemporaryDirectory() as work:
            with patch.object(render, "_download", side_effect=[self.metadata(archive), archive]) as download:
                self.assertEqual(render.fetch_wstunnel(Path(work), "arm64"), expected_binary)
                self.assertEqual(download.call_count, 2)
            with patch.object(render, "_download", side_effect=AssertionError("Offline cache must not fetch")):
                self.assertEqual(render.fetch_wstunnel(Path(work), "arm64"), expected_binary)
            (Path(work) / "wstunnel_11.0.0_linux_arm64.tar.gz").write_bytes(archive + b"tampered")
            with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
                render.fetch_wstunnel(Path(work), "arm64")

    def test_missing_digest_wrong_pin_and_wrong_architecture_refused(self):
        archive, _ = self.archive(62)
        cases = [
            (json.dumps({"tag_name": "v11.0.0", "assets": []}).encode(), "arm64", "digest"),
            (self.metadata(archive, "amd64"), "amd64", "pinned amd64"),
            (self.metadata(archive), "arm64", "architecture"),
        ]
        for metadata, arch, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as work:
                with patch.object(render, "_download", side_effect=[metadata, archive]):
                    with self.assertRaisesRegex(RuntimeError, message):
                        render.fetch_wstunnel(Path(work), arch)
                self.assertFalse((Path(work) / f"wstunnel_11.0.0_linux_{arch}.tar.gz").exists())


if __name__ == "__main__":
    unittest.main()
