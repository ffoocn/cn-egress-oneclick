#!/usr/bin/env bash
# Verify the real menu entrypoint can export a saved file without VPN/SSH tools.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-lazy-bootstrap-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source "$ROOT/shell/controller.sh"
source "$ROOT/shell/download.sh"
source "$ROOT/shell/bootstrap.sh"
CNE_STATE=$WORK/state
CNE_TEMP=$CNE_STATE/session
mkdir -p "$CNE_TEMP" "$CNE_STATE/clients"
TRACE=$WORK/trace
: > "$TRACE"
printf '[Interface]\nPrivateKey = offline-fixture-private-key\nAddress = 10.77.10.2/32\n\n[Peer]\nPublicKey = offline-fixture-public-key\nEndpoint = 203.0.113.10:51820\n' > "$CNE_STATE/clients/phone.conf"
printf 'hk\t203.0.113.10\troot\t22\t%s\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tssh\n' "$WORK/moved-key" > "$CNE_STATE/nodes.tsv"

uname() { printf 'Linux\n'; }
id() { printf '1000\n'; }
command() {
    if [[ ${1:-} == -v ]]; then
        case ${2:-} in ssh|sshpass|wg|curl|openssl|qrencode|python|python3) return 1 ;; esac
        return 0
    fi
    builtin command "$@"
}
dpkg-query() { printf 'CA-package-query\n' >> "$TRACE"; return 1; }
dpkg() {
    printf 'dpkg %s\n' "$*" >> "$TRACE"
    [[ $* == --audit ]] || fail 'unexpected package operation'
    printf 'unrelated-service: package is unpacked but not configured\n'
}
sudo() { fail 'offline configuration export requested sudo'; }
apt-get() { fail 'offline configuration export accessed APT'; }
cne_root() { fail 'offline configuration export requested a package change'; }
ssh() { fail 'offline configuration export initiated SSH'; }
sshpass() { fail 'offline configuration export initiated SSH'; }
wg() { fail 'offline configuration export required WireGuard tools'; }
curl() { fail 'offline configuration export initiated a download'; }
openssl() { fail 'offline configuration export required OpenSSL'; }
qrencode() { fail 'missing QR renderer was invoked'; }
# Directory locking is covered separately; keep this test focused on entrypoint
# bootstrap, the actual menu and the actual configuration-export fallback.
cne_initialize() { cne_load_config; }

cne_main menu <<<'12
phone
2
0' > "$WORK/output" 2>&1 || fail 'missing VPN/SSH tools or broken dpkg blocked offline menu export'
grep -Fq 'PrivateKey = offline-fixture-private-key' "$WORK/output" || fail 'menu did not display the existing client file'
grep -Fq "$CNE_STATE/clients/phone.conf" "$WORK/output" || fail 'menu did not provide the existing file path'
grep -Fq '离线查看不连接服务器，也不安装依赖' "$WORK/output" || fail 'export did not clearly explain offline validity and dependency behavior'
[[ ! -s $TRACE ]] || fail 'offline menu accessed package state or prepared unrelated prerequisites'
if grep -Eq '操作未完成|配置导出未完成' "$WORK/output"; then fail 'offline export was reported as a failed action'; fi
printf 'PASS: real menu exports a saved profile despite missing VPN/SSH tools, missing CA package and broken dpkg\n'
printf 'unrecognized\tsetting\n' > "$CNE_STATE/downloads.tsv"
cne_main menu <<<'12
phone
2
0' > "$WORK/invalid-downloads" 2>&1 || fail 'invalid download settings blocked offline management'
grep -Fq 'PrivateKey = offline-fixture-private-key' "$WORK/invalid-downloads" || fail 'invalid download settings blocked saved profile display'
grep -Fq '18. 配置下载来源' "$WORK/invalid-downloads" || fail 'invalid download settings did not identify the repair entry'
[[ ! -s $TRACE ]] || fail 'invalid download settings prepared unrelated dependencies'
printf 'PASS: malformed download settings leave offline management and the repair menu accessible\n'
CNE_AUTH_READY[0]=1
if cne_authenticate 0 > "$WORK/auth-output" 2>&1; then fail 'missing SSH key was accepted from the authentication cache'; fi
[[ ${CNE_AUTH_READY[0]} == 0 && ! -s $TRACE ]] || fail 'missing SSH key prepared packages or kept cached authentication'
grep -Fq '2. 修改节点' "$WORK/auth-output" || fail 'missing SSH key did not explain how to fix the saved path'
printf 'PASS: a moved saved SSH key permits offline menu access and fails SSH before package or credential prompts\n'
printf 'Lazy bootstrap checks passed. No packages, host services or SSH connections changed.\n'
