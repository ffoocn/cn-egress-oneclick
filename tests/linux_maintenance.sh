#!/usr/bin/env bash
# Optional isolated Linux/systemd test for real node maintenance APIs.
# Requires Docker and the verified native wstunnel archive, never production SSH.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
assets=${1:?Usage: tests/linux_maintenance.sh VERIFIED_COMPONENT_DIRECTORY}
assets=$(cd -- "$assets" && pwd -P)
arch=$(docker info --format '{{.Architecture}}')
case $arch in
    aarch64|arm64) arch=arm64; checksum=b86abf73e340ed0c3ff9a77a5458aa27213784920ec65513132b36def45edc94;;
    x86_64|amd64) arch=amd64; checksum=9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e;;
    *) exit 1;;
esac
archive="$assets/wstunnel_11.0.0_linux_$arch.tar.gz"
[[ -f $archive ]]
if command -v sha256sum >/dev/null; then digest=$(sha256sum "$archive"); else digest=$(shasum -a 256 "$archive"); fi
[[ ${digest%% *} == "$checksum" ]]
name=cne-maintenance-$$-$RANDOM
started=0
cleanup() {
    local result=$?
    trap - EXIT
    if ((started)); then
        if ((result)); then docker exec "$name" journalctl --no-pager -n 30 -u cn-egress.service -u cn-egress-obfs.service >&2 || :; fi
        docker rm -f "$name" >/dev/null || :
    fi
    exit "$result"
}
trap cleanup EXIT
docker run -d --privileged --name "$name" -e container=docker -v "$repo:/repo:ro" -v "$assets:/assets:ro" "${CNE_TEST_IMAGE:-cne-maintenance-test:local}" /lib/systemd/systemd >/dev/null
started=1
docker exec -i "$name" bash -s -- "$arch" <<'LINUX'
set -Eeuo pipefail
trap 'printf "Linux maintenance test failed at line %s\n" "$LINENO" >&2' ERR
source /repo/cn-egress-oneclick.sh
source /repo/shell/render.sh
export CNE_NODE_LIBRARY=1
source /repo/shell/node.sh
cne_render_bundle /tmp/bundle 192.0.2.10 192.0.2.20 51820 8443 eth0 wireguard
cp -a /tmp/bundle/hk/. /
# The installer copies files into the existing system tree; fixture directory
# copies must not replace normal parent traversal permissions with staging 0700.
chmod 755 / /usr /usr/local /usr/local/sbin /etc /etc/systemd /etc/systemd/system /opt
mkdir -p /opt/cn-egress/wstunnel-11.0.0
chmod 755 /opt/cn-egress /opt/cn-egress/wstunnel-11.0.0
tar -xzf "/assets/wstunnel_11.0.0_linux_$1.tar.gz" -C /opt/cn-egress/wstunnel-11.0.0 wstunnel
chmod 755 /opt/cn-egress/wstunnel-11.0.0/wstunnel
cne_n_deployment_mark deployment-original
cne_n_transport_user
chown root:cn-egress-wss /etc/cn-egress-wss/{role,sh-host,port,ca.crt,node.crt,node.key}
systemctl daemon-reload
systemctl enable cn-egress.service cn-egress-obfs.service >/dev/null
systemctl start cn-egress.service cn-egress-obfs.service
systemctl is-active --quiet cn-egress.service
systemctl is-active --quiet cn-egress-obfs.service
ip -4 route show default > /tmp/default.before
ip -4 rule show > /tmp/rules.before
cat /proc/sys/net/ipv4/ip_forward > /tmp/forwarding.before
ip netns exec cn-egress-relay wg show all public-key > /tmp/wg-public.before
sha256sum /etc/wireguard/cne-{users,cn}.conf > /tmp/wg-files.before
mkdir /tmp/business-files
printf 'business data unchanged\n' > /tmp/business-files/settings.conf
sha256sum /tmp/business-files/settings.conf > /tmp/business-files.before
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -keyout /tmp/business.key -out /tmp/business.crt >/dev/null 2>&1
nohup openssl s_server -accept 9443 -key /tmp/business.key -cert /tmp/business.crt -www >/tmp/business.log 2>&1 </dev/null &
business_pid=$!
curl --noproxy '*' -ksf --retry 3 --retry-connrefused --retry-delay 1 --max-time 5 https://127.0.0.1:9443/ >/dev/null
original=$(cne_node_main backup hk)
cne_node_main backup-export hk "$original" > /tmp/export.base64
base64 -d /tmp/export.base64 > /tmp/export.tar.gz
cmp -s "$original" /tmp/export.tar.gz
chmod 600 /tmp/export.tar.gz
cne_render_pki /tmp/new-pki 192.0.2.20
mkdir /tmp/certificate-stage
cp /tmp/new-pki/ca.crt /tmp/certificate-stage/ca.crt
cp /tmp/new-pki/hk.crt /tmp/certificate-stage/node.crt
cp /tmp/new-pki/hk.key /tmp/certificate-stage/node.key
tar -czf /tmp/certificate.tar.gz -C /tmp/certificate-stage ca.crt node.crt node.key
chmod 600 /tmp/certificate.tar.gz
before_info=$(cne_node_main maintenance-info hk)
before_config=$(sed -n 's/^config_sha256=//p' <<< "$before_info")
before_tls=$(sed -n 's/^tls_sha256=//p' <<< "$before_info")
! cne_node_main certificate-apply hk /tmp/certificate.tar.gz deployment-other operation-rejected >/dev/null 2>&1
[[ $(cne_node_main maintenance-info hk) == "$before_info" ]]
cp /tmp/new-pki/ca.key /tmp/certificate-stage/ca.key
tar -czf /tmp/invalid-cert.tar.gz -C /tmp/certificate-stage ca.crt node.crt node.key ca.key
chmod 600 /tmp/invalid-cert.tar.gz
! cne_node_main certificate-apply hk /tmp/invalid-cert.tar.gz deployment-original operation-invalid >/dev/null 2>&1
[[ $(cne_node_main maintenance-info hk) == "$before_info" ]]
cne_node_main certificate-apply hk /tmp/certificate.tar.gz deployment-original operation-renew
after_info=$(cne_node_main maintenance-info hk)
[[ $(sed -n 's/^config_sha256=//p' <<< "$after_info") == "$before_config" ]]
[[ $(sed -n 's/^tls_sha256=//p' <<< "$after_info") != "$before_tls" ]]
sha256sum -c /tmp/wg-files.before >/dev/null
ip netns exec cn-egress-relay wg show all public-key > /tmp/wg-public.after
cmp -s /tmp/wg-public.before /tmp/wg-public.after
systemctl is-active --quiet cn-egress.service
systemctl is-active --quiet cn-egress-obfs.service
[[ $(systemctl is-enabled cn-egress-obfs.service) == enabled ]]
kill -0 "$business_pid"
curl --noproxy '*' -ksf --max-time 5 https://127.0.0.1:9443/ >/dev/null

