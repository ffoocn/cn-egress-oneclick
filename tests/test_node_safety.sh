#!/usr/bin/env bash
# Real archives and isolated filesystem/service mocks; no SSH, root or deployment.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cne-node-safety.XXXXXXXX")
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
systemctl() {
    local action=$1 unit=${*: -1}
    case $action in
        show)
            if [[ -f $node/etc/systemd/system/$unit ]]; then printf 'FragmentPath=%s/etc/systemd/system/%s\n' "$node" "$unit"; else printf 'FragmentPath=\n'; fi
            printf 'DropInPaths=\n';;
        is-active)
            if [[ $unit == cn-egress.service || $unit == cn-egress-obfs.service ]]; then
                [[ ${2:-} == --quiet ]] || printf 'active\n'
            else [[ ${2:-} == --quiet ]] || printf 'inactive\n'; return 3; fi;;
        is-enabled) if [[ $unit == cn-egress.service ]]; then printf 'enabled\n'; else printf 'disabled\n'; return 1; fi;;
        *) printf '%s\n' "$*" >> "$work/services.log";;
    esac
}
mkdir -p "$node/etc/cn-egress" "$node/etc/cn-egress-wss" "$node/etc/sysctl.d" "$node/etc/systemd/system"
printf '0123456789abcdef0123456789abcdef\n' > "$node/etc/machine-id"
printf 'hk\n' > "$node/etc/cn-egress/role"
printf 'deployment-before\n' > "$node/etc/cn-egress/deployment-id"
printf '50001 50002 50003 50004 50005\n' > "$node/etc/cn-egress-wss/internal-ports"
printf 'operator sysctl content\n' > "$node/etc/sysctl.d/90-cn-egress.conf"
printf 'explicit forwarding retained\n' > "$node/etc/sysctl.d/90-cn-egress-forwarding.conf"
printf '0\n' > "$node/etc/cn-egress/forwarding-before"
printf 'retained setting\n' > "$node/etc/cn-egress/forwarding-settings"
printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-net start hk\n' "$node" > "$node/etc/systemd/system/cn-egress.service"
printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
cp "$node/etc/sysctl.d/90-cn-egress.conf" "$work/operator-before"
cp "$node/etc/systemd/system/cn-egress.service" "$work/unit-before"
! cne_n_all_files | grep -Fxq etc/sysctl.d/90-cn-egress.conf || fail legacy-owned
! cne_n_payload_allowed hk etc/sysctl.d/90-cn-egress.conf || fail legacy-payload
archive=$(cne_n_backup) || fail backup
[[ -f $archive ]] || fail no-backup
[[ $(tar -xOzf "$archive" etc/cn-egress-wss/internal-ports) == '50001 50002 50003 50004 50005' ]] || fail internal-port-backup
! tar -tzf "$archive" | grep -Fxq etc/sysctl.d/90-cn-egress.conf || fail operator-backed-up
! tar -tvzf "$archive" | grep -qv '^-' || fail nonregular-backup
cne_n_remove_files || fail remove
cmp -s "$node/etc/sysctl.d/90-cn-egress.conf" "$work/operator-before" || fail operator-removed
[[ -f $node/etc/sysctl.d/90-cn-egress-forwarding.conf && -f $node/etc/cn-egress/forwarding-before && -f $node/etc/cn-egress/forwarding-settings ]] || fail forwarding-removed
[[ ! -f $node/etc/cn-egress/deployment-id ]] || fail owned-not-removed
cne_n_restore "$archive" >/dev/null 2>&1 || fail restore
[[ $(cat "$node/etc/cn-egress-wss/internal-ports") == '50001 50002 50003 50004 50005' ]] || fail internal-port-restore
cmp -s "$node/etc/sysctl.d/90-cn-egress.conf" "$work/operator-before" || fail operator-restored-over
cmp -s "$node/etc/systemd/system/cn-egress.service" "$work/unit-before" || fail unit-not-restored
[[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-before ]] || fail id-not-restored
grep -Fxq 'start cn-egress.service' "$work/services.log" && grep -Fxq 'start cn-egress-obfs.service' "$work/services.log" || fail services-not-restored
ok 'Real backup, removal and restore preserve operator sysctl and explicit forwarding'

printf 'deployment-new\n' > "$node/etc/cn-egress/deployment-id"
printf 'new-only\n' > "$node/etc/cn-egress/clients.tsv"
printf 'changed explicit setting\n' > "$node/etc/cn-egress/forwarding-settings"
cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || fail guarded-restore
[[ ! -f $node/etc/cn-egress/clients.tsv && $(cat "$node/etc/cn-egress/deployment-id") == deployment-before ]] || fail incomplete-restore
[[ $(cat "$node/etc/cn-egress/forwarding-settings") == 'changed explicit setting' ]] || fail forwarding-overwritten
result=$(cne_n_restore "$archive" deployment-new 2>&1) || fail "already-rolled-back: $result"
cp "$work/services.log" "$work/services-before"
printf 'deployment-later\n' > "$node/etc/cn-egress/deployment-id"
! cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || fail later-deployment
cmp -s "$work/services.log" "$work/services-before" || fail later-deployment-mutated
[[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-later ]] || fail later-id-mutated
ok 'Deployment guard accepts successful/self rollback and rejects a later deployment before service mutation'

