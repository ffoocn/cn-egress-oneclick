#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
CNE_PROBE_LIBRARY=1 source shell/assets/cn-egress-probe.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/cne-probe-test.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
count=0
ok() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
ip() {
    printf '%s\n' "$*" >> "$work/ip.log"
    if [[ $* == *' dig '* ]]; then
        [[ ${dns_failure:-none} != tcp || $* != *' +tcp '* ]] || return 1
        case ${dns_failure:-none} in
            nxdomain) printf ';; status: NXDOMAIN, id: 1\n';;
            empty) printf ';; status: NOERROR, id: 1\n';;
            malformed) printf ';; status: NOERROR, id: 1\nwww.example.com. 30 IN A 999.2.3.4\n';;
            *) printf ';; status: NOERROR, id: 1\nwww.example.com. 30 IN CNAME edge.example.com.\nedge.example.com. 30 IN A 192.0.2.4\n';;
        esac
    fi
}
dns_failure=none
[[ $(cne_probe_dns www.example.com) == 192.0.2.4 ]] || fail valid-dns
[[ $(wc -l < "$work/ip.log" | tr -d ' ') == 2 ]] && grep -q ' +tcp ' "$work/ip.log" || fail tcp-not-checked
ok 'DNS success requires actual UDP and TCP answers from the exit address'
for dns_failure in tcp nxdomain empty malformed; do
    ! cne_probe_dns www.example.com >/dev/null 2>&1 || fail "$dns_failure"
done
ok 'TCP failures, NXDOMAIN, empty answers and invalid addresses fail the probe'
! cne_probe_ipv4 '192.0.2.4;true' && ! cne_probe_ipv4 '256.0.0.1' && cne_probe_ipv4 192.0.2.4 || fail ipv4
ok 'Only IPv4 data can reach curl --resolve'
: > "$work/ip.log"
(
    CNE_PROBE_NS_CREATED=0 CNE_PROBE_HOST_CREATED=0 CNE_PROBE_PID='' CNE_PROBE_WORK=''
    cne_probe_cleanup
)
[[ ! -s $work/ip.log ]] || fail unowned-cleanup
ok 'Cleanup leaves pre-existing namespace and interface names untouched'
(
    CNE_PROBE_NS_CREATED=1 CNE_PROBE_HOST_CREATED=0 CNE_PROBE_PID='' CNE_PROBE_WORK=''
    cne_probe_cleanup
)
[[ $(cat "$work/ip.log") == $'-n cn-egress-check link delete cne-probe\nnetns delete cn-egress-check' ]] || fail owned-cleanup
ok 'A created probe removes only its temporary interface and namespace'
printf '%s probe tests passed.\n' "$count"
