#!/usr/bin/env bash
# QR fallback and normal management paths use isolated package/remote mocks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-optional-qr-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
KEY_PRIVATE=$(openssl rand -base64 32)
KEY_CLIENT=$(openssl rand -base64 32)
KEY_SERVER=$(openssl rand -base64 32)
KEY_PSK=$(openssl rand -base64 32)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing output: $2"; }
assert_absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected output/call: $2"; fi; }

mock_setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/download.sh"
    source "$ROOT/shell/bootstrap.sh"
    CNE_STATE=$WORK/$1
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_STATE/clients" "$CNE_TEMP"
    MOCK_TRACE=$CNE_STATE/calls
    : > "$MOCK_TRACE"
    MOCK_UID=0
    MOCK_AUDIT=clean
    MOCK_PLAN=safe
    MOCK_REPOSITORY=ok
    MOCK_INSTALL=ok
    MOCK_RENDER=ok
    MOCK_SUDO=ok
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    printf '[Interface]\nPrivateKey = %s\nAddress = 10.77.10.2/32, fd77:77:10::2/128\nDNS = 10.77.30.2\nMTU = 1380\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 203.0.113.10:51820\nPersistentKeepalive = 25\n' "$KEY_PRIVATE" "$KEY_SERVER" "$KEY_PSK" > "$CNE_STATE/clients/phone.conf"
    uname() { printf 'Linux\n'; }
    id() { printf '%s\n' "$MOCK_UID"; }
    dpkg-query() { printf 'install ok installed'; }
    command() {
        if [[ ${1:-} == -v ]]; then
            case ${2:-} in
                qrencode) [[ -f $CNE_STATE/qr-installed ]]; return ;;
                sudo) [[ $MOCK_SUDO != absent ]]; return ;;
                python|python3) return 1 ;;
            esac
            return 0
        fi
        builtin command "$@"
    }
    dpkg() {
        printf 'dpkg %s\n' "$*" >> "$MOCK_TRACE"
        [[ $* == --audit ]] || fail 'unexpected dpkg operation'
        case $MOCK_AUDIT in
            clean) return 0 ;;
            broken) printf 'unrelated-server: package is unpacked but not configured\n' ;;
            failed) printf 'dpkg: package database is unreadable\n' >&2; return 2 ;;
        esac
    }
    sudo() {
        printf 'sudo %s\n' "$*" >> "$MOCK_TRACE"
        [[ $* == -v ]] || fail 'unexpected sudo operation'
        [[ $MOCK_SUDO == ok ]]
    }
    apt-get() { fail 'package manager bypassed isolated cne_root mock'; }
    cne_root() {
        printf '%s\n' "$*" >> "$MOCK_TRACE"
        case "$*" in
            'apt-get -qq update')
                [[ $MOCK_REPOSITORY == ok ]] || { printf 'APT repository unavailable\n' >&2; return 1; } ;;
            'apt-get -s --no-install-recommends --no-upgrade --no-remove install qrencode')
                case $MOCK_PLAN in
                    safe) printf 'Inst libqrencode4 (new Debian)\nInst qrencode (new Debian)\nConf libqrencode4 (new Debian)\nConf qrencode (new Debian)\n' ;;
                    upgrade) printf 'Inst libc6 [old] (new Debian)\n' ;;
                    removal) printf 'Remv unrelated-server [1.0]\n' ;;
                    pending) printf 'Inst qrencode (new Debian)\nConf unrelated-server (1.0 Debian)\n' ;;
                    failed) printf 'APT cannot resolve QR dependencies\n'; return 1 ;;
                esac ;;
            'apt-get -y -qq --no-install-recommends --no-upgrade --no-remove install qrencode')
                case $MOCK_INSTALL in
                    ok) touch "$CNE_STATE/qr-installed" ;;
                    missing) return 0 ;;
                    failed) printf 'APT QR installation failed\n' >&2; return 1 ;;
                esac ;;
            *) fail "unexpected privileged operation: $*" ;;
        esac
    }
    qrencode() {
        printf 'qrencode %s\n' "$*" >> "$MOCK_TRACE"
        [[ $* == '-t ANSIUTF8' ]] || fail 'unexpected QR options'
        cat > "$CNE_STATE/qr-input"
        [[ $MOCK_RENDER == ok ]] || { printf 'QR render failed\n' >&2; return 1; }
        printf 'QR-RENDERED\n'
    }
    ssh() { fail 'unexpected real SSH operation'; }
    sshpass() { fail 'unexpected real SSH operation'; }
    python() { fail 'unexpected Python runtime'; }
    python3() { fail 'unexpected Python runtime'; }
    cne_initialize() { return 0; }
    cne_require_config() { return 0; }
    cne_authenticate() { return 0; }
    wg() { [[ $1 == pubkey ]] || fail 'unexpected key operation'; cat >/dev/null; printf '%s\n' "$KEY_CLIENT"; }
    cne_remote() {
        printf 'remote %s\n' "$*" >> "$MOCK_TRACE"
        case $2 in
            inspect) printf 'state=present\nrole=hk\nuser_port=51820\nuser_transport=wireguard\n';;
            server-public) printf '%s\n' "$KEY_SERVER";;
            client-list) printf 'phone\t2\t%s\n' "$KEY_CLIENT";;
            client-verify)
                local expected
                expected=$(printf '%s\n' "$KEY_PSK" | sha256sum); expected=${expected%% *}
                [[ $3 == "$KEY_CLIENT" && $4 == "$KEY_SERVER" && $5 == "$expected" ]] || fail 'QR export omitted current PSK verification';;
        esac
    }
}

