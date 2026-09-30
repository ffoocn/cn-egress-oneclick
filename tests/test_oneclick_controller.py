import base64
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'oneclick'))
import cn_egress as controller


def pair(value):
    return {'private': base64.b64encode(bytes([value]) * 32).decode(),
            'public': base64.b64encode(bytes([value + 1]) * 32).decode()}


class FakeSSH:
    def __init__(self, replies):
        self.replies, self.calls = replies, []

    def prepare(self, role):
        pass

    def call(self, role, action, **request):
        self.calls.append((role, action, request))
        reply = self.replies.get((role, action), {})
        return reply(role, action, request) if callable(reply) else reply

    def close(self):
        pass


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name) / 'state'
        self.controller = controller.Controller(self.state, password_provider=lambda _: 'test-password')
        controller.private_write(self.controller.config, json.dumps(self.controller.topology))
        self.controller.ssh.close()
        self.output = io.StringIO()

    def fake(self, replies):
        self.controller.ssh = FakeSSH(replies)
        return self.controller.ssh

    def tearDown(self):
        self.controller.close()
        self.temp.cleanup()

    def test_existing_install_only_adopts_without_key_rotation_or_service_restart(self):
        ssh = self.fake({(role, 'inspect'): {'installed': True} for role in controller.ROLES})
        with contextlib.redirect_stdout(self.output):
            self.controller.install()
        self.assertEqual([action for _, action, _ in ssh.calls], ['inspect'] * 3 + ['adopt'] * 3)
        for _, action, request in ssh.calls:
            if action == 'adopt':
                self.assertEqual(set(request['files']), {'/usr/local/sbin/cn-egress', '/etc/cn-egress/oneclick-node.py'})
        self.assertFalse((self.state / 'keys.json').exists())
        self.assertFalse((self.state / 'pki').exists())

    def test_partial_unknown_deployment_is_not_overwritten(self):
        ssh = self.fake({(role, 'inspect'): {'installed': role == 'hk'} for role in controller.ROLES})
        with self.assertRaises(controller.ToolError):
            self.controller.install()
        self.assertTrue(all(action == 'inspect' for _, action, _ in ssh.calls))

    def test_fresh_exit_forwarding_zero_fails_before_keygen(self):
        ssh = self.fake({(role, 'inspect'): {'installed': False, 'systemd': True, 'forwarding': {'ipv4': 0}}
                         for role in controller.ROLES})
        with self.assertRaises(controller.ToolError):
            with contextlib.redirect_stdout(self.output):
                self.controller.install()
        self.assertTrue(all(action == 'inspect' for _, action, _ in ssh.calls))

    def test_install_rollback_matches_transaction_even_if_response_was_lost(self):
        transaction = {'deployment_id': 'txn-123', 'topology': self.controller.topology,
                       'installed': ['sh'], 'attempted': ['sh', 'exit']}
        controller.private_write(self.state / 'pending-install.json', json.dumps(transaction))
        controller.private_write(self.state / 'keys.json', json.dumps({'private': 'keep-for-recovery'}))
        ssh = self.fake({(role, 'inspect'): {'installed': True, 'manifest': {
                            'origin': 'fresh-install', 'deployment_id': 'txn-123'}} for role in ('sh', 'exit')})
        with contextlib.redirect_stdout(self.output):
            self.controller.rollback_install()
        self.assertEqual([(role, action) for role, action, _ in ssh.calls],
                         [('exit', 'inspect'), ('exit', 'uninstall'), ('sh', 'inspect'), ('sh', 'uninstall')])
        self.assertFalse((self.state / 'pending-install.json').exists())
        self.assertTrue((self.state / 'installation-history/txn-123/keys.json').exists())
        self.assertTrue(all(request.get('deployment_id') == 'txn-123'
                            for _, action, request in ssh.calls if action == 'uninstall'))

    def test_rollback_cannot_remove_another_deployment(self):
        controller.private_write(self.state / 'pending-install.json', json.dumps({
            'deployment_id': 'our-txn', 'topology': self.controller.topology, 'attempted': ['hk']}))
        ssh = self.fake({('hk', 'inspect'): {'installed': True, 'manifest': {
                            'origin': 'fresh-install', 'deployment_id': 'someone-else'}}})
        with self.assertRaises(controller.ToolError):
            self.controller.rollback_install()
        self.assertEqual([action for _, action, _ in ssh.calls], ['inspect'])
        self.assertTrue((self.state / 'pending-install.json').exists())

    def test_client_address_allocation_respects_all_existing_allowed_networks(self):
        ssh = self.fake({('hk', 'client_list'): {'server_public': pair(4)['public'], 'clients': [
            {'allowed_ips': ['10.77.10.0/29']}, {'allowed_ips': ['10.77.10.10/32']}]},
            ('hk', 'keygen'): {'keys': [pair(8)]}})
        with contextlib.redirect_stdout(self.output):
            self.controller.clients('add', 'new_phone')
        request = next(request for _, action, request in ssh.calls if action == 'client_add')
        self.assertEqual(request['address'], '10.77.10.8')
        self.assertIn('preshared_key', request)
        self.assertNotIn(pair(8)['private'], self.output.getvalue())
        self.assertEqual((self.state / 'clients/new_phone.conf').stat().st_mode & 0o777, 0o600)

    def test_pending_client_retries_same_credentials_without_generating_new_key(self):
        existing = dict(pair(10), psk=pair(11)['private'], address=8,
                        path=str(self.state / 'clients/phone.conf'), state='pending')
        controller.private_write(self.state / 'clients.json', json.dumps({'phone': existing}))
        ssh = self.fake({('hk', 'client_list'): {'clients': []}})
        with contextlib.redirect_stdout(self.output):
            self.controller.clients('add', 'phone')
        self.assertEqual([action for _, action, _ in ssh.calls], ['client_list', 'client_add'])
        request = ssh.calls[-1][2]
        self.assertEqual(request['public_key'], existing['public'])
        self.assertEqual(request['preshared_key'], existing['psk'])
        self.assertEqual(json.loads((self.state / 'clients.json').read_text())['phone']['state'], 'active')

    def test_config_rejects_duplicate_roles_or_embedded_passwords(self):
        topology = json.loads(json.dumps(controller.DEFAULTS))
        topology['sh']['host'] = topology['hk']['host']
        with self.assertRaises(controller.ToolError):
            controller.validate_topology(topology)
        topology = json.loads(json.dumps(controller.DEFAULTS))
        topology['hk']['password'] = 'not-a-supported-field'
        with self.assertRaises(controller.ToolError):
            controller.validate_topology(topology)

    def test_controller_lock_prevents_parallel_registry_overwrite(self):
        with self.assertRaises(controller.ToolError):
            controller.Controller(self.state, password_provider=lambda _: '')


