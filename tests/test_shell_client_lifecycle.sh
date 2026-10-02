#!/usr/bin/env bash
# Reproduce stale exports and uncertain revocations without server connections.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-client-lifecycle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
PRIVATE=$(openssl rand -base64 32)
PUBLIC=$(openssl rand -base64 32)
SERVER=$(openssl rand -base64 32)
OTHER_PRIVATE=$(openssl rand -base64 32)
OTHER_PUBLIC=$(openssl rand -base64 32)
OTHER_SERVER=$(openssl rand -base64 32)
PSK=$(openssl rand -base64 32)
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${CNE_STATE:-}/output ]] || cat "$CNE_STATE/output" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected: $2"; fi; }

setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/render.sh"
    CNE_STATE=$WORK/$1
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_STATE/clients" "$CNE_TEMP"
    TRACE=$CNE_STATE/trace; : > "$TRACE"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    MODE=wireguard; INSPECT_STATE=present; CURRENT_SERVER=$SERVER; REMOVE_RESULT=success
    cat > "$CNE_STATE/params" <<'PARAMS'
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
    printf 'phone\t2\t%s\n' "$PUBLIC" > "$CNE_STATE/peers"
    cne_render_client "$CNE_STATE/clients/phone.conf" 2 "$PRIVATE" "$SERVER" "$PSK" 203.0.113.10 51820 "$MODE" "$CNE_STATE/params"
    cne_mutation_guard() { printf 'guard\n' >> "$TRACE"; return 0; }
    cne_bootstrap() { [[ $1 == client ]] || fail 'unexpected dependency phase'; printf 'bootstrap client\n' >> "$TRACE"; return 0; }
    cne_require_config() { printf 'config\n' >> "$TRACE"; return 0; }
    cne_authenticate() { printf 'authenticate %s\n' "$*" >> "$TRACE"; return 0; }
    wg() {
        [[ $1 == pubkey ]] || fail 'unexpected WireGuard operation'
        local key; IFS= read -r key
        case $key in "$PRIVATE") printf '%s\n' "$PUBLIC";; "$OTHER_PRIVATE") printf '%s\n' "$OTHER_PUBLIC";; *) return 1;; esac
    }
    cne_remote() {
        [[ $1 == 0 ]] || fail 'client operation touched another node'
        printf 'rpc %s\n' "$2" >> "$TRACE"
        case $2 in
            inspect) printf 'state=%s\nrole=hk\nuser_port=51820\nuser_transport=%s\n' "$INSPECT_STATE" "$MODE";;
            server-public) printf '%s\n' "$CURRENT_SERVER";;
            client-list) cat "$CNE_STATE/peers";;
            client-params) cat "$CNE_STATE/params";;
            client-verify)
                local expected
                expected=$(printf '%s\n' "$PSK" | sha256sum); expected=${expected%% *}
                [[ $4 == "$CURRENT_SERVER" && $5 == "$expected" ]] || return 1
                awk -F'\t' -v key="$3" '$3==key{found=1}END{exit !found}' "$CNE_STATE/peers";;
            client-remove)
                [[ $3 == phone ]] || fail 'unexpected revoke name'
                [[ $4 == "$PUBLIC" && $5 == "$SERVER" ]] || fail 'revoke omitted key guards'
                [[ $REMOVE_RESULT != failed ]] || return 42
                : > "$CNE_STATE/peers"
                [[ $REMOVE_RESULT != lost ]] || return 42;;
            *) fail "unexpected RPC: $2";;
        esac
    }
    cne_ensure_qrencode() { printf 'qr-prepare\n' >> "$TRACE"; return 0; }
    qrencode() { printf 'qr-render\n' >> "$TRACE"; cat > "$CNE_STATE/qr-input"; printf 'QR-RENDERED\n'; }
    ssh() { fail 'unexpected SSH connection'; }
    sshpass() { fail 'unexpected SSH connection'; }
    apt-get() { fail 'unexpected package change'; }
    dpkg() { fail 'unexpected package query'; }
    sudo() { fail 'unexpected privilege request'; }
}

test_export_verified() (
    setup "verified-$1"; MODE=$1
    if [[ $MODE == awg2 ]]; then
        rm "$CNE_STATE/clients/phone.conf"
        cne_render_client "$CNE_STATE/clients/phone.conf" 2 "$PRIVATE" "$SERVER" "$PSK" 203.0.113.10 51820 awg2 "$CNE_STATE/params"
    fi
    printf '%s\n' 1 1 | cne_client_export > "$CNE_STATE/output" 2>&1 || fail 'valid device could not be exported'
    contains "$CNE_STATE/output" '已核对当前入口'
    contains "$CNE_STATE/output" '每台设备使用独立配置'
    contains "$CNE_STATE/output" 'QR-RENDERED'
    cmp "$CNE_STATE/clients/phone.conf" "$CNE_STATE/qr-input" || fail 'wrong device encoded'
    [[ $MODE != awg2 ]] || contains "$TRACE" 'rpc client-params'
    printf 'PASS: %s exports verify current keys, protocol and registered peer before QR\n' "$MODE"
)