assert_fallback() {
    assert_contains "$CNE_STATE/output" "$CNE_STATE/clients/phone.conf"
    assert_contains "$CNE_STATE/output" '二维码暂不可用'
    assert_contains "$CNE_STATE/output" "PrivateKey = $KEY_PRIVATE"
    [[ -s $CNE_STATE/clients/phone.conf ]] || fail 'fallback lost the client file'
    assert_absent "$CNE_STATE/output" '配置导出未完成|操作未完成'
    assert_absent "$MOCK_TRACE" '--configure|--fix-broken|python|ssh '
}

export_client() {
    cne_client_export <<<'phone
1' > "$CNE_STATE/output" 2>&1 || fail 'optional QR failure blocked config export'
}

test_management() (
    mock_setup management
    MOCK_AUDIT=broken
    MOCK_UID=1000
    cne_main menu <<<'3
5
6
7
0' > "$CNE_STATE/output" 2>&1 || fail 'optional QR blocked the management menu'
    local action idx
    for action in status start stop restart; do
        for idx in 0 1 2; do assert_contains "$MOCK_TRACE" "remote $idx $action"; done
    done
    assert_absent "$MOCK_TRACE" 'apt-get|dpkg|sudo|qrencode|python|ssh '
    assert_absent "$CNE_STATE/output" '未完成|失败|错误'
    printf 'PASS: missing QR and broken dpkg leave menu, status and services usable\n'
)

test_export_menu() (
    mock_setup export-menu
    MOCK_AUDIT=broken
    MOCK_UID=1000
    cne_main menu <<<'12
phone
1
5
0' > "$CNE_STATE/output" 2>&1 || fail 'QR fallback ended the management menu'
    assert_fallback
    assert_absent "$MOCK_TRACE" 'apt-get|sudo|^qrencode '
    local idx
    for idx in 0 1 2; do assert_contains "$MOCK_TRACE" "remote $idx start"; done
    printf 'PASS: QR fallback returns to the menu and later service actions succeed\n'
)

test_audit() (
    mock_setup "audit-$1"
    MOCK_AUDIT=$1
    MOCK_UID=1000
    export_client
    assert_fallback
    assert_contains "$MOCK_TRACE" 'dpkg --audit'
    assert_absent "$MOCK_TRACE" 'apt-get|sudo|qrencode'
    case $1 in
        broken) assert_contains "$CNE_STATE/output" 'unrelated-server: package is unpacked but not configured' ;;
        failed) assert_contains "$CNE_STATE/output" 'dpkg: package database is unreadable' ;;
    esac
    printf 'PASS: dpkg %s reports details and preserves a successful config export\n' "$1"
)

