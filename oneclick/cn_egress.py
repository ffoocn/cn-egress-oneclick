#!/usr/bin/env python3
"""Manage one HK -> one mainland relay -> one private egress over SSH."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import datetime
import fcntl
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
ROLES = ('hk', 'sh', 'exit')
LABELS = {'hk': '香港', 'sh': '大陆中转', 'exit': '国内出口'}
DEFAULTS = {
    'hk': {'host': '203.0.113.10', 'user': 'root', 'port': 22},
    'sh': {'host': '198.51.100.20', 'user': 'root', 'port': 22},
    'exit': {'host': '192.168.1.2', 'user': 'vpnadmin', 'port': 22},
    'transport': 'wss', 'wss_port': 443, 'user_port': 51820,
}
LOCAL_LAUNCHER = '''#!/bin/sh
if [ "$(id -u)" != 0 ]; then
    exec sudo /usr/bin/python3 -I /etc/cn-egress/oneclick-node.py --local "$@"
fi
exec /usr/bin/python3 -I /etc/cn-egress/oneclick-node.py --local "$@"
'''


class ToolError(Exception):
    pass


def acquire_release_lock():
    """Protect shared code even when a direct controller uses custom state."""
    inherited = os.environ.pop('CNE_BUNDLE_LOCK_FD', None)
    path = ROOT / '.bundle.lock'
    try:
        expected = path.lstat()
    except FileNotFoundError:
        if inherited is not None:
            raise ToolError('继承的发布锁不存在，无法启动管理菜单。')
        # Editable source and unpacked ZIP directories do not use this lock.
        return None
    descriptor = None
    try:
        if inherited is None:
            descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        else:
            try:
                inherited_descriptor = int(inherited)
            except ValueError:
                raise ToolError('继承的发布锁描述符无效。')
            if inherited_descriptor < 3:
                raise ToolError('继承的发布锁描述符无效。')
            descriptor = os.dup(inherited_descriptor)
        actual = os.fstat(descriptor)
        if (not stat.S_ISREG(expected.st_mode) or not stat.S_ISREG(actual.st_mode)
                or expected.st_uid != os.geteuid() or actual.st_uid != os.geteuid()
                or expected.st_mode & 0o077 or actual.st_mode & 0o077
                or expected.st_nlink != 1 or actual.st_nlink != 1
                or (expected.st_dev, expected.st_ino) != (actual.st_dev, actual.st_ino)):
            raise ToolError('发布锁不是安全的用户文件，或继承锁与管理目录不匹配。')
        try:
            # A valid inherited lock is converted from exclusive to shared.
            # An arbitrary environment descriptor cannot bypass the flock.
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ToolError('一键脚本正在更新，请稍后再启动管理菜单。')
        current = path.lstat()
        if (current.st_dev, current.st_ino) != (actual.st_dev, actual.st_ino):
            raise ToolError('发布锁在启动期间发生变化，请重试。')
        os.set_inheritable(descriptor, False)
        if inherited is not None:
            os.close(inherited_descriptor)
        lock = os.fdopen(descriptor, 'rb')
        descriptor = None
        return lock
    except OSError as error:
        raise ToolError('无法取得发布锁：' + str(error))
    finally:
        if descriptor is not None:
            os.close(descriptor)


def private_write(path, data):
    path = Path(path)
    if path.is_symlink():
        raise ToolError('拒绝写入符号链接：' + str(path))
    for parent in path.parents:
        if parent.is_symlink() and parent.lstat().st_uid != 0:
            raise ToolError('父目录含非系统符号链接：' + str(parent))
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data.encode() if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_topology(topology):
    if set(topology) - set(ROLES) - {'transport', 'wss_port', 'user_port'}:
        raise ToolError('节点配置含未知字段；大陆中转只能填写一个 sh 节点。')
    hosts = []
    for role in ROLES:
        node = topology.get(role)
        if not isinstance(node, dict):
            raise ToolError('缺少节点：' + role)
        if set(node) - {'host', 'user', 'port', 'identity_file', 'sudo_password_same_as_ssh', 'wan'}:
            raise ToolError('节点含未知字段：' + role)
        host = node.get('host', '')
        try:
            ipaddress.IPv4Address(host)
        except (ValueError, TypeError):
            raise ToolError('此版本节点地址请填写 IPv4 地址：' + role)
        if not re.fullmatch(r'[a-z_][a-z0-9_-]*', node.get('user', '')):
            raise ToolError('SSH 用户名无效：' + role)
        if not isinstance(node.get('port', 22), int) or not 1 <= node.get('port', 22) <= 65535:
            raise ToolError('SSH 端口无效：' + role)
        if node.get('identity_file') and not Path(node['identity_file']).expanduser().is_file():
            raise ToolError('SSH 私钥文件不存在：' + role)
        hosts.append(host)
    if len(set(hosts)) != 3:
        raise ToolError('三个角色必须使用不同机器。')
    if topology.get('transport', 'wss') != 'wss':
        raise ToolError('此工具只安装 WSS 版本，不自动降级。')
    for field, default in [('wss_port', 443), ('user_port', 51820)]:
        value = topology.get(field, default)
        if not isinstance(value, int) or not 1 <= value <= 65535:
            raise ToolError('端口无效：' + field)
    return topology


def validate_keypair(pair):
    for field in ('private', 'public'):
        try:
            raw = base64.b64decode(pair[field], validate=True)
        except (KeyError, ValueError, TypeError):
            raise ToolError('WireGuard 未返回有效密钥。')
        if len(raw) != 32:
            raise ToolError('WireGuard 密钥长度无效。')
    return pair


def new_keys(pairs):
    if not isinstance(pairs, list) or len(pairs) != 8:
        raise ToolError('WireGuard 密钥生成结果不完整。')
    pairs = [validate_keypair(pair) for pair in pairs]
    keys = {name: pairs[i] for i, name in enumerate(['hk_users', 'hk_cn', 'sh_cn', 'sh_exit', 'exit'])}
    keys['psks'] = {name: base64.b64encode(secrets.token_bytes(32)).decode()
                    for name in ['hk_sh', 'sh_exit']}
    keys['clients'] = {}
    for i, (name, address) in enumerate([('iPhone', 10), ('Android', 20), ('Windows', 30)]):
        keys['clients'][name] = dict(pairs[i + 5], address=address,
                                    psk=base64.b64encode(secrets.token_bytes(32)).decode())
    return keys


def encode_file(content, mode=0o600):
    data = content.encode() if isinstance(content, str) else content
    return {'content': base64.b64encode(data).decode(), 'mode': mode}


def manager_files():
    return {'/usr/local/sbin/cn-egress': encode_file(LOCAL_LAUNCHER, 0o755),
            '/etc/cn-egress/oneclick-node.py': encode_file((ROOT / 'node.py').read_bytes(), 0o700)}


class SSH:
    def __init__(self, topology, state, password_provider=None):
        self.topology, self.state = topology, Path(state)
        self.password_provider = password_provider or getpass.getpass
        self.credentials = {}
        self.temp = tempfile.TemporaryDirectory(prefix='cn-egress-auth-')
        self.directory = Path(self.temp.name)
        os.chmod(self.directory, 0o700)
        self.askpass = self.directory / 'askpass.py'
        private_write(self.askpass, '#!' + sys.executable + '\n'
                      'import json,os,pathlib\n'
                      'p=pathlib.Path(__file__).with_name("auth.json")\n'
                      'print(json.loads(p.read_text())[os.environ["CNE_ROLE"]]["login"])\n')
        self.askpass.chmod(0o700)
        self.known_hosts = self.state / 'known_hosts'
        if not self.known_hosts.exists():
            private_write(self.known_hosts, '')

    def prepare(self, role):
        if role in self.credentials:
            return
        node = self.topology[role]
        identity = node.get('identity_file')
        label = LABELS[role] + ' ' + node['host']
        login = self.password_provider(label + (' SSH 私钥口令（无口令可留空）：' if identity else ' SSH 密码：'))
        sudo = ''
        if node['user'] != 'root':
            sudo = login if not identity and node.get('sudo_password_same_as_ssh', True) else self.password_provider(label + ' sudo 密码：')
        self.credentials[role] = {'login': login, 'sudo': sudo}
        private_write(self.directory / 'auth.json', json.dumps(self.credentials))

    def call(self, role, action, **kwargs):
        self.prepare(role)
        node = self.topology[role]
        request = dict(kwargs, action=action, role=role)
        program = (ROOT / 'node.py').read_bytes()
        bootstrap = 'import base64;exec(compile(base64.b64decode(' + repr(base64.b64encode(program).decode()) + '),"cn-egress-node","exec"),{"__name__":"__main__"})'
        command = ['/usr/bin/python3', '-I', '-c', bootstrap]
        data = json.dumps(request, separators=(',', ':')).encode()
        if node['user'] != 'root':
            command = ['sudo', '-S', '-p', '', '--'] + command
            data = (self.credentials[role]['sudo'] + '\n').encode() + data
        args = ['ssh', '-F', '/dev/null', '-p', str(node.get('port', 22)),
                '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' + str(self.known_hosts),
                '-o', 'ConnectTimeout=10', '-o', 'NumberOfPasswordPrompts=1',
                '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3', '-o', 'LogLevel=ERROR']
        identity = node.get('identity_file')
        if identity:
            args += ['-o', 'IdentitiesOnly=yes', '-i', str(Path(identity).expanduser())]
        else:
            args += ['-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password']
        args += [node['user'] + '@' + node['host'], shlex.join(command)]
        env = os.environ.copy()
        env.update(SSH_ASKPASS=str(self.askpass), SSH_ASKPASS_REQUIRE='force', DISPLAY='cn-egress', CNE_ROLE=role)
        try:
            p = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=env, timeout=600 if action in ('install', 'keygen') else 90)
        except subprocess.TimeoutExpired:
            raise ToolError(LABELS[role] + ' 超时。服务器状态请运行 status / doctor 检查。')
        try:
            result = json.loads(p.stdout)
        except (ValueError, UnicodeDecodeError):
            # Do not echo remote stdout: install/inspect may contain private material.
            message = p.stderr.decode(errors='replace').strip()[-1500:]
            raise ToolError(LABELS[role] + ' SSH/执行失败：' + (message or '远端未返回有效 JSON'))
        if not result.get('ok'):
            error = result.get('error', {})
            raise ToolError(LABELS[role] + '：' + error.get('message', str(error)))
        return result.get('data', {})

    def close(self):
        self.credentials.clear()
        self.temp.cleanup()


class Controller:
    def __init__(self, state, config=None, password_provider=None):
        self._release_lock = acquire_release_lock()
        self._lock = None
        self.ssh = None
        try:
            requested_state = Path(state).expanduser().absolute()
            if requested_state.is_symlink():
                raise ToolError('私有状态目录不能是符号链接。')
            if requested_state.exists():
                metadata = requested_state.stat()
                if not requested_state.is_dir() or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
                    raise ToolError('私有状态目录必须由当前用户拥有，且不可被其他用户写入。')
            for parent in requested_state.parents:
                if parent.is_symlink() and parent.lstat().st_uid != 0:
                    raise ToolError('私有目录的父路径含非系统符号链接。')
            self.state = requested_state.resolve()
            self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.state.chmod(0o700)
            lock_path = self.state / '.controller.lock'
            if lock_path.is_symlink():
                raise ToolError('管理锁不能是符号链接。')
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            self._lock = os.fdopen(fd, 'a+')
            os.fchmod(fd, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ToolError('同一管理目录已有运行中的菜单；先退出该会话。')
            self.config = Path(config).expanduser().resolve() if config else self.state / 'topology.json'
            self.topology = validate_topology(json.loads(self.config.read_text()) if self.config.exists() else json.loads(json.dumps(DEFAULTS)))
            self.password_provider = password_provider
            self.ssh = SSH(self.topology, self.state, password_provider)
        except Exception:
            self.close()
            raise

    def close(self):
        try:
            if self.ssh is not None:
                self.ssh.close()
                self.ssh = None
        finally:
            if self._lock is not None:
                self._lock.close()
                self._lock = None
            if self._release_lock is not None:
                self._release_lock.close()
                self._release_lock = None

    def setup(self, source=None):
        if source:
            topology = validate_topology(json.loads(Path(source).read_text()))
        else:
            topology = json.loads(json.dumps(self.topology))
            print('只设置一个大陆中转节点；更换节点时不要同时保留上海与北京。')
            for role in ROLES:
                node = topology[role]
                for field, text, default in [('host', 'IPv4 地址', node['host']), ('user', 'SSH 用户', node['user']), ('port', 'SSH 端口', node.get('port', 22)), ('identity_file', '私钥路径（留空为密码登录）', node.get('identity_file', ''))]:
                    value = input(f'{LABELS[role]} {text} [{default}]：').strip() or default
                    if field == 'port':
                        value = int(value)
                    if field == 'identity_file' and not value:
                        node.pop(field, None)
                    else:
                        node[field] = value
            validate_topology(topology)
        private_write(self.config, json.dumps(topology, ensure_ascii=False, indent=2) + '\n')
        self.ssh.close()
        self.topology = topology
        self.ssh = SSH(topology, self.state, self.password_provider)
        print('节点配置已保存：' + str(self.config) + '；登录密码只在本次进程中使用。')

    def execute(self, action, target='all', **kwargs):
        roles = list(ROLES) if target == 'all' else [target]
        if action in ('start', 'restart'):
            roles = [role for role in ('sh', 'exit', 'hk') if role in roles]
        elif action in ('stop', 'uninstall'):
            roles = [role for role in ('hk', 'exit', 'sh') if role in roles]
        for role in roles:
            self.ssh.prepare(role)
        result = {}
        # Mutations remain ordered. Independent read-only operations may run together.
        if action in ('status', 'doctor', 'logs', 'inspect'):
            with ThreadPoolExecutor(max_workers=len(roles)) as pool:
                futures = {role: pool.submit(self.ssh.call, role, action, **kwargs) for role in roles}
                for role, future in futures.items():
                    try:
                        result[role] = future.result()
                    except ToolError as e:
                        result[role] = {'error': str(e)}
        else:
            for role in roles:
                result[role] = self.ssh.call(role, action, **kwargs)
        return result

    def show(self, action, target='all', **kwargs):
        results = self.execute(action, target, **kwargs)
        print(json.dumps(results, ensure_ascii=False, indent=2))
        if any('error' in result for result in results.values()):
            raise ToolError('部分节点检查失败，详见上方结果。')
        return results

    def install(self, adopt_only=False):
        if not self.config.exists():
            self.setup()
        inspections = self.execute('inspect')
        if any('error' in value for value in inspections.values()):
            self.print_safe(inspections)
            raise ToolError('SSH / 节点预检失败；尚未安装。')
        pending = self.state / 'pending-install.json'
        if pending.exists():
            raise ToolError('存在未完成安装记录；运行 rollback-install 安全回滚后重新安装。')
        installed = [role for role, value in inspections.items() if value.get('installed')]
        if installed:
            if len(installed) != 3:
                raise ToolError('只有部分节点已部署；为避免覆盖密钥已停止。请恢复同一套三节点后使用 adopt。')
            for role in ROLES:
                self.print_safe({role: self.ssh.call(role, 'adopt', files=manager_files())})
            print('现有三节点已纳入管理，原隧道、密钥、证书和客户端配置保留。')
            return
        if adopt_only:
            raise ToolError('未发现完整现有部署；新安装请运行 install。')
        print('开始新安装：保留原主机路由，生成独立 WireGuard 密钥及 mTLS 证书。')
        import render
        for role, info in inspections.items():
            if not info.get('systemd'):
                raise ToolError(LABELS[role] + ' 需要 Linux systemd。')
            if info.get('arch') not in ('x86_64', 'amd64'):
                raise ToolError(LABELS[role] + '：此版本的节点安装支持 Linux x86_64。')
            node_time = info.get('utc_time')
            if isinstance(node_time, (int, float)) and abs(time.time() - node_time) > 120:
                raise ToolError(LABELS[role] + ' 时钟与控制器相差超过两分钟，先校准时间再签发证书。')
        if inspections['exit'].get('forwarding', {}).get('ipv4') != 1:
            raise ToolError('出口机尚未开启 IPv4 转发。为保留原业务网络，脚本不自动改变此宿主参数。')
        wan = inspections['exit'].get('wan_interface')
        if not wan:
            raise ToolError('无法识别出口机原出网接口。')
        self.topology['exit']['wan'] = wan
        private_write(self.config, json.dumps(self.topology, ensure_ascii=False, indent=2) + '\n')
        keys = new_keys(self.ssh.call('hk', 'keygen', count=8).get('keys'))
        deployment_id = str(uuid.uuid4())
        tls = render.generate_pki(self.topology, self.state / 'pki' / deployment_id)
        binaries = {}
        for role in ROLES:
            arch = inspections[role].get('arch', 'amd64')
            arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(arch, arch)
            if arch not in binaries:
                bundled = ROOT / 'software'
                cache = bundled if (bundled / f'wstunnel_11.0.0_linux_{arch}.tar.gz').exists() else self.state / 'cache'
                binaries[arch] = render.fetch_wstunnel(cache, arch)
        plans = {}
        for role in ROLES:
            arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(inspections[role].get('arch', 'amd64'), inspections[role].get('arch', 'amd64'))
            plans[role] = render.make_plan(self.topology, keys, tls, ROOT / 'assets', binaries[arch])[role]
            plans[role].update(manager_files())
        for role in ROLES:
            self.ssh.call(role, 'preflight', files=plans[role])
        private_write(self.state / 'keys.json', json.dumps(keys))
        transaction = {'topology': self.topology, 'deployment_id': deployment_id,
                       'installed': [], 'attempted': [], 'pki_dir': str(self.state / 'pki' / deployment_id)}
        private_write(pending, json.dumps(transaction))
        complete = []
        try:
            for role in ('sh', 'exit', 'hk'):
                print('安装 ' + LABELS[role] + '…', flush=True)
                registry = [{'name': name, 'public_key': record['public'],
                             'address': '10.77.10.' + str(record['address']) + '/32'}
                            for name, record in keys['clients'].items()] if role == 'hk' else []
                transaction['attempted'].append(role)
                private_write(pending, json.dumps(transaction))
                self.print_safe({role: self.ssh.call(role, 'install', files=plans[role], client_registry=registry,
                                                   deployment_id=deployment_id)})
                complete.append(role)
                transaction['installed'] = complete
                private_write(pending, json.dumps(transaction))
        except Exception:
            print('安装中止。已完成节点：' + ', '.join(complete) + '；运行 rollback-install 安全回滚，逐节点备份保留。', file=sys.stderr)
            raise
        clients = {}
        for name, client in keys['clients'].items():
            profile = render.client_profile(name, client['address'], client['private'], keys['hk_users']['public'], client['psk'], self.topology['hk']['host'], self.topology.get('user_port', 51820))
            path = self.state / 'clients' / (name + '.conf')
            private_write(path, profile)
            clients[name] = dict(client, path=str(path))
        private_write(self.state / 'clients.json', json.dumps(clients, ensure_ascii=False))
        pending.unlink()
        print('三节点安装完成。手机/Windows 配置目录：' + str(self.state / 'clients'))
        self.show('doctor')

    def rollback_install(self):
        pending = self.state / 'pending-install.json'
        if not pending.exists():
            print('没有未完成的安装。')
            return
        transaction = json.loads(pending.read_text())
        if transaction.get('topology') != self.topology:
            raise ToolError('节点配置与安装记录不同；恢复记录中的原节点配置后再回滚。')
        for role in reversed(transaction.get('attempted', [])):
            info = self.ssh.call(role, 'inspect')
            if not info.get('installed'):
                continue
            manifest = info.get('manifest', {})
            if manifest.get('origin') != 'fresh-install' or manifest.get('deployment_id') != transaction['deployment_id']:
                raise ToolError(LABELS[role] + ' 不属于此次安装；已停止，避免卸载其他部署。')
            self.print_safe({role: self.ssh.call(role, 'uninstall', confirm=True,
                                               deployment_id=transaction['deployment_id'], expected_origin='fresh-install')})
        archive = self.state / 'installation-history' / transaction['deployment_id']
        archive.mkdir(parents=True, mode=0o700, exist_ok=True)
        private_write(archive / 'transaction.json', pending.read_bytes())
        if (self.state / 'keys.json').exists():
            private_write(archive / 'keys.json', (self.state / 'keys.json').read_bytes())
            (self.state / 'keys.json').unlink()
        pending.unlink()
        print('此次未完成安装已回滚。记录与密钥保留在私有历史目录，可重新运行 install。')

    def backup(self, target='all'):
        results = self.show('backup', target)
        directory = self.state / 'backups'
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3)
        path = directory / ('controller-' + stamp + '.tar.gz')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            with tarfile.open(fileobj=stream, mode='w:gz') as archive:
                for candidate in sorted(self.state.rglob('*')):
                    relative = candidate.relative_to(self.state)
                    if relative.parts[0] in ('backups', 'cache') or candidate.is_symlink() or candidate.name == '.controller.lock':
                        continue
                    if candidate.is_file():
                        archive.add(candidate, arcname='controller/' + str(relative), recursive=False)
                if self.config.parent != self.state:
                    archive.add(self.config, arcname='controller/topology.json', recursive=False)
                receipt = json.dumps(results, ensure_ascii=False, indent=2).encode()
                item = tarfile.TarInfo('controller/remote-backups.json')
                item.mode, item.size = 0o600, len(receipt)
                import io
                archive.addfile(item, io.BytesIO(receipt))
        print('控制器备份：' + str(path) + '（含配置私钥，权限 600；服务器备份位置见上方。）')
        return results

    @staticmethod
    def print_safe(value):
        print(json.dumps(value, ensure_ascii=False, indent=2))

    def clients(self, action, name=None, output=None):
        registry_file = self.state / 'clients.json'
        registry = json.loads(registry_file.read_text()) if registry_file.exists() else {}
        if action == 'list':
            self.print_safe(self.ssh.call('hk', 'client_list'))
            print('本控制器可导出配置：' + (', '.join(registry) or '无；现有手机配置继续使用原文件。'))
            return
        if not name or not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', name):
            raise ToolError('客户端名称使用 1–32 位英文字母、数字、下划线或短横线。')
        if action == 'add':
            if name in registry:
                client = registry[name]
                if client.get('state') != 'pending':
                    raise ToolError('客户端已存在；使用 client export 导出。')
                info = self.ssh.call('hk', 'client_list')
                existing = [peer for peer in info.get('clients', []) if peer.get('public_key') == client['public']]
                if existing:
                    wanted = '10.77.10.' + str(client['address']) + '/32'
                    if len(existing) != 1 or existing[0].get('address') != wanted or not existing[0].get('managed'):
                        raise ToolError('远端存在同公钥但登记信息不一致的客户端；未改变其配置。')
                else:
                    self.ssh.call('hk', 'client_add', name=name, public_key=client['public'],
                                  preshared_key=client['psk'], address='10.77.10.' + str(client['address']))
                client['state'] = 'active'
                private_write(registry_file, json.dumps(registry, ensure_ascii=False))
                print('已恢复此前未完成的登记，配置文件：' + client['path'])
                return
            info = self.ssh.call('hk', 'client_list')
            used = {10, 20, 30}
            for peer in info.get('clients', []):
                allowed = peer.get('allowed_ips', [])
                if isinstance(allowed, str):
                    allowed = re.split(r'[, ]+', allowed)
                for cidr in allowed:
                    try:
                        network = ipaddress.ip_network(cidr, strict=False)
                        if network.version == 4:
                            for candidate in range(2, 250):
                                if ipaddress.ip_address('10.77.10.' + str(candidate)) in network:
                                    used.add(candidate)
                        elif network.version == 6:
                            for candidate in range(2, 250):
                                if ipaddress.ip_address(f'fd77:77:10::{candidate}') in network:
                                    used.add(candidate)
                    except ValueError:
                        pass
            if 'next_address' in info:
                assigned = info['next_address']
                if assigned is None:
                    address = None
                else:
                    try:
                        candidate_ip = ipaddress.IPv4Interface(str(assigned))
                        address = int(str(candidate_ip.ip).rsplit('.', 1)[1])
                    except ValueError:
                        raise ToolError('服务器返回了无效的客户端地址。')
                    if candidate_ip.ip not in ipaddress.IPv4Network('10.77.10.0/24') or address in used or not 2 <= address <= 249:
                        raise ToolError('服务器返回的客户端地址已占用或不在可分配范围。')
            else:
                address = next((i for i in range(2, 250) if i not in used), None)
            if address is None:
                raise ToolError('客户端网段没有可分配地址。')
            server_public = info.get('server_public')
            if not server_public:
                raise ToolError('未取得香港用户入口公钥。')
            pair = self.ssh.call('hk', 'keygen', count=1).get('keys', [])
            if len(pair) != 1:
                raise ToolError('客户端密钥生成失败。')
            client = dict(validate_keypair(pair[0]), address=address, psk=base64.b64encode(secrets.token_bytes(32)).decode())
            import render
            profile = render.client_profile(name, address, client['private'], server_public, client['psk'], self.topology['hk']['host'], self.topology.get('user_port', 51820))
            path = self.state / 'clients' / (name + '.conf')
            # Persist the recovery material before touching the remote peer.
            private_write(path, profile)
            client['path'] = str(path)
            client['state'] = 'pending'
            registry[name] = client
            private_write(registry_file, json.dumps(registry, ensure_ascii=False))
            self.ssh.call('hk', 'client_add', name=name, public_key=client['public'],
                          preshared_key=client['psk'], address='10.77.10.' + str(address))
            client['state'] = 'active'
            private_write(registry_file, json.dumps(registry, ensure_ascii=False))
            print('客户端已添加，配置文件：' + str(path))
        elif action == 'remove':
            if name not in registry:
                raise ToolError('只能移除本控制器创建的客户端，原有手机配置保留。')
            client = registry[name]
            info = self.ssh.call('hk', 'client_list')
            if any(peer.get('public_key') == client['public'] for peer in info.get('clients', [])):
                self.ssh.call('hk', 'client_remove', name=name, public_key=client['public'])
            client['state'] = 'revoked'
            private_write(registry_file, json.dumps(registry, ensure_ascii=False))
            print('客户端已撤销；本地配置留作记录，将无法连接。')
        elif action == 'export':
            if name not in registry or registry[name].get('state', 'active') != 'active':
                raise ToolError('没有该客户端的有效导出配置。')
            source = Path(registry[name]['path'])
            destination = Path(output).expanduser() if output else self.state / 'exports' / (name + '.conf')
            private_write(destination, source.read_bytes())
            print('配置已导出：' + str(destination.resolve()))
            if shutil.which('qrencode'):
                png = destination.with_suffix('.png')
                p = subprocess.run(['qrencode', '-t', 'PNG', '-o', '-'], input=source.read_bytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if p.returncode:
                    raise ToolError('二维码生成失败，配置文件仍可导入。')
                private_write(png, p.stdout)
                print('二维码：' + str(png.resolve()))

    def menu(self):
        while True:
            print('\n一键安装与管理')
            print('1 配置 SSH 节点   2 一键安装/接管现有部署   3 状态   4 诊断')
            print('5 启动   6 停止   7 重启   8 日志   9 备份')
            print('10 客户端列表   11 新增客户端   12 导出配置   13 撤销客户端')
            print('14 卸载 VPN 服务   15 回滚未完成安装   0 退出')
            choice = input('请选择：').strip()
            try:
                if choice == '0':
                    return
                if choice == '1':
                    self.setup()
                elif choice == '2':
                    self.install()
                elif choice in ('3', '4', '5', '6', '7', '8', '9'):
                    action = {'3': 'status', '4': 'doctor', '5': 'start', '6': 'stop', '7': 'restart', '8': 'logs', '9': 'backup'}[choice]
                    self.backup() if action == 'backup' else self.show(action)
                elif choice == '10':
                    self.clients('list')
                elif choice in ('11', '12', '13'):
                    self.clients({'11': 'add', '12': 'export', '13': 'remove'}[choice], input('客户端名称：').strip())
                elif choice == '14':
                    if input('卸载三个节点的 VPN 服务，原有业务保留。输入 UNINSTALL 确认：') == 'UNINSTALL':
                        self.show('uninstall', confirm=True)
                elif choice == '15':
                    self.rollback_install()
                else:
                    print('请选择菜单中的编号。')
            except (ToolError, ValueError, OSError, subprocess.CalledProcessError) as e:
                print('操作未完成：' + str(e), file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description='一键安装与管理')
    parser.add_argument('--state-dir', default=str(ROOT / 'private'))
    parser.add_argument('--config', help='节点 JSON 配置；不应包含密码')
    sub = parser.add_subparsers(dest='command')
    setup = sub.add_parser('setup'); setup.add_argument('--from', dest='source')
    sub.add_parser('menu'); sub.add_parser('install'); sub.add_parser('adopt'); sub.add_parser('rollback-install')
    for action in ['status', 'doctor', 'start', 'stop', 'restart', 'logs', 'backup', 'uninstall']:
        p = sub.add_parser(action)
        p.add_argument('--target', choices=['all', *ROLES], default='all')
        if action == 'uninstall':
            p.add_argument('--yes', action='store_true', help='确认卸载所选节点 VPN，先备份')
    client = sub.add_parser('client')
    client.add_argument('action', choices=['list', 'add', 'remove', 'export'])
    client.add_argument('name', nargs='?'); client.add_argument('--output')
    args = parser.parse_args(argv)
    if not shutil.which('ssh'):
        parser.error('需要 OpenSSH 客户端。')
    controller = None
    try:
        controller = Controller(args.state_dir, args.config)
        command = args.command or 'menu'
        if command == 'setup':
            controller.setup(args.source)
        elif command in ('install', 'adopt'):
            controller.install(command == 'adopt')
        elif command == 'menu':
            controller.menu()
        elif command == 'rollback-install':
            controller.rollback_install()
        elif command == 'backup':
            controller.backup(args.target)
        elif command == 'client':
            controller.clients(args.action, args.name, args.output)
        else:
            if command == 'uninstall' and not args.yes:
                raise ToolError('卸载需要 --yes 或在菜单输入 UNINSTALL。')
            controller.show(command, args.target, **({'confirm': True} if command == 'uninstall' else {}))
        return 0
    except (ToolError, ValueError, OSError, subprocess.CalledProcessError) as e:
        print('操作未完成：' + str(e), file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print('\n已退出。')
        return 130
    finally:
        if controller:
            controller.close()


if __name__ == '__main__':
    sys.exit(main())
