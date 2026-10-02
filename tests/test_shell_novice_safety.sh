#!/usr/bin/env bash
# Exercise novice recovery, destructive actions and retained results without SSH.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CNE_BACKUP_TEST_LIBRARY=1 source "$ROOT/tests/test_shell_backup.sh"

test_stop_confirmation() (
    mock_setup stop-confirmation
    cne_prompt() { CNE_ANSWER=${ANSWER:-N}; }
    cne_authenticate() { printf 'auth %s\n' "$1" >> "$MOCK_TRACE"; }
    cne_remote() { printf 'action %s %s\n' "$1" "$2" >> "$MOCK_TRACE"; }
    ANSWER=N
    cne_action_all stop > "$CNE_STATE/output" 2>&1 || fail 'stop cancel failed'
    [[ ! -s $MOCK_TRACE ]] || fail 'cancelled stop touched a node'
    cne_action_all restart >> "$CNE_STATE/output" 2>&1 || fail 'restart cancel failed'
    [[ ! -s $MOCK_TRACE ]] || fail 'cancelled restart touched a node'
    ANSWER=y
    cne_action_all stop >> "$CNE_STATE/output" 2>&1 || fail 'confirmed stop failed'
    [[ $(awk '$1=="action"{print $2}' "$MOCK_TRACE") == $'0\n2\n1' ]] || fail 'stop did not affect exactly the confirmed three nodes'
    grep -Fq '所有正在使用的手机和电脑都会断开' "$CNE_STATE/output" || fail 'missing scope warning'
    printf 'PASS: stop/restart cancellation makes no node calls; confirmed stop declares its full scope\n'
)
test_recovery_credentials() (
    mock_setup recovery-credentials
    local id=20261002T010101Z-abcdef012345 directory original
    directory=$CNE_STATE/history/$id
    mkdir "$directory"
    CNE_IDENTITIES[0]=$WORK/missing-private-key
    printf 'hk\t203.0.113.10\troot\t22\t%s\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tlocal\n' "${CNE_IDENTITIES[0]}" > "$CNE_STATE/nodes.tsv"
    cp "$CNE_STATE/nodes.tsv" "$directory/nodes.tsv"
    printf '%s\n' "$id" > "$CNE_STATE/active-transaction"
    printf 'rollback-incomplete\n' > "$directory/transaction-status"
    printf 'hk\t/root/cn-egress-backups/hk.tar.gz\n' > "$directory/backups.tsv"
    printf '0\n' > "$directory/attempted.txt"
    cne_authenticate() { [[ $1 == 0 && ${CNE_IDENTITIES[0]} == - ]] || fail 'missing key was not corrected'; }
    cne_remote() { [[ $* == "0 restore /root/cn-egress-backups/hk.tar.gz $id" ]] || fail 'recovery changed its target'; printf 'restore\n' >> "$MOCK_TRACE"; }
    # Real prompting: accept the original username and port, switch to password.
    unset -f cne_prompt
    source "$ROOT/shell/controller.sh"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_CONNECTIONS=(ssh ssh local)
    CNE_IDENTITIES=("$WORK/missing-private-key" - -)
    cne_authenticate() { [[ $1 == 0 && ${CNE_IDENTITIES[0]} == - ]] || fail 'missing key was not corrected'; }
    cne_remote() { [[ $* == "0 restore /root/cn-egress-backups/hk.tar.gz $id" ]] || fail 'recovery changed its target'; printf 'restore\n' >> "$MOCK_TRACE"; }
    cne_transaction_recover <<<$'\n\n1' > "$CNE_STATE/output" 2>&1 || { cat "$CNE_STATE/output" >&2; fail 'missing key recovery loop persists'; }
    [[ ! -e $CNE_STATE/active-transaction && $(cat "$MOCK_TRACE") == restore ]] || fail 'recovery did not complete'
    [[ $(awk -F'\t' 'NR==1{print $5}' "$CNE_STATE/nodes.tsv") == - ]] || fail 'new non-secret login method was not saved after success'
    grep -Fq '服务器地址、角色和原备份保持不变' "$CNE_STATE/output" || fail 'missing fixed-target explanation'
    printf 'PASS: missing recovery key can be replaced without changing target or deleting journal\n'
)
test_recovery_target_guard() (
    mock_setup recovery-target-guard
    local id=20261002T010101Z-abcdef012345 directory
    directory=$CNE_STATE/history/$id; mkdir "$directory"
    cp "$CNE_STATE/nodes.tsv" "$directory/nodes.tsv"
    printf '%s\n' "$id" > "$CNE_STATE/active-transaction"
    printf 'rollback-incomplete\n' > "$directory/transaction-status"
    printf 'hk\t/root/cn-egress-backups/hk.tar.gz\n' > "$directory/backups.tsv"
    printf '0\n' > "$directory/attempted.txt"
    sed 's/203.0.113.10/203.0.113.11/' "$CNE_STATE/nodes.tsv" > "$CNE_TEMP/changed"
    mv "$CNE_TEMP/changed" "$CNE_STATE/nodes.tsv"
    if cne_transaction_recover credentials > "$CNE_STATE/output" 2>&1; then fail 'credential repair allowed a changed node target'; fi
    [[ ! -s $MOCK_TRACE && -f $CNE_STATE/active-transaction ]] || fail 'wrong target recovery contacted or changed a node'
    printf 'PASS: recovery credential repair retains the original target guard\n'
)
test_recovery_password_stdin() (
    mock_setup recovery-password-stdin
    source "$ROOT/shell/controller.sh"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_CONNECTIONS=(ssh ssh local)
    local id=20261002T010102Z-abcdef012345 directory
    directory=$CNE_STATE/history/$id; mkdir "$directory"
    cp "$CNE_STATE/nodes.tsv" "$directory/nodes.tsv"
    printf '%s\n' "$id" > "$CNE_STATE/active-transaction"
    printf 'rollback-incomplete\n' > "$directory/transaction-status"
    printf 'hk\t/root/cn-egress-backups/hk.tar.gz\nsh\t/root/cn-egress-backups/sh.tar.gz\n' > "$directory/backups.tsv"
    printf '0\n1\n' > "$directory/attempted.txt"
    cne_remote() {
        [[ $2 == restore && $4 == "$id" ]] || fail 'unexpected recovery call'
        [[ ${CNE_PASSWORDS[0]} == first-test-password && ${CNE_PASSWORDS[1]} == second-test-password ]] || fail 'journal input consumed a login password'
    }
    cne_transaction_recover <<<$'first-test-password\nsecond-test-password' > "$CNE_STATE/output" 2>&1 || fail 'actual recovery password prompts lost user input'
    [[ ! -e $CNE_STATE/active-transaction ]] || fail 'password recovery left its journal'
    if grep -Fq 'test-password' "$CNE_STATE/nodes.tsv" "$directory/nodes.tsv"; then fail 'recovery saved a password'; fi
    printf 'PASS: two real recovery password prompts read user input independently of journal records\n'
)
test_uninstall_restorable_backup() (
    mock_setup uninstall-restorable
    printf 'UNINSTALL\n1\n' > "$CNE_STATE/answers"
    cne_action_all() {
        [[ $1 == uninstall ]] && cne_backup_validate "$CNE_BACKUP_CREATED" && cne_backup_restorable "$CNE_BACKUP_CREATED" || fail 'uninstall began without a validated restorable backup'
        printf 'uninstall\n' >> "$MOCK_TRACE"
        rm "$CNE_STATE/nodefiles/0" "$CNE_STATE/nodefiles/1" "$CNE_STATE/nodefiles/2"
    }
    cne_menu_uninstall > "$CNE_STATE/output" 2>&1 || fail 'safe uninstall failed'
    cne_backup_pick >> "$CNE_STATE/output" 2>&1 || fail 'uninstall backup is not selectable'
    [[ $CNE_BACKUP_SELECTION == "$CNE_BACKUP_CREATED" ]] || fail 'history selected another backup'
    cne_backup_validate "$CNE_BACKUP_SELECTION" || fail 'uninstall damaged backup'
    grep -Fq '恢复入口：维护与设置' "$CNE_STATE/output" || fail 'missing recovery handoff'
    printf 'PASS: uninstall creates a real complete backup which the history picker can select\n'
)
test_uninstall_backup_failure() (
    mock_setup uninstall-backup-failure
    MOCK_CHANGE_INFO=1
    printf 'UNINSTALL\n' > "$CNE_STATE/answers"
    cne_action_all() { fail 'uninstall proceeded after backup failure'; }
    if cne_menu_uninstall > "$CNE_STATE/output" 2>&1; then fail 'inconsistent uninstall backup reported success'; fi
    grep -Fq '未开始卸载' "$CNE_STATE/output" || fail 'missing safe failure outcome'
    printf 'PASS: backup failure stops uninstall before any service changes\n'
)
test_partial_uninstall_cancel() (
    mock_setup uninstall-incomplete
    touch "$CNE_STATE/absent"
    printf 'UNINSTALL\n\n' > "$CNE_STATE/answers"
    cne_action_all() { fail 'incomplete deployment removed without explicit second confirmation'; }
    cne_menu_uninstall > "$CNE_STATE/output" 2>&1 || fail 'partial uninstall cancel failed'
    grep -Fq '不能从它一键恢复完整服务' "$CNE_STATE/output" || fail 'snapshot incorrectly promised complete restore'
    printf 'PASS: incomplete deployment cleanup needs explicit additional confirmation\n'
)
test_result_redaction() (
    mock_setup result-redaction
    local key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    cne_result_begin '隔离失败检查'
    cne_result_event '阶段' '国内出口准备依赖；尚未替换服务'
    cne_error "PrivateKey = $key" >/dev/null 2>&1 || :
    cne_error 'password=secret-fixture' >/dev/null 2>&1 || :
    cne_result_finish '未全部完成'
    cne_result_show > "$CNE_STATE/output"
    grep -Fq '国内出口准备依赖' "$CNE_STATE/output" || fail 'cleared result is unavailable'
    if grep -Fq "$key" "$CNE_STATE/output" || grep -Fq 'secret-fixture' "$CNE_STATE/output"; then fail 'retained result leaked credentials'; fi
    if [[ $(uname -s) == Darwin ]]; then [[ $(stat -f %Lp "$CNE_STATE/last-result") == 600 ]] || fail 'retained result is not private'
    else [[ $(stat -c %a "$CNE_STATE/last-result") == 600 ]] || fail 'retained result is not private'; fi
    printf 'PASS: retained structured result is private and redacts credential-shaped text\n'
)
test_result_node_failure() (
    mock_setup result-node-failure
    source "$ROOT/shell/controller.sh"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    cne_node_source() { printf ':\n'; }
    cne_send_script() { return 5; }
    cne_result_begin '一键安装'
    if cne_remote 0 inspect >/dev/null 2>&1; then fail 'failed RPC reported success'; fi
    cne_result_finish '未全部完成'
    cne_result_show > "$CNE_STATE/output"
    grep -Fq '香港入口 · 203.0.113.10 · inspect · 返回码 5' "$CNE_STATE/output" || fail 'retained failure lost the affected node and operation'
    printf 'PASS: failed RPC retains affected node, operation and return code after screen clearing\n'
)
for test in test_stop_confirmation test_recovery_credentials test_recovery_target_guard test_recovery_password_stdin test_uninstall_restorable_backup test_uninstall_backup_failure test_partial_uninstall_cancel test_result_redaction test_result_node_failure; do "$test"; done