backupdir="$node/root/cn-egress-backups"
bad_owner=$archive
! cne_n_validate_backup "$archive" "$work/extract" >/dev/null 2>&1 || fail nonroot-backup
bad_owner=''
chmod 644 "$archive"
! cne_n_validate_backup "$archive" "$work/extract" >/dev/null 2>&1 || fail readable-backup
chmod 600 "$archive"
cp "$archive" "$work/outside.tar.gz"
! cne_n_validate_backup "$work/outside.tar.gz" "$work/extract" >/dev/null 2>&1 || fail outside-backup
linkarchive="$backupdir/20261002-120000-abcdefgh.tar.gz"
ln -s "$archive" "$linkarchive"
! cne_n_validate_backup "$linkarchive" "$work/extract" >/dev/null 2>&1 || fail symlink-backup
rm "$linkarchive"
ln "$archive" "$linkarchive"
! cne_n_validate_backup "$archive" "$work/extract" >/dev/null 2>&1 || fail hardlinked-backup
rm "$linkarchive"
chmod 755 "$backupdir"
! cne_n_restore "$archive" >/dev/null 2>&1 || fail public-directory
[[ $(stat -c %a "$backupdir") == 755 ]] || fail directory-auto-repaired
chmod 700 "$backupdir"
[[ -z $(ls -A "$work/extract") ]] || fail invalid-extracted
ok 'Restore rejects outside, linked, non-root or exposed backups before extraction'

fixture="$work/archive-fixture"
mkdir -p "$fixture/etc/cn-egress" "$fixture/etc/sysctl.d" "$fixture/etc"
printf 'fixture\n' > "$fixture/etc/cn-egress/role"
printf 'not-owned\n' > "$fixture/etc/passwd"
printf 'operator\n' > "$fixture/etc/sysctl.d/90-cn-egress.conf"
printf '%s\tinactive\tdisabled\n' cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service > "$fixture/.cn-egress-services.tsv"
write_metadata() {
    printf 'format=cn-egress-node-backup-v1\narchive=%s\nnode=0123456789abcdef0123456789abcdef\n' "${1##*/}" > "$fixture/.cn-egress-backup"
}
check_rejected() {
    local candidate=$1
    chmod 600 "$candidate"
    ! cne_n_validate_backup "$candidate" "$work/extract" >/dev/null 2>&1 || fail "accepted-$2"
    [[ -z $(ls -A "$work/extract") ]] || fail "extracted-$2"
}
candidate="$backupdir/20261002-120001-abcdefgh.tar.gz"
write_metadata "$candidate"
tar -czf "$candidate" -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/cn-egress/role etc/cn-egress/role
check_rejected "$candidate" duplicate
candidate="$backupdir/20261002-120002-abcdefgh.tar.gz"
write_metadata "$candidate"
tar -czf "$candidate" -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/passwd
check_rejected "$candidate" unrelated
candidate="$backupdir/20261002-120003-abcdefgh.tar.gz"
write_metadata "$candidate"
tar -czf "$candidate" -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/sysctl.d/90-cn-egress.conf
check_rejected "$candidate" operator-sysctl
candidate="$backupdir/20261002-120004-abcdefgh.tar.gz"
write_metadata "$candidate"
rm "$fixture/etc/cn-egress/role"
ln -s /etc/passwd "$fixture/etc/cn-egress/role"
tar -czf "$candidate" -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/cn-egress/role
check_rejected "$candidate" member-symlink
rm "$fixture/etc/cn-egress/role"
printf 'fixture\n' > "$fixture/etc/cn-egress/role"
candidate="$backupdir/20261002-120005-abcdefgh.tar.gz"
write_metadata "$candidate"
printf 'format=foreign\n' > "$fixture/.cn-egress-backup"
tar -czf "$candidate" -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/cn-egress/role
check_rejected "$candidate" provenance
candidate="$backupdir/20261002-120006-abcdefgh.tar.gz"
write_metadata "$candidate"
if [[ $(uname -s) == Darwin ]]; then
    tar -czf "$candidate" -s ',^etc/passwd$,../../outside,' -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/passwd
else
    tar -czf "$candidate" --transform='s#^etc/passwd$#../../outside#' -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/passwd
fi
check_rejected "$candidate" traversal
[[ ! -e $work/outside ]] || fail traversal-write
ok 'Real archives reject duplicate, unowned, operator, symlink, foreign and traversal members'

candidate="$backupdir/20261002-120007-abcdefgh.tar.gz"
write_metadata "$candidate"
printf 'other.service\tactive\tenabled\n' > "$fixture/.cn-egress-services.tsv"
tar -czf "$candidate" -C "$fixture" .cn-egress-backup .cn-egress-services.tsv etc/cn-egress/role
chmod 600 "$candidate"
cp "$work/services.log" "$work/services-before"
! cne_n_restore "$candidate" >/dev/null 2>&1 || fail invalid-service-state
cmp -s "$work/services.log" "$work/services-before" || fail invalid-service-mutated
ok 'Backup service metadata is validated before any service operation'

(
    cne_n_os_check() { :; }
    cne_n_has() { [[ $1 != dig ]]; }
    dpkg() { return 0; }
    apt-get() {
        case $1 in
            update) :;;
            -s) printf 'Inst dnsutils (fixture)\nConf dnsutils (fixture)\nConf business-service (fixture)\n';;
            *) printf 'package mutation\n' >> "$work/apt-install.log";;
        esac
    }
    ! cne_n_prepare hk wireguard >/dev/null 2>&1 || exit 1
    [[ ! -e $work/apt-install.log ]] || exit 1
    cne_n_install_plan_safe $'Inst dnsutils (fixture)\nConf dnsutils (fixture)' || exit 1
) || fail pending-package-configure
ok 'Node dependency preparation blocks configuring an unrelated existing package'

