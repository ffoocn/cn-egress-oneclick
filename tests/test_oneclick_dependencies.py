"""Exercise dependency bootstrap with isolated executables, never host packages."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "oneclick/bootstrap-deps.sh"
BASH = shutil.which("bash")


class DependencyBootstrapTests(unittest.TestCase):
    def setUp(self):
        temp_parent = "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
        self.temp = tempfile.TemporaryDirectory(prefix="cn-egress-dependency-test-", dir=temp_parent)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state"
        self.state.mkdir()
        self.log = self.root / "commands.log"
        self.environment = os.environ.copy()
        for name in list(self.environment):
            if name.startswith("CNE_"):
                del self.environment[name]
        self.environment.update({
            "PATH": str(self.bin),
            "CNE_TEST_BIN": str(self.bin),
            "CNE_TEST_STATE": str(self.state),
            "CNE_TEST_LOG": str(self.log),
            "CNE_TEST_UID": "0",
            "CNE_TEST_OS": "Linux",
        })
        # Only harmless tools are reachable through PATH. Managers and sudo are
        # always fixtures, including when these tests are executed as root.
        for name in ("cat", "cp", "mkdir", "chmod", "dirname", "basename",
                     "readlink", "realpath", "tr", "sed", "grep", "awk",
                     "head", "tail", "sort", "find", "sleep", "env", "ln"):
            command = shutil.which(name)
            if command:
                (self.bin / name).symlink_to(command)
        self.write_command("uname", 'printf "%s\\n" "$CNE_TEST_OS"\n')
        self.write_command("id", 'printf "%s\\n" "$CNE_TEST_UID"\n')
        self.write_command("dpkg", r'''case "$*" in
  --audit)
    [[ "${CNE_TEST_DPKG_DIRTY:-0}" == 0 ]] || printf 'fixture package requires configuration\n'
    exit 0
    ;;
  *--compare-versions*)
    [[ "$*" != *"3.8"* ]] || exit 1
    exit 0
    ;;
  *) exit 0 ;;
esac
''')
        self.write_command("apt-cache", r'''case "$*" in
  "policy python3") printf 'python3:\n  Candidate: %s\n' "${CNE_TEST_APT_CANDIDATE:-3.11.2-1}" ;;
  "policy ${CNE_TEST_SIDE_BY_SIDE_PACKAGE:-unused}") printf '  Candidate: 3.11.2-1\n' ;;
  *) printf '  Candidate: (none)\n' ;;
esac
''')
        self.write_command("sudo", r'''printf 'sudo %s\n' "$*" >> "$CNE_TEST_LOG"
while [[ $# -gt 0 && "$1" == -* ]]; do
  [[ "$1" == -v ]] && exit 0
  shift
done
exec "$@"
''')
        self.write_command("dpkg-query", r'''case "$*" in
  *ca-certificates*)
    [[ -f "$CNE_TEST_STATE/ca-certificates" ]] || exit 1
    printf 'install ok installed\n'
    ;;
  *) exit 1 ;;
esac
''')
        self.runtime = self.root / "python-runtime"
        self.runtime.write_text("#!/bin/bash\n" + r'''printf 'python %s\n' "$*" >> "$CNE_TEST_LOG"
[[ "${CNE_TEST_PYTHON_BAD:-0}" == 0 ]] || exit 1
[[ -f "$CNE_TEST_STATE/python3" ]] || exit 1
printf '%s\n' "$0"
''')
        self.runtime.chmod(0o755)
        self.environment["CNE_TEST_RUNTIME"] = str(self.runtime)
        self.write_command("apt-get", r'''printf 'apt-get %s\n' "$*" >> "$CNE_TEST_LOG"
# A package manager must not consume the caller's menu choice.
if IFS= read -r consumed; then
  printf 'CONSUMED_STDIN:%s\n' "$consumed" >> "$CNE_TEST_LOG"
fi
installing=0
simulating=0
for argument in "$@"; do
  [[ "$argument" != -s && "$argument" != --simulate ]] || simulating=1
done
if [[ "$simulating" == 1 && -n "${CNE_TEST_APT_PLAN_EXTRA:-}" ]]; then
  printf '%s\n' "$CNE_TEST_APT_PLAN_EXTRA"
fi
for argument in "$@"; do
  case "$argument" in
    update)
      [[ "${CNE_TEST_APT_FAIL_UPDATE:-0}" == 0 ]] || exit 17
      exit 0
      ;;
    install)
      [[ "$simulating" == 1 || "${CNE_TEST_APT_FAIL_INSTALL:-0}" == 0 ]] || exit 18
      installing=1
      ;;
    python3|python3.9|python3.10|python3.11|python3.12|python3.13|python3.14)
      [[ "$installing" == 1 ]] || continue
      if [[ "$simulating" == 1 ]]; then
        printf 'Inst %s (3.11.2-1 fixture [amd64])\n' "$argument"
        continue
      fi
      : > "$CNE_TEST_STATE/python3"
      if [[ -n "${CNE_TEST_REAL_PYTHON:-}" ]]; then
        ln -s "$CNE_TEST_REAL_PYTHON" "$CNE_TEST_BIN/$argument"
      else
        cp "$CNE_TEST_RUNTIME" "$CNE_TEST_BIN/$argument"
      fi
      ;;
    openssh-client|openssh-clients)
      [[ "$installing" == 1 ]] || continue
      if [[ "$simulating" == 1 ]]; then
        printf 'Inst %s (1.0 fixture [amd64])\n' "$argument"
        continue
      fi
      printf '#!/bin/bash\nexit 0\n' > "$CNE_TEST_BIN/ssh"
      chmod +x "$CNE_TEST_BIN/ssh"
      ;;
    openssl)
      [[ "$installing" == 1 ]] || continue
      if [[ "$simulating" == 1 ]]; then
        printf 'Inst openssl (1.0 fixture [amd64])\n'
        continue
      fi
      printf '#!/bin/bash\nexit 0\n' > "$CNE_TEST_BIN/openssl"
      chmod +x "$CNE_TEST_BIN/openssl"
      ;;
    ca-certificates)
      [[ "$installing" == 1 ]] || continue
      if [[ "$simulating" == 1 ]]; then
        printf 'Inst ca-certificates (1.0 fixture [amd64])\n'
        continue
      fi
      : > "$CNE_TEST_STATE/ca-certificates"
      ;;
  esac
done
''')
        self.make_ready()

    def tearDown(self):
        self.temp.cleanup()

    def write_command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)
        return path

    def make_ready(self):
        (self.state / "python3").touch()
        shutil.copyfile(self.runtime, self.bin / "python3")
        (self.bin / "python3").chmod(0o755)
        self.write_command("ssh", "exit 0\n")
        self.write_command("openssl", "exit 0\n")
        (self.state / "ca-certificates").touch()

    def run_helper(self, *, input="menu-choice\n", read_choice=False):
        body = '''set -euo pipefail
source "$1"
cne_ensure_dependencies
printf 'SELECTED_PYTHON=%s\\n' "$CNE_PYTHON"
'''
        if read_choice:
            body += '''IFS= read -r choice
printf 'MENU_CHOICE=%s\\n' "$choice"
'''
        return subprocess.run([BASH, "-c", body, "dependency-test", str(HELPER)],
                              input=input, text=True, capture_output=True,
                              env=self.environment, timeout=15)

    def commands(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def manager_commands(self):
        return [line for line in self.commands() if line.startswith("apt-get ")]

    def install_commands(self):
        return [line.split() for line in self.manager_commands()
                if "install" in line.split() and "-s" not in line.split()
                and "--simulate" not in line.split()]

    def use_other_manager(self, manager):
        (self.bin / "apt-get").unlink(missing_ok=True)
        for other in ("dnf", "yum", "apk"):
            (self.bin / other).unlink(missing_ok=True)
        self.write_command("rpm", r'''case "$*" in
  *ca-certificates*) [[ -f "$CNE_TEST_STATE/ca-certificates" ]] ;;
  *) exit 1 ;;
esac
''')
        self.write_command("fixture-install-packages", r'''for package in "$@"; do
  case "$package" in
    python3|python3.*|python39)
      : > "$CNE_TEST_STATE/python3"
      cp "$CNE_TEST_RUNTIME" "$CNE_TEST_BIN/$package"
      ;;
    openssh-client|openssh-clients)
      printf '#!/bin/bash\nexit 0\n' > "$CNE_TEST_BIN/ssh"
      chmod +x "$CNE_TEST_BIN/ssh"
      ;;
    openssl)
      printf '#!/bin/bash\nexit 0\n' > "$CNE_TEST_BIN/openssl"
      chmod +x "$CNE_TEST_BIN/openssl"
      ;;
    ca-certificates) : > "$CNE_TEST_STATE/ca-certificates" ;;
  esac
done
''')
        if manager in ("dnf", "yum"):
            self.write_command(manager, r'''manager=${0##*/}
printf '%s %s\n' "$manager" "$*" >> "$CNE_TEST_LOG"
if IFS= read -r consumed; then
  printf 'CONSUMED_STDIN:%s\n' "$consumed" >> "$CNE_TEST_LOG"
fi
if [[ "$*" == *"--assumeno"* ]]; then
  printf '%s\n' "${CNE_TEST_RPM_PLAN:-Updating Subscription Management repositories.
Dependencies resolved.
Installing:
 python3 x86_64 3.11.2 fixture 10 M
Transaction Summary
Install 1 Package}"
  exit 1
fi
if [[ "$*" == *"list --available"* ]]; then exit 0; fi
[[ "${CNE_TEST_OTHER_INSTALL_FAIL:-0}" == 0 ]] || exit 19
"$CNE_TEST_BIN/fixture-install-packages" "$@"
''')
        elif manager == "apk":
            self.write_command("apk", r'''printf 'apk %s\n' "$*" >> "$CNE_TEST_LOG"
if [[ "$1" == info ]]; then
  case "$*" in
    *ca-certificates*) [[ -f "$CNE_TEST_STATE/ca-certificates" ]] ;;
    *) exit 1 ;;
  esac
  exit $?
fi
if IFS= read -r consumed; then
  printf 'CONSUMED_STDIN:%s\n' "$consumed" >> "$CNE_TEST_LOG"
fi
if [[ "$*" == *"--simulate"* ]]; then
  if [[ "${CNE_TEST_APK_PLAN_TO_STDERR:-0}" == 1 ]]; then
    printf '%s\n' "${CNE_TEST_APK_PLAN:-(1/1) Installing python3 (3.11.2-r0)}" >&2
  else
    printf '%s\n' "${CNE_TEST_APK_PLAN:-(1/1) Installing python3 (3.11.2-r0)}"
  fi
  exit 0
fi
[[ "${CNE_TEST_OTHER_INSTALL_FAIL:-0}" == 0 ]] || exit 19
"$CNE_TEST_BIN/fixture-install-packages" "$@"
''')

    def other_actual_installs(self, manager):
        return [line for line in self.commands()
                if line.startswith(manager + " ")
                and (("install" in line.split() and "--assumeno" not in line.split())
                     or ("add" in line.split() and "--simulate" not in line.split()))]

    def remove_python_commands(self):
        for path in self.bin.glob("python3*"):
            path.unlink()

    def test_present_dependencies_are_idempotent_and_optional_qrencode_is_not_installed(self):
        for _ in range(2):
            result = self.run_helper()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("SELECTED_PYTHON=" + str(self.bin / "python3"), result.stdout)
        self.assertEqual(self.manager_commands(), [])
        self.assertFalse((self.bin / "qrencode").exists())

    def test_missing_python_is_installed_and_returns_an_absolute_interpreter(self):
        (self.bin / "python3").unlink()
        (self.state / "python3").unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELECTED_PYTHON=" + str(self.bin / "python3"), result.stdout)
        commands = self.manager_commands()
        self.assertTrue(any("update" in line.split() for line in commands), commands)
        installs = self.install_commands()
        self.assertEqual(len(installs), 1, commands)
        self.assertIn("python3", installs[0])
        self.assertNotIn("openssh-client", installs[0])
        self.assertNotIn("openssl", installs[0])
        self.assertNotIn("CONSUMED_STDIN", "\n".join(self.commands()))

    def test_missing_ssh_and_openssl_install_only_those_required_tools(self):
        (self.bin / "ssh").unlink()
        (self.bin / "openssl").unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        installs = self.install_commands()
        self.assertEqual(len(installs), 1, self.manager_commands())
        self.assertIn("openssh-client", installs[0])
        self.assertIn("openssl", installs[0])
        self.assertNotIn("python3", installs[0])
        self.assertNotIn("qrencode", installs[0])
        for line in self.manager_commands():
            self.assertTrue(set(line.split()).isdisjoint({"upgrade", "dist-upgrade", "remove", "autoremove"}))

    def test_package_manager_failure_stops_before_running_the_menu(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APT_FAIL_INSTALL"] = "1"
        result = self.run_helper(read_choice=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SELECTED_PYTHON=", result.stdout)
        self.assertNotIn("MENU_CHOICE=", result.stdout)

    def test_package_metadata_failure_does_not_attempt_install(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APT_FAIL_UPDATE"] = "1"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("install" in line.split() for line in self.manager_commands()))

    def test_installed_python_that_still_fails_runtime_probe_is_rejected(self):
        self.environment["CNE_TEST_PYTHON_BAD"] = "1"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SELECTED_PYTHON=", result.stdout)
        self.assertTrue(any("install" in line.split() for line in self.manager_commands()))

    def test_installation_preserves_original_menu_stdin(self):
        (self.bin / "python3").unlink()
        result = self.run_helper(input="2\n", read_choice=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MENU_CHOICE=2", result.stdout)
        self.assertFalse(any("CONSUMED_STDIN" in line for line in self.commands()))

    def test_missing_manager_fails_without_running_uncontrolled_commands(self):
        (self.bin / "python3").unlink()
        (self.bin / "apt-get").unlink()
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.manager_commands(), [])

    def test_missing_ca_package_is_installed_without_reinstalling_ready_tools(self):
        (self.state / "ca-certificates").unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        installs = self.install_commands()
        self.assertEqual(len(installs), 1, self.manager_commands())
        self.assertIn("ca-certificates", installs[0])
        self.assertNotIn("python3", installs[0])
        self.assertNotIn("openssh-client", installs[0])
        self.assertNotIn("openssl", installs[0])

    def test_broken_package_state_is_reported_without_attempting_automatic_repair(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_DPKG_DIRTY"] = "1"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.install_commands(), [])
        self.assertFalse(any("--configure" in line for line in self.commands()))

    def test_simulated_removal_and_upgrade_are_refused_before_real_install(self):
        for plan in ("Remv existing-service [1.0]",
                     "Inst existing-library [1.0] (2.0 fixture [amd64])"):
            with self.subTest(plan=plan):
                (self.bin / "python3").unlink(missing_ok=True)
                self.environment["CNE_TEST_APT_PLAN_EXTRA"] = plan
                self.log.unlink(missing_ok=True)
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.install_commands(), [])

    def test_supported_side_by_side_python_is_used_when_default_package_is_old(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APT_CANDIDATE"] = "3.8.10-1"
        self.environment["CNE_TEST_SIDE_BY_SIDE_PACKAGE"] = "python3.11"
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELECTED_PYTHON=" + str(self.bin / "python3.11"), result.stdout)
        installs = self.install_commands()
        self.assertEqual(len(installs), 1, self.manager_commands())
        self.assertIn("python3.11", installs[0])
        self.assertNotIn("python3", installs[0])

    def test_old_official_python_candidates_stop_without_installing_an_unusable_runtime(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APT_CANDIDATE"] = "3.8.10-1"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.install_commands(), [])

    def test_nonroot_install_uses_existing_sudo_and_preserves_menu_input(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_UID"] = "1000"
        result = self.run_helper(input="2\n", read_choice=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MENU_CHOICE=2", result.stdout)
        self.assertTrue(any(line.startswith("sudo ") for line in self.commands()))

    def test_rpm_managers_install_new_packages_with_subscription_update_header(self):
        for manager in ("dnf", "yum"):
            with self.subTest(manager=manager):
                self.use_other_manager(manager)
                self.remove_python_commands()
                self.log.unlink(missing_ok=True)
                result = self.run_helper(input="2\n", read_choice=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("MENU_CHOICE=2", result.stdout)
                installs = self.other_actual_installs(manager)
                self.assertEqual(len(installs), 1, self.commands())
                self.assertTrue(any(name.startswith("python3") for name in installs[0].split()), installs)
                self.assertNotIn("CONSUMED_STDIN", "\n".join(self.commands()))

    def test_rpm_dependency_replacement_and_upgrade_plans_are_refused(self):
        self.use_other_manager("dnf")
        (self.bin / "python3").unlink()
        for mutation in ("Updating:", "Updating for dependencies:",
                         "Upgrade 1 Package", "Replacing:",
                         " replacing existing-package.x86_64 1.0-1",
                         "Removing:", "Downgrading:", "Reinstalling:"):
            with self.subTest(mutation=mutation):
                self.remove_python_commands()
                self.log.unlink(missing_ok=True)
                self.environment["CNE_TEST_RPM_PLAN"] = (
                    "Installing:\n python3 x86_64 3.11.2 fixture 10 M\n"
                    "Transaction Summary\nInstall 1 Package\n" + mutation)
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.other_actual_installs("dnf"), [])

    def test_rpm_missing_transaction_summary_and_install_failure_stop(self):
        self.use_other_manager("dnf")
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_RPM_PLAN"] = "Error: package unavailable"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.other_actual_installs("dnf"), [])
        del self.environment["CNE_TEST_RPM_PLAN"]
        self.environment["CNE_TEST_OTHER_INSTALL_FAIL"] = "1"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SELECTED_PYTHON=", result.stdout)

    def test_apk_install_plan_in_stderr_is_captured_and_input_is_preserved(self):
        self.use_other_manager("apk")
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APK_PLAN_TO_STDERR"] = "1"
        result = self.run_helper(input="2\n", read_choice=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MENU_CHOICE=2", result.stdout)
        self.assertEqual(len(self.other_actual_installs("apk")), 1)
        self.assertNotIn("CONSUMED_STDIN", "\n".join(self.commands()))

    def test_apk_existing_package_mutations_in_stderr_are_refused(self):
        self.use_other_manager("apk")
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APK_PLAN_TO_STDERR"] = "1"
        for mutation in ("Upgrading", "Downgrading", "Purging", "Replacing",
                         "Reinstalling", "Updating pinning"):
            with self.subTest(mutation=mutation):
                self.log.unlink(missing_ok=True)
                self.environment["CNE_TEST_APK_PLAN"] = (
                    "(1/2) " + mutation + " existing-package (1.0-r0)\n"
                    "(2/2) Installing python3 (3.11.2-r0)")
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.other_actual_installs("apk"), [])

    def test_apk_ambiguous_plan_and_install_failure_stop(self):
        self.use_other_manager("apk")
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_APK_PLAN"] = "OK: 5 MiB in 10 packages"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.other_actual_installs("apk"), [])
        del self.environment["CNE_TEST_APK_PLAN"]
        self.environment["CNE_TEST_OTHER_INSTALL_FAIL"] = "1"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SELECTED_PYTHON=", result.stdout)

    def test_generated_download_launcher_installs_runtime_before_unpacking_and_menu(self):
        spec = importlib.util.spec_from_file_location(
            "dependency_release_fixture", HELPER.parent / "build-release.py")
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        source = self.root / "source"
        source.mkdir(mode=0o700)
        for name in release.REQUIRED:
            path = source / name
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text("Public regression fixture\n")
        (source / "bootstrap-deps.sh").write_text(HELPER.read_text())
        (source / "cn_egress.py").write_text(
            'print("FIXTURE_MENU_READY", flush=True)\n'
            'print("FIXTURE_CHOICE=" + input(), flush=True)\n')
        release_result = release.build(source, self.root / "output")
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_REAL_PYTHON"] = sys.executable
        self.environment["CNE_HOME"] = str(self.root / "installed")
        for _ in range(2):
            result = subprocess.run([BASH, str(release_result["launcher"])],
                                    input="0\n", text=True, capture_output=True,
                                    env=self.environment, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("FIXTURE_MENU_READY", result.stdout)
            self.assertIn("FIXTURE_CHOICE=0", result.stdout)
        self.assertEqual(len(self.install_commands()), 1, self.commands())
        self.assertFalse(any("CONSUMED_STDIN" in line for line in self.commands()))

    def test_existing_homebrew_installs_only_missing_python_with_maintenance_disabled(self):
        (self.bin / "python3").unlink()
        self.environment["CNE_TEST_OS"] = "Darwin"
        self.environment["CNE_TEST_UID"] = "1000"
        self.write_command("brew", r'''printf 'brew %s\n' "$*" >> "$CNE_TEST_LOG"
printf 'BREW_ENV:%s:%s:%s:%s\n' \
  "${HOMEBREW_NO_AUTO_UPDATE:-}" \
  "${HOMEBREW_NO_INSTALL_UPGRADE:-}" \
  "${HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK:-}" \
  "${HOMEBREW_NO_INSTALL_CLEANUP:-}" >> "$CNE_TEST_LOG"
if IFS= read -r consumed; then
  printf 'CONSUMED_STDIN:%s\n' "$consumed" >> "$CNE_TEST_LOG"
fi
[[ "$*" == 'install python' ]] || exit 20
cp "$CNE_TEST_RUNTIME" "$CNE_TEST_BIN/python3"
''')
        result = self.run_helper(input="2\n", read_choice=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELECTED_PYTHON=" + str(self.bin / "python3"), result.stdout)
        self.assertIn("MENU_CHOICE=2", result.stdout)
        self.assertEqual([line for line in self.commands() if line.startswith("brew ")],
                         ["brew install python"])
        self.assertIn("BREW_ENV:1:1:1:1", self.commands())
        self.assertFalse(any(line.startswith(("sudo ", "apt-get ", "dnf ", "yum ", "apk "))
                             for line in self.commands()))
        self.assertFalse(any("CONSUMED_STDIN" in line for line in self.commands()))


if __name__ == "__main__":
    unittest.main()
