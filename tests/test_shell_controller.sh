#!/usr/bin/env bash
# Controller workflow tests: all remote operations and rendering are isolated mocks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-controller-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_line() { grep -Fqx -- "$2" "$1" || fail "missing trace: $2"; }
assert_absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected trace: $2"; fi; }
assert_count() {
    local count
    count=$(grep -Ec -- "$2" "$1" || true)
    [[ $count == "$3" ]] || fail "expected $3 matches of $2, got $count"
}

mock_setup() {
    source "$ROOT/shell/controller.sh"
    CNE_STATE=$WORK/$1
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/clients" "$CNE_STATE/cache" "$CNE_STATE/history"
    printf 'configured nodes\n' > "$CNE_STATE/nodes.tsv"
    printf '51820 443\n' > "$CNE_STATE/ports"
    MOCK_TRACE=$CNE_STATE/trace
    : > "$MOCK_TRACE"
    MOCK_STATES=(absent absent absent)
    MOCK_CHOICE=2
    MOCK_PREFLIGHT_FAIL=-1
    MOCK_PREFLIGHT_ROUND=0
    MOCK_INSTALL_FAIL=-1
    MOCK_FORWARDING=1
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_USERS=(root root root)
    CNE_ROLES=(hk sh exit)
    cne_require_config() { return 0; }
    cne_inspect_all() {
        local idx
        printf 'inspect\n' >> "$MOCK_TRACE"
        CNE_INSPECTIONS=()
        for idx in 0 1 2; do
            CNE_INSPECTIONS[$idx]=$(printf 'state=%s\nrole=%s\nwan=eth0\narch=x86_64\nforwarding=%s\n' "${MOCK_STATES[$idx]}" "${CNE_ROLES[$idx]}" "$MOCK_FORWARDING")
        done
    }
    cne_existing_choice() { printf 'choice\n' >> "$MOCK_TRACE"; CNE_INSTALL_CHOICE=$MOCK_CHOICE; }
    cne_status() { printf 'status\n' >> "$MOCK_TRACE"; }
    openssl() {
        [[ $# == 3 && $1 == rand && $2 == -hex && $3 == 6 ]] || fail 'unexpected openssl operation'
        printf 'random\n' >> "$MOCK_TRACE"
        printf '001122334455\n'
    }
    cne_remote() {
        local idx=$1 action=$2
        shift 2
        printf 'rpc %s %s' "$idx" "$action" >> "$MOCK_TRACE"
        [[ $# == 0 ]] || printf ' %s' "$@" >> "$MOCK_TRACE"
        printf '\n' >> "$MOCK_TRACE"
        if [[ $action == preflight && $idx == "$MOCK_PREFLIGHT_FAIL" ]]; then
            if [[ $MOCK_PREFLIGHT_ROUND == 0 || -f $CNE_STATE/prepared ]]; then return 72; fi
        fi
        case $action in
            inspect) printf 'state=%s\nrole=%s\nwan=eth0\narch=x86_64\nforwarding=%s\n' "${MOCK_STATES[$idx]}" "${CNE_ROLES[$idx]}" "$MOCK_FORWARDING" ;;
            backup) printf '/var/backups/cn-egress/%s.tar.gz\n' "${CNE_ROLES[$idx]}" ;;
            prepare) touch "$CNE_STATE/prepared" ;;
        esac
        return 0
    }
    cne_render_bundle() {
        local out=$1 role
        printf 'render\n' >> "$MOCK_TRACE"
        mkdir -p "$out/clients"
        for role in hk sh exit; do
            mkdir -p "$out/$role/etc/cn-egress"
            printf '%s\n' "$role" > "$out/$role/etc/cn-egress/role"
        done
        printf 'client fixture\n' > "$out/clients/iPhone.conf"
    }
    cne_fetch_binary() {
        printf 'binary %s\n' "$1" >> "$MOCK_TRACE"
        CNE_BINARY=$CNE_TEMP/wstunnel
        printf 'executable fixture\n' > "$CNE_BINARY"
    }
    cne_remote_install() {
        printf 'install %s %s\n' "$1" "$2" >> "$MOCK_TRACE"
        [[ -s $3 ]] || fail 'empty installation archive'
        [[ $1 != "$MOCK_INSTALL_FAIL" ]]
    }
}

test_fresh() (
    mock_setup fresh
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'fresh installation failed'
    assert_absent "$MOCK_TRACE" '^(choice|rpc [012] backup)$'
    assert_count "$MOCK_TRACE" '^rpc [012] preflight fresh 51820 443$' 6
    assert_count "$MOCK_TRACE" '^rpc [012] prepare$' 3
    [[ $(grep '^install ' "$MOCK_TRACE") == $'install 1 fresh\ninstall 2 fresh\ninstall 0 fresh' ]] || fail 'fresh installation order or mode'
    assert_line "$MOCK_TRACE" render
    [[ -s $CNE_STATE/clients/iPhone.conf && -s $CNE_STATE/current-deployment ]] || fail 'client publication missing'
    printf 'PASS: new devices install directly\n'
)

test_partial_replace() (
    mock_setup partial
    MOCK_STATES=(absent absent present)
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'partial existing installation was blocked'
    assert_count "$MOCK_TRACE" '^choice$' 1
    assert_line "$MOCK_TRACE" 'rpc 2 backup'
    assert_absent "$MOCK_TRACE" '^rpc [01] backup$'
    [[ $(grep '^install ' "$MOCK_TRACE") == $'install 1 fresh\ninstall 2 replace\ninstall 0 fresh' ]] || fail 'partial install must replace only the existing exit'
    local backup_line install_line
    backup_line=$(grep -n '^rpc 2 backup$' "$MOCK_TRACE" | cut -d: -f1)
    install_line=$(grep -n '^install 1 fresh$' "$MOCK_TRACE" | cut -d: -f1)
    (( backup_line < install_line )) || fail 'old node not backed up before installation'
    printf 'PASS: partially installed set offers backup and replacement\n'
)

test_choice() (
    mock_setup "choice-$1"
    MOCK_STATES=(absent absent present)
    MOCK_CHOICE=$1
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'cancel/keep returned an error'
    assert_line "$MOCK_TRACE" choice
    assert_absent "$MOCK_TRACE" '^(random|render|binary|install|rpc )'
    [[ ! -e $CNE_STATE/current-deployment ]] || fail 'cancel/keep changed current deployment'
    [[ -z $(find "$CNE_STATE/history" -mindepth 1 -print -quit) ]] || fail 'cancel/keep created history or keys'
    if [[ $1 == 1 ]]; then assert_line "$MOCK_TRACE" status; else assert_absent "$MOCK_TRACE" '^status$'; fi
    printf 'PASS: choice %s does not generate keys or install\n' "$1"
)

test_preflight_failure() (
    local failed=$1 round=$2
    mock_setup "preflight-$failed-$round"
    MOCK_STATES=(present present present)
    MOCK_PREFLIGHT_FAIL=$failed
    MOCK_PREFLIGHT_ROUND=$round
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'preflight error was ignored'; fi
    assert_absent "$MOCK_TRACE" '^(random|render|binary|install|rpc [012] (backup|enable-forwarding))'
    [[ ! -e $CNE_STATE/current-deployment ]] || fail 'failed preflight changed current deployment'
    printf 'PASS: preflight failure at node %s round %s prevents replacement\n' "$failed" "$round"
)

test_install_failure() (
    mock_setup "install-failure-$1"
    MOCK_INSTALL_FAIL=$1
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'remote installation error was ignored'; fi
    case $1 in
        1) [[ $(grep '^install ' "$MOCK_TRACE") == 'install 1 fresh' ]] || fail 'continued after first node failed' ;;
        2) [[ $(grep '^install ' "$MOCK_TRACE") == $'install 1 fresh\ninstall 2 fresh' ]] || fail 'continued after second node failed' ;;
    esac
    [[ ! -e $CNE_STATE/current-deployment && ! -e $CNE_STATE/clients/iPhone.conf ]] || fail 'published clients after failed installation'
    printf 'PASS: remote failure at node %s stops subsequent installs\n' "$1"
)

test_menu() (
    source "$ROOT/shell/controller.sh"
    cne_menu <<< '0' > "$WORK/menu" 2>&1
    local item count
    for item in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        count=$(grep -Ec "^  $item\\. [^[:cntrl:]]+$" "$WORK/menu" || true)
        [[ $count == 1 ]] || fail "menu item $item is missing or not on its own line"
    done
    if grep -Eq '^  [0-9]+\. .* [0-9]+\. ' "$WORK/menu"; then fail 'menu contains multiple items on one line'; fi
    printf 'PASS: menu items occupy separate lines\n'
)

test_fresh
test_partial_replace
test_choice 0
test_choice 1
for node in 0 1 2; do test_preflight_failure "$node" 0; test_preflight_failure "$node" 1; done
test_install_failure 1
test_install_failure 2
test_menu
printf 'Controller workflow tests passed. No server connections or package changes occurred.\n'