(
    cne_n_stop_owned() { :; }
    cne_n_transport_user() { return 1; }
    stage="$work/failed-stage"
    mkdir -p "$stage"
    printf 'deployment-before\n' > "$node/etc/cn-egress/deployment-id"
    ! cne_n_install_apply hk "$stage" deployment-new >/dev/null 2>&1 || exit 1
    [[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-new ]] || exit 1
    cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || exit 1
    [[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-before ]] || exit 1
) || fail partial-install-identity
ok 'An interrupted replace retains its transaction identity for guarded controller recovery'

(
    cne_n_remove_files || exit 1
    fresh_archive=$(cne_n_backup) || exit 1
    : > "$work/fresh-services.log"
    systemctl() {
        if [[ $1 == show ]]; then
            if [[ -f $node/etc/systemd/system/${*: -1} ]]; then printf 'FragmentPath=%s/etc/systemd/system/%s\n' "$node" "${*: -1}"; else printf 'FragmentPath=\n'; fi
            printf 'DropInPaths=\n'
        else printf '%s\n' "$*" >> "$work/fresh-services.log"; fi
    }
    cne_n_restore "$fresh_archive" deployment-new >/dev/null 2>&1 || exit 1
    ! grep -q '^start ' "$work/fresh-services.log" || exit 1
    cne_n_restore "$archive" >/dev/null 2>&1 || exit 1
) || fail fresh-restore-unit-ownership
ok 'A fresh-node snapshot restores absence without starting a same-named unowned unit'

(
    printf 'deployment-new\n' > "$node/etc/cn-egress/deployment-id"
    cp() {
        if [[ ${*: -1} == "$node/etc/systemd/system/cn-egress.service" ]]; then return 1; fi
        command cp "$@"
    }
    ! cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || exit 1
    [[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-new ]] || exit 1
    unset -f cp
    cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || exit 1
    [[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-before ]] || exit 1
) || fail interrupted-restore-identity
ok 'Failed restore retains the same transaction ID and permits a guarded retry'

(
    cne_n_remove_files keep-deployment || exit 1
    printf 'deployment-new\n' > "$node/etc/cn-egress/deployment-id"
    cache_stale=1
    vendor_fallback=0
    systemctl() {
        local unit=${*: -1}
        case $1 in
            show)
                if ((vendor_fallback)); then printf 'FragmentPath=%s/usr/lib/systemd/system/%s\nDropInPaths=\n' "$node" "$unit"
                elif ((cache_stale)) || [[ -f $node/etc/systemd/system/$unit ]]; then
                    printf 'FragmentPath=%s/etc/systemd/system/%s\n' "$node" "$unit"
                    if ((cache_stale)); then printf 'DropInPaths=%s/etc/systemd/system/cn-egress.service.d/obfs.conf\n' "$node"; else printf 'DropInPaths=\n'; fi
                else printf 'FragmentPath=\nDropInPaths=\n'; fi;;
            daemon-reload) cache_stale=0;;
            *) printf '%s\n' "$*" >> "$work/stale-services.log";;
        esac
    }
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || exit 1
    [[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-before ]] || exit 1
    grep -Fxq 'start cn-egress.service' "$work/stale-services.log" || exit 1
    cne_n_remove_files keep-deployment || exit 1
    printf 'deployment-new\n' > "$node/etc/cn-egress/deployment-id"
    vendor_fallback=1
    cp "$work/stale-services.log" "$work/stale-services-before"
    ! cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || exit 1
    cmp -s "$work/stale-services.log" "$work/stale-services-before" || exit 1
    [[ $(cat "$node/etc/cn-egress/deployment-id") == deployment-new ]] || exit 1
    vendor_fallback=0
    cne_n_restore "$archive" deployment-new >/dev/null 2>&1 || exit 1
) || fail stale-loaded-restore
ok 'Guarded restore refreshes stale owned paths but still rejects a loaded vendor fallback before stop/start'

(
    reloaded=0
    systemctl() {
        local unit=${*: -1}
        case $1 in
            show)
                if [[ -f $node/etc/systemd/system/$unit ]]; then printf 'FragmentPath=%s/etc/systemd/system/%s\n' "$node" "$unit"; else printf 'FragmentPath=\n'; fi
                printf 'DropInPaths=\n';;
            daemon-reload) reloaded=1;;
            stop|start) ((reloaded)) || { printf 'stale command executed\n' >> "$work/stale-command"; return 1; };;
        esac
    }
    cne_n_service_action restart hk >/dev/null 2>&1 || exit 1
    [[ ! -e $work/stale-command ]] || exit 1
) || fail stale-loaded-execution
ok 'Service management refreshes cached commands before executing any stop/start'