# Restoring a history set leaves the new transaction marker committed; undoing
# an interrupted manager transaction still accepts the same operation marker.
renew_snapshot=$(cne_node_main backup hk)
cne_node_main restore-import hk /tmp/export.tar.gz "${original##*/}" operation-renew operation-history
[[ $(cne_n_deployment_read) == operation-history ]]
cmp -s /tmp/bundle/pki/hk.crt /etc/cn-egress-wss/node.crt
cne_node_main restore hk "$renew_snapshot" operation-history
[[ $(cne_n_deployment_read) == operation-renew ]]
cmp -s /tmp/new-pki/hk.crt /etc/cn-egress-wss/node.crt

# Do not accidentally start services an administrator deliberately stopped.
systemctl stop cn-egress-obfs.service
systemctl disable cn-egress-obfs.service >/dev/null
cne_node_main certificate-apply hk /tmp/certificate.tar.gz operation-renew operation-stopped
[[ $(systemctl is-active cn-egress-obfs.service || :) == inactive ]]
[[ $(systemctl is-enabled cn-egress-obfs.service || :) == disabled ]]
systemctl is-active --quiet cn-egress.service
stopped_snapshot=$(cne_node_main backup hk)
cp "$stopped_snapshot" /tmp/stopped-export.tar.gz
chmod 600 /tmp/stopped-export.tar.gz
systemctl start cn-egress-obfs.service
systemctl enable cn-egress-obfs.service >/dev/null
cne_node_main restore-import hk /tmp/stopped-export.tar.gz "${stopped_snapshot##*/}" operation-stopped operation-stopped-history
systemctl is-active --quiet cn-egress.service
[[ $(systemctl is-active cn-egress-obfs.service || :) == inactive ]]
[[ $(systemctl is-enabled cn-egress-obfs.service || :) == disabled ]]

ip -4 route show default > /tmp/default.after
ip -4 rule show > /tmp/rules.after
cat /proc/sys/net/ipv4/ip_forward > /tmp/forwarding.after
cmp -s /tmp/default.before /tmp/default.after
cmp -s /tmp/rules.before /tmp/rules.after
cmp -s /tmp/forwarding.before /tmp/forwarding.after
sha256sum -c /tmp/wg-files.before /tmp/business-files.before >/dev/null
kill -0 "$business_pid"
curl --noproxy '*' -ksf --max-time 5 https://127.0.0.1:9443/ >/dev/null
printf 'PASS: real Linux/systemd certificate apply, stopped transport state, backup export/import and guarded undo; WG keys, default routes, forwarding and unrelated HTTPS/files preserved; malformed payload and deployment drift rejected before mutation\n'
LINUX
