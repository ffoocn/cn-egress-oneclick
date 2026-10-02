#!/usr/bin/env bash
# Controller workflow tests: all remote operations, downloads and rendering are mocks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-controller-test.XXXXXX")
# Recovery validates every path component; macOS exposes /var and /tmp as aliases.
WORK=$(cd "$WORK" && pwd -P)
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
    mkdir -p "$CNE_TEMP" "$CNE_STATE/clients" "$CNE_STATE/cache" "$CNE_STATE/history" "$CNE_STATE/mock-nodes" "$CNE_STATE/mock-backups"
    printf 'hk\t203.0.113.10\troot\t22\t-\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    printf '51820 443\n' > "$CNE_STATE/ports"
    MOCK_TRACE=$CNE_STATE/trace
    : > "$MOCK_TRACE"
    MOCK_STATES=(absent absent absent)
    MOCK_CHOICE=2
    MOCK_PREFLIGHT_FAIL=-1
    MOCK_PREFLIGHT_ROUND=0
    MOCK_INSTALL_FAIL=-1
    MOCK_DOCTOR_FAIL=-1
    MOCK_RESTORE_FAIL=-1
    MOCK_FORWARDING=1
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_USERS=(root root root)
    CNE_ROLES=(hk sh exit)
    local idx
    for idx in 0 1 2; do
        printf 'original node %s\n' "$idx" > "$CNE_STATE/mock-nodes/$idx"
        cp "$CNE_STATE/mock-nodes/$idx" "$CNE_STATE/mock-nodes/$idx.before"
    done
    cne_require_config() { return 0; }
    cne_bootstrap() { return 0; }
    cne_authenticate() { printf 'authenticate %s\n' "$1" >> "$MOCK_TRACE"; }
    # Production targets GNU chmod on Linux; preserve its effect on the macOS test host.
    chmod() {
        if [[ $# == 3 && $1 == -R && $2 == u+w && $3 == "$CNE_TEMP" ]]; then command chmod "$@"
        else [[ $# == 3 && $1 == 700 && $2 == -- ]] || fail 'unexpected chmod operation'; command chmod "$1" "$3"; fi
    }
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
            backup)
                cp "$CNE_STATE/mock-nodes/$idx" "$CNE_STATE/mock-backups/${CNE_ROLES[$idx]}"
                printf '/root/cn-egress-backups/%s.tar.gz\n' "${CNE_ROLES[$idx]}" ;;
            prepare) [[ $* == awg2 ]] || fail 'node preparation did not select AWG2'; touch "$CNE_STATE/prepared" ;;
            doctor) [[ $idx != "$MOCK_DOCTOR_FAIL" ]] || return 73 ;;
            restore)
                [[ $# == 2 && $1 == /root/cn-egress-backups/"${CNE_ROLES[$idx]}".tar.gz && $2 == "$CNE_TRANSACTION_ID" ]] || fail 'restore used the wrong snapshot or deployment'
                [[ $idx != "$MOCK_RESTORE_FAIL" ]] || return 74
                cp "$CNE_STATE/mock-backups/${CNE_ROLES[$idx]}" "$CNE_STATE/mock-nodes/$idx" ;;
        esac
        return 0
    }
    cne_render_bundle() {
        local out=$1 role name
        [[ $# == 7 && $7 == awg2 ]] || fail 'renderer did not select AWG2'
        printf 'render\n' >> "$MOCK_TRACE"
        mkdir -p "$out/clients"
        for role in hk sh exit; do
            mkdir -p "$out/$role/etc/cn-egress"
            printf '%s\n' "$role" > "$out/$role/etc/cn-egress/role"
        done
        for name in iPhone Android Windows; do
            printf '[Interface]\nPrivateKey = new-%s-fixture\nJc = 6\n' "$name" > "$out/clients/$name.conf"
        done
    }
    cne_fetch_binary() {
        [[ $1 == x86_64 ]] || fail 'unexpected wstunnel architecture'
        printf 'binary %s\n' "$1" >> "$MOCK_TRACE"
        CNE_BINARY=$CNE_TEMP/wstunnel
        printf 'wstunnel fixture\n' > "$CNE_BINARY"
    }
    cne_fetch_awg() {
        [[ $1 == x86_64 ]] || fail 'unexpected AWG architecture'
        printf 'awg %s\n' "$1" >> "$MOCK_TRACE"
        CNE_AWG_ENGINE=$CNE_TEMP/amneziawg-go
        CNE_AWG_TOOLS_SOURCE=$CNE_TEMP/amneziawg-tools.tar.gz
        printf 'AWG engine fixture\n' > "$CNE_AWG_ENGINE"
        printf 'AWG tools fixture\n' > "$CNE_AWG_TOOLS_SOURCE"
    }
    cne_remote_install() {
        printf 'install %s %s\n' "$1" "$2" >> "$MOCK_TRACE"
        [[ $# == 4 && -s $3 && $4 == "$CNE_TRANSACTION_ID" ]] || fail 'invalid installation archive/deployment'
        [[ $(tar -xOf "$3" etc/cn-egress/deployment-id) == "$4" ]] || fail 'archive has the wrong deployment ID'
        if [[ $1 == 0 ]]; then
            [[ $(tar -xOf "$3" opt/cn-egress/awg-0.2.16/amneziawg-go) == 'AWG engine fixture' ]] || fail 'HK archive omitted AWG engine'
            [[ $(tar -xOf "$3" opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz) == 'AWG tools fixture' ]] || fail 'HK archive omitted AWG tools'
        fi
        # A failed call can already have changed the node. Its snapshot must be restored too.
        printf 'changed node %s deployment %s\n' "$1" "$4" > "$CNE_STATE/mock-nodes/$1"
        [[ $1 != "$MOCK_INSTALL_FAIL" ]]
    }
    sleep() { [[ $* == 2 ]] || fail 'unexpected verification wait'; printf 'verification-wait\n' >> "$MOCK_TRACE"; }
    ssh() { fail 'unexpected SSH connection'; }
    sshpass() { fail 'unexpected SSH connection'; }
    curl() { fail 'unexpected network download'; }
    apt-get() { fail 'unexpected host package change'; }
    python() { fail 'unexpected Python runtime'; }
    python3() { fail 'unexpected Python runtime'; }
}

seed_local_profiles() {
    printf 'previous iPhone private config\n' > "$CNE_STATE/clients/iPhone.conf"
    printf 'previous custom private config\n' > "$CNE_STATE/clients/custom.conf"
    printf '20250101T000000Z-aaaaaaaaaaaa\n' > "$CNE_STATE/current-deployment"
    cp -R "$CNE_STATE/clients" "$CNE_STATE/expected-clients"
    cp "$CNE_STATE/current-deployment" "$CNE_STATE/expected-deployment"
}

assert_local_preserved() {
    diff -r "$CNE_STATE/expected-clients" "$CNE_STATE/clients" || fail 'old client names or contents changed'
    cmp "$CNE_STATE/expected-deployment" "$CNE_STATE/current-deployment" || fail 'old deployment pointer changed'
}

assert_nodes_restored() {
    local idx
    for idx in 0 1 2; do
        cmp "$CNE_STATE/mock-nodes/$idx.before" "$CNE_STATE/mock-nodes/$idx" || fail "node $idx was not restored"
    done
}

assert_restore_order() {
    [[ $(awk '$1 == "rpc" && $3 == "restore" { print $2 }' "$MOCK_TRACE") == "$1" ]] || fail 'incorrect reverse restoration order'
}

assert_rolled_back() {
    assert_line "$CNE_TRANSACTION_DIRECTORY/transaction-status" rolled-back
    [[ ! -e $CNE_STATE/active-transaction && $CNE_TRANSACTION_ACTIVE == 0 ]] || fail 'completed rollback left an active transaction'
    assert_nodes_restored
    assert_local_preserved
}

assert_backups_before_install() {
    local idx backup_line install_line
    assert_count "$MOCK_TRACE" '^rpc [012] backup$' 3
    install_line=$(grep -n '^install ' "$MOCK_TRACE" | head -1 | cut -d: -f1)
    for idx in 0 1 2; do
        backup_line=$(grep -n "^rpc $idx backup$" "$MOCK_TRACE" | cut -d: -f1)
        (( backup_line < install_line )) || fail "node $idx snapshot was taken after an installation"
    done
}

test_fresh() (
    mock_setup fresh
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'fresh installation failed'
    assert_absent "$MOCK_TRACE" '^choice$|^rpc [012] restore '
    assert_count "$MOCK_TRACE" '^rpc [012] preflight fresh 51820 443$' 6
    assert_count "$MOCK_TRACE" '^rpc [012] prepare awg2$' 3
    assert_count "$MOCK_TRACE" '^awg x86_64$' 1
    [[ $(grep '^install ' "$MOCK_TRACE") == $'install 1 fresh\ninstall 2 fresh\ninstall 0 fresh' ]] || fail 'fresh installation order or mode'
    assert_backups_before_install
    assert_line "$MOCK_TRACE" render
    assert_count "$MOCK_TRACE" '^rpc [012] doctor$' 3
    local name
    for name in iPhone Android Windows; do
        cmp "$CNE_TRANSACTION_DIRECTORY/bundle/clients/$name.conf" "$CNE_STATE/clients/$name.conf" || fail "profile $name was not committed"
    done
    assert_line "$CNE_STATE/current-deployment" "$CNE_TRANSACTION_ID"
    assert_line "$CNE_TRANSACTION_DIRECTORY/transaction-status" committed
    [[ ! -e $CNE_STATE/active-transaction && $CNE_TRANSACTION_ACTIVE == 0 ]] || fail 'successful commit left an active transaction'
    printf 'PASS: fresh AWG2 installation snapshots all nodes, verifies the chain and commits all profiles\n'
)

test_partial_replace() (
    mock_setup partial
    MOCK_STATES=(absent absent present)
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'partial existing installation was blocked'
    assert_count "$MOCK_TRACE" '^choice$' 1
    assert_backups_before_install
    [[ $(grep '^install ' "$MOCK_TRACE") == $'install 1 fresh\ninstall 2 replace\ninstall 0 fresh' ]] || fail 'partial install must replace only the existing exit'
    printf 'PASS: partial installations replace the existing node and snapshot all three nodes\n'
)

test_replace_commit() (
    mock_setup replace-commit
    MOCK_STATES=(present present present)
    seed_local_profiles
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'replacement commit failed'
    assert_backups_before_install
    [[ $(grep '^install ' "$MOCK_TRACE") == $'install 1 replace\ninstall 2 replace\ninstall 0 replace' ]] || fail 'replacement did not use replace mode'
    assert_line "$CNE_TRANSACTION_DIRECTORY/transaction-status" committed
    assert_line "$CNE_STATE/current-deployment" "$CNE_TRANSACTION_ID"
    diff -r "$CNE_STATE/expected-clients" "$CNE_TRANSACTION_DIRECTORY/previous-clients" || fail 'commit did not retain old private profiles in history'
    cmp "$CNE_STATE/expected-deployment" "$CNE_TRANSACTION_DIRECTORY/previous-deployment" || fail 'commit did not retain old deployment ID'
    [[ ! -e $CNE_STATE/clients/custom.conf && ! -e $CNE_STATE/active-transaction ]] || fail 'committed profiles or journal were not finalized'
    local name
    for name in iPhone Android Windows; do
        cmp "$CNE_TRANSACTION_DIRECTORY/bundle/clients/$name.conf" "$CNE_STATE/clients/$name.conf" || fail "replacement profile $name was not committed"
    done
    assert_absent "$MOCK_TRACE" '^rpc [012] restore '
    printf 'PASS: verified replacement commits new profiles while retaining old profiles in history\n'
)

test_choice() (
    mock_setup "choice-$1"
    MOCK_STATES=(absent absent present)
    MOCK_CHOICE=$1
    seed_local_profiles
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'cancel/keep returned an error'
    assert_line "$MOCK_TRACE" choice
    assert_absent "$MOCK_TRACE" '^(random|render|binary|awg|install|rpc )'
    assert_local_preserved
    [[ -z $(find "$CNE_STATE/history" -mindepth 1 -print -quit) ]] || fail 'cancel/keep created history or keys'
    if [[ $1 == 1 ]]; then assert_line "$MOCK_TRACE" status; else assert_absent "$MOCK_TRACE" '^status$'; fi
    printf 'PASS: choice %s keeps old profiles and does not generate keys or install\n' "$1"
)

test_preflight_failure() (
    local failed=$1 round=$2
    mock_setup "preflight-$failed-$round"
    MOCK_STATES=(present present present)
    MOCK_PREFLIGHT_FAIL=$failed
    MOCK_PREFLIGHT_ROUND=$round
    seed_local_profiles
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'preflight error was ignored'; fi
    assert_absent "$MOCK_TRACE" '^(random|render|binary|awg|install|rpc [012] (backup|enable-forwarding|restore))'
    assert_local_preserved
    assert_nodes_restored
    printf 'PASS: preflight failure at node %s round %s preserves old deployment\n' "$failed" "$round"
)

test_install_failure() (
    local failed=$1 mode=$2 expected
    mock_setup "install-failure-$failed-$mode"
    [[ $mode != replace ]] || MOCK_STATES=(present present present)
    MOCK_INSTALL_FAIL=$failed
    seed_local_profiles
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'remote installation error was ignored'; fi
    case $failed in
        1) expected="install 1 $mode"; assert_restore_order 1 ;;
        2) expected=$(printf 'install 1 %s\ninstall 2 %s' "$mode" "$mode"); assert_restore_order $'2\n1' ;;
        0) expected=$(printf 'install 1 %s\ninstall 2 %s\ninstall 0 %s' "$mode" "$mode" "$mode"); assert_restore_order $'0\n2\n1' ;;
    esac
    [[ $(grep '^install ' "$MOCK_TRACE") == "$expected" ]] || fail 'continued installation after a failed node'
    assert_backups_before_install
    assert_absent "$MOCK_TRACE" '^rpc [012] doctor$|^status$'
    assert_rolled_back
    printf 'PASS: %s failure at node %s restores attempted nodes in reverse, including the failed node\n' "$mode" "$failed"
)

test_doctor_failure() (
    mock_setup "doctor-failure-$1"
    MOCK_STATES=(present present present)
    MOCK_DOCTOR_FAIL=$1
    seed_local_profiles
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'doctor failure was ignored'; fi
    assert_count "$MOCK_TRACE" '^install [012] replace$' 3
    assert_count "$MOCK_TRACE" '^rpc [012] doctor$' 9
    assert_count "$MOCK_TRACE" '^verification-wait$' 2
    assert_restore_order $'0\n2\n1'
    assert_rolled_back
    printf 'PASS: doctor failure at node %s rolls back the whole chain and preserves old profiles\n' "$1"
)

test_publish_failure() (
    mock_setup publish-failure
    MOCK_STATES=(present present present)
    seed_local_profiles
    mv() {
        if [[ ${@: -1} == "$CNE_STATE/current-deployment" ]]; then
            printf 'publish-failure\n' >> "$MOCK_TRACE"
            return 1
        fi
        command mv "$@"
    }
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'publication failure was ignored'; fi
    assert_line "$MOCK_TRACE" publish-failure
    assert_count "$MOCK_TRACE" '^rpc [012] doctor$' 3
    assert_restore_order $'0\n2\n1'
    assert_rolled_back
    printf 'PASS: failure after local profile replacement restores previous profiles and deployment ID\n'
)

prepare_recovery_journal() {
    local id=20250102T000000Z-bbbbbbbbbbbb idx
    MOCK_JOURNAL_DIRECTORY=$CNE_STATE/history/$id
    mkdir -p "$MOCK_JOURNAL_DIRECTORY"
    printf '%s\n' "$id" > "$CNE_STATE/active-transaction"
    printf 'prepared\n' > "$MOCK_JOURNAL_DIRECTORY/transaction-status"
    cp "$CNE_STATE/nodes.tsv" "$MOCK_JOURNAL_DIRECTORY/nodes.tsv"
    for idx in 0 1 2; do
        cp "$CNE_STATE/mock-nodes/$idx.before" "$CNE_STATE/mock-backups/${CNE_ROLES[$idx]}"
        printf '%s\t/root/cn-egress-backups/%s.tar.gz\n' "${CNE_ROLES[$idx]}" "${CNE_ROLES[$idx]}" >> "$MOCK_JOURNAL_DIRECTORY/backups.tsv"
        printf 'interrupted node %s\n' "$idx" > "$CNE_STATE/mock-nodes/$idx"
    done
    printf '1\n2\n0\n' > "$MOCK_JOURNAL_DIRECTORY/attempted.txt"
}

test_recovery_node_mismatch() (
    mock_setup recovery-node-mismatch
    seed_local_profiles
    prepare_recovery_journal
    printf 'changed node endpoints\n' > "$CNE_STATE/nodes.tsv"
    cp -R "$CNE_STATE/mock-nodes" "$CNE_STATE/expected-interrupted-nodes"
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'recovery accepted changed node configuration'; fi
    assert_absent "$MOCK_TRACE" '^(authenticate|inspect|random|render|binary|awg|install|rpc )'
    grep -Fq '当前节点已改变' "$CNE_STATE/output" || { cat "$CNE_STATE/output" >&2; fail 'node mismatch did not explain the refusal'; }
    [[ -f $CNE_STATE/active-transaction ]] || fail 'refused recovery discarded the journal'
    assert_line "$MOCK_JOURNAL_DIRECTORY/transaction-status" prepared
    diff -r "$CNE_STATE/expected-interrupted-nodes" "$CNE_STATE/mock-nodes" || fail 'refused recovery changed a node'
    assert_local_preserved
    printf 'PASS: recovery refuses changed node configuration before authentication or remote mutations\n'
)

test_recovery() (
    mock_setup recovery
    seed_local_profiles
    prepare_recovery_journal
    cne_transaction_recover > "$CNE_STATE/output" 2>&1 || fail 'safe interrupted recovery failed'
    assert_restore_order $'0\n2\n1'
    assert_count "$MOCK_TRACE" '^authenticate [012]$' 3
    assert_rolled_back
    printf 'PASS: an interrupted transaction recovers snapshots in reverse and clears its journal\n'
)

test_incomplete_recovery() (
    mock_setup incomplete-recovery
    MOCK_STATES=(present present present)
    MOCK_INSTALL_FAIL=2
    MOCK_RESTORE_FAIL=2
    seed_local_profiles
    if cne_install > "$CNE_STATE/output" 2>&1; then fail 'installation failure with incomplete rollback was ignored'; fi
    assert_restore_order $'2\n1'
    assert_line "$CNE_TRANSACTION_DIRECTORY/transaction-status" rollback-incomplete
    [[ -f $CNE_STATE/active-transaction ]] || fail 'incomplete rollback discarded recovery journal'
    assert_local_preserved
    : > "$MOCK_TRACE"
    MOCK_RESTORE_FAIL=-1
    cne_transaction_recover >> "$CNE_STATE/output" 2>&1 || fail 'incomplete rollback could not be retried'
    assert_restore_order $'2\n1'
    assert_rolled_back
    printf 'PASS: failed snapshot restoration retains the journal and succeeds on the next recovery\n'
)

test_journal_publication_boundary() (
    local published=$1 id=20250103T000000Z-cccccccccccc idx directory
    mock_setup "journal-boundary-$published"
    seed_local_profiles
    directory=$CNE_STATE/history/$id
    mkdir -p "$directory"
    cp "$CNE_STATE/nodes.tsv" "$directory/nodes.tsv"
    for idx in 0 1 2; do
        printf '%s\t/root/cn-egress-backups/%s.tar.gz\n' "${CNE_ROLES[$idx]}" "${CNE_ROLES[$idx]}" >> "$directory/backups.tsv"
    done
    mv() {
        if [[ ${@: -1} == "$CNE_STATE/active-transaction" ]]; then
            # Model interruption at the publication boundary. Durable metadata
            # must already be readable even before ACTIVE is set in memory.
            assert_line "$directory/transaction-status" prepared
            [[ $CNE_TRANSACTION_ACTIVE == 0 ]] || fail 'transaction activated before publishing a complete journal'
            [[ $published == 0 ]] || command mv "$@" || return 1
            return 75
        fi
        command mv "$@"
    }
    if cne_transaction_begin "$directory" "$id"; then fail 'journal publication interruption was ignored'; fi
    [[ $CNE_TRANSACTION_ACTIVE == 0 ]] || fail 'failed journal publication left the in-memory transaction active'
    assert_nodes_restored
    assert_local_preserved
    if [[ $published == 1 ]]; then
        assert_line "$CNE_STATE/active-transaction" "$id"
        cne_transaction_recover > "$CNE_STATE/output" 2>&1 || fail 'journal exposed before ACTIVE was set could not recover'
        assert_line "$directory/transaction-status" rolled-back
        [[ ! -e $CNE_STATE/active-transaction ]] || fail 'recovered publication-boundary journal was retained'
    else
        [[ ! -e $CNE_STATE/active-transaction ]] || fail 'failed publication created an active journal'
        assert_line "$directory/transaction-status" prepared
    fi
    assert_absent "$MOCK_TRACE" '^(authenticate|rpc )'
    printf 'PASS: interruption at journal publication (%s) leaves complete metadata and preserves all nodes and profiles\n' "$published"
)

test_cleanup_after_commit_boundary() (
    mock_setup cleanup-committed
    MOCK_STATES=(present present present)
    seed_local_profiles
    cne_install > "$CNE_STATE/output" 2>&1 || fail 'fixture commit failed'
    cp -R "$CNE_STATE/mock-nodes" "$CNE_STATE/expected-committed-nodes"
    cp -R "$CNE_STATE/clients" "$CNE_STATE/expected-committed-clients"
    cp "$CNE_STATE/current-deployment" "$CNE_STATE/expected-committed-deployment"
    # A signal can arrive after committed was written but before ACTIVE and the
    # journal are cleared. EXIT cleanup must honor that durable commit boundary.
    CNE_TRANSACTION_ACTIVE=1
    printf '%s\n' "$CNE_TRANSACTION_ID" > "$CNE_STATE/active-transaction"
    : > "$MOCK_TRACE"
    cne_cleanup || fail 'commit-boundary cleanup failed'
    [[ $CNE_TRANSACTION_ACTIVE == 0 && ! -e $CNE_STATE/active-transaction ]] || fail 'committed cleanup retained transaction state'
    assert_line "$CNE_TRANSACTION_DIRECTORY/transaction-status" committed
    assert_absent "$MOCK_TRACE" '^rpc [012] restore '
    diff -r "$CNE_STATE/expected-committed-nodes" "$CNE_STATE/mock-nodes" || fail 'cleanup rolled back committed nodes'
    diff -r "$CNE_STATE/expected-committed-clients" "$CNE_STATE/clients" || fail 'cleanup rolled back committed profiles'
    cmp "$CNE_STATE/expected-committed-deployment" "$CNE_STATE/current-deployment" || fail 'cleanup rolled back committed deployment pointer'
    printf 'PASS: EXIT cleanup after the durable commit boundary clears the journal without restoring nodes or profiles\n'
)

test_menu() (
    source "$ROOT/shell/controller.sh"
    CNE_STATE=$WORK/menu-state
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
test_replace_commit
test_choice 0
test_choice 1
for node in 0 1 2; do test_preflight_failure "$node" 0; test_preflight_failure "$node" 1; done
for node in 1 2 0; do test_install_failure "$node" fresh; test_install_failure "$node" replace; done
for node in 0 1 2; do test_doctor_failure "$node"; done
test_publish_failure
test_recovery_node_mismatch
test_recovery
test_incomplete_recovery
test_journal_publication_boundary 0
test_journal_publication_boundary 1
test_cleanup_after_commit_boundary
test_menu
printf 'Controller workflow tests passed. No server connections or package changes occurred.\n'
