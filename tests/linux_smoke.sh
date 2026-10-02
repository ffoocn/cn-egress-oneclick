#!/usr/bin/env bash
# Optional real Linux integration test. No production SSH, published ports or
# host network mounts. Requires Docker and preverified native test assets.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
assets=${1:?Usage: tests/linux_smoke.sh DIRECTORY_WITH_VERIFIED_COMPONENTS}
assets=$(cd -- "$assets" && pwd -P)
arch=$(docker info --format '{{.Architecture}}')
case $arch in aarch64|arm64) arch=arm64; checksum=b86abf73e340ed0c3ff9a77a5458aa27213784920ec65513132b36def45edc94;; x86_64|amd64) arch=amd64; checksum=9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e;; *) exit 1;; esac
[[ -f $assets/amneziawg-go-$arch && -f $assets/amneziawg-tools.tar.gz && -f $assets/wstunnel_11.0.0_linux_$arch.tar.gz ]]
if command -v sha256sum >/dev/null; then digest=$(sha256sum "$assets/wstunnel_11.0.0_linux_$arch.tar.gz"); else digest=$(shasum -a 256 "$assets/wstunnel_11.0.0_linux_$arch.tar.gz"); fi
[[ ${digest%% *} == "$checksum" ]]
prefix=cne-smoke-$$-$RANDOM
containers=(); networks=()
passed=0
work=$(mktemp -d "${TMPDIR:-/tmp}/cne-linux-smoke.XXXXXXXX")
cleanup() {
    local result=$? item
    ((passed)) || result=1
    trap - EXIT
    if ((result)); then
        for item in "${containers[@]}"; do
            docker exec "$item" bash -c 'for f in /tmp/*.log; do [[ ! -f $f ]] || tail -25 "$f"; done' >&2 || :
            docker exec "$item" journalctl --no-pager -n 30 -u cn-egress.service -u cn-egress-users.service -u cn-egress-obfs.service -u cn-egress-dns.service >&2 || :
            docker exec "$item" bash -c 'wg show; if [[ -x /opt/cn-egress/awg-0.2.16/awg ]]; then /opt/cn-egress/awg-0.2.16/awg show; fi; if ip netns list | grep -q cn-egress-relay; then ip netns exec cn-egress-relay wg show; ip netns exec cn-egress-relay nft list table inet cn_egress; else nft list table inet cn_egress; fi' >&2 || :
        done
    fi
    for item in "${containers[@]}"; do docker rm -f "$item" >/dev/null || :; done
    for item in "${networks[@]}"; do docker network rm "$item" >/dev/null || :; done
    rm -rf -- "$work"
    exit "$result"
}
trap cleanup EXIT
# Benchmark-range fixture represents the WAN, separately from private relays.
docker network create --subnet 198.18.64.0/24 "$prefix-wan" >/dev/null; networks+=("$prefix-wan")
for role in hk sh exit site client; do
    network=$prefix-wan
    args=(run -d --privileged --network "$network" --name "$prefix-$role" -v "$repo:/repo:ro" -v "$assets:/assets:ro")
    case $role in hk|sh|exit) args+=(-e container=docker cn-egress-test:local /lib/systemd/systemd);; *) args+=(cn-egress-test:local sleep infinity);; esac
    docker "${args[@]}" >/dev/null
    containers+=("$prefix-$role")
done
hk=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$prefix-hk")
sh=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$prefix-sh")
site=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$prefix-site")
docker exec -i "$prefix-hk" bash -s -- "$hk" "$sh" "$arch" <<'BUILD'
set -Eeuo pipefail
source /repo/cn-egress-oneclick.sh
CNE_NODE_LIBRARY=1 source <(cne_node_source)
cne_render_bundle /tmp/bundle "$1" "$2" 51820 8443 eth0 awg2
for role in hk sh exit; do
    mkdir -p "/tmp/bundle/$role/opt/cn-egress/wstunnel-11.0.0"
    tar -xzf "/assets/wstunnel_11.0.0_linux_$3.tar.gz" -C "/tmp/bundle/$role/opt/cn-egress/wstunnel-11.0.0" wstunnel
done
mkdir -p /tmp/bundle/hk/opt/cn-egress/awg-0.2.16
cp "/assets/amneziawg-go-$3" /tmp/bundle/hk/opt/cn-egress/awg-0.2.16/amneziawg-go
cp /assets/amneziawg-tools.tar.gz /tmp/bundle/hk/opt/cn-egress/awg-0.2.16/
# Check actual complete archives before native compilation, as the installer does.
for role in hk sh exit; do
    (cd "/tmp/bundle/$role"; find . -type f | sed 's#^./##' > "/tmp/$role.files"; tar -czf "/tmp/$role.tar.gz" -T "/tmp/$role.files")
    mkdir "/tmp/validated-$role"
    cne_n_validate_archive "$role" "/tmp/$role.tar.gz" "/tmp/validated-$role"
