#!/usr/bin/env bash
# Exercise real profile rendering and retry decisions with isolated RPC/key mocks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-client-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
key_private=$(openssl rand -base64 32)
key_public=$(openssl rand -base64 32)
key_server=$(openssl rand -base64 32)
key_other_server=$(openssl rand -base64 32)
key_psk=$(openssl rand -base64 32)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_line() { grep -Fqx -- "$2" "$1" || fail "missing profile/trace line: $2"; }
assert_absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected profile/trace line: $2"; fi; }
assert_count() {
    local count
    count=$(grep -Ec -- "$2" "$1" || true)
    [[ $count == "$3" ]] || fail "expected $3 matches of $2, got $count"
}

mock_setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/render.sh"
    CNE_STATE=$WORK/$1
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_STATE/clients" "$CNE_TEMP"
    MOCK_TRACE=$CNE_STATE/trace
    : > "$MOCK_TRACE"
    MOCK_TRANSPORT=legacy
    MOCK_SERVER_KEY=$key_server
    MOCK_FAIL_BEFORE=0
    MOCK_REPLY_LOST=0
    MOCK_PARAM_RPC_FAIL=0
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    cat > "$CNE_STATE/server-params" <<'PARAMS'
Jc = 6
Jmin = 40
Jmax = 700
S1 = 32
S2 = 48
S3 = 24
S4 = 8
H1 = 100000001-100001024
H2 = 1100000001-1100001024
H3 = 2100000001-2100001024
H4 = 3100000001-3100001024
PARAMS
    cne_require_config() { return 0; }
    cne_bootstrap() { [[ $1 == client ]]; }
    cne_authenticate() { return 0; }
    cne_prompt() { CNE_ANSWER=phone; }
    wg() {
        case $1 in
            genkey) printf 'keygen\n' >> "$MOCK_TRACE"; printf '%s\n' "$key_private" ;;
            pubkey) local input; read -r input; [[ $input == "$key_private" ]] || fail 'profile private key changed'; printf '%s\n' "$key_public" ;;
            genpsk) printf '%s\n' "$key_psk" ;;
            *) fail 'unexpected WireGuard key operation' ;;
        esac
    }
    cne_remote() {
        local index=$1 action=$2
        shift 2
        [[ $index == 0 ]] || fail 'client operation targeted a non-entry node'
        printf 'rpc %s\n' "$action" >> "$MOCK_TRACE"
        case $action in
            inspect)
                printf 'user_port=55123\n'
                [[ $MOCK_TRANSPORT == legacy ]] || printf 'user_transport=%s\n' "$MOCK_TRANSPORT" ;;
            server-public) printf '%s\n' "$MOCK_SERVER_KEY" ;;
            client-params)
                [[ $MOCK_TRANSPORT == awg2 ]] || fail 'legacy client fetched AWG parameters'
                cat "$CNE_STATE/server-params"
                [[ $MOCK_PARAM_RPC_FAIL == 0 ]] || return 1 ;;
            client-list) [[ ! -f $CNE_STATE/peers ]] || cat "$CNE_STATE/peers" ;;
            client-add)
                [[ $# == 4 && $1 == phone && $3 == "$key_public" && $4 == "$MOCK_SERVER_KEY" ]] || fail 'unexpected client addition or missing server identity guard'
                [[ $CNE_CLIENT_PSK == "$key_psk" ]] || fail 'client PSK changed'
                printf 'add-attempt\n' >> "$MOCK_TRACE"
                [[ $MOCK_FAIL_BEFORE == 0 ]] || return 1
                printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$CNE_STATE/peers"
                [[ $MOCK_REPLY_LOST == 0 ]] || return 1 ;;
            *) fail "unexpected client RPC: $action" ;;
        esac
        return 0
    }
    ssh() { fail 'unexpected SSH connection'; }
    sshpass() { fail 'unexpected SSH connection'; }
    apt-get() { fail 'unexpected package change'; }
    python() { fail 'unexpected Python runtime'; }
    python3() { fail 'unexpected Python runtime'; }
}