class SSHTests(unittest.TestCase):
    def test_password_not_in_argv_and_untrusted_stdout_never_echoed(self):
        with tempfile.TemporaryDirectory() as directory:
            ssh = controller.SSH(controller.DEFAULTS, directory, lambda _: 'test-login-private-marker')
            captured = {}

            def bad_reply(args, **kwargs):
                captured['args'] = args
                captured['input'] = kwargs['input']
                return type('Result', (), {'stdout': b'PrivateKey = confidential', 'stderr': b'', 'returncode': 1})()

            try:
                with patch.object(controller.subprocess, 'run', side_effect=bad_reply):
                    with self.assertRaises(controller.ToolError) as error:
                        ssh.call('hk', 'status')
                self.assertNotIn('confidential', str(error.exception))
                self.assertNotIn('test-login-private-marker', ' '.join(captured['args']))
                self.assertNotIn(b'test-login-private-marker', captured['input'])
                self.assertIn('-I', captured['args'][-1])
                temp_auth = ssh.directory
            finally:
                ssh.close()
            self.assertFalse(temp_auth.exists())


class ReleaseLockTests(unittest.TestCase):
    """Exercise real local flock protection without connecting to any node."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'code'
        self.root.mkdir(mode=0o700)
        self.path = self.root / '.bundle.lock'
        self.root_patch = patch.object(controller, 'ROOT', self.root)
        self.root_patch.start()
        self.environment = patch.dict(os.environ)
        self.environment.start()
        os.environ.pop('CNE_BUNDLE_LOCK_FD', None)

    def tearDown(self):
        self.environment.stop()
        self.root_patch.stop()
        self.temp.cleanup()

    def create_lock(self):
        descriptor = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        return os.fdopen(descriptor, 'r+b')

    def new_controller(self, name='custom-state'):
        return controller.Controller(Path(self.temp.name) / name, password_provider=lambda _: '')

    def test_editable_tree_does_not_create_release_lock(self):
        instance = self.new_controller()
        try:
            self.assertIsNone(instance._release_lock)
            self.assertFalse(self.path.exists())
        finally:
            instance.close()

    def test_custom_state_protects_release_until_controller_exits(self):
        with self.create_lock() as updater:
            instance = self.new_controller()
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                instance.close()
            fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_multiple_custom_states_share_code_but_block_updates(self):
        with self.create_lock() as updater:
            first = self.new_controller('first-state')
            second = self.new_controller('second-state')
            try:
                first.close()
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                first.close()
                second.close()
            fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_active_extraction_refuses_before_state_creation(self):
        with self.create_lock() as updater:
            fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(controller.ToolError, '正在更新'):
                self.new_controller()
            self.assertFalse((Path(self.temp.name) / 'custom-state').exists())

    def test_inherited_lock_is_verified_held_and_not_propagated(self):
        self.path.touch(mode=0o600)
        inherited = os.open(self.path, os.O_RDWR)
        fcntl.flock(inherited, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.set_inheritable(inherited, True)
        os.environ['CNE_BUNDLE_LOCK_FD'] = str(inherited)
        instance = None
        try:
            instance = self.new_controller()
            self.assertNotIn('CNE_BUNDLE_LOCK_FD', os.environ)
            # Controller setup may reuse the closed FD number for its state
            # lock; the original release handle must no longer occupy it.
            try:
                reused = os.fstat(inherited)
            except OSError:
                pass
            else:
                release = self.path.stat()
                self.assertNotEqual((reused.st_dev, reused.st_ino),
                                    (release.st_dev, release.st_ino))
            self.assertFalse(os.get_inheritable(instance._release_lock.fileno()))
            with self.path.open('r+b') as updater:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                instance.close()
                fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if instance is not None:
                instance.close()
            else:
                os.close(inherited)

    def test_arbitrary_inherited_descriptor_cannot_bypass_lock(self):
        with self.create_lock() as updater:
            fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            other = Path(self.temp.name) / 'other-lock'
            descriptor = os.open(other, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                os.environ['CNE_BUNDLE_LOCK_FD'] = str(descriptor)
                with self.assertRaisesRegex(controller.ToolError, '不匹配'):
                    self.new_controller()
                self.assertNotIn('CNE_BUNDLE_LOCK_FD', os.environ)
                self.assertEqual(os.fstat(descriptor).st_ino, other.stat().st_ino)
            finally:
                os.close(descriptor)
            with self.assertRaisesRegex(controller.ToolError, '正在更新'):
                self.new_controller()

    def test_unsafe_lock_and_symbolic_link_are_rejected(self):
        with self.create_lock():
            self.path.chmod(0o666)
            with self.assertRaisesRegex(controller.ToolError, '安全'):
                self.new_controller()
        self.path.unlink()
        target = Path(self.temp.name) / 'target'
        target.touch(mode=0o600)
        self.path.symlink_to(target)
        with self.assertRaises(controller.ToolError):
            self.new_controller()

    def test_failed_controller_construction_releases_code_lock(self):
        state = Path(self.temp.name) / 'custom-state'
        state.mkdir(mode=0o700)
        controller.private_write(state / 'topology.json', '{}')
        with self.create_lock() as updater:
            with self.assertRaises(controller.ToolError):
                self.new_controller()
            fcntl.flock(updater.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)


if __name__ == '__main__':
    unittest.main()
