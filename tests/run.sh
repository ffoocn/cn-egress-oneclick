#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
for source_file in build.sh shell/*.sh shell/assets/*.sh tests/*.sh; do bash -n "$source_file"; done
for test_file in tests/test_shell_bootstrap.sh tests/test_shell_optional_qr.sh tests/test_shell_transport.sh tests/test_shell_local.sh tests/test_shell_lazy_bootstrap.sh tests/test_shell_awg.sh tests/test_shell_cleanup.sh tests/test_shell_controller.sh tests/test_shell_usability.sh tests/test_shell_render.sh tests/test_shell_clients.sh tests/test_shell_client_lifecycle.sh tests/test_shell_routes.sh tests/test_shell_probe.sh tests/test_node.sh tests/test_node_safety.sh tests/test_node_maintenance.sh tests/test_shell_backup.sh tests/test_shell_renew.sh tests/test_shell_download.sh tests/test_shell_automatic.sh; do
    bash "$test_file"
done
bash build.sh
./cn-egress-oneclick.sh --help >/dev/null
printf 'All Shell checks passed. No real node services were changed.\n'
