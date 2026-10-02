#!/usr/bin/env bash
# User-visible node changes and lifecycle outcomes, without network mutations.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-usability.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
setup() {
    source "$ROOT/shell/controller.sh"
    CNE_STATE=$WORK/$1; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/history"
    CNE_HOSTS=(8.8.8.10 9.9.9.20 10.200.10.2)
    printf 'hk\t8.8.8.10\troot\t22\t-\tssh\nsh\t9.9.9.20\troot\t22\t-\tssh\nexit\t10.200.10.2\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    printf '51820 443\n' > "$CNE_STATE/ports"
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/nodes.before"
    cp "$CNE_STATE/ports" "$CNE_STATE/ports.before"
    TRACE=$CNE_STATE/trace; : > "$TRACE"
    cne_bootstrap() { fail 'unexpected dependency change'; }
    cne_require_config() { return 0; }
    cne_authenticate() { printf 'authenticate %s\n' "$1" >> "$TRACE"; }
    ssh() { fail 'unexpected SSH connection'; }
    cne_remote() {
        printf 'rpc %s %s\n' "$1" "$2" >> "$TRACE"
        if [[ $2 == doctor ]]; then [[ ${DOCTOR_FAIL:-0} == 0 ]]
        else [[ ${SERVICE_FAIL:-0} == 0 ]]; fi
    }
    sleep() { [[ $1 == 2 ]]; }
}
test_node_change() (
    local choice=$1 history
    setup "change-$choice"
    ANSWERS=(2 1 8.8.8.11 root 22 - 1 9.9.9.20 root 22 - 1 10.200.10.2 root 22 - 51821 8443 "$choice")
    ANSWER_INDEX=0
    cne_prompt() { CNE_ANSWER=${ANSWERS[$ANSWER_INDEX]}; ANSWER_INDEX=$((ANSWER_INDEX+1)); }
    cne_setup > "$CNE_STATE/output" 2>&1 || fail 'node-change workflow failed'
    grep -Fq '保存设置不会迁移或停止旧服务器服务' "$CNE_STATE/output" || fail 'change did not explain what happens to old services'
    [[ ! -s $TRACE ]] || fail 'editing addresses changed a service'
    if [[ $choice == y ]]; then
        [[ ${CNE_HOSTS[0]} == 8.8.8.11 && $CNE_USER_PORT == 51821 && $CNE_WSS_PORT == 8443 ]] || fail 'confirmed changes were not saved'
        history=$(find "$CNE_STATE/history" -maxdepth 1 -type d -name 'node-settings.*')
        [[ -n $history ]] || fail 'old node settings were not retained'
        cmp "$CNE_STATE/nodes.before" "$history/nodes.tsv" || fail 'previous addresses were lost'
        cmp "$CNE_STATE/ports.before" "$history/ports" || fail 'previous ports were lost'
    else
        [[ ${CNE_HOSTS[0]} == 8.8.8.10 && $CNE_USER_PORT == 51820 && $CNE_WSS_PORT == 443 ]] || fail 'declined changes changed runtime settings'
        cmp "$CNE_STATE/nodes.before" "$CNE_STATE/nodes.tsv" || fail 'declined changes changed saved addresses'
        cmp "$CNE_STATE/ports.before" "$CNE_STATE/ports" || fail 'declined changes changed saved ports'
        [[ -z $(find "$CNE_STATE/history" -mindepth 1 -print -quit) ]] || fail 'declined changes created history'
    fi
    printf 'PASS: node-address/port change (%s) explains old services and preserves prior settings\n' "$choice"
)
test_service_outcome() (
    local action=$1 failure=$2 expected=0 count
    setup "$action-$failure"
    DOCTOR_FAIL=0; SERVICE_FAIL=0
    case $failure in doctor) DOCTOR_FAIL=1; expected=1;; service) SERVICE_FAIL=1; expected=1;; esac
    if cne_action_all "$action" <<<'y' > "$CNE_STATE/output" 2>&1; then
        [[ $expected == 0 ]] || fail 'failed lifecycle reported usable connection'
    else [[ $expected == 1 ]] || fail 'healthy lifecycle failed'; fi
    count=$(grep -c ' doctor$' "$TRACE" || true)
    case $failure in
        none) [[ $count == 3 ]] || fail 'service action did not verify all three nodes'; grep -Fq '节点链路已通过验证' "$CNE_STATE/output" || fail 'missing verified outcome';;
        doctor) [[ $count == 9 ]] || fail 'verification did not retry'; grep -Fq '链路验证失败' "$CNE_STATE/output" || fail 'failure did not distinguish service start from usable chain';;
        service) [[ $count == 0 ]] || fail 'failed services were reported verified'; grep -Fq '链路尚未确认恢复' "$CNE_STATE/output" || fail 'missing service failure guidance';;
    esac
    [[ $(awk '$1=="rpc" && $3!="doctor" {print $2}' "$TRACE") == $'1\n2\n0' ]] || fail 'incorrect lifecycle node order'
    printf 'PASS: %s (%s) distinguishes service commands from verified chain\n' "$action" "$failure"
)
test_node_change n
test_node_change y
for action in start restart; do
    for failure in none doctor service; do test_service_outcome "$action" "$failure"; done
done
printf '8 usability checks passed. No server operations occurred.\n'
