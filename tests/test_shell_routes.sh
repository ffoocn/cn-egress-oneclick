#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
CNE_NODE_LIBRARY=1 source shell/node.sh
ip() {
    case "$*" in
        '-4 route show table all') printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'; [[ ${test_owned:-0} != 1 ]] || printf '10.77.10.0/24 dev cne-exit\n';;
        '-6 route show table all') printf 'default via %s dev eth0 proto ra expires %ssec pref medium\n' "$test_gateway" "$test_lifetime";;
        '-4 rule show'|'-6 rule show') printf '32766: from all lookup main\n';;
        *) return 1;;
    esac
}
cat() { case "$1" in /proc/sys/net/ipv4/ip_forward) printf '1\n';; /proc/sys/net/ipv6/conf/all/forwarding) printf '0\n';; *) command cat "$@";; esac; }
test_gateway=fe80::1; test_lifetime=1800; test_owned=0
before=$(cne_n_route_snapshot exit)
test_lifetime=1790; test_owned=1
[[ $(cne_n_route_snapshot exit) == "$before" ]]
printf 'PASS: RA countdown and owned exit return route do not cause false rollback\n'
test_gateway=fe80::2
[[ $(cne_n_route_snapshot exit) != "$before" ]]
printf 'PASS: a real host default gateway change is still detected\n'
