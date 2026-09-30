#!/usr/bin/env python3
"""Build the public, self-extracting launcher from a strict file allowlist.

Never traverses private/, configuration backups, credentials, tests or pycache.
This is a local build operation; it neither connects to nodes nor downloads.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import textwrap
import zipfile

CORE = ("cn_egress.py", "node.py", "render.py", "cn-egress.sh", "topology.example.json", "README.md")
ASSETS = ("assets/cn-egress-net.sh", "assets/cn-egress-obfs.py", "assets/cn-egress-wss-restrictions.yaml")
SOFTWARE = ("software/wstunnel_11.0.0_linux_amd64.tar.gz",
            "software/wstunnel_11.0.0_linux_arm64.tar.gz",
            "software/wstunnel-11.0.0-release.json")
REQUIRED = CORE + ASSETS
ALLOWED = REQUIRED + SOFTWARE
AMD64_SHA256 = "9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e"
MAX_BUNDLE = 200 * 1024 * 1024

# The quoted heredoc keeps shell expansions out of the embedded Python and ZIP.
# FD 3 preserves the caller's original stdin for the interactive management menu.
SHELL_HEADER = '''#!/usr/bin/env bash
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo '需要 Python 3.9 或更新版本：Debian/Ubuntu 可安装 python3。' >&2
  exit 1
fi
exec 3<&0
exec python3 -I - "$@" <<'CNE_ONECLICK_BOOTSTRAP_V1'
'''

BOOTSTRAP = '''import sys
if sys.version_info < (3, 9):
    raise SystemExit('需要 Python 3.9 或更新版本。')
import base64
import fcntl
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile
import zipfile

REQUIRED = __REQUIRED__
ALLOWED = __ALLOWED__
EXPECTED = __DIGEST__
PAYLOAD = """__PAYLOAD__"""

def checked_directory(path, home=False):
    state = path.lstat()
    if not stat.S_ISDIR(state.st_mode):
        raise ValueError('目录不是普通目录，或使用了符号链接：' + str(path))
    if state.st_uid not in (0, os.geteuid()) or (home and state.st_uid != os.geteuid()):
        raise ValueError('目录所有者与当前用户不匹配：' + str(path))
    if state.st_mode & 0o022:
        if home or state.st_uid != 0 or not state.st_mode & stat.S_ISVTX:
            raise ValueError('目录允许其他用户写入：' + str(path))

def secure_home():
    requested = Path(os.environ.get('CNE_HOME', str(Path.home() / '.local/share/cn-egress-oneclick'))).expanduser()
    requested = Path(os.path.abspath(str(requested)))
    # macOS system aliases are root-owned; arbitrary directory symlinks fail.
    for component in reversed((requested,) + tuple(requested.parents)):
        if not component.exists() and not component.is_symlink():
            component.mkdir(mode=0o700, exist_ok=True)
        if component.is_symlink():
            target = str(component.resolve())
            permitted = {'/tmp': '/private/tmp', '/var': '/private/var'}
            if (str(component) not in permitted or target != permitted[str(component)]
                    or component.lstat().st_uid != 0 or component == requested):
                raise ValueError('拒绝符号链接目录：' + str(component))
            checked_directory(component.resolve())
        else:
            checked_directory(component, home=component == requested)
    home = requested.resolve()
    os.chmod(home, 0o700)
    return home

def ensure_parent(home, relative):
    current = home
    for name in relative.parts[:-1]:
        current = current / name
        if not current.exists() and not current.is_symlink():
            current.mkdir(mode=0o700, exist_ok=True)
        checked_directory(current, home=True)
        os.chmod(current, 0o700)
    return current

def atomic_file(home, relative, contents, mode):
    parent = ensure_parent(home, relative)
    target = parent / relative.name
    if target.exists() or target.is_symlink():
        state = target.lstat()
        if not stat.S_ISREG(state.st_mode) or state.st_uid != os.geteuid():
            raise ValueError('拒绝覆盖符号链接或不属于当前用户的文件：' + str(target))
    descriptor, temporary = tempfile.mkstemp(prefix='.bundle-', dir=str(parent))
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def guard_existing_controller(home):
    private = home / 'private'
    if not private.exists() and not private.is_symlink():
        return None
    checked_directory(private, home=True)
    descriptor = os.open(str(private / '.controller.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    guard = os.fdopen(descriptor, 'r+b')
    try:
        state = os.fstat(guard.fileno())
        if not stat.S_ISREG(state.st_mode) or state.st_uid != os.geteuid() or state.st_nlink != 1:
            raise ValueError('管理锁不是安全的用户文件。')
        os.fchmod(guard.fileno(), 0o600)
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return guard
    except BlockingIOError:
        guard.close()
        raise ValueError('管理菜单仍在运行，请先退出后重试。')
    except Exception:
        guard.close()
        raise

try:
    archive_bytes = base64.b64decode(''.join(PAYLOAD.split()).encode(), validate=True)
    if len(archive_bytes) > __MAX_BUNDLE__ or hashlib.sha256(archive_bytes).hexdigest() != EXPECTED:
        raise ValueError('内嵌安装包 SHA256 校验失败。')
    home = secure_home()
    lock_path = home / '.bundle.lock'
    descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'r+b') as lock:
        state = os.fstat(lock.fileno())
        if not stat.S_ISREG(state.st_mode) or state.st_uid != os.geteuid() or state.st_nlink != 1:
            raise ValueError('解压锁不是安全的用户文件。')
        os.fchmod(lock.fileno(), 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('管理菜单仍在运行，请先退出后重试。')
        guard = guard_existing_controller(home)
        try:
            with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
                entries = archive.infolist()
                names = [entry.filename for entry in entries]
                if len(names) != len(set(names)) or not set(REQUIRED) <= set(names) or not set(names) <= set(ALLOWED):
                    raise ValueError('安装包文件清单不符合白名单。')
                if sum(entry.file_size for entry in entries) > __MAX_BUNDLE__:
                    raise ValueError('安装包解压大小超限。')
                for entry in entries:
                    path = PurePosixPath(entry.filename)
                    if path.is_absolute() or '..' in path.parts or '\\\\' in entry.filename or not stat.S_ISREG(entry.external_attr >> 16):
                        raise ValueError('安装包含不安全的文件路径。')
                    mode = 0o755 if entry.filename == 'cn-egress.sh' else 0o644
                    atomic_file(home, path, archive.read(entry), mode)
        finally:
            if guard is not None:
                guard.close()
        # Keep the release lock through the menu so another download cannot
        # replace modules that a running controller will read on its next action.
        os.set_inheritable(lock.fileno(), True)
        os.environ['CNE_BUNDLE_LOCK_FD'] = str(lock.fileno())
        # Preserve terminal or piped input; the heredoc was bootstrap source only.
        os.dup2(3, 0)
        os.close(3)
        os.execv(sys.executable, [sys.executable, '-E', '-s', str(home / 'cn_egress.py'), *sys.argv[1:]])
except (OSError, ValueError, zipfile.BadZipFile) as error:
    raise SystemExit('一键管理包无法启动：' + str(error))
'''


def _regular_source(source: Path, name: str) -> bytes:
    path = source
    for part in Path(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Public source must not contain symlinks: " + name)
    state = path.stat()
    if not stat.S_ISREG(state.st_mode) or state.st_mode & 0o022:
        raise ValueError("Public source must be a regular file, not writable by others: " + name)
    if state.st_size > MAX_BUNDLE:
        raise ValueError("Public source exceeds package size limit: " + name)
    return path.read_bytes()


def _check_software(files: dict) -> None:
    present = [name for name in SOFTWARE if name.endswith(".tar.gz") and name in files]
    if not present:
        return
    receipt = "software/wstunnel-11.0.0-release.json"
    if receipt not in files:
        raise ValueError("Bundled software requires its official release digest receipt")
    metadata = json.loads(files[receipt])
    if metadata.get("tag_name") != "v11.0.0":
        raise ValueError("Bundled software metadata must describe pinned v11.0.0")
    assets = {asset.get("name"): asset.get("digest") for asset in metadata.get("assets", [])}
    for name in present:
        expected = assets.get(Path(name).name)
        actual = "sha256:" + hashlib.sha256(files[name]).hexdigest()
        if actual != expected:
            raise ValueError("Bundled software SHA256 differs from official receipt: " + name)
        if name.endswith("_amd64.tar.gz") and actual != "sha256:" + AMD64_SHA256:
            raise ValueError("Bundled amd64 software SHA256 differs from embedded known checksum")


def public_archive(source: Path) -> bytes:
    source = Path(source)
    if source.is_symlink():
        raise ValueError("Public source directory must not be a symlink")
    files = {name: _regular_source(source, name) for name in REQUIRED}
    for name in SOFTWARE:
        path = source / name
        if path.exists() or path.is_symlink():
            files[name] = _regular_source(source, name)
    _check_software(files)
    if sum(map(len, files.values())) > MAX_BUNDLE:
        raise ValueError("Public bundle exceeds size limit")
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, contents in files.items():
            # Stable zip metadata means the same public files produce the same ZIP.
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            mode = 0o755 if name == "cn-egress.sh" else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, contents)
    return output.getvalue()


def launcher(archive: bytes) -> bytes:
    if len(archive) > MAX_BUNDLE:
        raise ValueError("Embedded ZIP exceeds size limit")
    payload = "\n".join(textwrap.wrap(base64.b64encode(archive).decode(), width=76))
    bootstrap = (BOOTSTRAP.replace("__REQUIRED__", repr(REQUIRED))
                 .replace("__ALLOWED__", repr(ALLOWED))
                 .replace("__DIGEST__", repr(hashlib.sha256(archive).hexdigest()))
                 .replace("__MAX_BUNDLE__", str(MAX_BUNDLE))
                 .replace("__PAYLOAD__", payload))
    return (SHELL_HEADER + bootstrap + "\nCNE_ONECLICK_BOOTSTRAP_V1\n").encode()


def _atomic_output(path: Path, contents: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("Refusing unsafe release destination: " + str(path))
    descriptor, temporary = tempfile.mkstemp(prefix=".release-", dir=str(path.parent))
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def build(source: Path, output_dir: Path) -> dict:
    """Write only the public .sh and .zip; return their paths and ZIP SHA256."""
    archive = public_archive(source)
    output_dir = Path(output_dir)
    if output_dir.is_symlink():
        raise ValueError("Release output directory must not be a symlink")
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    shell_path = output_dir / "cn-egress-oneclick.sh"
    zip_path = output_dir / "一键安装管理包.zip"
    lock_path = output_dir / ".release-build.lock"
    descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+b") as lock:
        state = os.fstat(lock.fileno())
        if not stat.S_ISREG(state.st_mode) or state.st_uid != os.geteuid() or state.st_nlink != 1:
            raise ValueError("Release build lock is not a safe user file")
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        _atomic_output(shell_path, launcher(archive), 0o755)
        _atomic_output(zip_path, archive, 0o644)
    return {"launcher": shell_path, "zip": zip_path, "sha256": hashlib.sha256(archive).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the public one-click management package")
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "deployment")
    args = parser.parse_args()
    try:
        result = build(args.source, args.output)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.exit(1, "Build refused: " + str(error) + "\n")
    print("Public launcher:", result["launcher"])
    print("Public package:", result["zip"])
    print("Package SHA256:", result["sha256"])


if __name__ == "__main__":
    main()
