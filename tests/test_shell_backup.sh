#!/usr/bin/env bash
# Portable backup and history restoration; no SSH, real services or downloads.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-backup-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mock_setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/backup.sh"
    CNE_STATE=$WORK/$1; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/clients" "$CNE_STATE/history" "$CNE_STATE/backups" "$CNE_STATE/nodefiles" "$CNE_STATE/remote-backups"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_CONNECTIONS=(ssh ssh local)
    printf 'hk\t203.0.113.10\troot\t22\t-\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tlocal\n' > "$CNE_STATE/nodes.tsv"
    printf '51820 443\n' > "$CNE_STATE/ports"
    printf 'previous1234\n' > "$CNE_STATE/current-deployment"
    printf 'private device profile\n' > "$CNE_STATE/clients/device.conf"
    printf 'previous revoked profile\n' > "$CNE_STATE/clients/old.conf.revoked"
    MOCK_TRACE=$CNE_STATE/trace; : > "$MOCK_TRACE"
    MOCK_APPLY_FAIL=-1; MOCK_DOCTOR_FAIL=0; MOCK_PUBLISH_FAIL=0; MOCK_CHANGE_INFO=0
    local idx
    for idx in 0 1 2; do printf 'original-node-%s\n' "$idx" > "$CNE_STATE/nodefiles/$idx"; done
    cne_bootstrap() { printf 'bootstrap %s\n' "$1" >> "$MOCK_TRACE"; }
    cne_require_config() { return 0; }
    cne_authenticate() { printf 'auth %s\n' "$1" >> "$MOCK_TRACE"; }
    chmod() {
        if [[ $# == 3 && $2 == -- ]]; then command chmod "$1" "$3"; else command chmod "$@"; fi
    }
    openssl() {
        [[ $* == 'rand -hex 6' ]] || fail 'unexpected cryptographic operation'
        local count=0
        [[ ! -f $CNE_STATE/random-count ]] || read -r count < "$CNE_STATE/random-count"
        count=$((count+1)); printf '%s\n' "$count" > "$CNE_STATE/random-count"
        printf '%012x\n' "$count"
    }
    cne_prompt() {
        local answer
        [[ -s $CNE_STATE/answers ]] || fail "unexpected prompt: $1"
        IFS= read -r answer < "$CNE_STATE/answers"
        tail -n +2 "$CNE_STATE/answers" > "$CNE_TEMP/remaining-answers"
        mv "$CNE_TEMP/remaining-answers" "$CNE_STATE/answers"
        CNE_ANSWER=$answer
    }
    mock_info() {
        local idx=$1 role=${CNE_ROLES[$1]} hash active=active ca users=active enabled=enabled
        hash=$(sha256sum "$CNE_STATE/nodefiles/$idx" | awk '{print $1}')
        ca=$(printf '%064d' 1)
        [[ ! -e $CNE_STATE/stopped || $idx != 1 ]] || active=inactive
        [[ ! -e $CNE_STATE/ca-mismatch || $idx != 2 ]] || ca=$(printf '%064d' 2)
        [[ ! -e $CNE_STATE/legacy ]] || { users=inactive; enabled=not-found; }
        if [[ -e $CNE_STATE/absent && $idx == 2 ]]; then
            printf 'state=absent\nrole=unknown\ndeployment=none\nca_sha256=none\nconfig_sha256=%s\ntls_sha256=none\nwss_host=none\n' "$hash"
        else printf 'state=present\nrole=%s\ndeployment=current1234\nca_sha256=%s\nconfig_sha256=%s\ntls_sha256=%064d\nwss_host=198.51.100.20\n' "$role" "$ca" "$hash" 3; fi
        printf 'main_active=%s\nmain_enabled=enabled\nobfs_active=active\nobfs_enabled=enabled\ndns_active=active\ndns_enabled=enabled\nusers_active=%s\nusers_enabled=%s\n' "$active" "$users" "$enabled"
    }
    mock_archive() {
        local idx=$1 archive=$2 stage role=${CNE_ROLES[$1]}
        stage=$(mktemp -d "$CNE_TEMP/node-archive.XXXXXXXX")
        mkdir -p "$stage/etc/cn-egress" "$stage/etc/cn-egress-wss" "$stage/etc/systemd/system"
        printf '%s\n' "$role" > "$stage/etc/cn-egress/role"
        printf '%s\n' "$role" > "$stage/etc/cn-egress-wss/role"
        cp "$CNE_STATE/nodefiles/$idx" "$stage/etc/cn-egress/version"
        if [[ -f $CNE_STATE/nodefiles/$idx.deployment ]]; then cp "$CNE_STATE/nodefiles/$idx.deployment" "$stage/etc/cn-egress/deployment-id"
        else printf 'current1234\n' > "$stage/etc/cn-egress/deployment-id"; fi
        if [[ -f $CNE_STATE/nodefiles/$idx.ca ]]; then
            cp "$CNE_STATE/nodefiles/$idx.ca" "$stage/etc/cn-egress-wss/ca.crt"
            cp "$CNE_STATE/nodefiles/$idx.cert" "$stage/etc/cn-egress-wss/node.crt"
            cp "$CNE_STATE/nodefiles/$idx.key" "$stage/etc/cn-egress-wss/node.key"
        fi
        printf 'main-unit\n' > "$stage/etc/systemd/system/cn-egress.service"
        printf 'obfs-unit\n' > "$stage/etc/systemd/system/cn-egress-obfs.service"
        [[ $role != exit ]] || printf 'dns-unit\n' > "$stage/etc/systemd/system/cn-egress-dns.service"
        if [[ $role == hk && ! -e $CNE_STATE/legacy ]]; then
            printf 'awg2\n' > "$stage/etc/cn-egress/user-transport"
            printf 'users-unit\n' > "$stage/etc/systemd/system/cn-egress-users.service"
        fi
        (cd "$stage" && find etc -type f | LC_ALL=C sort > files && tar -czf "$archive" -T files)
        rm -rf "$stage"
    }
    cne_remote() {
        local idx=$1 action=$2 path count=0
        shift 2
        printf 'rpc %s %s' "$idx" "$action" >> "$MOCK_TRACE"
        [[ $# == 0 ]] || printf ' %s' "$@" >> "$MOCK_TRACE"
        printf '\n' >> "$MOCK_TRACE"
        case $action in
            maintenance-info)
                [[ ! -f $CNE_STATE/info-count-$idx ]] || read -r count < "$CNE_STATE/info-count-$idx"
                count=$((count+1)); printf '%s\n' "$count" > "$CNE_STATE/info-count-$idx"
                if [[ $MOCK_CHANGE_INFO == 1 && $idx == 1 && $count == 2 ]]; then printf 'external-change\n' > "$CNE_STATE/nodefiles/$idx"; fi
                mock_info "$idx" ;;
            backup)
                [[ ! -f $CNE_STATE/backup-count-$idx ]] || read -r count < "$CNE_STATE/backup-count-$idx"
                count=$((count+1)); printf '%s\n' "$count" > "$CNE_STATE/backup-count-$idx"
                path=${CNE_ROLES[$idx]}-$count.tar.gz
                mock_archive "$idx" "$CNE_STATE/remote-backups/$path"
                printf '/root/cn-egress-backups/%s\n' "$path" ;;
            backup-export) base64 < "$CNE_STATE/remote-backups/${1##*/}" ;;
            restore)
                [[ $# == 2 && $2 == "$CNE_TRANSACTION_ID" ]] || fail 'rollback missing operation ID'
                tar -xOzf "$CNE_STATE/remote-backups/${1##*/}" etc/cn-egress/version > "$CNE_STATE/nodefiles/$idx"
                if [[ -f $CNE_STATE/nodefiles/$idx.ca ]]; then
                    tar -xOzf "$CNE_STATE/remote-backups/${1##*/}" etc/cn-egress-wss/ca.crt > "$CNE_STATE/nodefiles/$idx.ca"
                    tar -xOzf "$CNE_STATE/remote-backups/${1##*/}" etc/cn-egress-wss/node.crt > "$CNE_STATE/nodefiles/$idx.cert"
                    tar -xOzf "$CNE_STATE/remote-backups/${1##*/}" etc/cn-egress-wss/node.key > "$CNE_STATE/nodefiles/$idx.key"
                    tar -xOzf "$CNE_STATE/remote-backups/${1##*/}" etc/cn-egress/deployment-id > "$CNE_STATE/nodefiles/$idx.deployment"
                fi ;;
            *) fail "unexpected RPC: $action" ;;
        esac
    }
    cne_remote_payload() {
        [[ $# == 6 && $2 == restore-import && $5 == current1234 && $6 == "$CNE_TRANSACTION_ID" ]] || fail 'invalid restore import guard'
        printf 'apply %s %s\n' "$1" "$4" >> "$MOCK_TRACE"
        tar -xOzf "$3" etc/cn-egress/version > "$CNE_STATE/nodefiles/$1"
        [[ $1 != "$MOCK_APPLY_FAIL" ]]
    }
    cne_verify_install() { printf 'verify\n' >> "$MOCK_TRACE"; [[ $MOCK_DOCTOR_FAIL == 0 ]]; }
    cne_maintenance_commit() {
        [[ $# == 2 && $1 == "$CNE_TRANSACTION_DIRECTORY" && $2 == "$CNE_TRANSACTION_ID" ]] || fail 'invalid commit identity'
        printf 'commit\n' >> "$MOCK_TRACE"
        [[ $MOCK_PUBLISH_FAIL == 0 ]] || return 1
        printf 'committed\n' > "$1/transaction-status"
        CNE_TRANSACTION_ACTIVE=0
        rm -f "$CNE_STATE/active-transaction"
    }
    ssh() { fail 'unexpected real SSH'; }; sshpass() { fail 'unexpected real SSH'; }
    curl() { fail 'unexpected network download'; }; apt-get() { fail 'unexpected host package installation'; }
}
create_backup() {
    cne_backup_create > "$CNE_STATE/create-output" 2>&1 || { cat "$CNE_STATE/create-output" >&2; fail 'backup creation failed'; }
    TARGET=$CNE_BACKUP_CREATED
    cne_backup_validate "$TARGET" || fail 'created portable backup invalid'
}
change_current() {
    local idx
    for idx in 0 1 2; do printf 'newer-node-%s\n' "$idx" > "$CNE_STATE/nodefiles/$idx"; cp "$CNE_STATE/nodefiles/$idx" "$CNE_STATE/before-$idx"; done
    printf 'new profile\n' > "$CNE_STATE/clients/new.conf"
    printf 'modified profile\n' > "$CNE_STATE/clients/device.conf"
    printf '51822 8443\n' > "$CNE_STATE/ports"
    CNE_USER_PORT=51822; CNE_WSS_PORT=8443
    cp -R "$CNE_STATE/clients" "$CNE_STATE/current-clients"
    cp "$CNE_STATE/ports" "$CNE_STATE/current-ports"
    cp "$CNE_STATE/current-deployment" "$CNE_STATE/current-pointer"
    : > "$MOCK_TRACE"
}
test_portable_create() (
    mock_setup create
    create_backup
    [[ $(grep -c ' backup$' "$MOCK_TRACE") == 3 && $(grep -c ' backup-export ' "$MOCK_TRACE") == 3 ]] || fail 'did not download all three snapshots'
    [[ $(grep -c 'maintenance-info$' "$MOCK_TRACE") == 6 ]] || fail 'did not verify coherent node states before and after'
    cmp "$CNE_STATE/clients/device.conf" "$TARGET/clients/device.conf" && cmp "$CNE_STATE/clients/old.conf.revoked" "$TARGET/clients/old.conf.revoked" || fail 'client states not preserved'
    rm -rf "$CNE_STATE/remote-backups"; mkdir "$CNE_STATE/remote-backups"
    cne_backup_validate "$TARGET" && cne_backup_restorable "$TARGET" || fail 'portable set depended on remote backup vault'
    printf 'PASS: portable private backup contains three archives, complete metadata and revoked device files\n'
)
test_inconsistent_snapshot() (
    mock_setup inconsistent
    MOCK_CHANGE_INFO=1
    if cne_backup_create > "$CNE_STATE/output" 2>&1; then fail 'mixed node generation accepted'; fi
    [[ -z $(find "$CNE_STATE/backups" -name complete -print) ]] || fail 'inconsistent snapshot marked complete'
    ! grep -q '^apply ' "$MOCK_TRACE" || fail 'backup changed node services'
    printf 'PASS: changes during snapshot leave an incomplete set and never change services\n'
)
test_tamper_and_symlink() (
    mock_setup tamper; create_backup
    printf 'tampered\n' >> "$TARGET/clients/device.conf"
    if cne_backup_validate "$TARGET"; then fail 'modified private profile passed checksum'; fi
    cp "$CNE_STATE/clients/device.conf" "$TARGET/clients/device.conf"
    cne_backup_validate "$TARGET" || fail 'restored exact bytes invalid'
    ln -s "$CNE_STATE/current-deployment" "$TARGET/clients/link.conf"
    if cne_backup_validate "$TARGET" 2>/dev/null; then fail 'symlink file accepted'; fi
    printf 'PASS: backup validates every byte and rejects extra linked files\n'
)
test_missing_manifest_entry() (
    mock_setup missing-entry; create_backup
    tail -n +2 "$TARGET/manifest.sha256" > "$CNE_TEMP/short-manifest"
    mv "$CNE_TEMP/short-manifest" "$TARGET/manifest.sha256"
    if cne_backup_validate "$TARGET"; then fail 'unhashed snapshot file accepted'; fi
    printf 'PASS: manifest must cover every stored file exactly once\n'
)
test_cancel_restore() (
    mock_setup cancel; create_backup; change_current
    printf '0\n' > "$CNE_STATE/answers"
    cne_backup_restore > "$CNE_STATE/output" 2>&1 || fail 'cancel failed'
    ! grep -Eq '^rpc |^apply ' "$MOCK_TRACE" || fail 'cancel contacted or changed node'
    [[ ! -e $CNE_STATE/active-transaction ]] || fail 'cancel created active journal'
    printf '1\nn\n' > "$CNE_STATE/answers"
    cne_backup_restore >> "$CNE_STATE/output" 2>&1 || fail 'decline failed'
    ! grep -Eq '^rpc |^apply ' "$MOCK_TRACE" || fail 'decline contacted or changed node'
    diff -r "$CNE_STATE/current-clients" "$CNE_STATE/clients" >/dev/null || fail 'decline changed profiles'
    printf 'PASS: selection cancellation and confirmation decline leave all nodes and files untouched\n'
)
test_wrong_hosts() (
    mock_setup hosts; create_backup; change_current
    CNE_HOSTS[1]=198.51.100.99
    printf '1\ny\n' > "$CNE_STATE/answers"
    if cne_backup_restore > "$CNE_STATE/output" 2>&1; then fail 'restored different configured host'; fi
    ! grep -Eq '^rpc |^apply ' "$MOCK_TRACE" || fail 'host mismatch contacted node'
    printf 'PASS: historical state cannot overwrite a different configured machine\n'
)
test_restore_success() (
    mock_setup success; create_backup; change_current
    # Losing the original remote snapshots must not prevent importing the local set.
    rm -rf "$CNE_STATE/remote-backups"; mkdir "$CNE_STATE/remote-backups"
    printf '1\ny\n' > "$CNE_STATE/answers"
    cne_backup_restore > "$CNE_STATE/output" 2>&1 || { cat "$CNE_STATE/output" >&2; fail 'restore failed'; }
    [[ $(awk '$1=="apply"{print $2}' "$MOCK_TRACE") == $'1\n2\n0' ]] || fail 'wrong restore ordering'
    local first idx
    first=$(grep -n '^apply ' "$MOCK_TRACE" | head -1 | cut -d: -f1)
    for idx in 0 1 2; do
        [[ $(grep -n "^rpc $idx backup$" "$MOCK_TRACE" | cut -d: -f1) -lt $first ]] || fail 'mutation before all snapshots'
        [[ $(cat "$CNE_STATE/nodefiles/$idx") == "original-node-$idx" ]] || fail 'historical node content not restored'
    done
    diff -r "$TARGET/clients" "$CNE_STATE/clients" >/dev/null && cmp "$TARGET/ports" "$CNE_STATE/ports" || fail 'local profiles/ports not restored'
    [[ $(cat "$CNE_STATE/current-deployment") == "$CNE_TRANSACTION_ID" && $(cat "$CNE_TRANSACTION_DIRECTORY/transaction-status") == committed && ! -e $CNE_STATE/active-transaction ]] || fail 'restore journal not committed'
    [[ $CNE_USER_PORT == 51820 && $CNE_WSS_PORT == 443 ]] || fail 'menu retained outdated ports'
    grep -Fxq verify "$MOCK_TRACE" || fail 'active chain was not verified'
    printf 'PASS: history restore snapshots all nodes, imports portable files, verifies and atomically publishes devices\n'
)
test_failed_apply_rolls_back() (
    mock_setup fail-apply; create_backup; change_current
    MOCK_APPLY_FAIL=2
    printf '1\ny\n' > "$CNE_STATE/answers"
    if cne_backup_restore > "$CNE_STATE/output" 2>&1; then fail 'failed mutation reported success'; fi
    [[ $(awk '$1=="rpc"&&$3=="restore"{print $2}' "$MOCK_TRACE") == $'2\n1' ]] || fail 'failed node not rolled back first'
    local idx
    for idx in 0 1 2; do cmp "$CNE_STATE/before-$idx" "$CNE_STATE/nodefiles/$idx" || fail 'current node state not recovered'; done
    diff -r "$CNE_STATE/current-clients" "$CNE_STATE/clients" >/dev/null && cmp "$CNE_STATE/current-ports" "$CNE_STATE/ports" || fail 'failed import modified local configuration'
    [[ $(cat "$CNE_TRANSACTION_DIRECTORY/transaction-status") == rolled-back && ! -e $CNE_STATE/active-transaction ]] || fail 'rollback left journal pending'
    printf 'PASS: partially applied failed node and prior node recover in reverse order\n'
)
test_failed_doctor_rolls_back() (
    mock_setup fail-doctor; create_backup; change_current
    MOCK_DOCTOR_FAIL=1
    printf '1\ny\n' > "$CNE_STATE/answers"
    if cne_backup_restore > "$CNE_STATE/output" 2>&1; then fail 'unusable active chain committed'; fi
    [[ $(awk '$1=="rpc"&&$3=="restore"{print $2}' "$MOCK_TRACE") == $'0\n2\n1' ]] || fail 'all applied nodes not recovered'
    [[ ! -e $CNE_STATE/active-transaction && $(cat "$CNE_TRANSACTION_DIRECTORY/transaction-status") == rolled-back ]] || fail 'doctor failure did not close recovery'
    printf 'PASS: failed real-path verification restores all three nodes before publishing profiles\n'
)
test_stopped_backup() (
    mock_setup stopped; touch "$CNE_STATE/stopped"; create_backup; change_current
    printf '1\ny\n' > "$CNE_STATE/answers"
    cne_backup_restore > "$CNE_STATE/output" 2>&1 || fail 'stopped-state restore failed'
    ! grep -Fxq verify "$MOCK_TRACE" || fail 'stopped backup was forced online for verification'
    grep -q '未做连通性验证' "$CNE_STATE/output" || fail 'stopped state was presented as verified'
    printf 'PASS: stopped service state is retained and never reported as a verified active chain\n'
)
test_partial_and_mismatched_ca() (
    mock_setup partial; touch "$CNE_STATE/absent"; create_backup
    if cne_backup_restorable "$TARGET"; then fail 'absent node backup offered for manual restore'; fi
    grep -q '不会列为历史恢复目标' "$CNE_STATE/create-output" || fail 'partial backup limitation hidden'
    rm "$CNE_STATE/absent"; touch "$CNE_STATE/ca-mismatch"; create_backup
    if cne_backup_restorable "$TARGET"; then fail 'different CA node set offered for restore'; fi
    printf 'PASS: partial or different-CA snapshots remain preserved but are excluded from manual restore\n'
)
test_legacy_and_auth_changes() (
    mock_setup legacy; touch "$CNE_STATE/legacy"; create_backup; change_current
    cne_backup_restorable "$TARGET" || fail 'complete legacy WireGuard backup rejected'
    printf 'hk\t203.0.113.10\tadmin\t2222\t/custom/key\tssh\nsh\t198.51.100.20\tadmin\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    printf '1\ny\n' > "$CNE_STATE/answers"
    cne_backup_restore > "$CNE_STATE/output" 2>&1 || fail 'changed SSH credentials/mode blocked same-node restore'
    grep -q '/custom/key' "$CNE_STATE/nodes.tsv" || fail 'history restore overwrote current SSH credentials'
    printf 'PASS: complete legacy profiles restore while current SSH credentials and local/SSH mode remain intact\n'
)
test_publish_failure() (
    mock_setup publish-failure; create_backup; change_current
    MOCK_PUBLISH_FAIL=1
    printf '1\ny\n' > "$CNE_STATE/answers"
    if cne_backup_restore > "$CNE_STATE/output" 2>&1; then fail 'failed local commit reported success'; fi
    local idx
    for idx in 0 1 2; do cmp "$CNE_STATE/before-$idx" "$CNE_STATE/nodefiles/$idx" || fail 'local commit failure left restored node running'; done
    diff -r "$CNE_STATE/current-clients" "$CNE_STATE/clients" >/dev/null && cmp "$CNE_STATE/current-ports" "$CNE_STATE/ports" && cmp "$CNE_STATE/current-pointer" "$CNE_STATE/current-deployment" || fail 'local commit failure did not recover local state'
    [[ $CNE_USER_PORT == 51822 && $CNE_WSS_PORT == 8443 && ! -e $CNE_STATE/active-transaction ]] || fail 'local commit rollback left stale port values or journal'
    printf 'PASS: local publication failure reverses nodes, device files, deployment pointer and menu ports\n'
)
test_pending_guard() (
    mock_setup pending
    printf '20260101T000000Z-aaaaaaaaaaaa\n' > "$CNE_STATE/active-transaction"
    if cne_backup_create > "$CNE_STATE/output" 2>&1; then fail 'pending transaction allowed a new backup'; fi
    if cne_backup_restore >> "$CNE_STATE/output" 2>&1; then fail 'pending transaction allowed historical restore'; fi
    [[ ! -s $MOCK_TRACE ]] || fail 'pending guard installed dependencies or contacted node'
    printf 'PASS: unresolved recovery blocks new backup and restore before prerequisites or node contact\n'
)
if [[ ${CNE_BACKUP_TEST_LIBRARY:-0} != 1 ]]; then
    for test in test_portable_create test_inconsistent_snapshot test_tamper_and_symlink test_missing_manifest_entry test_cancel_restore test_wrong_hosts test_restore_success test_failed_apply_rolls_back test_failed_doctor_rolls_back test_stopped_backup test_partial_and_mismatched_ca test_legacy_and_auth_changes test_publish_failure test_pending_guard; do "$test"; done
fi