assert_profile() {
    local profile=$CNE_STATE/clients/phone.conf
    [[ -f $profile && ! -e $profile.pending ]] || fail 'profile did not finalize'
    assert_line "$profile" "PrivateKey = $key_private"
    assert_line "$profile" "PublicKey = $MOCK_SERVER_KEY"
    assert_line "$profile" "PresharedKey = $key_psk"
    assert_line "$profile" 'Endpoint = 203.0.113.10:55123'
    if [[ $MOCK_TRANSPORT == awg2 ]]; then
        awk '/^(Jc|Jmin|Jmax|S[1-4]|H[1-4])[[:space:]]*=/ { print }' "$profile" > "$CNE_STATE/profile-params"
        cmp "$CNE_STATE/server-params" "$CNE_STATE/profile-params" || fail 'profile did not preserve all eleven current AWG parameters'
        assert_line "$MOCK_TRACE" 'rpc client-params'
        cmp "$CNE_STATE/server-params" "$CNE_TEMP/client-awg-params" || fail 'controller did not fetch current server parameters'
    else
        assert_absent "$profile" '^(Jc|Jmin|Jmax|S[1-4]|H[1-4])[[:space:]]*='
        assert_absent "$MOCK_TRACE" '^rpc client-params$'
    fi
}

test_add() (
    mock_setup "add-$1"
    MOCK_TRANSPORT=$1
    cne_client_add > "$CNE_STATE/output" 2>&1 || fail "$1 client addition failed"
    assert_profile
    assert_count "$MOCK_TRACE" '^keygen$' 1
    assert_count "$MOCK_TRACE" '^add-attempt$' 1
    printf 'PASS: %s addition renders current server port, keys and protocol parameters\n' "$1"
)

test_retry() (
    mock_setup "retry-$1"
    MOCK_TRANSPORT=$1
    MOCK_FAIL_BEFORE=1
    if cne_client_add > "$CNE_STATE/output" 2>&1; then fail 'failed addition was ignored'; fi
    [[ -f $CNE_STATE/clients/phone.conf.pending && ! -e $CNE_STATE/peers ]] || fail 'failed addition lost its retry profile'
    cp "$CNE_STATE/clients/phone.conf.pending" "$CNE_STATE/expected-profile"
    MOCK_FAIL_BEFORE=0
    cne_client_add >> "$CNE_STATE/output" 2>&1 || fail 'addition could not retry'
    assert_profile
    cmp "$CNE_STATE/expected-profile" "$CNE_STATE/clients/phone.conf" || fail 'retry replaced the private profile'
    assert_count "$MOCK_TRACE" '^keygen$' 1
    assert_count "$MOCK_TRACE" '^add-attempt$' 2
    printf 'PASS: %s failed addition retries the same private profile and parameters\n' "$1"
)

test_lost_reply() (
    mock_setup "lost-reply-$1"
    MOCK_TRANSPORT=$1
    MOCK_REPLY_LOST=1
    if cne_client_add > "$CNE_STATE/output" 2>&1; then fail 'lost reply was ignored'; fi
    [[ -f $CNE_STATE/peers && -f $CNE_STATE/clients/phone.conf.pending ]] || fail 'lost reply did not retain both remote peer and pending profile'
    cp "$CNE_STATE/clients/phone.conf.pending" "$CNE_STATE/expected-profile"
    cne_client_add >> "$CNE_STATE/output" 2>&1 || fail 'matching existing peer was not recovered'
    assert_profile
    cmp "$CNE_STATE/expected-profile" "$CNE_STATE/clients/phone.conf" || fail 'recovered client profile changed'
    assert_count "$MOCK_TRACE" '^keygen$' 1
    assert_count "$MOCK_TRACE" '^add-attempt$' 1
    printf 'PASS: %s lost SSH reply recovers the exact profile without duplicate peer creation\n' "$1"
)

test_changed_server() (
    mock_setup changed-server
    MOCK_FAIL_BEFORE=1
    if cne_client_add > "$CNE_STATE/output" 2>&1; then fail 'failed addition was ignored'; fi
    cp "$CNE_STATE/clients/phone.conf.pending" "$CNE_STATE/expected-profile"
    MOCK_SERVER_KEY=$key_other_server
    MOCK_FAIL_BEFORE=0
    if cne_client_add >> "$CNE_STATE/output" 2>&1; then fail 'pending profile reused for a different server key'; fi
    cmp "$CNE_STATE/expected-profile" "$CNE_STATE/clients/phone.conf.pending" || fail 'rejected pending profile changed'
    [[ ! -e $CNE_STATE/clients/phone.conf ]] || fail 'wrong deployment profile was published'
    assert_count "$MOCK_TRACE" '^add-attempt$' 1
    printf 'PASS: pending client material is not reused for another server key\n'
)

