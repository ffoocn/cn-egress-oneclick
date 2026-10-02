#!/usr/bin/env bash
# Real setup defaults distinguish local execution from the external endpoint.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-local-address.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check_role() (
    local role=$1 address=$2 expected=$3
    source "$ROOT/shell/controller.sh"
    CNE_STATE=$WORK/role-$role-${address//./-}; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/history"
    ADDRESS_TRACE=$CNE_STATE/addresses
    FIXTURE_SOURCE=$address
    ip() { [[ $* == '-4 route get 1.1.1.1' ]] || fail 'unexpected network query'; printf '1.1.1.1 dev eth0 src %s\n' "$FIXTURE_SOURCE"; }
    id() { [[ $* == -un ]] || fail 'unexpected identity query'; printf 'fixture\n'; }
    ssh() { fail 'setup connected to a node'; }
    curl() { fail 'setup contacted an external IP lookup'; }
    apt-get() { fail 'setup installed dependencies'; }
    sudo() { fail 'setup requested privilege'; }
    cne_prompt() {
        case $1 in
            *连接方式*) if [[ $idx == "$role" ]]; then CNE_ANSWER=2; else CNE_ANSWER=1; fi;;
            *IPv4*)
                printf '%s\t%s\n' "$idx" "${2:-}" >> "$ADDRESS_TRACE"
                if [[ $idx == "$role" ]]; then CNE_ANSWER=${2:-8.8.4.4}
                elif [[ $idx == 0 ]]; then CNE_ANSWER=203.0.113.10
                elif [[ $idx == 1 ]]; then CNE_ANSWER=198.51.100.20
                else CNE_ANSWER=192.0.2.30; fi;;
            *SSH*用户*) [[ $idx != "$role" ]] || fail 'local node requested SSH user'; CNE_ANSWER=root;;
            *SSH*端口*) [[ $idx != "$role" ]] || fail 'local node requested SSH port'; CNE_ANSWER=22;;
            *SSH*私钥*) [[ $idx != "$role" ]] || fail 'local node requested SSH key'; CNE_ANSWER=-;;
            *客户端*端口*) CNE_ANSWER=51820;;
            *TLS*端口*) CNE_ANSWER=443;;
            *) fail "unexpected setup prompt: $1";;
        esac
    }
    cne_setup > "$CNE_STATE/output" 2>&1 || { cat "$CNE_STATE/output" >&2; fail 'setup failed'; }
    [[ $(awk -F'\t' -v idx="$role" '$1==idx{print $2}' "$ADDRESS_TRACE") == "$expected" ]] || fail 'incorrect local endpoint default'
    [[ ${CNE_CONNECTIONS[$role]} == local && ${CNE_IDENTITIES[$role]} == - ]] && cne_configured || fail 'local configuration was not published'
    if [[ $role == 0 ]]; then grep -Fq '手机和电脑连接香港入口' "$CNE_STATE/output" || fail 'local HK external address purpose missing'
    elif [[ $role == 1 ]]; then grep -Fq '其他节点连接大陆中转' "$CNE_STATE/output" || fail 'relay address incorrectly described as a direct client endpoint'; fi
    if [[ -z $expected ]]; then
        [[ ${CNE_HOSTS[$role]} == 8.8.4.4 ]] || fail 'private source was silently saved as public endpoint'
        grep -Fq '云服务器公网地址或路由器映射地址' "$CNE_STATE/output" || fail 'private address did not explain manual entry'
    fi
    printf 'PASS: local role %s (%s) uses the correct endpoint default without SSH or IP lookup\n' "$role" "$address"
)
check_role 0 8.8.8.8 8.8.8.8
check_role 1 8.8.8.8 8.8.8.8
check_role 0 10.200.10.2 ''
check_role 1 100.100.1.2 ''
check_role 2 10.200.10.2 10.200.10.2
source "$ROOT/shell/controller.sh"
for address in 0.1.2.3 10.1.2.3 100.64.0.1 100.127.255.254 127.0.0.1 169.254.1.2 172.16.0.1 172.31.1.2 192.168.1.1 192.0.2.1 198.18.0.1 198.19.1.1 198.51.100.1 203.0.113.1 224.0.0.1 255.255.255.255; do
    if cne_public_ipv4_candidate "$address"; then fail "non-public candidate accepted: $address"; fi
done
printf 'PASS: non-public, shared, benchmark and reserved source addresses never become public endpoint defaults\n'
