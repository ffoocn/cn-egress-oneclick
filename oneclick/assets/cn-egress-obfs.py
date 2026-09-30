#!/usr/bin/python3
"""Run only the authenticated WSS transport; it never changes host routes."""
import os
from pathlib import Path

config = Path('/etc/cn-egress-wss')
role = (config / 'role').read_text().strip()
if role not in ('hk', 'sh', 'exit'):
    raise SystemExit('Invalid transport role')

binary = '/opt/cn-egress/wstunnel-11.0.0/wstunnel'
args = [binary, 'server' if role == 'sh' else 'client',
        '--no-color', '--log-lvl', 'INFO', '--nb-worker-threads', '2',
        '--tls-certificate', str(config / 'node.crt'),
        '--tls-private-key', str(config / 'node.key')]
if role == 'sh':
    args += ['--tls-client-ca-certs', str(config / 'ca.crt'),
             '--restrict-config', str(config / 'restrictions.yaml'),
             'wss://0.0.0.0:443']
else:
    # Limit CA trust to this process, without changing the host trust store.
    os.environ['SSL_CERT_FILE'] = str(config / 'ca.crt')
    os.environ['SSL_CERT_DIR'] = str(config / 'empty-ca')
    local_port, remote_port = (51831, 51821) if role == 'hk' else (51832, 51822)
    args += ['--tls-verify-certificate', '-L',
             f'udp://127.0.0.1:{local_port}:127.0.0.1:{remote_port}?timeout_sec=0',
             'wss://198.51.100.20:443']
for variable in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
                 'http_proxy', 'https_proxy', 'all_proxy'):
    os.environ.pop(variable, None)
os.execv(binary, args)
