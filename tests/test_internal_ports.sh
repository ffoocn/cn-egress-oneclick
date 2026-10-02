#!/usr/bin/env bash
# Internal-port planning and runtime consistency, using isolated files only.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-internal-ports.XXXXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077
export CNE_NODE_LIBRARY=1
source "$ROOT/shell/node.sh"
source "$ROOT/shell/render.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing $2 in $1"; }
PORT_LISTENERS=$'udp UNCONN 0 0 0.0.0.0:51831 *:*\nudp UNCONN 0 0 0.0.0.0:51821 *:*\nudp UNCONN 0 0 0.0.0.0:51822 *:*\nudp UNCONN 0 0 0.0.0.0:51832 *:*\ntcp LISTEN 0 0 [::]:5354 *:*\nudp UNCONN 0 0 127.0.0.1:49152 *:*'
(
    cne_n_has() { [[ $1 == ss ]]; }
    ss() { printf '%s\n' "$PORT_LISTENERS"; }
    cne_n_port_owned() { return 1; }
    [[ $(cne_n_plan_ports hk fresh 49152 443) == hk_local=49153 ]] || fail hk-planning
    [[ $(cne_n_dispatch plan-ports sh fresh 51820 443) == $'sh_hk=49153\nsh_exit=49154' ]] || fail relay-planning
    [[ $(cne_n_plan_ports exit fresh 51820 443) == $'exit_local=49153\ndns=49154' ]] || fail dns-tcp-conflict
    cne_n_ports_check hk fresh 51820 443 49153 49153 49154 49153 49154 || fail planned-preflight
    cne_n_ports_check exit fresh 51820 443 49153 49153 49154 49153 49154 || fail exit-preflight
    PORT_LISTENERS+=$'\nudp UNCONN 0 0 127.0.0.1:49153 *:*'
    if cne_n_ports_check exit fresh 51820 443 49153 49153 49154 49153 49154 2> "$WORK/race-error"; then fail race-accepted; fi
    contains "$WORK/race-error" '内部端口'
    contains "$WORK/race-error" '重新执行一键安装'
    PORT_LISTENERS=$'udp UNCONN 0 0 0.0.0.0:51820 *:*'
    if cne_n_ports_check hk fresh 51820 443 49153 49153 49154 49153 49154 2> "$WORK/public-error"; then fail public-port-accepted; fi
    contains "$WORK/public-error" '对外端口'
    printf 'PASS: internal ports avoid business UDP/TCP listeners, reserved peers and race conflicts; public ports are never silently changed\n'
)
(
    cne_n_has() { [[ $1 == ss ]]; }
    ss() { return 7; }
    if cne_n_plan_ports hk fresh 51820 443 > /dev/null 2>&1; then fail ss-failure-accepted; fi
    if cne_n_ports_check hk fresh 51820 443 > /dev/null 2>&1; then fail failed-preflight-read; fi
    cne_n_has() { return 1; }
    [[ $(cne_n_plan_ports hk fresh 51820 443 2> "$WORK/no-ss") == hk_local=51831 ]] || fail no-ss-candidate
    contains "$WORK/no-ss" '准备依赖后重新检查'
    cne_n_has() { [[ $1 == ss ]]; }
    ss() { printf 'udp UNCONN 0 0 127.0.0.1:50001 *:*\n'; }
    cne_n_internal_ports() { printf '50001 50002 50003 50004 50005\n'; }
    cne_n_port_owned() { [[ $3 == 50001 ]]; }
    [[ $(cne_n_plan_ports hk replace 51820 443) == hk_local=50001 ]] || fail existing-port-not-retained
    [[ $(cne_n_plan_ports hk fresh 51820 443) == hk_local=51831 ]] || fail fresh-reused-old-plan
    ss() { printf 'udp UNCONN 0 0 127.0.0.1:50001 *:* owned\nudp UNCONN 0 0 0.0.0.0:50001 *:* business\n'; }
    cne_n_port_owned() { [[ $4 == *owned ]]; }
    [[ $(cne_n_plan_ports hk replace 51820 443) == hk_local=49152 ]] || fail mixed-listeners-reused
    if cne_n_ports_check hk replace 51820 443 50001 50002 50003 50004 50005 > /dev/null 2>&1; then fail mixed-listeners-preflight; fi
    printf 'PASS: missing ss defers detection explicitly, failed ss refuses progress, and owned replacement ports remain stable\n'
)
(
    mkdir -p "$WORK/proc/123" "$WORK/proc/124" "$WORK/proc/125"
    printf '0::/system.slice/cn-egress-obfs.service\n' > "$WORK/proc/123/cgroup"
    printf '0::/system.slice/nginx.service\n' > "$WORK/proc/124/cgroup"
    printf '0::/system.slice/cn-egress-dns.service\n' > "$WORK/proc/125/cgroup"
    definition=$(declare -f cne_n_port_owned)
    definition=${definition//\/proc\//$WORK/proc/}
    eval "$definition"
    cne_n_has() { [[ $1 == wg ]]; }
    wg() { printf '50001\n'; }
    if cne_n_port_owned hk udp 50001 'udp UNCONN 0 0 *:50001 *:* users:(pid=123,pid=124)'; then fail business-pid-hidden; fi
    cne_n_port_owned hk udp 50001 'udp UNCONN 0 0 *:50001 *:* users:(pid=123,pid=125)' || fail tool-pids-not-owned
    if cne_n_port_owned hk udp 50001 'udp UNCONN 0 0 *:50001 *:* users:(pid=123,pid=126)'; then fail unknown-pid-hidden; fi
    printf 'PASS: mixed business/tool listeners and mixed process ownership cannot be hidden by an owned WireGuard port\n'
)
printf '50001 50002 50003 50004 50005\n' > "$WORK/internal-ports"
[[ $(cne_n_internal_ports "$WORK/internal-ports") == '50001 50002 50003 50004 50005' ]] || fail manifest-read
[[ $(cne_n_internal_ports "$WORK/missing") == '51831 51821 51822 51832 5354' ]] || fail legacy-default
for invalid in '1 2 3 4 4' '1 2 2 4 5' '1 2 3 4 65536' '1 2 3 4 05' '1 2 3 4 $(id)' '1 2 3 4 5 extra'; do
    printf '%s\n' "$invalid" > "$WORK/invalid-ports"
    if cne_n_internal_ports "$WORK/invalid-ports" >/dev/null 2>&1; then fail invalid-manifest; fi
done
ln -s "$WORK/internal-ports" "$WORK/linked-ports"
if cne_n_internal_ports "$WORK/linked-ports" >/dev/null 2>&1; then fail linked-manifest; fi
cne_n_all_files | grep -Fxq etc/cn-egress-wss/internal-ports || fail backup-allowlist
for role in hk sh exit; do cne_n_payload_allowed "$role" etc/cn-egress-wss/internal-ports || fail payload-allowlist; done
printf 'PASS: validated data-only internal-port manifests are owned by every role; missing legacy manifests retain fixed defaults\n'

cne_net_source() { cat "$ROOT/shell/assets/cn-egress-net.sh"; }
cne_obfs_source() { cat "$ROOT/shell/assets/cn-egress-obfs.sh"; }
cne_restrictions_source() { cat "$ROOT/shell/assets/restrictions.yaml"; }
cne_node_source() { printf '#!/usr/bin/env bash\nexit 0\n'; }
mkdir "$WORK/bin"
cat > "$WORK/bin/wg" <<'WG'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
    genkey|genpsk) openssl rand -base64 32;;
    pubkey) openssl dgst -sha256 -binary | openssl base64 -A; printf '\n';;
    *) exit 1;;
