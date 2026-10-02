#!/usr/bin/env bash
# Isolated backend tests. No root, real service operations, packages or SSH.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cne-node-test.XXXXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
export CNE_NODE_LIBRARY=1
source "$repo/shell/node.sh"
passed=0
ok() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

# These assertions reject input before any filesystem or service mutation.
cne_n_payload_allowed hk etc/wireguard/cne-users.conf || fail allowlist
! cne_n_payload_allowed exit etc/wireguard/cne-users.conf || fail wrong-role
! cne_n_payload_allowed hk ../etc/passwd || fail traversal
! cne_n_payload_allowed hk etc/ssh/sshd_config || fail unrelated
! cne_n_payload_allowed hk etc/cn-egress/oneclick-node.py || fail python-payload
ok 'Payload allowlist excludes traversal, unrelated files and Python'
mkdir -p "$work/safe"
ln -s "$work/safe" "$work/link"
! cne_n_safe_path "$work/link/config" 2>/dev/null || fail symlink
cne_n_safe_path "$work/safe/config" || fail safe-path
ok 'Symlink ancestors are rejected'
(
    cne_n_exists() { return 0; }
    cne_n_existing_role() { printf 'unknown\n'; }
    cne_n_safe_path() { :; }
    cne_n_has() { return 1; }
    cne_n_forwarding() { printf '0\n'; }
    result=$(cne_n_inspect)
    [[ $result == *'state=present'* && $result == *'role=unknown'* ]] || exit 1
) || fail partial-inspect
ok 'Incomplete legacy deployments remain inspectable'
(
    cne_n_os_check() { :; }; cne_n_scope_check() { :; }; cne_n_ports_check() { :; }; cne_n_routes_check() { :; }
    cne_n_exists() { return 0; }; cne_n_forwarding() { printf '0\n'; }
    ! cne_n_preflight exit fresh 51820 443 >/dev/null 2>&1 || exit 1
    cne_n_preflight exit replace 51820 443 >/dev/null || exit 1
) || fail replace-preflight
ok 'Replacement accepts partial installations and defers forwarding confirmation'
(
    cne_n_has() { [[ $1 == ip ]]; }
    ip() {
        if [[ $1 == -4 ]]; then printf '%s\n' 'default via 192.0.2.1 dev eth0' '10.0.0.0/8 dev eth1'; else :; fi
    }
    ! cne_n_routes_check fresh >/dev/null 2>&1 || exit 1
) || fail broad-route
ok 'IPv4 supernet overlap is rejected'
(
    cne_n_has() { [[ $1 == ip ]]; }
    ip() {
        if [[ $1 == -4 ]]; then printf '%s\n' 'default via 192.0.2.1 dev eth0' '10.77.10.0/24 dev cne-exit'; else :; fi
    }
    cne_n_routes_check replace || exit 1
    ! cne_n_routes_check fresh >/dev/null 2>&1 || exit 1
) || fail own-route
ok 'Replacement tolerates only owned existing VPN routes'
(
    cne_n_has() { [[ $1 == ss ]]; }
    ss() { printf 'tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=99,fd=1))\n'; }
    cne_n_port_owned() { return 1; }
    ! cne_n_ports_check sh replace 51820 443 >/dev/null 2>&1 || exit 1
    cne_n_ports_check sh fresh 51820 8443 || exit 1
) || fail business-port
ok 'Business port conflicts are rejected even during replacement'

