#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source shell/controller.sh
source shell/render.sh
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
umask 077
key_private=$(openssl rand -base64 32)
key_public=$(openssl rand -base64 32)
key_server=$(openssl rand -base64 32)
key_psk=$(openssl rand -base64 32)
cne_require_config() { :; }
cne_authenticate() { :; }
cne_prompt() { CNE_ANSWER=phone; }
CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
wg() {
    case $1 in
        genkey) printf 'generated\n' >> "$CNE_STATE/keygen-count"; printf '%s\n' "$key_private";;
        pubkey) local input; read -r input; [[ $input == "$key_private" ]]; printf '%s\n' "$key_public";;
        genpsk) printf '%s\n' "$key_psk";;
        *) return 1;;
    esac
}
cne_remote() {
    local index=$1 action=$2
    shift 2
    case $action in
        inspect) printf 'user_port=55123\n';;
        server-public) printf '%s\n' "$key_server";;
        client-list) [[ ! -f $CNE_STATE/peers ]] || cat "$CNE_STATE/peers";;
        client-add)
            printf 'attempt\n' >> "$CNE_STATE/add-count"
            [[ $CNE_CLIENT_PSK == "$key_psk" ]]
            if [[ ${test_fail_before:-0} == 1 ]]; then return 1; fi
            printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$CNE_STATE/peers"
            [[ ${test_reply_lost:-0} != 1 ]];;
        *) return 1;;
    esac
}
CNE_STATE=$sandbox/retry
mkdir -p "$CNE_STATE/clients"
test_fail_before=1
if cne_client_add > "$sandbox/output" 2>&1; then exit 1; fi
[[ -f $CNE_STATE/clients/phone.conf.pending ]]
test_fail_before=0
cne_client_add > "$sandbox/output"
[[ -f $CNE_STATE/clients/phone.conf ]]
[[ $(wc -l < "$CNE_STATE/keygen-count" | tr -d ' ') == 1 ]]
grep -qx 'Endpoint = 203.0.113.10:55123' "$CNE_STATE/clients/phone.conf"
printf 'PASS: failed add retries the same keys and uses actual server port\n'
CNE_STATE=$sandbox/lost
mkdir -p "$CNE_STATE/clients"
test_reply_lost=1
if cne_client_add > "$sandbox/output" 2>&1; then exit 1; fi
[[ -f $CNE_STATE/peers && -f $CNE_STATE/clients/phone.conf.pending ]]
cne_client_add > "$sandbox/output"
[[ -f $CNE_STATE/clients/phone.conf ]]
[[ $(wc -l < "$CNE_STATE/add-count" | tr -d ' ') == 1 ]]
printf 'PASS: lost SSH reply recovers the saved matching client profile\n'
CNE_STATE=$sandbox/changed
mkdir -p "$CNE_STATE/clients"
test_reply_lost=0; test_fail_before=1
if cne_client_add > "$sandbox/output" 2>&1; then exit 1; fi
key_server=$(openssl rand -base64 32)
if cne_client_add > "$sandbox/output" 2>&1; then exit 1; fi
[[ -f $CNE_STATE/clients/phone.conf.pending && ! -f $CNE_STATE/clients/phone.conf ]]
[[ $(wc -l < "$CNE_STATE/add-count" | tr -d ' ') == 1 ]]
printf 'PASS: pending client material is not reused for another deployment\n'
