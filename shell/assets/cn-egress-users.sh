#!/usr/bin/env bash
# Keep the first-hop UDP sockets in the host namespace. cn-egress-net moves
# only the TUN into the isolated relay after configuring the userspace daemon.
set -Eeuo pipefail
[[ ${1:-start} == start ]] || { printf '用法：cn-egress-users start\n' >&2; exit 2; }
[[ $(cat /etc/cn-egress/user-transport) == awg2 ]]
[[ -c /dev/net/tun ]] || { printf 'AmneziaWG 需要 /dev/net/tun。\n' >&2; exit 1; }
exec env WG_PROCESS_FOREGROUND=1 LOG_LEVEL=error \
    /opt/cn-egress/awg-0.2.16/amneziawg-go -f cne-users