test_invalid_params() (
    mock_setup "invalid-params-$1"
    MOCK_TRANSPORT=awg2
    case $1 in
        missing) sed '/^H4 = /d' "$CNE_STATE/server-params" > "$CNE_STATE/changed-params" ;;
        duplicate) cat "$CNE_STATE/server-params" > "$CNE_STATE/changed-params"; printf 'Jc = 6\n' >> "$CNE_STATE/changed-params" ;;
        overlap) sed -E 's/^H2 = .*/H2 = 100000001-100001024/' "$CNE_STATE/server-params" > "$CNE_STATE/changed-params" ;;
        bounds) sed -E 's/^Jc = .*/Jc = 99/' "$CNE_STATE/server-params" > "$CNE_STATE/changed-params" ;;
        rpc) cp "$CNE_STATE/server-params" "$CNE_STATE/changed-params"; MOCK_PARAM_RPC_FAIL=1 ;;
    esac
    mv "$CNE_STATE/changed-params" "$CNE_STATE/server-params"
    if cne_client_add > "$CNE_STATE/output" 2>&1; then fail "invalid AWG parameters accepted: $1"; fi
    assert_line "$MOCK_TRACE" 'rpc client-params'
    assert_absent "$MOCK_TRACE" '^keygen$|^add-attempt$'
    [[ ! -e $CNE_STATE/clients/phone.conf.pending && ! -e $CNE_STATE/clients/phone.conf && ! -e $CNE_STATE/peers ]] || fail 'bad AWG parameter response created client material'
    printf 'PASS: AWG parameter %s error stops before key generation or peer mutation\n' "$1"
)

test_changed_pending_params() (
    local field=$1 replacement=$2
    mock_setup "changed-param-$field"
    MOCK_TRANSPORT=awg2
    MOCK_FAIL_BEFORE=1
    if cne_client_add > "$CNE_STATE/output" 2>&1; then fail 'failed AWG addition was ignored'; fi
    cp "$CNE_STATE/clients/phone.conf.pending" "$CNE_STATE/expected-profile"
    sed -E "s/^$field = .*/$field = $replacement/" "$CNE_STATE/server-params" > "$CNE_STATE/changed-params"
    mv "$CNE_STATE/changed-params" "$CNE_STATE/server-params"
    cne_render_awg_params "$CNE_STATE/server-params" >/dev/null || fail 'changed parameter fixture is not valid'
    MOCK_FAIL_BEFORE=0
    if cne_client_add >> "$CNE_STATE/output" 2>&1; then fail "pending AWG profile reused after $field changed"; fi
    cmp "$CNE_STATE/expected-profile" "$CNE_STATE/clients/phone.conf.pending" || fail 'rejected AWG profile changed'
    [[ ! -e $CNE_STATE/clients/phone.conf && ! -e $CNE_STATE/peers ]] || fail 'mismatching AWG profile was published or submitted'
    assert_count "$MOCK_TRACE" '^keygen$' 1
    assert_count "$MOCK_TRACE" '^add-attempt$' 1
    grep -Fq '混淆参数已经改变' "$CNE_STATE/output" || fail 'parameter mismatch did not explain the refusal'
    printf 'PASS: pending AWG profile rejects changed %s without resubmission\n' "$field"
)

test_protocol_change() (
    local before=$1 after=$2
    mock_setup "protocol-$before-$after"
    MOCK_TRANSPORT=$before
    MOCK_FAIL_BEFORE=1
    if cne_client_add > "$CNE_STATE/output" 2>&1; then fail 'failed addition was ignored'; fi
    cp "$CNE_STATE/clients/phone.conf.pending" "$CNE_STATE/expected-profile"
    MOCK_TRANSPORT=$after
    MOCK_FAIL_BEFORE=0
    if cne_client_add >> "$CNE_STATE/output" 2>&1; then fail 'pending profile reused across an entry protocol change'; fi
    cmp "$CNE_STATE/expected-profile" "$CNE_STATE/clients/phone.conf.pending" || fail 'protocol change modified the private pending file'
    [[ ! -e $CNE_STATE/clients/phone.conf ]] || fail 'protocol mismatch was published'
    assert_count "$MOCK_TRACE" '^add-attempt$' 1
    printf 'PASS: pending %s profile is not reused after changing to %s\n' "$before" "$after"
)

for transport in legacy wireguard awg2; do test_add "$transport"; done
for transport in legacy awg2; do test_retry "$transport"; test_lost_reply "$transport"; done
test_changed_server
for invalid in missing duplicate overlap bounds rpc; do test_invalid_params "$invalid"; done
for pair in Jc:7 Jmin:41 Jmax:701 S1:33 S2:49 S3:25 S4:9 H1:100000002-100001025 H2:1100000002-1100001025 H3:2100000002-2100001025 H4:3100000002-3100001025; do
    test_changed_pending_params "${pair%%:*}" "${pair#*:}"
done
test_protocol_change legacy awg2
test_protocol_change awg2 wireguard
printf 'Client checks passed. No real peers, packages or SSH connections changed.\n'
