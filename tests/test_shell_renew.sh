#!/usr/bin/env bash
# Certificate transactions reuse the trusted, service-free backup fixtures.
set -euo pipefail
CNE_BACKUP_TEST_LIBRARY=1
source "$(dirname "${BASH_SOURCE[0]}")/test_shell_backup.sh"
renew_setup() {
    mock_setup "$1"
    source "$ROOT/shell/renew.sh"
    CNE_NONINTERACTIVE=0
    MOCK_POST_BAD=-1; MOCK_CONFIG_BAD=-1; MOCK_SERVICE_BAD=-1
    local idx
    for idx in 0 1 2; do
        printf 'original common CA\n' > "$CNE_STATE/nodefiles/$idx.ca"
        printf 'original certificate %s\n' "$idx" > "$CNE_STATE/nodefiles/$idx.cert"
        printf 'original private node key %s\n' "$idx" > "$CNE_STATE/nodefiles/$idx.key"
        printf 'current1234\n' > "$CNE_STATE/nodefiles/$idx.deployment"
        cp "$CNE_STATE/nodefiles/$idx.ca" "$CNE_STATE/before-$idx.ca"
        cp "$CNE_STATE/nodefiles/$idx.cert" "$CNE_STATE/before-$idx.cert"
        cp "$CNE_STATE/nodefiles/$idx.key" "$CNE_STATE/before-$idx.key"
    done
    cp -R "$CNE_STATE/clients" "$CNE_STATE/before-clients"
    cp "$CNE_STATE/ports" "$CNE_STATE/before-ports"
    cp "$CNE_STATE/current-deployment" "$CNE_STATE/before-pointer"
    mock_info() {
        local idx=$1 role=${CNE_ROLES[$1]} ca tls config active=active enabled=enabled due=0
        ca=$(sha256sum "$CNE_STATE/nodefiles/$idx.ca" | awk '{print $1}')
        tls=$(cat "$CNE_STATE/nodefiles/$idx.ca" "$CNE_STATE/nodefiles/$idx.cert" "$CNE_STATE/nodefiles/$idx.key" | sha256sum | awk '{print $1}')
        config=$(sha256sum "$CNE_STATE/nodefiles/$idx" | awk '{print $1}')
        [[ ! -e $CNE_STATE/stopped || $idx != 1 ]] || active=inactive
        [[ ! -e $CNE_STATE/due ]] || due=1
        if [[ $idx == "$MOCK_POST_BAD" && $(cat "$CNE_STATE/nodefiles/$idx.deployment") != current1234 ]]; then ca=$(printf '%064d' 99); fi
        if [[ $idx == "$MOCK_SERVICE_BAD" && $(cat "$CNE_STATE/nodefiles/$idx.deployment") != current1234 ]]; then enabled=disabled; fi
        printf 'state=present\nrole=%s\ndeployment=%s\nca_sha256=%s\nconfig_sha256=%s\ntls_sha256=%s\nwss_host=198.51.100.20\ncert_due=%s\nca_due=%s\n' "$role" "$(cat "$CNE_STATE/nodefiles/$idx.deployment")" "$ca" "$config" "$tls" "$due" "$due"
        printf 'main_active=%s\nmain_enabled=%s\nobfs_active=active\nobfs_enabled=enabled\ndns_active=active\ndns_enabled=enabled\nusers_active=active\nusers_enabled=enabled\n' "$active" "$enabled"
    }
    cne_render_pki() {
        [[ $# == 2 && $2 == 198.51.100.20 ]] || fail 'wrong PKI middle host'
        mkdir -m 700 "$1"
        printf 'renewed common CA\n' > "$1/ca.crt"
        printf 'DO NOT UPLOAD CA PRIVATE KEY\n' > "$1/ca.key"
        local role
        for role in hk sh exit; do
            printf 'renewed certificate %s\n' "$role" > "$1/$role.crt"
            printf 'renewed node key %s\n' "$role" > "$1/$role.key"
        done
    }
    cne_remote_payload() {
        local idx=$1 action=$2 archive=$3 expected=$4 operation=$5 list
        [[ $# == 5 && $action == certificate-apply && $expected == current1234 && $operation == "$CNE_TRANSACTION_ID" ]] || fail 'certificate payload missing transaction guard'
        list=$(tar -tzf "$archive" | LC_ALL=C sort)
        [[ $list == $'ca.crt\nnode.crt\nnode.key' ]] || fail 'certificate upload contains non-TLS files or CA private key'
        ! tar -xOzf "$archive" node.key | grep -Fq 'DO NOT UPLOAD CA PRIVATE KEY' || fail 'CA private key leaked in node key upload'
        printf 'certapply %s\n' "$idx" >> "$MOCK_TRACE"
        tar -xOzf "$archive" ca.crt > "$CNE_STATE/nodefiles/$idx.ca"
        tar -xOzf "$archive" node.crt > "$CNE_STATE/nodefiles/$idx.cert"
        tar -xOzf "$archive" node.key > "$CNE_STATE/nodefiles/$idx.key"
        printf '%s\n' "$operation" > "$CNE_STATE/nodefiles/$idx.deployment"
        if [[ $idx == "$MOCK_CONFIG_BAD" ]]; then printf 'unexpected non-TLS change\n' > "$CNE_STATE/nodefiles/$idx"; fi
        [[ $idx != "$MOCK_APPLY_FAIL" ]]
    }
    # Preserve the fixture random generator, and mock only the final display.
    eval "$(declare -f openssl | sed '1s/openssl/mock_openssl_random/')"
    openssl() {
        if [[ $1 == rand ]]; then mock_openssl_random "$@"
        elif [[ $1 == x509 && ${*: -2} == '-noout -enddate' ]]; then printf 'notAfter=Jan 1 00:00:00 2030 GMT\n'
        else fail 'unexpected certificate CLI operation'; fi
    }
}
assert_renew_old_nodes() {
    local idx field
    for idx in 0 1 2; do
        for field in ca cert key; do cmp "$CNE_STATE/before-$idx.$field" "$CNE_STATE/nodefiles/$idx.$field" || fail "node $idx TLS state not recovered"; done
        [[ $(cat "$CNE_STATE/nodefiles/$idx.deployment") == current1234 ]] || fail 'rollback left maintenance identity'
        [[ $(cat "$CNE_STATE/nodefiles/$idx") == "original-node-$idx" ]] || fail 'rollback left non-TLS change'
    done
}
assert_renew_local_preserved() {
    diff -r "$CNE_STATE/before-clients" "$CNE_STATE/clients" >/dev/null && cmp "$CNE_STATE/before-ports" "$CNE_STATE/ports" || fail 'renewal changed device configuration or ports'
}
test_renew_success() (
    renew_setup renew-success
    printf 'y\n' > "$CNE_STATE/answers"
    cne_renew_certificates > "$CNE_STATE/output" 2>&1 || { cat "$CNE_STATE/output" >&2; fail 'manual renewal failed'; }
    [[ $(awk '$1=="certapply"{print $2}' "$MOCK_TRACE") == $'1\n2\n0' ]] || fail 'wrong certificate apply order'
    local idx first
    first=$(grep -n '^certapply ' "$MOCK_TRACE" | head -1 | cut -d: -f1)
    for idx in 0 1 2; do
        [[ $(grep -n "^rpc $idx backup$" "$MOCK_TRACE" | cut -d: -f1) -lt $first ]] || fail 'certificate update before all snapshots'
        [[ $(cat "$CNE_STATE/nodefiles/$idx.ca") == 'renewed common CA' && $(cat "$CNE_STATE/nodefiles/$idx.deployment") == "$CNE_TRANSACTION_ID" && $(cat "$CNE_STATE/nodefiles/$idx") == "original-node-$idx" ]] || fail 'certificate state or non-TLS config mismatch'
    done
    assert_renew_local_preserved
    [[ $(cat "$CNE_STATE/current-deployment") == "$CNE_TRANSACTION_ID" && $(cat "$CNE_TRANSACTION_DIRECTORY/transaction-status") == committed && ! -e $CNE_STATE/active-transaction ]] || fail 'certificate commit incomplete'
    grep -Fxq verify "$MOCK_TRACE" || fail 'running chain not verified'
    printf 'PASS: TLS-only renewal snapshots all nodes, excludes CA private key and preserves device configuration\n'
)
test_renew_decline() (
    renew_setup renew-decline
    printf 'n\n' > "$CNE_STATE/answers"
    cne_renew_certificates > "$CNE_STATE/output" 2>&1 || fail 'decline renewal failed'
    ! grep -Eq ' backup$|^certapply ' "$MOCK_TRACE" || fail 'decline saved/changed node state'
    assert_renew_old_nodes; assert_renew_local_preserved
    printf 'PASS: declining manual certificate update leaves all files and services untouched\n'
)
test_renew_partial_failure() (
    renew_setup renew-partial
    MOCK_APPLY_FAIL=2
    printf 'y\n' > "$CNE_STATE/answers"
    if cne_renew_certificates > "$CNE_STATE/output" 2>&1; then fail 'partial TLS failure committed'; fi
    [[ $(awk '$1=="rpc"&&$3=="restore"{print $2}' "$MOCK_TRACE") == $'2\n1' ]] || fail 'failed TLS node not recovered first'
    assert_renew_old_nodes; assert_renew_local_preserved
    [[ ! -e $CNE_STATE/active-transaction ]] || fail 'successful TLS rollback left pending journal'
    printf 'PASS: interrupted certificate application rolls back failed and previously updated nodes\n'
)
test_renew_postchecks() (
    local defect
    for defect in ca config service; do
        renew_setup "renew-post-$defect"
        case $defect in ca) MOCK_POST_BAD=0;; config) MOCK_CONFIG_BAD=0;; service) MOCK_SERVICE_BAD=0;; esac
        printf 'y\n' > "$CNE_STATE/answers"
        if cne_renew_certificates > "$CNE_STATE/output" 2>&1; then fail "$defect mismatch committed"; fi
        assert_renew_old_nodes; assert_renew_local_preserved
        [[ $(awk '$1=="rpc"&&$3=="restore"{print $2}' "$MOCK_TRACE") == $'0\n2\n1' ]] || fail 'postcheck did not recover all applied nodes'
    done
    printf 'PASS: CA, non-TLS configuration and service-state mismatches cannot be committed\n'
)
test_renew_doctor_failure() (
    renew_setup renew-doctor
    MOCK_DOCTOR_FAIL=1
    printf 'y\n' > "$CNE_STATE/answers"
    if cne_renew_certificates > "$CNE_STATE/output" 2>&1; then fail 'unusable renewed chain committed'; fi
    assert_renew_old_nodes; assert_renew_local_preserved
    cmp "$CNE_STATE/before-pointer" "$CNE_STATE/current-deployment" || fail 'failed chain published deployment'
    printf 'PASS: failed chain verification recovers all certificates without publishing a deployment\n'
)
test_renew_publish_failure() (
    renew_setup renew-publish
    MOCK_PUBLISH_FAIL=1
    printf 'y\n' > "$CNE_STATE/answers"
    if cne_renew_certificates > "$CNE_STATE/output" 2>&1; then fail 'failed local renewal commit succeeded'; fi
    assert_renew_old_nodes; assert_renew_local_preserved
    cmp "$CNE_STATE/before-pointer" "$CNE_STATE/current-deployment" || fail 'failed renewal publication did not restore pointer'
    [[ ! -e $CNE_STATE/active-transaction ]] || fail 'renewal publication recovery incomplete'
    printf 'PASS: local certificate publication failure also restores the previous deployment pointer\n'
)
test_renew_stopped() (
    renew_setup renew-stopped
    touch "$CNE_STATE/stopped"
    printf 'y\n' > "$CNE_STATE/answers"
    cne_renew_certificates > "$CNE_STATE/output" 2>&1 || fail 'stopped-state renewal failed'
    ! grep -Fxq verify "$MOCK_TRACE" || fail 'stopped service forced online'
    grep -q '不宣称链路可用' "$CNE_STATE/output" || fail 'stopped renewal claimed working chain'
    assert_renew_local_preserved
    printf 'PASS: certificate update retains stopped service state and clearly reports unverified connectivity\n'
)
test_auto_not_due() (
    renew_setup auto-not-due
    cne_prompt() { fail 'automatic maintenance requested confirmation'; }
    cne_secret() { fail 'automatic maintenance requested secret'; }
    cne_renew_auto > "$CNE_STATE/output" 2>&1 || fail 'automatic no-op failed'
    [[ $CNE_NONINTERACTIVE == 1 ]] || fail 'automatic check not marked noninteractive'
    ! grep -Eq ' backup$|^certapply |^commit$' "$MOCK_TRACE" || fail 'not-due certs were rotated'
    printf 'PASS: automatic maintenance does not prompt or alter certificates outside the renewal window\n'
)
test_auto_due() (
    renew_setup auto-due
    touch "$CNE_STATE/due"
    cne_prompt() { fail 'automatic maintenance requested confirmation'; }
    cne_secret() { fail 'automatic maintenance requested secret'; }
    cne_renew_auto > "$CNE_STATE/output" 2>&1 || { cat "$CNE_STATE/output" >&2; fail 'automatic due renewal failed'; }
    grep -Fxq commit "$MOCK_TRACE" || fail 'automatic due certificate was not rotated'
    assert_renew_local_preserved
    printf 'PASS: due automatic renewal uses the complete guarded transaction without any confirmation prompt\n'
)
test_auto_bad_due() (
    renew_setup auto-invalid
    eval "$(declare -f mock_info | sed '1s/mock_info/base_renew_info/')"
    mock_info() { base_renew_info "$1" | sed 's/^cert_due=.*/cert_due=unknown/'; }
    cne_prompt() { fail 'invalid automatic state prompted'; }
    if cne_renew_auto > "$CNE_STATE/output" 2>&1; then fail 'invalid due state accepted'; fi
    ! grep -q '^certapply ' "$MOCK_TRACE" || fail 'invalid due state caused update'
    printf 'PASS: automatic renewal rejects missing or invalid expiration status before changing certificates\n'
)
test_noninteractive_credentials() (
    renew_setup auto-credentials
    source "$ROOT/shell/controller.sh"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_NONINTERACTIVE=1
    cne_bootstrap() { return 0; }
    cne_secret() { fail 'noninteractive credentials requested password'; }
    if cne_authenticate 0 > "$CNE_STATE/output" 2>&1; then fail 'password-only SSH accepted for automatic maintenance'; fi
    CNE_IDENTITIES[0]=$CNE_TEMP/key; printf 'encrypted fixture key\n' > "${CNE_IDENTITIES[0]}"
    ssh-keygen() { [[ $* == *'-P '* ]] || fail 'key probe did not suppress passphrase'; return 1; }
    if cne_authenticate 0 >> "$CNE_STATE/output" 2>&1; then fail 'encrypted key accepted for automatic maintenance'; fi
    printf 'PASS: automatic credentials reject password authentication and encrypted keys without prompting\n'
)
test_timer_quoting() (
    renew_setup timer-quoting
    CNE_STATE=$WORK/'state space%"quote'; HOME=$WORK/'home space%"quote'
    cne_renew_timer_id || fail 'timer identity invalid'
    local directory=$WORK/generated-timer
    mkdir "$directory"
    cne_renew_timer_files "$directory" || fail 'timer generation failed'
    grep -Fq 'space%%\"quote' "$directory/service" || fail 'systemd values did not escape percent or quote'
    grep -Fxq 'Environment=CNE_NONINTERACTIVE=1' "$directory/service" || fail 'timer did not request password-free mode'
    grep -Fxq 'OnCalendar=daily' "$directory/timer" || fail 'timer not daily'
    grep -Fxq 'Restart=on-failure' "$directory/service" && grep -Fxq 'RestartPreventExitStatus=1' "$directory/service" && grep -Fxq 'RestartSec=15min' "$directory/service" || fail 'timer did not preserve the busy-lock retry and ordinary failure policy'
    printf 'PASS: generated daily timer quotes management paths and forces noninteractive private execution\n'
)
timer_root_setup() {
    renew_setup "$1"
    TIMER_ROOT=$CNE_STATE/mock-root
    TIMER_ID=112233aabbcc; TIMER_UNIT=cn-egress-renew-$TIMER_ID
    TIMER_DIRECTORY=$TIMER_ROOT/usr/local/lib/$TIMER_UNIT
    TIMER_SERVICE=$TIMER_ROOT/etc/systemd/system/$TIMER_UNIT.service
    TIMER_TIMER=$TIMER_ROOT/etc/systemd/system/$TIMER_UNIT.timer
    mkdir -p "$TIMER_ROOT/usr/local/lib" "$TIMER_ROOT/etc/systemd/system" "$TIMER_ROOT/run/systemd/system" "$TIMER_ROOT/usr/lib/systemd/system" "$TIMER_ROOT/lib/systemd/system"
    # Map the trusted helper's fixed system paths to an isolated fixture tree.
    # No real privileged path is read, written or passed to systemctl.
    [[ $TIMER_ROOT =~ ^[A-Za-z0-9_./-]+$ ]] || fail 'mock root path cannot be substituted safely'
    local helper
    helper=$(declare -f cne_renew_timer_root)
    helper=${helper//\/usr/$TIMER_ROOT\/usr}
    helper=${helper//\/etc/$TIMER_ROOT\/etc}
    helper=${helper//\/run/$TIMER_ROOT\/run}
    # Match /lib only at the beginning of a literal path, not .../usr/local/lib.
    helper=${helper// \/lib\/systemd/ $TIMER_ROOT\/lib\/systemd}
    eval "$helper"
    id() { [[ $* == -u ]] || fail 'unexpected root helper identity query'; printf '0\n'; }
    stat() {
        [[ $# == 3 && $1 == -c && $2 == %a ]] || fail 'unexpected stat query'
        if [[ $(uname -s) == Darwin ]]; then command stat -f %Lp "$3"; else command stat "$@"; fi
    }
    wc() {
        # Match Linux coreutils' count-only output on the macOS test host.
        if [[ $# == 1 && $1 == -l ]]; then command wc -l | tr -d '[:space:]'; printf '\n'
        else command wc "$@"; fi
    }
    MOCK_INSTALL_FAIL=0
    install() {
        [[ $# == 8 && $1 == -o && $2 == 0 && $3 == -g && $4 == 0 && $5 == -m ]] || fail 'unexpected install arguments'
        local count=0
        [[ ! -f $CNE_STATE/install-count ]] || read -r count < "$CNE_STATE/install-count"
        count=$((count+1)); printf '%s\n' "$count" > "$CNE_STATE/install-count"
        [[ $count != "$MOCK_INSTALL_FAIL" ]] || return 1
        cp "$7" "$8" && command chmod "$6" "$8"
    }
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$MOCK_TRACE"
        case $1 in
            show)
                [[ $# == 5 && $3 == -p && $5 == --value ]] || fail 'unexpected systemd show'
                if [[ $4 == FragmentPath && -f $TIMER_ROOT/etc/systemd/system/$2 ]]; then printf '%s\n' "$TIMER_ROOT/etc/systemd/system/$2"; fi
                ;;
            daemon-reload|enable|disable) return 0;;
            *) fail 'unexpected systemd mutation';;
        esac
    }
    TIMER_INPUT=$CNE_TEMP/timer-input
    mkdir "$TIMER_INPUT"
    CNE_RENEW_TIMER_ID=$TIMER_ID
    cne_renew_timer_files "$TIMER_INPUT"
    printf '#!/usr/bin/env bash\nprintf "fixture manager v1\\n"\n' > "$TIMER_INPUT/manager.sh"
}
assert_timer_receipt() {
    local file number=2 expected actual
    [[ -f $TIMER_DIRECTORY/ownership && $(wc -l < "$TIMER_DIRECTORY/ownership") == 4 ]] || fail 'root ownership receipt missing'
    [[ $(head -n 1 "$TIMER_DIRECTORY/ownership") == "$TIMER_UNIT" ]] || fail 'ownership receipt belongs to different timer'
    for file in "$TIMER_DIRECTORY/manager.sh" "$TIMER_SERVICE" "$TIMER_TIMER"; do
        expected=$(sed -n "${number}p" "$TIMER_DIRECTORY/ownership")
        actual=$(sha256sum "$file" | awk '{print $1}')
        [[ $actual == "$expected" ]] || fail 'published timer file differs from receipt'
        number=$((number+1))
    done
    [[ ! -e $TIMER_DIRECTORY/ownership.pending && ! -e $TIMER_DIRECTORY/candidate ]] || fail 'timer publication left a pending candidate'
}
test_timer_root_fresh() (
    timer_root_setup timer-root-fresh
    cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT" || fail 'fresh timer install failed'
    assert_timer_receipt
    grep -Fxq "systemctl enable --now $TIMER_UNIT.timer" "$MOCK_TRACE" || fail 'fresh timer was not enabled'
    cne_renew_timer_root disable "$TIMER_ID" || fail 'owned timer disable failed'
    grep -Fxq "systemctl disable --now $TIMER_UNIT.timer" "$MOCK_TRACE" || fail 'owned timer was not disabled'
    printf 'PASS: timer root helper installs and disables only exact files proven by private ownership receipts\n'
)
test_timer_initial_interruption() (
    timer_root_setup timer-interrupted
    MOCK_INSTALL_FAIL=5
    if cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT"; then fail 'interrupted publication reported success'; fi
    [[ -f $TIMER_DIRECTORY/ownership.pending && -d $TIMER_DIRECTORY/candidate && -f $TIMER_DIRECTORY/manager.sh && ! -e $TIMER_SERVICE ]] || fail 'publication failure did not retain evidence for retry'
    MOCK_INSTALL_FAIL=0
    cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT" || fail 'timer publication could not be retried'
    assert_timer_receipt
    printf 'PASS: interrupted first timer installation completes from a durable, hash-proven candidate\n'
)
test_timer_update_interruption() (
    timer_root_setup timer-update
    cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT" || fail 'baseline timer installation failed'
    printf '#!/usr/bin/env bash\nprintf "fixture manager v2\\n"\n' > "$TIMER_INPUT/manager.sh"
    printf '0\n' > "$CNE_STATE/install-count"; MOCK_INSTALL_FAIL=5
    if cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT"; then fail 'interrupted timer update reported success'; fi
    grep -q 'manager v2' "$TIMER_DIRECTORY/manager.sh" || fail 'fixture did not interrupt after first file update'
    printf '#!/usr/bin/env bash\nprintf "fixture manager v3\\n"\n' > "$TIMER_INPUT/manager.sh"
    MOCK_INSTALL_FAIL=0
    cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT" || fail 'mixed old/new timer files could not recover'
    assert_timer_receipt
    grep -q 'manager v3' "$TIMER_DIRECTORY/manager.sh" || fail 'recovered update did not accept subsequent new version'
    printf 'PASS: interrupted timer update recognizes old/new file hashes before accepting a later version\n'
)
test_timer_tamper_protection() (
    timer_root_setup timer-tamper
    MOCK_INSTALL_FAIL=5
    if cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT"; then fail 'fixture did not interrupt'; fi
    printf 'external operator modification\n' > "$TIMER_DIRECTORY/manager.sh"
    MOCK_INSTALL_FAIL=0
    if cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT"; then fail 'timer overwrote unrecognized operator file'; fi
    [[ $(cat "$TIMER_DIRECTORY/manager.sh") == 'external operator modification' && -f $TIMER_DIRECTORY/ownership.pending && ! -e $TIMER_SERVICE ]] || fail 'refused timer recovery changed files'
    printf 'PASS: timer recovery refuses any external modification outside old/new recorded hashes\n'
)
test_timer_dropin_protection() (
    local suffix
    for suffix in service.d cn-egress-renew-.service.d; do
        timer_root_setup "timer-dropin-$suffix"
        mkdir "$TIMER_ROOT/etc/systemd/system/$suffix"
        if cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT"; then fail 'global/prefix timer drop-in collision accepted'; fi
        [[ ! -e $TIMER_DIRECTORY && ! -e $TIMER_SERVICE && ! -e $TIMER_TIMER ]] || fail 'drop-in refusal changed service files'
    done
    printf 'PASS: global and dashed-prefix systemd drop-ins block timer creation before any service file changes\n'
)
test_timer_empty_retry() (
    timer_root_setup timer-empty
    mkdir "$TIMER_DIRECTORY"
    cne_renew_timer_root enable "$TIMER_ID" "$TIMER_INPUT" || fail 'proven-empty reserved directory could not retry first install'
    assert_timer_receipt
    printf 'PASS: a proven-empty reserved timer directory can retry a first installation\n'
)
for test in test_renew_success test_renew_decline test_renew_partial_failure test_renew_postchecks test_renew_doctor_failure test_renew_publish_failure test_renew_stopped test_auto_not_due test_auto_due test_auto_bad_due test_noninteractive_credentials test_timer_quoting test_timer_root_fresh test_timer_initial_interruption test_timer_update_interruption test_timer_tamper_protection test_timer_dropin_protection test_timer_empty_retry; do "$test"; done
