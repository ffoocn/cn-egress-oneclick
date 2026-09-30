#!/usr/bin/env bash
# Run from the extracted directory; no curl-to-shell or embedded credentials.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/bootstrap-deps.sh"
cne_ensure_dependencies
exec "$CNE_PYTHON" -E -s "$script_dir/cn_egress.py" "$@"
