#!/bin/bash
# Manage only the interfaces, routing tables and nftables table owned by this deployment.
set -Eeuo pipefail

action=${1:?start or stop}
role=${2:?hk, sh or exit}
config_dir=/etc/cn-egress
relay_ns=cn-egress-relay
relay_pending=()

net() {
    case "$role" in
        hk|sh) ip netns exec "$relay_ns" "$@" ;;
        *) "$@" ;;
    esac
}

relay_init() {
    if ! ip netns list | cut -d' ' -f1 | /usr/bin/grep -qx "$relay_ns"; then
        ip netns add "$relay_ns"
    fi
    net ip link set lo up
    # These settings belong only to the isolated relay, never to the host.
    net sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
}

relay_wg_up() {
    local interface=$1 ipv4=$2 ipv6=$3
    if ! ip -n "$relay_ns" link show "$interface" >/dev/null 2>&1; then
        # The encrypted UDP socket remains in its birth (host) namespace.
        ip link add "$interface" type wireguard
        relay_pending+=("$interface")
        ip link set "$interface" netns "$relay_ns"
        relay_pending=()
        wg-quick strip "/etc/wireguard/$interface.conf" | net wg setconf "$interface" /dev/stdin
        net ip address add "$ipv4" dev "$interface"
        net ip -6 address add "$ipv6" dev "$interface"
        net ip link set "$interface" mtu 1380 up
    fi
    net sysctl -q -w "net.ipv4.conf.$interface.rp_filter=2"
}

relay_users_up() {
    local mode=wireguard attempt ready=0
    [[ ! -f "$config_dir/user-transport" ]] || IFS= read -r mode < "$config_dir/user-transport"
    case $mode in
        wireguard) relay_wg_up cne-users 10.77.10.1/24 fd77:77:10::1/64; return;;
        awg2) ;;
        *) printf '入口协议无效，已停止。\n' >&2; return 1;;
    esac
    if ! ip -n "$relay_ns" link show cne-users >/dev/null 2>&1; then
        # The separate foreground daemon stays in the host namespace. Both
        # startup and later UDP rebinds therefore use the host's normal route.
        # A pathname Unix UAPI socket is accessible across network namespaces.
        for attempt in $(seq 1 100); do
            if [[ -S /var/run/amneziawg/cne-users.sock ]] && \
                ip link show cne-users >/dev/null 2>&1 && \
                /opt/cn-egress/awg-0.2.16/awg show cne-users >/dev/null 2>&1; then
                ready=1; break
            fi
            sleep 0.1
        done
        [[ $ready == 1 ]] || { printf 'AmneziaWG 用户态入口未就绪，已停止。\n' >&2; return 1; }
        relay_pending+=(cne-users)
        wg-quick strip /etc/wireguard/cne-users.conf | /opt/cn-egress/awg-0.2.16/awg setconf cne-users /dev/stdin
        # The daemon observes MTU changes in its host namespace. Configure MTU
        # before moving the TUN; its polling listener handles Up across netns.
        ip link set cne-users mtu 1380
        ip link set cne-users netns "$relay_ns"
        relay_pending=()
        net ip address add 10.77.10.1/24 dev cne-users
        net ip -6 address add fd77:77:10::1/64 dev cne-users
        net ip link set cne-users up
    fi
    net sysctl -q -w net.ipv4.conf.cne-users.rp_filter=2
}

relay_down() {
    local interface
    for interface in "${relay_pending[@]}"; do
        ip link delete "$interface" 2>/dev/null || true
    done
    # Delete devices explicitly so their host UDP sockets are released.
    for interface in cne-users cne-cn cne-exit; do
        ip -n "$relay_ns" link delete "$interface" 2>/dev/null || true
    done
    ip netns delete "$relay_ns" 2>/dev/null || true
}

wg_up() {
    local interface=$1
    if ! ip link show "$interface" >/dev/null 2>&1; then
        wg-quick up "/etc/wireguard/$interface.conf"
    fi
    sysctl -q -w "net.ipv4.conf.$interface.rp_filter=2"
}

wg_down() {
    local interface=$1
    if ip link show "$interface" >/dev/null 2>&1; then
        wg-quick down "/etc/wireguard/$interface.conf"
    fi
}

rule_delete() {
    local priority=$1
    while net ip rule del priority "$priority" 2>/dev/null; do :; done
    while net ip -6 rule del priority "$priority" 2>/dev/null; do :; done
}

load_firewall() {
    local batch
    batch=$(mktemp)
    if net nft list table inet cn_egress >/dev/null 2>&1; then
        printf 'delete table inet cn_egress\n' > "$batch"
    fi
    cat "$config_dir/firewall.nft" >> "$batch"
    net nft -c -f "$batch"
    net nft -f "$batch"
    rm -f "$batch"
}

