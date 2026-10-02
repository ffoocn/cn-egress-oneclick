#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-readable-status.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
export CNE_NODE_LIBRARY=1
source "$ROOT/shell/node.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/output" >&2; exit 1; }
cne_n_exists() { return 0; }
cne_n_existing_role() { printf 'hk\n'; }
cne_n_user_transport() { printf 'awg2\n'; }
systemctl() { case $2 in cn-egress-obfs.service) printf 'inactive\n'; return 3;; *) printf 'active\n';; esac; }
date() { printf '1000\n'; }
cne_n_client_list() { printf 'iPhone\t10\tKEY_PHONE\nAndroid\t20\tKEY_ANDROID\n'; }
cne_n_show_handshakes() {
    case $2 in cne-cn) printf 'KEY_RELAY 990\n';; cne-users) printf 'KEY_PHONE 0\nKEY_ANDROID 950\nKEY_PROBE 999\n';; *) return 1;; esac
}
cne_n_status hk > "$WORK/output"
grep -Fq '节点：香港入口' "$WORK/output" || fail 'internal role leaked'
grep -Fq '连接服务：运行中' "$WORK/output" || fail 'active was untranslated'
grep -Fq '节点传输：已停止' "$WORK/output" || fail 'inactive was untranslated'
grep -Fq '香港 ↔ 大陆中转：最近连接 10 秒前' "$WORK/output" || fail 'link missing'
grep -Fq 'iPhone：尚未连接' "$WORK/output" || fail 'idle phone was not mapped'
grep -Fq 'Android：最近连接 50 秒前' "$WORK/output" || fail 'live phone was not mapped'
grep -Fq '未连接属正常' "$WORK/output" || fail 'idle status looked like server fault'
if grep -Eq 'KEY_|cne-users|cne-cn|active|角色：hk' "$WORK/output"; then fail 'technical identifiers or probe leaked'; fi
printf 'PASS: readable node status separates server links from named idle devices and hides the probe\n'
