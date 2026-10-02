#!/usr/bin/env bash
# Exercise a reserved client through the configured chain, without changing
# the host's routes or resolver. Never remove an existing network object.
set -Eeuo pipefail

cne_probe_cleanup() {
    local code=$?
    trap - EXIT HUP INT TERM
    if [[ ${CNE_PROBE_NS_CREATED:-0} == 1 ]]; then
        ip -n cn-egress-check link delete cne-probe 2>/dev/null || :
        ip netns delete cn-egress-check 2>/dev/null || :
    fi
    if [[ ${CNE_PROBE_HOST_CREATED:-0} == 1 ]]; then ip link delete cne-probe 2>/dev/null || :; fi
    if [[ -n ${CNE_PROBE_PID:-} ]]; then kill "$CNE_PROBE_PID" 2>/dev/null || :; wait "$CNE_PROBE_PID" 2>/dev/null || :; fi
    [[ -z ${CNE_PROBE_WORK:-} ]] || rm -rf -- "$CNE_PROBE_WORK"
    exit "$code"
}

cne_probe_ipv4() {
    local octet value=$1
    [[ $value =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=.
    for octet in $value; do ((10#$octet<=255)) || return 1; done
}

cne_probe_dns() {
    local domain=$1 response udp tcp value
    response=$(ip netns exec cn-egress-check dig +time=3 +tries=1 +noall +comments +answer @10.77.30.2 "$domain" A) || { printf 'DNS UDP 查询失败：%s。\n' "$domain" >&2; return 1; }
    [[ $response == *'status: NOERROR,'* ]] || { printf 'DNS UDP 应答异常：%s。\n%s\n' "$domain" "$response" >&2; return 1; }
    udp=$(awk '$4=="A" {print $5;exit}' <<< "$response")
    cne_probe_ipv4 "$udp" || { printf 'DNS UDP 没有有效 IPv4 记录：%s。\n%s\n' "$domain" "$response" >&2; return 1; }
    response=$(ip netns exec cn-egress-check dig +tcp +time=3 +tries=1 +noall +comments +answer @10.77.30.2 "$domain" A) || { printf 'DNS TCP 查询失败：%s。\n' "$domain" >&2; return 1; }
    [[ $response == *'status: NOERROR,'* ]] || { printf 'DNS TCP 应答异常：%s。\n%s\n' "$domain" "$response" >&2; return 1; }
    tcp=$(awk '$4=="A" {print $5;exit}' <<< "$response")
    cne_probe_ipv4 "$tcp" || { printf 'DNS TCP 没有有效 IPv4 记录：%s。\n' "$domain" >&2; return 1; }
    printf '%s\n' "$udp"
}

cne_probe_main() {
    local config=/etc/cn-egress/probe.conf mode=wireguard control attempt ready=0 domain address code port
    [[ $EUID == 0 ]] || { printf '全链探测需要 root。\n' >&2; return 1; }
    [[ -f $config && ! -L $config && -O $config ]] || { printf '缺少受保护的诊断客户端配置。\n' >&2; return 1; }
    [[ ! -L /run/cn-egress-probe.lock ]] || return 1
    exec 9> /run/cn-egress-probe.lock
    flock -n 9 || { printf '已有全链探测在运行。\n' >&2; return 1; }
    if ip netns list | awk '{print $1}' | grep -qx cn-egress-check || ip link show cne-probe >/dev/null 2>&1 || [[ -e /var/run/amneziawg/cne-probe.sock ]]; then
        printf '诊断名称已被占用，未修改现有网络对象。\n' >&2; return 1
    fi
    [[ ! -f /etc/cn-egress/user-transport ]] || IFS= read -r mode < /etc/cn-egress/user-transport
    # Loopback deliberately tests the protocol and full relay path from HK.
    # An external phone is still needed to test public UDP reachability.
    port=$(awk '$1=="Endpoint" {print $3}' "$config")
    [[ $port =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]] && ((10#${BASH_REMATCH[1]}>=1 && 10#${BASH_REMATCH[1]}<=65535)) || { printf '诊断入口配置无效。\n' >&2; return 1; }
    umask 077
    CNE_PROBE_WORK=$(mktemp -d /run/cn-egress-check.XXXXXXXX)
    CNE_PROBE_NS_CREATED=0; CNE_PROBE_HOST_CREATED=0; CNE_PROBE_PID=''
    trap cne_probe_cleanup EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    wg-quick strip "$config" > "$CNE_PROBE_WORK/peer.conf"
    case $mode in
        wireguard)
            control=wg
            ip link add cne-probe type wireguard
            CNE_PROBE_HOST_CREATED=1
            wg setconf cne-probe "$CNE_PROBE_WORK/peer.conf"
            ;;
        awg2)
            control=/opt/cn-egress/awg-0.2.16/awg
            [[ -c /dev/net/tun ]] || { printf '诊断需要 /dev/net/tun。\n' >&2; return 1; }
            env WG_PROCESS_FOREGROUND=1 LOG_LEVEL=error /opt/cn-egress/awg-0.2.16/amneziawg-go -f cne-probe > "$CNE_PROBE_WORK/engine.log" 2>&1 &
            CNE_PROBE_PID=$!
            for attempt in $(seq 1 100); do
                kill -0 "$CNE_PROBE_PID" 2>/dev/null || break
                if [[ -S /var/run/amneziawg/cne-probe.sock ]] && ip link show cne-probe >/dev/null 2>&1 && "$control" show cne-probe >/dev/null 2>&1; then ready=1; break; fi
                sleep 0.1
            done
            [[ $ready == 1 ]] || { printf '诊断混淆客户端未就绪。\n' >&2; return 1; }
            CNE_PROBE_HOST_CREATED=1
            "$control" setconf cne-probe "$CNE_PROBE_WORK/peer.conf"
            ;;
        *) printf '诊断入口协议未知。\n' >&2; return 1;;
    esac
    ip link set cne-probe mtu 1380
    ip netns add cn-egress-check
    CNE_PROBE_NS_CREATED=1
    ip link set cne-probe netns cn-egress-check
    CNE_PROBE_HOST_CREATED=0
    ip -n cn-egress-check link set lo up
    ip -n cn-egress-check address add 10.77.10.250/32 dev cne-probe
    ip -n cn-egress-check link set cne-probe up
    ip -n cn-egress-check route add default dev cne-probe
    # Fixed sites, bounded DNS/HTTPS deadlines, and normal certificate checks.
    # curl gets a DNS answer from the exit, rather than the host resolver.
    for domain in www.baidu.com www.qq.com; do
        if address=$(cne_probe_dns "$domain") && code=$(ip netns exec cn-egress-check curl --noproxy '*' -4 -sS --connect-timeout 5 --max-time 15 --resolve "$domain:443:$address" -o /dev/null -w '%{http_code}' "https://$domain/") && [[ $code =~ ^[23][0-9]{2}$ ]]; then
            printf '模拟客户端：DNS（UDP/TCP）和 HTTPS 经配置链路访问成功（%s，HTTP %s）。\n' "$domain" "$code"
            printf '公网到香港入口还需用手机或 Windows 导入配置验证。\n'
            return 0
        fi
    done
    printf '模拟客户端的 DNS 或 HTTPS 访问失败，链路尚未验证通过。\n' >&2
    return 1
}

if [[ ${CNE_PROBE_LIBRARY:-0} != 1 ]]; then cne_probe_main "$@"; fi