done
cne_n_compile_tools hk /tmp/bundle/hk
BUILD
for role in hk sh exit; do
    mkdir "$work/$role"
    docker cp "$prefix-hk:/tmp/bundle/$role/." "$work/$role/" >/dev/null
    docker cp "$work/$role/." "$prefix-$role:/" >/dev/null
    docker exec "$prefix-$role" bash -c 'chown -R root:root /etc/cn-egress /etc/cn-egress-wss /etc/wireguard /etc/systemd/system/cn-egress* /usr/local/sbin/cn-egress-* /opt/cn-egress; chmod 755 /usr/local/sbin/cn-egress-* /opt/cn-egress/*/*; mkdir -p /etc/cn-egress-wss/empty-ca; ip -4 route show default > /tmp/default.before; ip -4 rule show > /tmp/rules.before'
    value=0; [[ $role != exit ]] || value=1
    docker exec "$prefix-$role" sysctl -qw "net.ipv4.ip_forward=$value"
done
docker exec "$prefix-site" bash -c 'openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=www.baidu.com -addext subjectAltName=DNS:www.baidu.com,DNS:www.qq.com -keyout /tmp/site.key -out /tmp/site.crt >/dev/null 2>&1; openssl s_server -accept 443 -key /tmp/site.key -cert /tmp/site.crt -www > /tmp/https.log 2>&1 &'
docker cp "$prefix-site:/tmp/site.crt" "$work/site.crt" >/dev/null
docker cp "$work/site.crt" "$prefix-hk:/usr/local/share/ca-certificates/cne-smoke.crt" >/dev/null
docker exec "$prefix-hk" update-ca-certificates >/dev/null 2>&1
docker cp "$prefix-site:/tmp/site.key" "$work/site.key" >/dev/null
for role in hk sh exit; do
    docker cp "$work/site.crt" "$prefix-$role:/tmp/business.crt" >/dev/null
    docker cp "$work/site.key" "$prefix-$role:/tmp/business.key" >/dev/null
    docker exec "$prefix-$role" bash -c 'nohup openssl s_server -accept 9443 -key /tmp/business.key -cert /tmp/business.crt -www > /tmp/business.log 2>&1 < /dev/null & printf "%s\n" "$!" > /tmp/business.pid'
done
docker exec -i "$prefix-exit" bash -s -- "$site" <<'DNS'
printf '\naddress=/www.baidu.com/%s\naddress=/www.qq.com/%s\n' "$1" "$1" >> /etc/cn-egress/dnsmasq.conf
DNS
for role in sh exit hk; do
    docker exec -i "$prefix-$role" bash -s <<'SERVICES'