(
    source "$repo/shell/render.sh"
    unitroot="$work/rendered-units"
    mkdir -p "$unitroot/etc/systemd/system/cn-egress.service.d"
    for role in hk sh exit; do
        for transport in wireguard awg2; do
            rm -f "$unitroot/etc/systemd/system/"*.service "$unitroot/etc/systemd/system/cn-egress.service.d/"*.conf
            rm -f "$node/etc/systemd/system/"*.service
            rm -rf "$node/etc/systemd/system/cn-egress.service.d"
            cne_render_services "$unitroot" "$role" "$transport" || exit 1
            printf '%s\n' "$role" > "$node/etc/cn-egress/role"
            printf '%s\n' "$transport" > "$node/etc/cn-egress/user-transport"
            for file in "$unitroot/etc/systemd/system/"*.service; do
                sed "s@/usr/local/sbin/@$node/usr/local/sbin/@g; s@/usr/sbin/@$node/usr/sbin/@g; s@/etc/cn-egress/@$node/etc/cn-egress/@g" "$file" > "$node/etc/systemd/system/${file##*/}"
            done
            mkdir -p "$node/etc/systemd/system/cn-egress.service.d"
            cp "$unitroot/etc/systemd/system/cn-egress.service.d/"*.conf "$node/etc/systemd/system/cn-egress.service.d/"
            cne_n_scope_check || exit 1
        done
    done
    rm -f "$node/etc/systemd/system/"*.service "$node/etc/cn-egress/user-transport"
    rm -rf "$node/etc/systemd/system/cn-egress.service.d"
    printf 'hk\n' > "$node/etc/cn-egress/role"
    cp "$work/unit-before" "$node/etc/systemd/system/cn-egress.service"
    printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
    cne_n_scope_check || exit 1
) || fail generated-unit-scope
ok 'Recognized generated units pass for all roles in new and legacy transports'

(
    cne_n_os_check() { :; }
    cne_n_ports_check() { :; }
    cne_n_routes_check() { :; }
    mkdir -p "$node/etc/cn-egress-wss"
    for marker in missing empty malformed conflicting; do
        cne_n_remove_files || exit 1
        mkdir -p "$node/etc/systemd/system/cn-egress.service.d"
        case $marker in
            missing) :;;
            empty) : > "$node/etc/cn-egress/role";;
            malformed) printf 'broken-marker\n' > "$node/etc/cn-egress/role";;
            conflicting) printf 'hk\n' > "$node/etc/cn-egress/role"; printf 'sh\n' > "$node/etc/cn-egress-wss/role";;
        esac
        printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
        [[ $(cne_n_existing_role) == unknown ]] || exit 1
        cne_n_preflight hk replace 51820 443 >/dev/null || exit 1
        printf '[Service]\nExecStart=%s/usr/sbin/dnsmasq --keep-in-foreground --conf-file=%s/etc/cn-egress/dnsmasq.conf\n' "$node" "$node" > "$node/etc/systemd/system/cn-egress-dns.service"
        cne_n_preflight exit replace 51820 443 >/dev/null || exit 1
        printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-users start\n' "$node" > "$node/etc/systemd/system/cn-egress-users.service"
        printf '[Unit]\nRequires=cn-egress-users.service\nBindsTo=cn-egress-users.service\nAfter=cn-egress-users.service\n' > "$node/etc/systemd/system/cn-egress.service.d/users.conf"
        cne_n_preflight hk replace 51820 443 >/dev/null || exit 1
        printf '[Service]\n ExecStart=%s/usr/local/sbin/cn-egress-net start hk\nExecStop=%s/usr/local/sbin/cn-egress-net stop hk\n' "$node" "$node" > "$node/etc/systemd/system/cn-egress.service"
        # Inference from the main command validates that unit even when broken
        # markers keep the overall role unknown; all commands remain exact.
        if [[ $marker == malformed || $marker == conflicting ]]; then cne_n_preflight hk replace 51820 443 >/dev/null || exit 1; fi
        printf ' ExecCondition=/bin/business\n' >> "$node/etc/systemd/system/cn-egress-obfs.service"
        ! cne_n_preflight hk replace 51820 443 >/dev/null 2>&1 || exit 1
    done
    cne_n_remove_files || exit 1
    mkdir -p "$node/etc/systemd/system/cn-egress.service.d"
    printf 'broken-marker\n' > "$node/etc/cn-egress/role"
    printf '[Service]\nExecStart=/bin/business\n' > "$node/etc/systemd/system/cn-egress-obfs.service"
    ! cne_n_preflight hk replace 51820 443 >/dev/null 2>&1 || exit 1
    printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
    printf '[Unit]\nConflicts=nginx.service\n' > "$node/etc/systemd/system/cn-egress.service.d/custom.conf"
    ! cne_n_preflight hk replace 51820 443 >/dev/null 2>&1 || exit 1
    rm "$node/etc/systemd/system/cn-egress.service.d/custom.conf"
    systemctl() { printf 'FragmentPath=%s/usr/lib/systemd/system/%s\nDropInPaths=\n' "$node" "${*: -1}"; }
    ! cne_n_preflight hk replace 51820 443 >/dev/null 2>&1 || exit 1
) || fail partial-tool-unit-replacement
ok 'Partial tool units with missing, empty, malformed or conflicting role markers permit replacement while business commands and overrides remain blocked'

# Restore the standard fixture after partial-unit filesystem mutations above.
cne_n_remove_files || fail reset-partial-units
mkdir -p "$node/etc/cn-egress"
printf 'hk\n' > "$node/etc/cn-egress/role"
cp "$work/unit-before" "$node/etc/systemd/system/cn-egress.service"
printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"

