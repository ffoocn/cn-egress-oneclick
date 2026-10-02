#!/usr/bin/env bash
# Verify device handoff and uncertain-add recovery without hosts or packages.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-delivery.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
PRIVATE=$(openssl rand -base64 32)
PUBLIC=$(openssl rand -base64 32)
SERVER=$(openssl rand -base64 32)
PSK=$(openssl rand -base64 32)
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${CNE_STATE:-}/output ]] || cat "$CNE_STATE/output" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected: $2"; fi; }
setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/render.sh"
    CNE_STATE=$WORK/$1; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_STATE/clients" "$CNE_TEMP"
    TRACE=$CNE_STATE/trace; : > "$TRACE"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    NETWORK=ok; ADD_REPLY=ok
    printf 'phone\t2\t%s\n' "$PUBLIC" > "$CNE_STATE/peers"
    cne_render_client "$CNE_STATE/clients/phone.conf" 2 "$PRIVATE" "$SERVER" "$PSK" 203.0.113.10 51820 wireguard
    cne_ui_interactive() { return 0; }
    cne_mutation_guard() { return 0; }
    cne_require_config() { return 0; }
    cne_bootstrap() { printf 'bootstrap %s\n' "$*" >> "$TRACE"; return 0; }
    cne_authenticate() { return 0; }
    wg() {
        case $1 in
            genkey) printf 'keygen\n' >> "$TRACE"; printf '%s\n' "$PRIVATE";;
            genpsk) printf '%s\n' "$PSK";;
            pubkey) cat >/dev/null; printf '%s\n' "$PUBLIC";;
            *) fail 'unexpected key action';;
        esac
    }
    cne_remote() {
        printf 'rpc %s\n' "$2" >> "$TRACE"
        [[ $NETWORK == ok ]] || return 42
        case $2 in
            inspect) printf 'state=present\nrole=hk\nuser_port=51820\nuser_transport=wireguard\n';;
            server-public) printf '%s\n' "$SERVER";;
            client-list) cat "$CNE_STATE/peers";;
            client-verify) return 0;;
            client-add) printf '%s\t%s\t%s\n' "$3" "$4" "$5" >> "$CNE_STATE/peers"; [[ $ADD_REPLY == ok ]];;
            *) fail "unexpected RPC: $2";;
        esac
    }
    cne_ensure_qrencode() { printf 'qr-prepare\n' >> "$TRACE"; return 0; }
    qrencode() { cat > "$CNE_STATE/qr-input"; printf 'QR-RENDERED\n'; }
    ssh() { fail 'real SSH'; }
    sshpass() { fail 'real SSH'; }
    apt-get() { fail 'package mutation'; }
    sudo() { fail 'unexpected elevation'; }
}
test_windows() (
    setup windows
    cne_client_onboarding phone <<<'
3' > "$CNE_STATE/output" 2>&1 || fail 'Windows onboarding failed'
    contains "$CNE_STATE/output" 'Windows 在应用中选择从文件导入'
    contains "$CNE_STATE/output" '文件类型选择“所有文件”'
    contains "$CNE_STATE/output" '避免生成 .conf.txt'
    contains "$CNE_STATE/output" '文件保存在当前运行脚本的机器'
    contains "$CNE_STATE/output" "PrivateKey = $PRIVATE"
    absent "$TRACE" 'qr-prepare'
    absent "$CNE_STATE/output" '扫描二维码'
    printf 'PASS: Windows receives file import steps and actual text without QR dependencies\n'
)
test_same_phone() (
    setup same-phone
    cne_client_onboarding phone <<<'
1
2' > "$CNE_STATE/output" 2>&1 || fail 'same-phone onboarding failed'
    contains "$CNE_STATE/output" '无法直接用相机扫描本手机屏幕'
    contains "$CNE_STATE/output" '在电脑上登录同一台机器、用同一账号打开菜单'
    contains "$CNE_STATE/output" '保存为 phone.conf（不要加 .txt）'
    contains "$CNE_STATE/output" "PrivateKey = $PRIVATE"
    absent "$TRACE" 'qr-prepare'
    printf 'PASS: same-phone handoff provides a complete savable file instead of camera instructions\n'
)
test_mobile_qr() (
    setup qr
    cne_client_onboarding phone <<<'
2
1' > "$CNE_STATE/output" 2>&1 || fail 'QR onboarding failed'
    contains "$CNE_STATE/output" '二维码和文件是此设备的连接凭证'
    contains "$CNE_STATE/output" '这台设备的网络访问都使用此出口'
    contains "$CNE_STATE/output" '服务器核对也不能证明设备公网连接或税务业务已通过'
    contains "$CNE_STATE/output" 'QR-RENDERED'
    awk '/连接凭证/{warning=NR}/QR-RENDERED/{qr=NR}END{exit !(warning>0&&qr>warning)}' "$CNE_STATE/output" || fail 'QR warning came too late'
    cmp "$CNE_STATE/clients/phone.conf" "$CNE_STATE/qr-input" || fail 'QR selected wrong profile'
    printf 'PASS: mobile QR warns before display and gives device-level acceptance steps\n'
)
test_cancel() (
    setup cancel
    cne_client_onboarding phone <<<0 > "$CNE_STATE/output" 2>&1 || fail 'handoff cancellation changed server success'
    [[ -s $CNE_STATE/clients/phone.conf && ! -s $TRACE ]] || fail 'cancel changed profile or contacted host'
    contains "$CNE_STATE/output" '稍后进入'
    printf 'PASS: later import keeps already-created configuration and performs no extra RPC\n'
)
test_verdict() (
    setup "verdict-$1"
    case $1 in unknown) NETWORK=failed;; invalid) : > "$CNE_STATE/peers";; esac
    if cne_client_export phone <<<'1