set -Eeuo pipefail
source /repo/cn-egress-oneclick.sh
CNE_NODE_LIBRARY=1 source <(cne_node_source)
cne_n_transport_user
# Docker cp preserves restrictive renderer directory modes even over standard
# system directories. The installer creates files in the existing system tree.
chmod 755 /usr /usr/local /usr/local/sbin /etc /etc/systemd /etc/systemd/system /opt
chmod 755 /opt/cn-egress /opt/cn-egress/wstunnel-11.0.0
[[ ! -d /opt/cn-egress/awg-0.2.16 ]] || chmod 755 /opt/cn-egress/awg-0.2.16
chown root:cn-egress-wss /etc/cn-egress-wss/* 2>/dev/null || :
find /etc/cn-egress-wss -maxdepth 1 -type f -exec chmod 640 {} +
systemctl daemon-reload
cne_n_scope_check
systemctl start cn-egress.service cn-egress-obfs.service
[[ $(cat /etc/cn-egress/role) != exit ]] || systemctl start cn-egress-dns.service
systemctl is-active --quiet cn-egress.service cn-egress-obfs.service
SERVICES
done
sleep 2
docker exec "$prefix-hk" /usr/local/sbin/cn-egress-probe
docker exec -i "$prefix-hk" bash -s -- "$hk" "$sh" <<'VERIFY'
set -Eeuo pipefail
source /repo/cn-egress-oneclick.sh
CNE_NODE_LIBRARY=1 source <(cne_node_source)
CNE_HOSTS=("$1" "$2" 198.18.64.254)
cne_bootstrap() { return 0; }
cne_require_config() { return 0; }
cne_authenticate() { return 0; }
cne_remote() { local action=$2; shift 2; cne_node_main "$action" hk "$@"; }
cne_client_verify_profile /tmp/bundle/clients/iPhone.conf
VERIFY
docker cp "$prefix-hk:/tmp/bundle/clients/iPhone.conf" "$work/mobile.conf" >/dev/null
docker cp "$work/mobile.conf" "$prefix-client:/tmp/mobile.conf" >/dev/null
docker cp "$work/hk/opt/cn-egress/awg-0.2.16/awg" "$prefix-client:/usr/local/bin/awg" >/dev/null
docker cp "$work/site.crt" "$prefix-client:/usr/local/share/ca-certificates/cne-smoke.crt" >/dev/null
docker exec "$prefix-client" update-ca-certificates >/dev/null 2>&1
# The client lives outside HK and sends the actual generated mobile profile
# to HK's public-facing UDP port; only its TUN moves into a test namespace.
docker exec -i "$prefix-client" bash -s -- "$arch" <<'MOBILE'
set -Eeuo pipefail
chmod +x /usr/local/bin/awg
nohup "/assets/amneziawg-go-$1" -f cne-mobile > /tmp/mobile.log 2>&1 < /dev/null &
for i in $(seq 1 100); do [[ ! -S /var/run/amneziawg/cne-mobile.sock ]] || break; sleep 0.1; done
wg-quick strip /tmp/mobile.conf | awg setconf cne-mobile /dev/stdin
ip link set cne-mobile mtu 1380
ip netns add cn-mobile-test
ip link set cne-mobile netns cn-mobile-test
ip -n cn-mobile-test link set lo up
ip -n cn-mobile-test address add 10.77.10.10/32 dev cne-mobile
ip -n cn-mobile-test link set cne-mobile up
ip -n cn-mobile-test route add default dev cne-mobile
address=$(ip netns exec cn-mobile-test dig +time=3 +tries=1 +short @10.77.30.2 www.baidu.com A)
[[ $address =~ ^198\.18\.64\.[0-9]+$ ]]
code=$(ip netns exec cn-mobile-test curl --noproxy '*' --connect-timeout 5 --max-time 15 --resolve "www.baidu.com:443:$address" -sS -o /dev/null -w '%{http_code}' https://www.baidu.com/)
[[ $code == 200 ]]
MOBILE
# A crashed user-space entry must stop the dependent network service, remove
# the owned namespace, and recover through the same service controls users see.
docker exec "$prefix-hk" systemctl kill --signal=KILL cn-egress-users.service
docker exec "$prefix-hk" bash -c 'for i in $(seq 1 100); do if ! systemctl is-active --quiet cn-egress.service && ! ip netns list | grep -q cn-egress-relay; then exit 0; fi; sleep 0.1; done; exit 1'
docker exec "$prefix-hk" systemctl start cn-egress.service cn-egress-obfs.service
docker exec "$prefix-hk" /usr/local/sbin/cn-egress-probe
for role in hk sh exit; do
    docker exec "$prefix-$role" bash -c 'ip -4 route show default | cmp -s /tmp/default.before -; ip -4 rule show | cmp -s /tmp/rules.before -; kill -0 "$(cat /tmp/business.pid)"; [[ $(curl --noproxy "*" --cacert /tmp/business.crt --resolve www.baidu.com:9443:127.0.0.1 -sS --max-time 5 -o /dev/null -w "%{http_code}" https://www.baidu.com:9443/) == 200 ]]'
    value=0; [[ $role != exit ]] || value=1
    [[ $(docker exec "$prefix-$role" sysctl -n net.ipv4.ip_forward) == "$value" ]]
done
# Stopping the relay must fail DNS instead of falling back to HK's host WAN.
docker exec "$prefix-sh" systemctl stop cn-egress.service
docker exec "$prefix-sh" bash -c 'kill -0 "$(cat /tmp/business.pid)"; [[ $(curl --noproxy "*" --cacert /tmp/business.crt --resolve www.baidu.com:9443:127.0.0.1 -sS --max-time 5 -o /dev/null -w "%{http_code}" https://www.baidu.com:9443/) == 200 ]]'
if docker exec "$prefix-hk" /usr/local/sbin/cn-egress-probe > "$work/stopped.log" 2>&1; then cat "$work/stopped.log"; exit 1; fi
docker exec "$prefix-hk" bash -c '! ip netns list | grep -q cn-egress-check; ! ip link show cne-probe >/dev/null 2>&1'
printf 'PASS: native AWG2 mobile profile and live PSK verification + WSS/mTLS + WireGuard chain, DNS UDP/TCP, verified HTTPS, real systemd units and crash recovery, unchanged host routes/forwarding, preserved business services, failed-closed relay loss, probe cleanup\n'
passed=1