test_available() (
    mock_setup available
    touch "$CNE_STATE/qr-installed"
    MOCK_AUDIT=broken
    export_client
    assert_contains "$CNE_STATE/output" 'QR-RENDERED'
    assert_absent "$MOCK_TRACE" 'apt-get|dpkg|sudo'
    cmp "$CNE_STATE/clients/phone.conf" "$CNE_STATE/qr-input" || fail 'QR used different client data'
    printf 'PASS: an available QR renderer works without package checks\n'
)

test_repository() (
    mock_setup repository
    MOCK_REPOSITORY=failed
    export_client
    assert_fallback
    assert_contains "$CNE_STATE/output" '软件源更新失败'
    assert_absent "$MOCK_TRACE" '^apt-get -[sy] |^qrencode '
    printf 'PASS: unavailable repositories degrade to the exported configuration\n'
)

test_plan() (
    mock_setup "plan-$1"
    MOCK_PLAN=$1
    export_client
    assert_fallback
    assert_absent "$MOCK_TRACE" '^apt-get -y |^qrencode '
    case $1 in
        upgrade) assert_contains "$CNE_STATE/output" 'Inst libc6 [old]' ;;
        removal) assert_contains "$CNE_STATE/output" 'Remv unrelated-server' ;;
        pending) assert_contains "$CNE_STATE/output" 'Conf unrelated-server' ;;
        failed) assert_contains "$CNE_STATE/output" 'APT cannot resolve QR dependencies' ;;
    esac
    printf 'PASS: optional QR %s plan cannot change existing packages\n' "$1"
)

test_install_failure() (
    mock_setup "install-$1"
    MOCK_INSTALL=$1
    export_client
    assert_fallback
    assert_absent "$MOCK_TRACE" '^qrencode '
    case $1 in
        failed) assert_contains "$CNE_STATE/output" '二维码工具暂不可用：安装失败' ;;
        missing) assert_contains "$CNE_STATE/output" '安装后仍未找到 qrencode' ;;
    esac
    printf 'PASS: optional QR install %s preserves config export\n' "$1"
)

test_render_failure() (
    mock_setup render-failure
    touch "$CNE_STATE/qr-installed"
    MOCK_RENDER=failed
    export_client
    assert_fallback
    assert_contains "$MOCK_TRACE" 'qrencode -t ANSIUTF8'
    assert_absent "$MOCK_TRACE" 'apt-get|dpkg|sudo'
    cmp "$CNE_STATE/clients/phone.conf" "$CNE_STATE/qr-input" || fail 'renderer did not receive config'
    printf 'PASS: QR rendering errors leave configuration export successful\n'
)

test_lazy_install() (
    mock_setup lazy-install
    export_client
    assert_contains "$MOCK_TRACE" 'apt-get -y -qq --no-install-recommends --no-upgrade --no-remove install qrencode'
    assert_contains "$CNE_STATE/output" 'QR-RENDERED'
    assert_absent "$CNE_STATE/output" '二维码暂不可用'
    cmp "$CNE_STATE/clients/phone.conf" "$CNE_STATE/qr-input" || fail 'lazy renderer did not receive config'
    printf 'PASS: config export can install only the optional QR tool and render it\n'
)

test_sudo_failure() (
    mock_setup "sudo-$1"
    MOCK_UID=1000
    MOCK_SUDO=$1
    export_client
    assert_fallback
    assert_absent "$MOCK_TRACE" 'apt-get|^qrencode '
    printf 'PASS: optional QR permission %s falls back without a failed action\n' "$1"
)

test_management
test_export_menu
test_audit broken
test_audit failed
test_available
test_repository
for plan in upgrade removal pending failed; do test_plan "$plan"; done
test_install_failure failed
test_install_failure missing
test_render_failure
test_lazy_install
test_sudo_failure absent
test_sudo_failure denied
printf 'Optional QR checks passed. No package changes or SSH connections occurred.\n'