# Create real tarballs and extract only into this private test directory.
fixture="$work/fixture"
mkdir -p "$fixture"
files='etc/cn-egress/firewall.nft etc/cn-egress-wss/role etc/cn-egress-wss/node.crt etc/cn-egress-wss/node.key etc/cn-egress-wss/ca.crt etc/cn-egress-wss/port etc/systemd/system/cn-egress.service etc/systemd/system/cn-egress-obfs.service usr/local/sbin/cn-egress-net usr/local/sbin/cn-egress-obfs opt/cn-egress/wstunnel-11.0.0/wstunnel etc/wireguard/cne-users.conf etc/wireguard/cne-cn.conf'
for file in $files; do mkdir -p "$fixture/${file%/*}"; printf 'fixture\n' > "$fixture/$file"; done
printf 'hk\n' > "$fixture/etc/cn-egress-wss/role"
printf '443\n' > "$fixture/etc/cn-egress-wss/port"
printf '[Interface]\nAddress = 10.77.10.1/24, fd77:77:10::1/64\nTable = off\n' > "$fixture/etc/wireguard/cne-users.conf"
printf '[Interface]\nAddress = 10.77.20.1/30, fd77:77:20::1/64\nTable = off\n[Peer]\nEndpoint = 127.0.0.1:51831\n' > "$fixture/etc/wireguard/cne-cn.conf"
printf '%s\n' $files > "$work/files.txt"
tar -czf "$work/valid.tar.gz" -C "$fixture" -T "$work/files.txt"
# Absolute destination paths are never written here. macOS /etc and /var are
# symlinks; Linux target checks are covered separately above.
cne_n_safe_path() { :; }
# stat on macOS uses -f; the backend intentionally targets GNU/Linux.
if [[ $(uname -s) != Linux ]]; then stat() { [[ $1 == -c && $2 == %s ]] || return 1; wc -c < "$3" | tr -d ' '; }; fi
mkdir "$work/extract"
cne_n_validate_archive hk "$work/valid.tar.gz" "$work/extract" || fail valid-archive
ok 'A complete real role archive validates and extracts'
mkdir "$work/duplicate"
tar -czf "$work/duplicate.tar.gz" -C "$fixture" etc/cn-egress-wss/role etc/cn-egress-wss/role
! cne_n_validate_archive hk "$work/duplicate.tar.gz" "$work/duplicate" >/dev/null 2>&1 || fail duplicate-archive
[[ -z $(ls -A "$work/duplicate") ]] || fail duplicate-extracted
ok 'Duplicate archive members are rejected before extraction'
mkdir "$work/link-extract"
rm "$fixture/etc/cn-egress-wss/node.key"
ln -s /etc/passwd "$fixture/etc/cn-egress-wss/node.key"
tar -czf "$work/link.tar.gz" -C "$fixture" etc/cn-egress-wss/node.key
! cne_n_validate_archive hk "$work/link.tar.gz" "$work/link-extract" >/dev/null 2>&1 || fail link-archive
[[ -z $(ls -A "$work/link-extract") ]] || fail link-extracted
ok 'Archive symlinks are rejected before extraction'
rm "$fixture/etc/cn-egress-wss/node.key"
printf 'fixture\n' > "$fixture/etc/cn-egress-wss/node.key"
printf 'PostUp = ip route replace default dev cne-users\n' >> "$fixture/etc/wireguard/cne-users.conf"
tar -czf "$work/hook.tar.gz" -C "$fixture" -T "$work/files.txt"
mkdir "$work/hook-extract"
! cne_n_validate_archive hk "$work/hook.tar.gz" "$work/hook-extract" >/dev/null 2>&1 || fail route-hook
ok 'WireGuard system-routing hooks are rejected'
(
    # Force failure after backup and prove the transaction rolls back; each mutator
    # is replaced by a test function and the real staging directory lives in work.
    cne_n_os_check() { :; }; cne_n_scope_check() { :; }; cne_n_preflight() { :; }
    cne_n_validate_archive() { mkdir -p "$3/etc/cn-egress-wss" "$3/etc/wireguard"; printf '443\n' > "$3/etc/cn-egress-wss/port"; printf 'ListenPort = 51820\n' > "$3/etc/wireguard/cne-users.conf"; }
    cne_n_backup() { printf '%s\n' "$work/snapshot.tar.gz"; }
    cne_n_route_snapshot() { printf 'baseline\n'; }
    cne_n_install_apply() { printf 'apply\n' >> "$work/transaction.log"; return 1; }
    cne_n_rollback() { printf 'rollback:%s\n' "$1" >> "$work/transaction.log"; }
    mktemp() { command mktemp -d "$work/install.XXXXXXXX"; }
    ! cne_n_install hk replace "$work/valid.tar.gz" deployment-test || exit 1
    [[ $(cat "$work/transaction.log") == $'apply\nrollback:'"$work/snapshot.tar.gz" ]] || exit 1
) || fail rollback
ok 'Installation failure invokes rollback using its pre-change backup'
(
    clientroot="$work/client-case"
    mkdir -p "$clientroot/etc/wireguard" "$clientroot/etc/cn-egress"
    config="$clientroot/etc/wireguard/cne-users.conf"
    registry="$clientroot/etc/cn-egress/clients.tsv"
    server=$(printf 'A%042d=' 0); old_public=$(printf 'D%042d=' 0); new_public=$(printf 'B%042d=' 0)
    CNE_CLIENT_PSK=$(printf 'C%042d=' 0)
    printf '[Interface]\nPrivateKey = fixture\nTable = off\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.77.10.10/32, fd77:77:10::10/128\n' "$old_public" > "$config"
    printf 'old\t10\t%s\n' "$old_public" > "$registry"
    cp "$config" "$work/config-before"
    cp "$registry" "$work/registry-before"
    # Redirect only the client functions' fixed paths into the isolated fixture.
    definitions=$(declare -f cne_n_client_add cne_n_client_remove cne_n_client_list)
    definitions=${definitions//\/etc\/wireguard/$clientroot\/etc\/wireguard}
    definitions=${definitions//\/etc\/cn-egress/$clientroot\/etc\/cn-egress}
    eval "$definitions"
    cne_n_require_role() { :; }
    cne_n_server_public() { printf '%s\n' "$server"; }
    cne_n_client_sync() { cp "$config" "$work/live-config"; }
    mv() { [[ ${*: -1} != "$registry" ]] || return 1; command mv "$@"; }
    ! cne_n_client_add hk new 11 "$new_public" >/dev/null 2>&1 || exit 1
    cmp -s "$config" "$work/config-before" && cmp -s "$work/live-config" "$work/config-before" && cmp -s "$registry" "$work/registry-before" || exit 1
    ! cne_n_client_remove hk old >/dev/null 2>&1 || exit 1
    cmp -s "$config" "$work/config-before" && cmp -s "$work/live-config" "$work/config-before" && cmp -s "$registry" "$work/registry-before" || exit 1
) || fail client-metadata-rollback
ok 'Client registry failure restores both saved configuration and live peers'
printf '%s backend tests passed.\n' "$passed"