test_export_offline() (
    setup offline; CNE_HOSTS=('' '' '')
    cne_require_config() { fail 'offline view entered node setup'; }
    cne_authenticate() { fail 'offline view requested a password'; }
    cne_remote() { fail 'offline view contacted a node'; }
    cne_ensure_qrencode() { fail 'offline view installed optional dependencies'; }
    printf '%s\n' phone 2 | cne_client_export > "$CNE_STATE/output" 2>&1 || fail 'offline viewing was blocked'
    contains "$CNE_STATE/output" '尚未验证当前有效性'
    contains "$CNE_STATE/output" "PrivateKey = $PRIVATE"
    [[ ! -s $TRACE ]] || fail 'offline viewing required management dependencies'
    printf 'PASS: offline viewing needs no nodes, passwords, packages or key tools\n'
)

test_export_stale() (
    setup "stale-$1"
    case $1 in
        key) CURRENT_SERVER=$OTHER_SERVER;;
        endpoint) CNE_HOSTS[0]=203.0.113.11;;
        revoked) : > "$CNE_STATE/peers";;
        absent) INSPECT_STATE=absent;;
        protocol) MODE=awg2;;
        ipv4) sed 's@10.77.10.2/32@10.88.99.2/32@' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        ipv6) sed 's@fd77:77:10::2/128@fd88::2/128@' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        dns) sed 's/DNS = 10.77.30.2/DNS = 8.8.8.8/' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        routes) sed 's@AllowedIPs = 0.0.0.0/0, ::/0@AllowedIPs = 10.0.0.0/8@' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        psk) sed "s@PresharedKey = $PSK@PresharedKey = $OTHER_PRIVATE@" "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        duplicate-field) awk '{print;if($1=="DNS")print}' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        duplicate-section) printf '\n[Peer]\nPublicKey = %s\n' "$OTHER_SERVER" >> "$CNE_STATE/clients/phone.conf";;
        hook) awk '{print;if($1=="MTU")print "PostUp = arbitrary-script-command"}' "$CNE_STATE/clients/phone.conf" > "$CNE_STATE/changed"; mv "$CNE_STATE/changed" "$CNE_STATE/clients/phone.conf";;
        parameters)
            MODE=awg2; rm "$CNE_STATE/clients/phone.conf"
            cne_render_client "$CNE_STATE/clients/phone.conf" 2 "$PRIVATE" "$SERVER" "$PSK" 203.0.113.10 51820 awg2 "$CNE_STATE/params"
            sed 's/Jc = 6/Jc = 7/' "$CNE_STATE/params" > "$CNE_STATE/new-params"
            mv "$CNE_STATE/new-params" "$CNE_STATE/params";;
    esac
    if printf '%s\n' 1 1 N | cne_client_export > "$CNE_STATE/output" 2>&1; then fail 'stale profile exported as current'; fi
    contains "$CNE_STATE/output" '当前有效性未通过验证'
    absent "$TRACE" 'qr-prepare|qr-render'
    [[ ! -e $CNE_STATE/qr-input ]] || fail 'stale profile generated a QR'
    if grep -Fq "$PRIVATE" "$CNE_STATE/output"; then fail 'rejected verification displayed private file'; fi
    printf 'PASS: changed %s cannot silently be delivered as verified\n' "$1"
)

test_numeric_picker() (
    setup numeric-picker
    rm "$CNE_STATE/clients/phone.conf"
    local name input expected number=2
    for name in 1 10 2; do
        cne_render_client "$CNE_STATE/clients/$name.conf" "$number" "$PRIVATE" "$SERVER" "$PSK" 203.0.113.10 51820 wireguard
        number=$((number+1))
    done
    for input in 2 n:2; do
        expected=10; [[ $input != n:2 ]] || expected=2
        printf '%s\n' "$input" 2 | cne_client_export > "$CNE_STATE/output" 2>&1 || fail 'numeric picker failed'
        contains "$CNE_STATE/output" "配置文件：$CNE_STATE/clients/$expected.conf"
    done
    printf 'PASS: numeric device names use n:NAME explicitly while plain numbers select listed indices\n'
)

test_export_explicit_fallback() (
    setup fallback; : > "$CNE_STATE/peers"
    printf '%s\n' 1 1 y | cne_client_export > "$CNE_STATE/output" 2>&1 || fail 'explicit offline fallback failed'
    contains "$CNE_STATE/output" '尚未验证当前有效性'
    contains "$CNE_STATE/output" "PrivateKey = $PRIVATE"
    absent "$TRACE" 'qr-prepare|qr-render'
    printf 'PASS: failed verification requires explicit offline-view acceptance\n'
)

test_picker() (
    setup picker
    cne_render_client "$CNE_STATE/clients/tablet.conf" 3 "$OTHER_PRIVATE" "$SERVER" "$PSK" 203.0.113.10 51820 wireguard
    printf 'tablet\t3\t%s\n' "$OTHER_PUBLIC" >> "$CNE_STATE/peers"
    printf '%s\n' 2 1 | cne_client_export > "$CNE_STATE/output" 2>&1 || fail 'device index selection failed'
    cmp "$CNE_STATE/clients/tablet.conf" "$CNE_STATE/qr-input" || fail 'picker selected wrong device'
    printf 'PASS: numbered picker exports the selected device without name recall\n'
)