(
    unitfile="$node/etc/systemd/system/cn-egress.service"
    for command in '  ExecStart=/bin/true' ' ExecCondition=/bin/true' 'ExecStartPre=/bin/true' 'ExecStopPost=/bin/true' "ExecStart=$node/usr/local/sbin/cn-egress-net start hk extra"; do
        cp "$work/unit-before" "$unitfile"
        printf '%s\n' "$command" >> "$unitfile"
        ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    done
    cp "$work/unit-before" "$unitfile"
    printf ' ExecCondition=/bin/true' >> "$unitfile"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    printf '[Service]\nRemainAfterExit=yes\n' > "$unitfile"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    cp "$work/unit-before" "$unitfile"
    printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-net start hk\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    printf '[Service]\nExecStart=%s/usr/local/sbin/cn-egress-obfs\n' "$node" > "$node/etc/systemd/system/cn-egress-obfs.service"
    cp "$work/unit-before" "$unitfile"
    for setting in Conflicts=nginx.service OnFailure=business.service OnSuccess=business.service FailureAction=reboot SuccessAction=poweroff StartLimitAction=reboot PropagatesStopTo=nginx.service Wants=business.service Requires=business.service; do
        cp "$work/unit-before" "$unitfile"
        printf '[Unit]\n %s\n' "$setting" >> "$unitfile"
        cp "$work/services.log" "$work/scope-services-before"
        ! cne_n_service_action start hk >/dev/null 2>&1 || exit 1
        cmp -s "$work/services.log" "$work/scope-services-before" || exit 1
    done
    cp "$work/unit-before" "$unitfile"
    cne_n_scope_check || exit 1
) || fail service-command-actions
ok 'Unknown or indented execution directives, wrong unit commands and business service actions are rejected before mutation'

(
    directory="$node/etc/systemd/system/cn-egress.service.d"
    mkdir -p "$directory"
    printf '[Service]\nExecStartPre=/bin/true\n' > "$directory/custom.conf"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    rm "$directory/custom.conf"
    mkdir -p "$node/etc/systemd/system/cn-.service.d" "$node/etc/systemd/system/service.d"
    printf '[Unit]\nConflicts=nginx.service\n' > "$node/etc/systemd/system/cn-.service.d/business.conf"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    rm "$node/etc/systemd/system/cn-.service.d/business.conf"
    printf '[Service]\nExecCondition=/bin/true\n' > "$node/etc/systemd/system/service.d/business.conf"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    rm "$node/etc/systemd/system/service.d/business.conf"
    printf '[Unit]\nWants=cn-egress-obfs.service\nAfter=cn-egress-obfs.service\n' > "$directory/obfs.conf"
    cne_n_scope_check || exit 1
    printf 'Conflicts=nginx.service\n' >> "$directory/obfs.conf"
    ! cne_n_scope_check >/dev/null 2>&1 || exit 1
    rm -f "$directory/obfs.conf"
    systemctl() {
        [[ $1 == show ]] || { printf 'mutation\n' >> "$work/unowned-mutation"; return; }
        printf 'FragmentPath=%s/usr/lib/systemd/system/%s\nDropInPaths=\n' "$node" "${*: -1}"
    }
    ! cne_n_service_action start hk >/dev/null 2>&1 || exit 1
    [[ ! -e $work/unowned-mutation ]] || exit 1
    systemctl() {
        [[ $1 == show ]] || { printf 'mutation\n' >> "$work/unowned-mutation"; return; }
        printf 'FragmentPath=%s/etc/systemd/system/%s\nDropInPaths=%s/run/systemd/system/%s.d/business.conf\n' "$node" "${*: -1}" "$node" "${*: -1}"
    }
    ! cne_n_service_action start hk >/dev/null 2>&1 || exit 1
    [[ ! -e $work/unowned-mutation ]] || exit 1
) || fail service-loaded-dropins
ok 'Arbitrary drop-ins, changed owned drop-ins and loaded vendor/runtime overrides are rejected before service action'

(
    cne_n_os_check() { :; }
    cne_n_has() { :; }
    dpkg() { :; }
    ca_installed=0
    dpkg-query() { if ((ca_installed)); then printf 'install ok installed'; else return 1; fi; }
    apt-get() {
        case $1 in
            update) :;;
            -s) printf 'Inst ca-certificates (fixture)\nConf ca-certificates (fixture)\n';;
            -y)
                [[ " $* " == *' ca-certificates '* ]] || return 1
                mkdir -p "$node/etc/ssl/certs"
                printf 'fixture CA bundle\n' > "$node/etc/ssl/certs/ca-certificates.crt"
                ca_installed=1;;
        esac
    }
    cne_n_prepare hk wireguard >/dev/null 2>&1 || exit 1
    ((ca_installed)) && [[ -s $node/etc/ssl/certs/ca-certificates.crt ]] || exit 1
    rm "$node/etc/ssl/certs/ca-certificates.crt"
    apt-get() { case $1 in -s) printf 'Inst ca-certificates (fixture)\nConf ca-certificates (fixture)\n';; *) :;; esac; }
    ! cne_n_prepare hk wireguard >/dev/null 2>&1 || exit 1
) || fail https-ca-dependency
ok 'HK installs and verifies a missing HTTPS CA bundle and rejects an unavailable bundle after installation'