obfs_guard_up() {
    # Only the two owned relay UDP ports are restricted to loopback.
    # Existing host services and the mobile-facing HK UDP port are untouched.
    local guard=/etc/cn-egress-wss/guard.nft batch
    if [[ ! -f "$guard" ]]; then
        return
    fi
    batch=$(mktemp)
    if nft list table inet cne_wss_input >/dev/null 2>&1; then
        printf 'delete table inet cne_wss_input\n' > "$batch"
    fi
    cat "$guard" >> "$batch"
    nft -c -f "$batch"
    nft -f "$batch"
    rm -f "$batch"
}

policy_up() {
    local incoming=$1 outgoing=$2 table=$3
    rule_delete "$table"
    net ip route replace unreachable default metric 32760 table "$table"
    net ip -6 route replace unreachable default metric 32760 table "$table"
    net ip route replace default dev "$outgoing" metric 10 table "$table"
    net ip -6 route replace default dev "$outgoing" metric 10 table "$table"
    net ip rule add priority "$table" iif "$incoming" lookup "$table"
    net ip -6 rule add priority "$table" iif "$incoming" lookup "$table"
}

docker_rules_up() {
    local wan
    wan=$(cat "$config_dir/wan-interface")
    # Docker's FORWARD policy is DROP. Its documented user chain is the
    # integration point; unrelated container traffic returns unchanged.
    iptables -N CNE_VPN 2>/dev/null || true
    iptables -F CNE_VPN
    iptables -A CNE_VPN -i cne-exit -s 10.77.10.0/24 -o "$wan" -j ACCEPT
    iptables -A CNE_VPN -o cne-exit -d 10.77.10.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A CNE_VPN -i cne-exit -j DROP
    iptables -A CNE_VPN -o cne-exit -j DROP
    iptables -A CNE_VPN -j RETURN
    if iptables -S DOCKER-USER >/dev/null 2>&1; then
        iptables -C DOCKER-USER -j CNE_VPN 2>/dev/null || iptables -I DOCKER-USER 1 -j CNE_VPN
    else
        iptables -C FORWARD -j CNE_VPN 2>/dev/null || iptables -I FORWARD 1 -j CNE_VPN
    fi
}

docker_rules_down() {
    while iptables -D DOCKER-USER -j CNE_VPN 2>/dev/null; do :; done
    while iptables -D FORWARD -j CNE_VPN 2>/dev/null; do :; done
    iptables -F CNE_VPN 2>/dev/null || true
    iptables -X CNE_VPN 2>/dev/null || true
}

start_hk() {
    relay_init
    # Install the leak prevention rules before allowing VPN forwarding.
    load_firewall
    relay_wg_up cne-cn 10.77.20.1/30 fd77:77:20::1/64
    relay_users_up
    policy_up cne-users cne-cn 20770
}

start_sh() {
    relay_init
    obfs_guard_up
    load_firewall
    relay_wg_up cne-cn 10.77.20.2/30 fd77:77:20::2/64
    relay_wg_up cne-exit 10.77.30.1/30 fd77:77:30::1/64
    net ip route replace 10.77.10.0/24 dev cne-cn
    net ip -6 route replace fd77:77:10::/64 dev cne-cn
    policy_up cne-cn cne-exit 20771
}

start_exit() {
    if [[ $(sysctl -n net.ipv4.ip_forward) != 1 ]]; then
        printf '出口机尚未启用 IPv4 转发，请在安装菜单确认后启用。\n' >&2
        return 1
    fi
    load_firewall
    wg_up cne-exit
    ip route replace 10.77.10.0/24 dev cne-exit
    ip -6 route replace fd77:77:10::/64 dev cne-exit
    docker_rules_up
    # IPv6 is rejected by the owned firewall until a domestic IPv6 exit is configured.
}

stop_role() {
    case "$role" in
        hk|sh)
            relay_down
            if [[ "$role" == sh ]]; then
                nft delete table inet cne_wss_input 2>/dev/null || true
            fi
            return
            ;;
        exit)
            wg_down cne-exit
            docker_rules_down
            ;;
        *) exit 2 ;;
    esac
    nft delete table inet cn_egress 2>/dev/null || true
}

case "$action" in
    start)
        trap 'stop_role' ERR
        case "$role" in
            hk) start_hk ;;
            sh) start_sh ;;
            exit) start_exit ;;
            *) exit 2 ;;
        esac
        trap - ERR
        ;;
    stop) stop_role ;;
    *) exit 2 ;;
esac