N' > "$CNE_STATE/output" 2>&1; then fail 'failed verification looked successful'; fi
    case $1 in
        unknown) [[ $CNE_PROFILE_VERDICT == unconfirmed ]] || fail 'network failure mislabeled stale'; contains "$CNE_STATE/output" '有效性未知';;
        invalid) [[ $CNE_PROFILE_VERDICT == invalid ]] || fail 'revoked device not classified invalid'; contains "$CNE_STATE/output" '已确认原文件不适用于当前部署';;
    esac
    absent "$TRACE" 'qr-prepare'
    absent "$CNE_STATE/output" "PrivateKey = $PRIVATE"
    printf 'PASS: %s verification has a specific next step and does not expose credentials by default\n' "$1"
)
test_name_retry() (
    setup names
    cne_client_add <<<'妈妈的手机

0' > "$CNE_STATE/output" 2>&1 || fail 'invalid-name retry failed'
    [[ -s $CNE_STATE/clients/device-1.conf ]] || fail 'empty answer did not create default device'
    contains "$CNE_STATE/output" '请重新输入，或回车使用默认名称'
    contains "$CNE_STATE/output" '客户端已添加：device-1'
    printf 'PASS: invalid names retry in place and Enter safely creates an automatic device name\n'
)
test_pending() (
    setup pending
    : > "$CNE_STATE/peers"; ADD_REPLY=lost
    if cne_client_add <<<'
' > "$CNE_STATE/output" 2>&1; then fail 'lost reply appeared confirmed'; fi
    [[ -s $CNE_STATE/clients/device-1.conf.pending ]] || fail 'pending profile lost'
    cp "$CNE_STATE/clients/device-1.conf.pending" "$CNE_STATE/expected"
    contains "$CNE_STATE/output" '使用同一名称 device-1 继续'
    cne_client_add <<<'
0' >> "$CNE_STATE/output" 2>&1 || fail 'default pending name did not recover'
    cmp "$CNE_STATE/expected" "$CNE_STATE/clients/device-1.conf" || fail 'recovery changed device identity'
    [[ $(grep -c '^rpc client-add$' "$TRACE") == 1 && $(grep -c '^keygen$' "$TRACE") == 1 ]] || fail 'recovery created a duplicate identity'
    contains "$CNE_STATE/output" '配置已取回'
    printf 'PASS: pending default resumes the same identity and recovered devices enter onboarding\n'
)
test_pending_list() (
    setup pending-list
    : > "$CNE_STATE/peers"
    cp "$CNE_STATE/clients/phone.conf" "$CNE_STATE/clients/device-1.conf.pending"
    cne_clients_list > "$CNE_STATE/output" 2>&1 || fail 'empty server hid pending clients'
    contains "$CNE_STATE/output" 'device-1  等待确认'
    printf 'PASS: an empty confirmed registry still lists a locally pending device and recovery action\n'
)
test_stale_default() (
    setup stale-default
    sed 's/203.0.113.10:51820/203.0.113.11:51820/' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/clients/device-1.conf.pending"
    cp "$CNE_STATE/clients/device-1.conf.pending" "$CNE_STATE/stale"
    cne_client_add <<<'
0' > "$CNE_STATE/output" 2>&1 || fail 'stale default trapped device creation'
    contains "$CNE_STATE/output" '不会自动继续使用它'
    [[ -s $CNE_STATE/clients/device-2.conf ]] || fail 'default did not skip stale reserved name'
    cmp "$CNE_STATE/stale" "$CNE_STATE/clients/device-1.conf.pending" || fail 'stale pending credentials overwritten'
    printf 'PASS: a stale pending file remains intact and does not trap the automatic name default\n'
)
test_windows
test_same_phone
test_mobile_qr
test_cancel
test_verdict unknown
test_verdict invalid
test_name_retry
test_pending
test_pending_list
test_stale_default
printf 'Device delivery checks passed. No real hosts or packages changed.\n'
