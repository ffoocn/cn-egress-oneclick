#!/usr/bin/env bash
# Real certificates/archives with isolated files and service mocks. No SSH or deployment.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cne-node-maintenance.XXXXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
node="$work/node"
mkdir -p "$node" "$work/extract"
export CNE_NODE_LIBRARY=1
source "$repo/shell/node.sh"
# Redirect literal node paths and dynamic owned-file paths into a private fixture.
for function_name in $(compgen -A function cne_); do
    definitions=$(declare -f "$function_name")
    # Protect nested /usr/lib occurrences while mapping literal /lib paths.
    definitions=${definitions//\/usr\/lib\//__CNE_USR_LIB__/}
    definitions=${definitions//\/usr\/local\/lib\//__CNE_USR_LOCAL_LIB__/}
    for prefix in lib root etc usr opt run proc; do definitions=${definitions//\/$prefix\//$node\/$prefix\/}; done
    definitions=${definitions//__CNE_USR_LIB__\//$node\/usr\/lib\/}
    definitions=${definitions//__CNE_USR_LOCAL_LIB__\//$node\/usr\/local\/lib\/}
    # Staging paths are already private and must not be redirected as host paths.
    for variable_name in temporary stage destination; do
        for prefix in root etc usr opt run proc lib; do
            fragment='$'"$variable_name$node/$prefix/"; replacement='$'"$variable_name/$prefix/"
            definitions=${definitions//$fragment/$replacement}
            fragment='$'"$variable_name\"$node/$prefix/"; replacement='$'"$variable_name\"/$prefix/"
            definitions=${definitions//$fragment/$replacement}
        done
    done
    fragment='"/$file"'; replacement='"'"$node"'/$file"'
    definitions=${definitions//$fragment/$replacement}
    fragment=' /$file'; replacement=" $node"'/$file'
    definitions=${definitions//$fragment/$replacement}
    fragment='"/${file%/\*}"'; replacement='"'"$node"'/${file%/*}"'
    definitions=${definitions//$fragment/$replacement}
    fragment='"/$path"'; replacement='"'"$node"'/$path"'
    definitions=${definitions//$fragment/$replacement}
    eval "$definitions"
done
passed=0
ok() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

# Supported nodes use GNU stat. Metadata ownership is simulated, while mode,
# size and hardlink count are measured from the actual fixture on either OS.
bad_owner=''
stat() {
    [[ $1 == -c ]] || return 1
    case $2 in
        %u) if [[ $3 == "$bad_owner" ]]; then printf '1000\n'; else printf '0\n'; fi;;
        %s) wc -c < "$3" | tr -d ' ';;
        %a) if [[ $(uname -s) == Darwin ]]; then command stat -f %Lp "$3"; else command stat -c %a "$3"; fi;;
        %h) if [[ $(uname -s) == Darwin ]]; then command stat -f %l "$3"; else command stat -c %h "$3"; fi;;
        *) return 1;;
    esac
}
cne_n_has() { case $1 in ip|nft|iptables) return 1;; *) command -v "$1" >/dev/null 2>&1;; esac; }
cne_n_wan() { printf '%s\n' "${wan_fixture:-eth0}"; }
service_failure=''
systemctl() {
    local action=$1 unit=${*: -1} state
    case $action in
        show)
            if [[ -f $node/etc/systemd/system/$unit ]]; then printf 'FragmentPath=%s/etc/systemd/system/%s\n' "$node" "$unit"; else printf 'FragmentPath=\n'; fi
            printf 'DropInPaths=\n';;
        is-active)
            state=inactive; [[ ! -f $work/states/$unit.active ]] || state=$(cat "$work/states/$unit.active")
            [[ ${2:-} == --quiet ]] || printf '%s\n' "$state"
            [[ $state == active ]];;
        is-enabled)
            state=not-found; [[ ! -f $work/states/$unit.enabled ]] || state=$(cat "$work/states/$unit.enabled")
            printf '%s\n' "$state"; [[ $state == enabled || $state == enabled-runtime ]];;
        *)
            printf '%s\n' "$*" >> "$work/services.log"
            [[ $* != "$service_failure" ]] || return 1
            case $action in
                start) printf 'active\n' > "$work/states/$unit.active";;
                stop) printf 'inactive\n' > "$work/states/$unit.active";;
                enable) if [[ ${2:-} == --runtime ]]; then state=enabled-runtime; else state=enabled; fi; printf '%s\n' "$state" > "$work/states/$unit.enabled";;
                disable) printf 'disabled\n' > "$work/states/$unit.enabled";;
            esac;;
    esac
}
if [[ $(uname -s) == Darwin && -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then
    openssl() { /opt/homebrew/opt/openssl@3/bin/openssl "$@"; }
fi
source "$repo/shell/render.sh"
cne_render_pki "$work/old-pki" 192.0.2.20
cne_render_pki "$work/new-pki" 192.0.2.20
cne_render_pki "$work/wrong-host-pki" 192.0.2.99
reset_node() {
    local role=$1 unit
    rm -rf "$node" "$work/states"
    mkdir -p "$node/etc/cn-egress" "$node/etc/cn-egress-wss" "$node/etc/wireguard" "$node/etc/systemd/system" "$work/states"
    printf '0123456789abcdef0123456789abcdef\n' > "$node/etc/machine-id"
    printf '%s\n' "$role" > "$node/etc/cn-egress/role"
    printf '%s\n' "$role" > "$node/etc/cn-egress-wss/role"
    printf 'deployment-old\n' > "$node/etc/cn-egress/deployment-id"
    chmod 600 "$node/etc/cn-egress/deployment-id"
    printf '192.0.2.20\n' > "$node/etc/cn-egress-wss/sh-host"
    printf '443\n' > "$node/etc/cn-egress-wss/port"
    cp "$work/old-pki/ca.crt" "$node/etc/cn-egress-wss/ca.crt"
    cp "$work/old-pki/$role.crt" "$node/etc/cn-egress-wss/node.crt"
    cp "$work/old-pki/$role.key" "$node/etc/cn-egress-wss/node.key"
    chmod 640 "$node/etc/cn-egress-wss/"{ca.crt,node.crt,node.key}
    printf '[Interface]\nPrivateKey = unchanged-device-key\n' > "$node/etc/wireguard/cne-cn.conf"
    printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-net start %s\n' "$node" "$role" > "$node/etc/systemd/system/cn-egress.service"
    printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
    if [[ $role == exit ]]; then
        rm "$node/etc/wireguard/cne-cn.conf"
        printf '[Interface]\nPrivateKey = unchanged-device-key\n' > "$node/etc/wireguard/cne-exit.conf"
        printf 'eth0\n' > "$node/etc/cn-egress/wan-interface"
        printf '[Service]\nExecStart=%s/usr/sbin/dnsmasq --keep-in-foreground --conf-file=%s/etc/cn-egress/dnsmasq.conf\n' "$node" "$node" > "$node/etc/systemd/system/cn-egress-dns.service"
    fi
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do
        printf 'inactive\n' > "$work/states/$unit.active"
        printf 'disabled\n' > "$work/states/$unit.enabled"
    done
    printf 'active\n' > "$work/states/cn-egress.service.active"
    printf 'active\n' > "$work/states/cn-egress-obfs.service.active"
    printf 'enabled\n' > "$work/states/cn-egress.service.enabled"
    printf 'enabled-runtime\n' > "$work/states/cn-egress-obfs.service.enabled"
    : > "$work/services.log"
    service_failure=''; wan_fixture=eth0
}
make_cert_archive() {
    local role=$1 pki=$2 archive=$3 fixture="$work/cert-stage"
    rm -rf "$fixture"; mkdir "$fixture"
    cp "$pki/ca.crt" "$fixture/ca.crt"
    cp "$pki/$role.crt" "$fixture/node.crt"
    cp "$pki/$role.key" "$fixture/node.key"
    tar -czf "$archive" -C "$fixture" ca.crt node.crt node.key
    chmod 600 "$archive"
}
decode_base64() { if [[ $(uname -s) == Darwin ]]; then base64 -D; else base64 -d; fi; }
reset_node hk
before_info=$(cne_n_maintenance_info hk) || fail info
[[ $before_info == *'deployment=deployment-old'* && $before_info == *'cert_due=0'* && $before_info == *'ca_due=0'* ]] || fail info-fields
before_config=$(printf '%s\n' "$before_info" | sed -n 's/^config_sha256=//p')
before_tls=$(printf '%s\n' "$before_info" | sed -n 's/^tls_sha256=//p')
cp "$work/new-pki/hk.crt" "$node/etc/cn-egress-wss/node.crt"
after_info=$(cne_n_maintenance_info hk) || fail changed-info
[[ $(printf '%s\n' "$after_info" | sed -n 's/^config_sha256=//p') == "$before_config" && $(printf '%s\n' "$after_info" | sed -n 's/^tls_sha256=//p') != "$before_tls" ]] || fail separated-fingerprints
! grep -Eq 'PRIVATE KEY|unchanged-device-key' <<< "$after_info" || fail secret-info
ok 'Read-only maintenance metadata reports separate config/TLS fingerprints without private material'

reset_node hk
archive=$(cne_n_backup) || fail backup
exported=$(cne_n_dispatch backup-export hk "$archive") || fail export
printf '%s\n' "$exported" | decode_base64 > "$work/exported.tar.gz"
cmp -s "$archive" "$work/exported.tar.gz" || fail export-content
chmod 644 "$archive"
! cne_n_backup_export hk "$archive" > "$work/rejected-export" 2>/dev/null || fail exposed-export
[[ ! -s $work/rejected-export ]] || fail export-noise
chmod 600 "$archive"
ok 'Backup export streams exactly a provenance-validated root-private archive'

printf 'deployment-current\n' > "$node/etc/cn-egress/deployment-id"
printf 'new-device-key\n' > "$node/etc/wireguard/cne-cn.conf"
rollback_archive=$(cne_n_backup) || fail rollback-backup
cp "$archive" "$work/upload.tar.gz"; chmod 600 "$work/upload.tar.gz"
cne_n_restore_import hk "$work/upload.tar.gz" "${archive##*/}" deployment-current operation-restore >/dev/null || fail import
[[ $(cat "$node/etc/cn-egress/deployment-id") == operation-restore && $(cat "$node/etc/wireguard/cne-cn.conf") == *'unchanged-device-key'* ]] || fail imported-state
[[ $(cat "$work/states/cn-egress.service.active") == active && $(cat "$work/states/cn-egress-obfs.service.enabled") == enabled-runtime ]] || fail imported-services
cne_n_restore "$rollback_archive" operation-restore >/dev/null 2>&1 || fail undo-import
[[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-current && $(cat "$node/etc/wireguard/cne-cn.conf") == new-device-key ]] || fail undo-import-state
ok 'Manual restore preserves archived service state, commits the operation ID and rolls back with the original snapshot'

: > "$work/services.log"
cp "$archive" "$work/collision-upload.tar.gz"; printf 'extra' >> "$work/collision-upload.tar.gz"; chmod 600 "$work/collision-upload.tar.gz"
! cne_n_restore_import hk "$work/collision-upload.tar.gz" "${archive##*/}" deployment-current operation-collision >/dev/null 2>&1 || fail collision
! cne_n_restore_import hk "$work/upload.tar.gz" "${archive##*/}" deployment-wrong operation-drift >/dev/null 2>&1 || fail drift
printf 'fedcba9876543210fedcba9876543210\n' > "$node/etc/machine-id"
! cne_n_restore_import hk "$work/upload.tar.gz" "${archive##*/}" deployment-current operation-foreign >/dev/null 2>&1 || fail foreign
[[ ! -s $work/services.log && $(cat "$node/etc/cn-egress/deployment-id") == deployment-current ]] || fail rejected-mutated
ok 'Restore rejects archive collisions, changed deployments and a different machine before service mutation'

reset_node exit
exit_archive=$(cne_n_backup) || fail exit-backup
cp "$exit_archive" "$work/exit-upload.tar.gz"; chmod 600 "$work/exit-upload.tar.gz"
wan_fixture=eth1
! cne_n_restore_import exit "$work/exit-upload.tar.gz" "${exit_archive##*/}" deployment-old operation-wan >/dev/null 2>&1 || fail changed-wan
[[ ! -s $work/services.log && $(cat "$node/etc/cn-egress/deployment-id") == deployment-old ]] || fail wan-mutated
reset_node hk
! cne_n_restore_import hk "$work/exit-upload.tar.gz" "${exit_archive##*/}" deployment-old operation-role >/dev/null 2>&1 || fail wrong-role
[[ ! -s $work/services.log ]] || fail role-mutated
ok 'Manual restore rejects another role or an exit snapshot for a different current WAN interface'

reset_node hk
rollback_archive=$(cne_n_backup) || fail partial-backup
cp "$rollback_archive" "$work/partial-upload.tar.gz"; chmod 600 "$work/partial-upload.tar.gz"
service_failure='start cn-egress.service'
! cne_n_restore_import hk "$work/partial-upload.tar.gz" "${rollback_archive##*/}" deployment-old operation-partial >/dev/null 2>&1 || fail interrupted-import
[[ $(cat "$node/etc/cn-egress/deployment-id") == operation-partial ]] || fail partial-marker
service_failure=''
cne_n_restore "$rollback_archive" operation-partial >/dev/null 2>&1 || fail partial-recovery
[[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-old && $(cat "$work/states/cn-egress.service.active") == active ]] || fail partial-recovery-state
ok 'A partially applied historical restore retains the transaction identity for guarded recovery'

reset_node hk
complete_archive=$(cne_n_backup) || fail absent-source-backup
cp "$complete_archive" "$work/complete-upload.tar.gz"; chmod 600 "$work/complete-upload.tar.gz"
cne_n_remove_files || fail make-absent
[[ $(cne_n_maintenance_info hk) == *'state=absent'* ]] || fail absent-info
: > "$work/services.log"
cne_n_restore_import hk "$work/complete-upload.tar.gz" "${complete_archive##*/}" none operation-after-uninstall >/dev/null || fail absent-import
[[ $(cat "$node/etc/cn-egress/role") == hk && $(cat "$node/etc/cn-egress/deployment-id") == operation-after-uninstall ]] || fail absent-import-state
cne_n_remove_files || fail empty-source
empty_archive=$(cne_n_backup) || fail empty-backup
cp "$empty_archive" "$work/empty-upload.tar.gz"; chmod 600 "$work/empty-upload.tar.gz"
reset_node hk
! cne_n_restore_import hk "$work/empty-upload.tar.gz" "${empty_archive##*/}" deployment-old operation-empty >/dev/null 2>&1 || fail empty-target
[[ ! -s $work/services.log ]] || fail empty-target-mutated
cne_n_remove_files || fail unknown-source
printf 'unfinished\n' > "$node/etc/cn-egress/version"
! cne_n_restore_import hk "$work/complete-upload.tar.gz" "${complete_archive##*/}" none operation-unknown >/dev/null 2>&1 || fail unknown-current
[[ ! -s $work/services.log ]] || fail unknown-current-mutated
ok 'A complete same-machine backup restores an uninstalled node, while empty targets and unknown partial current deployments are rejected'
reset_node hk
rm "$node/etc/systemd/system/cn-egress-obfs.service"
! cne_n_restore_import hk "$work/complete-upload.tar.gz" "${complete_archive##*/}" deployment-old operation-known-partial >/dev/null 2>&1 || fail known-partial-current
[[ ! -s $work/services.log && $(cat "$node/etc/cn-egress/deployment-id") == deployment-old ]] || fail known-partial-mutated
ok 'A matching role marker alone cannot authorize maintenance of a partial deployment with missing services'

reset_node hk
make_cert_archive hk "$work/new-pki" "$work/certificate.tar.gz"
before_config=$(cne_n_config_fingerprint config)
before_tls=$(cne_n_config_fingerprint tls)
cp "$node/etc/wireguard/cne-cn.conf" "$work/wg-before"
cne_n_dispatch certificate-apply hk "$work/certificate.tar.gz" deployment-old operation-cert >/dev/null || fail certificate-apply
[[ $(cat "$node/etc/cn-egress/deployment-id") == operation-cert && $(cne_n_config_fingerprint config) == "$before_config" && $(cne_n_config_fingerprint tls) != "$before_tls" ]] || fail certificate-fingerprints
cmp -s "$node/etc/wireguard/cne-cn.conf" "$work/wg-before" || fail wg-changed
[[ $(cat "$work/states/cn-egress-obfs.service.active") == active && $(cat "$work/states/cn-egress-obfs.service.enabled") == enabled-runtime ]] || fail cert-state
! grep -Eq '(start|stop|enable|disable) cn-egress\.(service)|cn-egress-(dns|users)\.service' "$work/services.log" || fail cert-touched-other-service
ok 'Certificate rotation changes TLS only, restarts only active transport and preserves device configuration and enablement'

reset_node hk
printf 'inactive\n' > "$work/states/cn-egress-obfs.service.active"
printf 'disabled\n' > "$work/states/cn-egress-obfs.service.enabled"
cne_n_certificate_apply hk "$work/certificate.tar.gz" deployment-old operation-stopped >/dev/null || fail stopped-cert
[[ $(cat "$work/states/cn-egress-obfs.service.active") == inactive && $(cat "$work/states/cn-egress-obfs.service.enabled") == disabled ]] || fail stopped-state
! grep -Eq '(start|stop|enable|disable)' "$work/services.log" || fail stopped-service-started
ok 'Certificate rotation keeps a stopped and disabled transport stopped and disabled'

reset_node sh
make_cert_archive sh "$work/new-pki" "$work/certificate-sh.tar.gz"
make_cert_archive sh "$work/wrong-host-pki" "$work/certificate-wrong-host.tar.gz"
make_cert_archive hk "$work/new-pki" "$work/certificate-wrong-role.tar.gz"
! cne_n_certificate_apply sh "$work/certificate-wrong-host.tar.gz" deployment-old operation-san >/dev/null 2>&1 || fail wrong-san
! cne_n_certificate_apply sh "$work/certificate-wrong-role.tar.gz" deployment-old operation-role-cert >/dev/null 2>&1 || fail wrong-cert-role
! cne_n_certificate_apply sh "$work/certificate-sh.tar.gz" deployment-other operation-cert-drift >/dev/null 2>&1 || fail cert-drift
[[ ! -s $work/services.log && $(cat "$node/etc/cn-egress/deployment-id") == deployment-old ]] || fail rejected-cert-mutated
cne_n_certificate_apply sh "$work/certificate-sh.tar.gz" deployment-old operation-sh-cert >/dev/null || fail valid-sh-cert
ok 'Relay certificate rotation validates the saved host SAN, certificate role and current deployment before mutation'

reset_node hk
make_cert_archive hk "$work/new-pki" "$work/cert-good.tar.gz"
cp "$work/new-pki/sh.key" "$work/cert-stage/node.key"
tar -czf "$work/cert-mismatch.tar.gz" -C "$work/cert-stage" ca.crt node.crt node.key
chmod 600 "$work/cert-mismatch.tar.gz"
cp "$work/new-pki/ca.key" "$work/cert-stage/ca.key"
tar -czf "$work/cert-extra.tar.gz" -C "$work/cert-stage" ca.crt node.crt node.key ca.key
chmod 600 "$work/cert-extra.tar.gz"
ln -s "$work/cert-good.tar.gz" "$work/cert-link.tar.gz"
for candidate in "$work/cert-mismatch.tar.gz" "$work/cert-extra.tar.gz" "$work/cert-link.tar.gz"; do
    ! cne_n_certificate_apply hk "$candidate" deployment-old operation-invalid >/dev/null 2>&1 || fail invalid-cert-accepted
done
[[ ! -s $work/services.log && $(cat "$node/etc/cn-egress/deployment-id") == deployment-old ]] || fail invalid-cert-mutated
ok 'Mismatched private keys, CA private-key uploads, extra files and linked archives are rejected before mutation'

make_cert_archive hk "$work/new-pki" "$work/cert-valid.tar.gz"
openssl req -new -sha256 -key "$work/new-pki/hk.key" -out "$work/custom.csr" -subj '/CN=cn-egress-hk' 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' > "$work/custom.ext"
openssl x509 -req -sha256 -days 365 -in "$work/custom.csr" -CA "$work/new-pki/ca.crt" -CAkey "$work/new-pki/ca.key" -set_serial 0x1122 -extfile "$work/custom.ext" -out "$work/cert-stage/node.crt" 2>/dev/null
tar -czf "$work/cert-wrong-eku.tar.gz" -C "$work/cert-stage" ca.crt node.crt node.key; chmod 600 "$work/cert-wrong-eku.tar.gz"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > "$work/custom.ext"
openssl x509 -req -sha256 -days 1 -in "$work/custom.csr" -CA "$work/new-pki/ca.crt" -CAkey "$work/new-pki/ca.key" -set_serial 0x1123 -extfile "$work/custom.ext" -out "$work/cert-stage/node.crt" 2>/dev/null
tar -czf "$work/cert-short-lived.tar.gz" -C "$work/cert-stage" ca.crt node.crt node.key; chmod 600 "$work/cert-short-lived.tar.gz"
cp "$work/new-pki/hk.crt" "$work/cert-stage/node.crt"
cp "$work/old-pki/ca.crt" "$work/cert-stage/ca.crt"
tar -czf "$work/cert-wrong-ca.tar.gz" -C "$work/cert-stage" ca.crt node.crt node.key; chmod 600 "$work/cert-wrong-ca.tar.gz"
for candidate in "$work/cert-wrong-eku.tar.gz" "$work/cert-short-lived.tar.gz" "$work/cert-wrong-ca.tar.gz"; do
    ! cne_n_certificate_apply hk "$candidate" deployment-old operation-invalid-chain >/dev/null 2>&1 || fail invalid-chain-accepted
done
[[ ! -s $work/services.log && $(cat "$node/etc/cn-egress/deployment-id") == deployment-old ]] || fail invalid-chain-mutated
ok 'A correct subject is insufficient: wrong TLS usage, near expiry and an unrelated CA chain are rejected before mutation'
reset_node hk
(
    fallback_name=tunl0
    fallback_details='2: tunl0@NONE: <NOARP> mtu 1480 qdisc noop state DOWN mode DEFAULT group default\    link/ipip 0.0.0.0 brd 0.0.0.0\    ipip any remote any local any ttl inherit nopmtudisc'
    fallback_addresses=''; fallback_routes=''
    cne_n_has() { case $1 in ip) return 0;; nft|iptables) return 1;; *) command -v "$1" >/dev/null 2>&1;; esac; }
    ip() {
        case "$*" in
            'netns list') printf 'cn-egress-relay\n';;
            '-n cn-egress-relay -o link show') printf '1: lo: <LOOPBACK> mtu 65536\n2: %s@NONE: <NOARP> mtu 1480\n' "$fallback_name";;
            '-n cn-egress-relay -o -d link show dev tunl0') printf '%s\n' "$fallback_details";;
            '-n cn-egress-relay -o address show dev tunl0') printf '%s' "$fallback_addresses";;
            '-n cn-egress-relay -4 route show table all dev tunl0'|'-n cn-egress-relay -6 route show table all dev tunl0') printf '%s' "$fallback_routes";;
            *) return 1;;
        esac
    }
    cne_n_scope_check || exit 1
    original_details=$fallback_details
    fallback_details=${fallback_details//<NOARP>/<NOARP,UP>}
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    fallback_details=$original_details; fallback_addresses='2: tunl0 inet 10.1.2.3/24'
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    fallback_addresses=''; fallback_routes='default dev tunl0'
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    fallback_routes=''; fallback_details=${original_details//remote any/remote 192.0.2.9}
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    fallback_details=${original_details//ipip/dummy}
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    fallback_details=$original_details; fallback_name=tunl1
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
) || fail kernel-fallback-scope
ok 'Only exact unused kernel fallback interfaces are accepted; active, addressed, routed, endpoint-configured, wrong-kind and arbitrary same-prefix devices remain protected'
printf '%s node maintenance tests passed.\n' "$passed"