test_remove() (
    setup "remove-$1"; REMOVE_RESULT=$1
    printf '%s\n' phone y | cne_client_remove > "$CNE_STATE/output" 2>&1 || fail 'confirmed revocation failed'
    [[ ! -s $CNE_STATE/peers && ! -e $CNE_STATE/clients/phone.conf && -f $CNE_STATE/clients/phone.conf.revoked ]] || fail 'revocation states diverged'
    cne_client_remove <<<phone >> "$CNE_STATE/output" 2>&1 || fail 'already revoked retry failed'
    [[ $(grep -c '^rpc client-remove$' "$TRACE") == 1 ]] || fail 'retry deleted client again'
    contains "$CNE_STATE/output" '无需再次撤销'
    printf 'PASS: %s revocation and retry keep local and remote states coherent\n' "$1"
)

test_remove_already_absent() (
    setup already-absent; : > "$CNE_STATE/peers"
    cne_client_remove <<<phone > "$CNE_STATE/output" 2>&1 || fail 'absent peer reconciliation failed'
    [[ ! -e $CNE_STATE/clients/phone.conf && -f $CNE_STATE/clients/phone.conf.revoked ]] || fail 'absent peer retained active profile'
    absent "$TRACE" 'rpc client-remove'
    printf 'PASS: completed revocation marks only the matching original local file\n'
)

test_remove_rejected() (
    setup "remove-reject-$1"
    case $1 in
        typo) : > "$CNE_STATE/peers"; rm "$CNE_STATE/clients/phone.conf";;
        different-peer) printf 'phone\t2\t%s\n' "$OTHER_PUBLIC" > "$CNE_STATE/peers";;
        different-server) CURRENT_SERVER=$OTHER_SERVER;;
        renamed) printf 'other-name\t2\t%s\n' "$PUBLIC" > "$CNE_STATE/peers";;
    esac
    if printf '%s\n' phone y | cne_client_remove > "$CNE_STATE/output" 2>&1; then fail 'ambiguous revocation accepted'; fi
    absent "$TRACE" 'rpc client-remove'
    [[ $1 == typo || -f $CNE_STATE/clients/phone.conf ]] || fail 'rejected revoke altered local file'
    printf 'PASS: %s cannot invalidate an unrelated active device\n' "$1"
)

test_remove_failure() (
    setup failed-remove; REMOVE_RESULT=failed
    if printf '%s\n' phone y | cne_client_remove > "$CNE_STATE/output" 2>&1; then fail 'failed revoke reported success'; fi
    [[ -s $CNE_STATE/peers && -f $CNE_STATE/clients/phone.conf ]] || fail 'failed revoke removed local device'
    contains "$CNE_STATE/output" '撤销未完成'
    REMOVE_RESULT=success
    printf '%s\n' phone y | cne_client_remove >> "$CNE_STATE/output" 2>&1 || fail 'failed revoke could not retry'
    printf 'PASS: failed revocation retains usable configuration and permits retry\n'
)

test_remove_local_variants() (
    setup "remove-local-$1"
    case $1 in
        missing) rm "$CNE_STATE/clients/phone.conf";;
        pending) mv "$CNE_STATE/clients/phone.conf" "$CNE_STATE/clients/phone.conf.pending";;
        historical) printf 'previous revoked configuration\n' > "$CNE_STATE/clients/phone.conf.revoked";;
    esac
    printf '%s\n' phone y | cne_client_remove > "$CNE_STATE/output" 2>&1 || fail 'local variation blocked revoke'
    [[ ! -s $CNE_STATE/peers ]] || fail 'local variation left peer registered'
    if [[ $1 != missing ]]; then
        cne_client_remove <<<phone >> "$CNE_STATE/output" 2>&1 || fail 'local variation could not retry'
    fi
    if [[ $1 == historical ]]; then
        local archive
        archive=$(find "$CNE_STATE/clients" -name 'phone.conf.revoked.archive.*' -print)
        [[ -n $archive ]] || fail 'older revoked file was discarded'
        contains "$archive" 'previous revoked configuration'
        contains "$CNE_STATE/clients/phone.conf.revoked" "$PRIVATE"
    fi
    printf 'PASS: %s local profile supports revocation without losing original history\n' "$1"
)

test_export_verified wireguard
test_export_verified awg2
test_export_offline
for kind in key endpoint revoked absent protocol parameters ipv4 ipv6 dns routes psk duplicate-field duplicate-section hook; do test_export_stale "$kind"; done
test_export_explicit_fallback
test_picker
test_numeric_picker
test_remove success
test_remove lost
test_remove_already_absent
for kind in typo different-peer different-server renamed; do test_remove_rejected "$kind"; done
test_remove_failure
for variant in missing pending historical; do test_remove_local_variants "$variant"; done
printf 'Client lifecycle checks passed. No server connections or package changes occurred.\n'