params="$work/params"
printf 'Jc = 6\nJmin = 40\nJmax = 700\nS1 = 32\nS2 = 33\nS3 = 16\nS4 = 8\nH1 = 100000000-100001000\nH2 = 1100000000-1100001000\nH3 = 2100000000-2100001000\nH4 = 3100000000-3100001000\n' > "$params"
cne_n_validate_awg_params "$params" || fail valid-params
cp "$params" "$work/params-good"
printf 'PrivateKey = unexpected\n' >> "$params"
! cne_n_validate_awg_params "$params" >/dev/null 2>&1 || fail injected-param
cp "$work/params-good" "$params"
sed 's/H2 = .*/H2 = 100000000-100001000/' "$params" > "$work/params-overlap"
! cne_n_validate_awg_params "$work/params-overlap" >/dev/null 2>&1 || fail overlapping-headers
sed 's/Jmax = 700/Jmax = 20/' "$params" > "$work/params-range"
! cne_n_validate_awg_params "$work/params-range" >/dev/null 2>&1 || fail invalid-junk-range
ok 'AWG parameters accept valid disjoint uint32 ranges and reject injected keys or invalid bounds'

(
    stage="$work/compile-stage"
    mkdir -p "$stage/etc/cn-egress" "$stage/opt/cn-egress/awg-0.2.16"
    printf 'awg2\n' > "$stage/etc/cn-egress/user-transport"
    printf 'untrusted source\n' > "$stage/opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz"
    cne_n_has() { :; }
    sha256sum() { return 1; }
    make() { printf 'make\n' >> "$work/compiler.log"; }
    ! cne_n_compile_tools hk "$stage" >/dev/null 2>&1 || exit 1
    [[ ! -e $work/compiler.log && ! -e $stage/opt/cn-egress/awg-0.2.16/awg ]] || exit 1
) || fail compile-unverified
ok 'Native AWG compiler refuses unverified source before make or node service changes'

(
    mkdir -p "$node/etc/wireguard" "$node/opt/cn-egress/awg-0.2.16"
    printf 'awg2\n' > "$node/etc/cn-egress/user-transport"
    printf '[Interface]\nAddress = 10.77.10.1/24\nTable = off\nMTU = 1380\nJc = 6\nH1 = 100000000-100001000\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.77.10.250/32\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.77.10.2/32\n' "$(printf 'A%042d=' 0)" "$(printf 'B%042d=' 0)" > "$node/etc/wireguard/cne-users.conf"
    cat > "$node/opt/cn-egress/awg-0.2.16/awg" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CNE_TEST_ARGS"
cat "$3" > "$CNE_TEST_STRIPPED"
TOOL
    chmod 755 "$node/opt/cn-egress/awg-0.2.16/awg"
    export CNE_TEST_ARGS="$work/awg-args" CNE_TEST_STRIPPED="$work/awg-stripped"
    ip() { return 0; }
    cne_n_client_sync || exit 1
    [[ $(cat "$work/awg-args") == 'syncconf cne-users '* ]] || exit 1
    grep -Fxq 'Jc = 6' "$work/awg-stripped" && grep -Fxq 'H1 = 100000000-100001000' "$work/awg-stripped" || exit 1
    ! grep -Eq '^(Address|Table|MTU) =' "$work/awg-stripped" || exit 1
    clients=$(cne_n_client_list)
    [[ $clients == legacy-2$'\t2\t'* && $clients != *$'\t250\t'* ]] || exit 1
) || fail native-client-sync
ok 'AWG client updates retain packet parameters, use native UAPI and hide the reserved diagnosis peer'

(
    mkdir -p "$node/etc/wireguard" "$node/etc/cn-egress" "$node/run/lock"
    server=$(printf 'A%042d=' 0); other_server=$(printf 'B%042d=' 0)
    old_peer=$(printf 'C%042d=' 0); new_peer=$(printf 'D%042d=' 0)
    config="$node/etc/wireguard/cne-users.conf"; registry="$node/etc/cn-egress/clients.tsv"
    printf '[Interface]\nPrivateKey = fixture\nTable = off\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.77.10.20/32, fd77:77:10::20/128\n' "$new_peer" > "$config"
    printf 'phone\t20\t%s\n' "$new_peer" > "$registry"
    cp "$config" "$work/guard-config-before"; cp "$registry" "$work/guard-registry-before"
    id() { if [[ $1 == -u ]]; then printf '0\n'; else command id "$@"; fi; }
    flock() { [[ $* == '-w 30 9' ]] || return 1; CNE_TEST_LOCKED=1; printf 'lock\n' >> "$work/client-guard-locks"; }
    cne_n_server_public() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; printf '%s\n' "$server"; }
    cne_n_client_sync() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; printf 'sync\n' >> "$work/client-guard-sync"; }
    ! cne_node_main client-remove hk phone "$old_peer" "$server" >/dev/null 2>&1 || exit 1
    cmp -s "$config" "$work/guard-config-before" && cmp -s "$registry" "$work/guard-registry-before" || exit 1
    ! cne_node_main client-remove hk phone "$new_peer" "$other_server" >/dev/null 2>&1 || exit 1
    cmp -s "$config" "$work/guard-config-before" && cmp -s "$registry" "$work/guard-registry-before" || exit 1
    [[ ! -e $work/client-guard-sync && $(wc -l < "$work/client-guard-locks" | tr -d ' ') == 2 ]] || exit 1
    cne_node_main client-remove hk phone "$new_peer" "$server" >/dev/null || exit 1
    ! grep -Fq "$new_peer" "$config" && [[ ! -s $registry && $(cat "$work/client-guard-sync") == sync ]] || exit 1
) || fail client-revoke-identity-race
ok 'Locked revoke rejects a concurrently replaced same-name peer or server without changing saved or live clients'

