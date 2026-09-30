#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
for source_file in build.sh shell/*.sh shell/assets/*.sh tests/*.sh; do bash -n "$source_file"; done
for test_file in tests/test_shell_bootstrap.sh tests/test_shell_transport.sh tests/test_shell_controller.sh tests/test_shell_render.sh tests/test_shell_clients.sh tests/test_shell_routes.sh tests/test_node.sh; do
    bash "$test_file"
done
bash build.sh
./cn-egress-oneclick.sh --help >/dev/null
printf 'All Shell checks passed. No real node services were changed.\n'