esac
WG
chmod 700 "$WORK/bin/wg"
export PATH="$WORK/bin:$PATH"
cne_render_bundle "$WORK/bundle" 203.0.113.10 198.51.100.20 51820 443 eth0 wireguard 50001 50002 50003 50004 50005
cne_n_wan() { printf 'eth0\n'; }
# Target node paths are validated as Linux paths; macOS /etc is a system symlink.
eval "$(declare -f cne_n_safe_path | sed '1s/cne_n_safe_path/cne_fixture_safe_path/')"
cne_n_safe_path() {
    case $1 in /etc/*|/usr/local/*|/opt/*) return 0;; *) cne_fixture_safe_path "$1";; esac
}
stat() {
    if [[ $1 == -c && $2 == %s ]]; then wc -c < "$3" | tr -d ' '; else command stat "$@"; fi
}
for role in hk sh exit; do
    root=$WORK/bundle/$role
    [[ $(cat "$root/etc/cn-egress-wss/internal-ports") == '50001 50002 50003 50004 50005' ]] || fail rendered-plan
    cne_n_internal_stage_check "$role" "$root" || fail stage-check
    mkdir -p "$root/opt/cn-egress/wstunnel-11.0.0" "$WORK/extract-$role"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/opt/cn-egress/wstunnel-11.0.0/wstunnel"
    (cd "$root"; find . -type f | sed 's#^./##' | LC_ALL=C sort > "$WORK/$role.files"; tar -czf "$WORK/$role.tar.gz" -T "$WORK/$role.files")
    cne_n_validate_archive "$role" "$WORK/$role.tar.gz" "$WORK/extract-$role" || fail dynamic-archive
done
contains "$WORK/bundle/hk/etc/wireguard/cne-cn.conf" 'Endpoint = 127.0.0.1:50001'
contains "$WORK/bundle/sh/etc/wireguard/cne-cn.conf" 'ListenPort = 50002'
contains "$WORK/bundle/sh/etc/wireguard/cne-exit.conf" 'ListenPort = 50003'
contains "$WORK/bundle/exit/etc/wireguard/cne-exit.conf" 'Endpoint = 127.0.0.1:50004'
contains "$WORK/bundle/sh/etc/cn-egress-wss/guard.nft" 'udp dport { 50002, 50003 }'
contains "$WORK/bundle/exit/etc/cn-egress/dnsmasq.conf" 'port=50005'
contains "$WORK/bundle/exit/etc/cn-egress/firewall.nft" 'redirect to :50005'
printf 'PASS: renderer, DNS redirect, relay restrictions and installation validation share the same dynamic ports\n'

for role in hk exit; do
    root=$WORK/bundle/$role
    cat > "$root/opt/cn-egress/wstunnel-11.0.0/wstunnel" <<'TRANSPORT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CNE_ARGUMENTS"
TRANSPORT
    chmod 700 "$root/opt/cn-egress/wstunnel-11.0.0/wstunnel"
    sed -e "s#/etc/cn-egress-wss#$root/etc/cn-egress-wss#g" -e "s#/opt/cn-egress/wstunnel-11.0.0#$root/opt/cn-egress/wstunnel-11.0.0#g" "$ROOT/shell/assets/cn-egress-obfs.sh" > "$WORK/runtime-$role"
    CNE_ARGUMENTS=$WORK/args-$role bash "$WORK/runtime-$role"
done
contains "$WORK/args-hk" 'udp://127.0.0.1:50001:127.0.0.1:50002?timeout_sec=0'
contains "$WORK/args-exit" 'udp://127.0.0.1:50004:127.0.0.1:50003?timeout_sec=0'
rm "$WORK/bundle/hk/etc/cn-egress-wss/internal-ports"
CNE_ARGUMENTS=$WORK/args-legacy bash "$WORK/runtime-hk"
contains "$WORK/args-legacy" 'udp://127.0.0.1:51831:127.0.0.1:51821?timeout_sec=0'
printf 'PASS: transport runtime maps dynamically planned ports and preserves legacy behavior without a manifest\n'

for role in sh exit; do
    cp -R "$WORK/bundle/$role" "$WORK/mismatch-$role"
done
printf '50001 50012 50003 50004 50005\n' > "$WORK/mismatch-sh/etc/cn-egress-wss/internal-ports"
printf '50001 50002 50003 50004 50015\n' > "$WORK/mismatch-exit/etc/cn-egress-wss/internal-ports"
for role in sh exit; do
    if cne_n_internal_stage_check "$role" "$WORK/mismatch-$role" > /dev/null 2>&1; then fail partial-plan-change; fi
done
(
    cne_n_has() { [[ $1 == dig ]]; }
    cne_n_internal_ports() { printf '50001 50002 50003 50004 50005\n'; }
    awk() { if [[ ${*: -1} == /etc/resolv.conf ]]; then return 0; else command awk "$@"; fi; }
    dig() { printf '%s\n' "$*" > "$WORK/dns-args"; printf ';; ->>HEADER<<- status: NOERROR,\napi.ipify.org. 30 IN A 203.0.113.50\n'; }
    cne_n_dns_check > /dev/null || fail dns-probe
    contains "$WORK/dns-args" '-p 50005'
)
printf 'PASS: mixed port files fail validation, and the exit DNS diagnostic uses the planned DNS port\n'
(
    cne_n_has() { [[ $1 == ss ]]; }
    ss() { printf 'udp UNCONN 0 0 0.0.0.0:50002 *:*\n'; }
    cne_n_port_owned() { return 1; }
    cne_n_stop_owned() { printf 'stop-called\n' > "$WORK/restore-mutation"; return 1; }
    if cne_n_restore_apply "$WORK/bundle/sh" operation-test > /dev/null 2>&1; then fail restore-port-collision; fi
    [[ ! -e $WORK/restore-mutation ]] || fail restore-stopped-before-port-check
    cne_n_port_owned() { return 0; }
    cne_n_restore_ports_check "$WORK/bundle/sh" || fail owned-restore-port
    printf 'cn-egress.service\tinactive\tdisabled\ncn-egress-obfs.service\tinactive\tdisabled\ncn-egress-dns.service\tinactive\tdisabled\ncn-egress-users.service\tinactive\tdisabled\n' > "$WORK/bundle/sh/.cn-egress-services.tsv"
    ss() { return 7; }
    cne_n_restore_ports_check "$WORK/bundle/sh" || fail stopped-restore-needs-port
)
printf 'PASS: running historical ports cannot replace a business listener or stop the current service; stopped backups retain their state\n'
{
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'relay_init() { :; }\nload_firewall() { :; }\n'
    printf 'relay_wg_up() { [[ $1 != cne-exit ]]; }\n'
    printf 'obfs_guard_up() { printf "unexpected guard\\n" > "$CNE_GUARD_TRACE"; }\n'
    sed -n '/^start_sh()/,/^}/p' "$ROOT/shell/assets/cn-egress-net.sh"
    printf '\nstart_sh\n'
} > "$WORK/guard-order"
if CNE_GUARD_TRACE=$WORK/guard-activated bash "$WORK/guard-order"; then fail failed-bind-accepted; fi
[[ ! -e $WORK/guard-activated ]] || fail guard-before-listener
printf 'PASS: relay input restrictions are applied only after both listeners bind, preserving business traffic on a late collision\n'
printf 'Internal port checks passed. No packages, interfaces, routes, business services or SSH were changed.\n'