(
    server=$(printf 'A%042d=' 0); other_server=$(printf 'B%042d=' 0); peer=$(printf 'D%042d=' 0)
    id() { if [[ $1 == -u ]]; then printf '0\n'; else command id "$@"; fi; }
    flock() { [[ $* == '-w 30 9' ]] || return 1; CNE_TEST_LOCKED=1; }
    cne_n_server_public() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; printf '%s\n' "$server"; }
    cne_n_client_sync() { printf 'unexpected sync\n' >> "$work/absent-client-sync"; return 1; }
    ! cne_node_main client-remove hk phone "$peer" "$other_server" >/dev/null 2>&1 || exit 1
    cne_node_main client-remove hk phone "$peer" "$server" >/dev/null || exit 1
    ! cne_node_main client-remove hk phone >/dev/null 2>&1 || exit 1
    ! cne_node_main client-remove hk phone "$peer" >/dev/null 2>&1 || exit 1
    [[ ! -e $work/absent-client-sync ]] || exit 1
) || fail absent-client-guard
ok 'Absent client revoke retries succeed only with matching server identity and both guards'

(
    server=$(printf 'A%042d=' 0); other_server=$(printf 'B%042d=' 0); peer=$(printf 'E%042d=' 0)
    CNE_CLIENT_PSK=$(printf 'F%042d=' 0)
    config="$node/etc/wireguard/cne-users.conf"; registry="$node/etc/cn-egress/clients.tsv"
    cp "$config" "$work/add-guard-config-before"; cp "$registry" "$work/add-guard-registry-before"
    id() { if [[ $1 == -u ]]; then printf '0\n'; else command id "$@"; fi; }
    flock() { [[ $* == '-w 30 9' ]] || return 1; CNE_TEST_LOCKED=1; }
    cne_n_server_public() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; printf '%s\n' "$server"; }
    cne_n_client_sync() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; cp "$config" "$work/add-guard-live"; }
    ! cne_node_main client-add hk phone 20 "$peer" "$other_server" >/dev/null 2>&1 || exit 1
    cmp -s "$config" "$work/add-guard-config-before" && cmp -s "$registry" "$work/add-guard-registry-before" || exit 1
    [[ ! -e $work/add-guard-live ]] || exit 1
    cne_node_main client-add hk phone 20 "$peer" "$server" >/dev/null || exit 1
    grep -Fq "$peer" "$config" && grep -Fq "$peer" "$registry" && cmp -s "$config" "$work/add-guard-live" || exit 1
) || fail client-add-server-race
ok 'Locked addition rejects a changed server before writes and accepts the same server identity'

(
    server=$(printf 'A%042d=' 0); changed_server=$(printf 'B%042d=' 0)
    peer=$(printf 'C%042d=' 0); missing_peer=$(printf 'D%042d=' 0)
    psk=$(printf 'E%042d=' 0); wrong_psk=$(printf 'F%042d=' 0)
    hash=$(printf '%s\n' "$psk" | sha256sum); hash=${hash%% *}
    config="$node/etc/wireguard/cne-users.conf"; output="$work/client-verification-output"
    write_verification_config() {
        printf '[Interface]\nPrivateKey = private-fixture-never-output\nTable = off\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.77.10.20/32, fd77:77:10::20/128\n' "$peer" "$1" > "$config"
    }
    id() { if [[ $1 == -u ]]; then printf '0\n'; else command id "$@"; fi; }
    flock() { [[ $* == '-w 30 9' ]] || return 1; CNE_TEST_LOCKED=1; }
    cne_n_server_public() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; printf '%s\n' "$server"; }
    cne_n_client_sync() { printf 'unexpected mutation\n' >> "$work/verification-mutation"; return 1; }
    : > "$output"
    write_verification_config "$psk"
    cp "$config" "$work/verification-before"
    cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
    cmp -s "$config" "$work/verification-before" || exit 1
    ! cne_node_main client-verify hk "$peer" "$changed_server" "$hash" >> "$output" 2>&1 || exit 1
    ! cne_node_main client-verify hk "$missing_peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
    ! cne_node_main client-verify hk "$peer" "$server" bad-hash >> "$output" 2>&1 || exit 1
    write_verification_config "$wrong_psk"
    cp "$config" "$work/verification-before"
    ! cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
    cmp -s "$config" "$work/verification-before" || exit 1
    write_verification_config "$psk"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.77.10.30/32\n' "$peer" "$psk" >> "$config"
    ! cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
    write_verification_config "$psk"
    printf 'PresharedKey = %s\n' "$wrong_psk" >> "$config"
    ! cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
    [[ ! -e $work/verification-mutation ]] || exit 1
    ! grep -Fq "$psk" "$output" && ! grep -Fq "$wrong_psk" "$output" && ! grep -Fq 'private-fixture-never-output' "$output" || exit 1
) || fail saved-client-psk-verification
ok 'Locked read-only verification matches the newline-hashed saved PSK and rejects changed server, missing/duplicate peer or corrupted PSK without exposing secrets'

