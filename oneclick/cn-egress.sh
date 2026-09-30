#!/usr/bin/env bash
# Run from the extracted directory; no curl-to-shell or embedded credentials.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  echo '需要 Python 3：Debian/Ubuntu 可执行 sudo apt-get install python3。' >&2
  exit 1
fi
exec python3 "$script_dir/cn_egress.py" "$@"
