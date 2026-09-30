"""Run temporary self-extracting launchers; never build production artifacts."""
import importlib.util
import fcntl
import io
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location("oneclick_release", Path(__file__).resolve().parents[1] / "oneclick/build-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        # /private/tmp avoids macOS's trusted /tmp and /var alias variations.
        root = "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
        self.temp = tempfile.TemporaryDirectory(prefix="cn-egress-release-test-", dir=root)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir(mode=0o700)
        for name in release.REQUIRED:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Public fixture\n")
            path.chmod(0o644)
        (self.source / "render.py").write_text("LABEL = 'sibling-import-ok'\n")
        (self.source / "cn_egress.py").write_text('''import argparse
import render
parser = argparse.ArgumentParser(description="Temporary release controller")
parser.add_argument("--read-stdin", action="store_true")
options = parser.parse_args()
if options.read_stdin:
    print("awaiting-input", flush=True)
print(input() if options.read_stdin else render.LABEL)
''')
        (self.source / "cn-egress.sh").chmod(0o755)
        self.output = self.root / "output"
        self.home = self.root / "installed"

    def tearDown(self):
        self.temp.cleanup()

    def run_launcher(self, script, *args, home=None, input=None):
        environment = os.environ.copy()
        environment["CNE_HOME"] = str(home or self.home)
        return subprocess.run(["bash", str(script), *args], env=environment, input=input,
                              capture_output=True, text=True, timeout=15)

    def test_actual_loader_help_repeated_execution_preserves_private(self):
        result = release.build(self.source, self.output)
        launched = self.run_launcher(result["launcher"], "--help")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertIn("Temporary release controller", launched.stdout)
        private = self.home / "private"
        private.mkdir(mode=0o700)
        sentinel = private / "sentinel.txt"
        sentinel.write_text("private material must stay untouched")
        sentinel.chmod(0o600)
        old_stat = sentinel.stat()
        for _ in range(2):
            launched = self.run_launcher(result["launcher"])
            self.assertEqual(launched.returncode, 0, launched.stderr)
            self.assertIn("sibling-import-ok", launched.stdout)
        self.assertEqual(sentinel.read_text(), "private material must stay untouched")
        self.assertEqual(sentinel.stat().st_mtime_ns, old_stat.st_mtime_ns)
        self.assertEqual(stat.S_IMODE(self.home.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.home / "assets").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.home / "cn_egress.py").stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE((self.home / "cn-egress.sh").stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(result["launcher"].stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(result["zip"].stat().st_mode), 0o644)

    def test_loader_restores_original_piped_stdin(self):
        result = release.build(self.source, self.output)
        launched = self.run_launcher(result["launcher"], "--read-stdin", input="menu-choice\n")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertIn("menu-choice", launched.stdout)

    def test_whitelist_excludes_fake_secrets_and_unknown_files(self):
        for name in ("private/ca.key", "private/config.json", "password.txt", "existing.conf", "__pycache__/cache.pyc", "tests/test_secret.py", "software/not-allowed.key"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("SECRET_MARKER_4acd9181")
        archive = release.public_archive(self.source)
        with zipfile.ZipFile(io.BytesIO(archive)) as package:
            self.assertEqual(set(package.namelist()), set(release.REQUIRED))
            for entry in package.namelist():
                self.assertNotIn(b"SECRET_MARKER_4acd9181", package.read(entry))

    def test_loader_rejects_symlink_and_shared_writable_home(self):
        result = release.build(self.source, self.output)
        target = self.root / "real"
        target.mkdir(mode=0o700)
        alias = self.root / "alias"
        alias.symlink_to(target, target_is_directory=True)
        launched = self.run_launcher(result["launcher"], "--help", home=alias)
        self.assertNotEqual(launched.returncode, 0)
        self.assertIn("符号链接", launched.stderr)
        shared = self.root / "shared"
        shared.mkdir(mode=0o777)
        shared.chmod(0o777)
        launched = self.run_launcher(result["launcher"], "--help", home=shared)
        self.assertNotEqual(launched.returncode, 0)
        self.assertIn("其他用户写入", launched.stderr)

    def test_loader_rejects_existing_child_symlink_without_touching_target(self):
        result = release.build(self.source, self.output)
        self.home.mkdir(mode=0o700)
        outside = self.root / "outside.py"
        outside.write_text("outside must stay unchanged")
        (self.home / "render.py").symlink_to(outside)
        launched = self.run_launcher(result["launcher"], "--help")
        self.assertNotEqual(launched.returncode, 0)
        self.assertEqual(outside.read_text(), "outside must stay unchanged")

    def test_digest_failure_refuses_before_extracting(self):
        archive = release.public_archive(self.source)
        script = self.root / "tampered.sh"
        launcher = release.launcher(archive)
        digest = release.hashlib.sha256(archive).hexdigest().encode()
        script.write_bytes(launcher.replace(digest, b"0" * 64, 1))
        launched = self.run_launcher(script, "--help")
        self.assertNotEqual(launched.returncode, 0)
        self.assertIn("SHA256", launched.stderr)
        self.assertFalse(self.home.exists())

    def test_archive_traversal_not_in_allowlist(self):
        output = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(release.public_archive(self.source))) as original:
            with zipfile.ZipFile(output, "w") as package:
                for entry in original.infolist():
                    package.writestr(entry, original.read(entry))
                entry = zipfile.ZipInfo("../escaped")
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                package.writestr(entry, "must not extract")
        script = self.root / "unsafe.sh"
        script.write_bytes(release.launcher(output.getvalue()))
        launched = self.run_launcher(script, "--help")
        self.assertNotEqual(launched.returncode, 0)
        self.assertFalse((self.root / "escaped").exists())

    def test_source_symlink_and_unverified_software_refused(self):
        source = self.source / "node.py"
        source.unlink()
        source.symlink_to(self.source / "README.md")
        with self.assertRaisesRegex(ValueError, "symlink"):
            release.public_archive(self.source)
        source.unlink()
        source.write_text("Public fixture")
        software = self.source / "software"
        software.mkdir()
        (software / "wstunnel_11.0.0_linux_amd64.tar.gz").write_bytes(b"unverified")
        with self.assertRaisesRegex(ValueError, "digest receipt"):
            release.public_archive(self.source)

    def test_running_menu_refuses_update_before_replacing_modules(self):
        result = release.build(self.source, self.output)
        environment = os.environ.copy()
        environment["CNE_HOME"] = str(self.home)
        process = subprocess.Popen(["bash", str(result["launcher"]), "--read-stdin"], env=environment,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "awaiting-input")
            original = (self.home / "render.py").read_bytes()
            (self.source / "render.py").write_text("LABEL = 'new-version'\n")
            result = release.build(self.source, self.output)
            blocked = self.run_launcher(result["launcher"], "--help")
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("管理菜单仍在运行", blocked.stderr)
            self.assertEqual((self.home / "render.py").read_bytes(), original)
            stdout, stderr = process.communicate("menu-choice\n", timeout=15)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIn("menu-choice", stdout)
            completed = self.run_launcher(result["launcher"])
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("new-version", completed.stdout)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=15)

    def test_existing_direct_controller_refuses_update_before_replacing_modules(self):
        result = release.build(self.source, self.output)
        launched = self.run_launcher(result["launcher"], "--help")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        private = self.home / "private"
        private.mkdir(mode=0o700)
        original = (self.home / "render.py").read_bytes()
        (self.source / "render.py").write_text("LABEL = 'new-version'\n")
        result = release.build(self.source, self.output)
        with (private / ".controller.lock").open("w") as guard:
            fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocked = self.run_launcher(result["launcher"], "--help")
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("管理菜单仍在运行", blocked.stderr)
            self.assertEqual((self.home / "render.py").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