(
    server=$(printf 'A%042d=' 0); peer=$(printf 'C%042d=' 0)
    psk=$(printf 'E%042d=' 0); wrong_psk=$(printf 'F%042d=' 0)
    hash=$(printf '%s\n' "$psk" | sha256sum); hash=${hash%% *}
    config="$node/etc/wireguard/cne-users.conf"; output="$work/live-client-verification-output"
    printf '[Interface]\nPrivateKey = private-fixture-never-output\nTable = off\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.77.10.20/32\n' "$peer" "$psk" > "$config"
    cp "$config" "$work/live-verification-before"
    id() { if [[ $1 == -u ]]; then printf '0\n'; else command id "$@"; fi; }
    flock() { [[ $* == '-w 30 9' ]] || return 1; export CNE_TEST_LOCKED=1; }
    cne_n_server_public() { [[ ${CNE_TEST_LOCKED:-0} == 1 ]] || return 1; printf '%s\n' "$server"; }
    cne_n_has() { command -v "$1" >/dev/null 2>&1; }
    ip() { [[ $* == '-n cn-egress-relay link show cne-users' ]]; }
    cne_n_user_transport() { printf '%s\n' "$CNE_TEST_VERIFY_TRANSPORT"; }
    export CNE_TEST_LIVE_PEER="$peer" CNE_TEST_LIVE_PSK="$psk" CNE_TEST_LIVE_SERVER="$server" CNE_TEST_LIVE_FAIL=0
    cne_n_net() {
        [[ ${CNE_TEST_LOCKED:-0} == 1 && $CNE_TEST_LIVE_FAIL == 0 ]] || return 1
        case $* in
            'hk wg show cne-users preshared-keys') printf '%s\t%s\n' "$CNE_TEST_LIVE_PEER" "$CNE_TEST_LIVE_PSK";;
            'hk wg show cne-users public-key') printf '%s\n' "$CNE_TEST_LIVE_SERVER";;
            *) return 1;;
        esac
    }
    cat > "$node/opt/cn-egress/awg-0.2.16/awg" <<'VERIFY_TOOL'
#!/usr/bin/env bash
[[ ${CNE_TEST_LOCKED:-0} == 1 && $CNE_TEST_LIVE_FAIL == 0 ]] || exit 1
case $* in
    'show cne-users preshared-keys') printf '%s\t%s\n' "$CNE_TEST_LIVE_PEER" "$CNE_TEST_LIVE_PSK";;
    'show cne-users public-key') printf '%s\n' "$CNE_TEST_LIVE_SERVER";;
    *) exit 1;;
esac
VERIFY_TOOL
    chmod 755 "$node/opt/cn-egress/awg-0.2.16/awg"
    : > "$output"
    for transport in wireguard awg2; do
        CNE_TEST_VERIFY_TRANSPORT=$transport
        CNE_TEST_LIVE_PSK=$psk; CNE_TEST_LIVE_FAIL=0
        cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
        CNE_TEST_LIVE_PSK=$wrong_psk
        ! cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
        CNE_TEST_LIVE_PSK=$psk; CNE_TEST_LIVE_SERVER=$(printf 'G%042d=' 0)
        ! cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
        CNE_TEST_LIVE_SERVER=$server
        CNE_TEST_LIVE_PSK=$psk; CNE_TEST_LIVE_FAIL=1
        ! cne_node_main client-verify hk "$peer" "$server" "$hash" >> "$output" 2>&1 || exit 1
    done
    cmp -s "$config" "$work/live-verification-before" || exit 1
    ! grep -Fq "$psk" "$output" && ! grep -Fq "$wrong_psk" "$output" || exit 1
) || fail live-client-psk-verification
ok 'Active WG and AWG entries additionally require matching live server key and PSK; drift or an unreadable live peer cannot pass verification'

(
    now=$(date +%s)
    stale=0
    cne_n_net() {
        [[ $3 == show && $5 == latest-handshakes ]] || return 1
        [[ $4 != cne-users ]] || return 1
        if ((stale)); then printf 'fixture-peer\t0\n'; else printf 'fixture-peer\t%s\n' "$((now-20))"; fi
    }
    cne_n_handshake_check hk && cne_n_handshake_check sh && cne_n_handshake_check exit || exit 1
    stale=1
    ! cne_n_handshake_check hk >/dev/null 2>&1 || exit 1
    cne_n_net() { :; }
    ! cne_n_handshake_check exit >/dev/null 2>&1 || exit 1
) || fail handshake-validation
ok 'Doctor requires recent interserver handshakes while allowing idle mobile peers'

(
    cne_n_status() { :; }
    cne_n_user_transport() { printf 'wireguard\n'; }
    cne_n_handshake_check() { :; }
    systemctl() { :; }
    openssl() { :; }
    ! cne_n_doctor hk >/dev/null 2>&1 || exit 1
    cne_n_chain_probe() { return 1; }
    ! cne_n_doctor hk >/dev/null 2>&1 || exit 1
    cne_n_chain_probe() { return 0; }
    cne_n_doctor hk >/dev/null || exit 1
) || fail doctor-false-pass
ok 'Doctor cannot report a complete chain pass when the full-path probe is missing or fails'

(
    printf 'nameserver 127.0.0.53\n' > "$node/etc/resolv.conf"
    dig() { printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 123\napi.ipify.org. 60 IN A 198.51.100.20\n'; }
    cne_n_dns_check >/dev/null || exit 1
    dig() { printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 123\n'; }
    ! cne_n_dns_check >/dev/null 2>&1 || exit 1
    printf '# no upstream\n' > "$node/etc/resolv.conf"
    ! cne_n_dns_check >/dev/null 2>&1 || exit 1
) || fail dns-validation
ok 'Exit DNS validation checks a resolver and a successful UDP IPv4 answer'
printf '%s node safety tests passed.\n' "$passed"
