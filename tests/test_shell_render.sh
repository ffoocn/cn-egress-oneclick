#!/usr/bin/env bash
# Renderer tests use real OpenSSL and a format-compatible WireGuard command stub.
# They do not configure interfaces, change host services, or require Python.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-render-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
cd "$ROOT"
source shell/render.sh
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing expected text in ${1##*/}"; }
cne_net_source() { cat shell/assets/cn-egress-net.sh; }
cne_obfs_source() { cat shell/assets/cn-egress-obfs.sh; }
cne_restrictions_source() { cat shell/assets/restrictions.yaml; }
cne_node_source() { printf '#!/usr/bin/env bash\nexit 0\n'; }
mkdir "$WORK/bin"
cat > "$WORK/bin/wg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
    genkey|genpsk) openssl rand -base64 32 ;;
    pubkey) openssl dgst -sha256 -binary | openssl base64 -A; printf '\n' ;;
    *) exit 1 ;;
esac
SH
chmod 700 "$WORK/bin/wg"
export PATH="$WORK/bin:$PATH"

bash -n shell/render.sh
bash -n shell/assets/cn-egress-net.sh
bash -n shell/assets/cn-egress-obfs.sh
cne_render_bundle "$WORK/bundle" 203.0.113.10 198.51.100.20 51820 443 eth0
[[ $(find "$WORK/bundle/clients" -type f | wc -l | tr -d ' ') == 3 ]] || fail 'three client profiles expected'
[[ $(wc -l < "$WORK/bundle/client-registry.tsv" | tr -d ' ') == 3 ]] || fail 'three registered clients expected'
cmp "$WORK/bundle/client-registry.tsv" "$WORK/bundle/hk/etc/cn-egress/clients.tsv"
for role in hk sh exit; do
    openssl verify -CAfile "$WORK/bundle/pki/ca.crt" "$WORK/bundle/$role/etc/cn-egress-wss/node.crt" >/dev/null
    [[ ! -e $WORK/bundle/$role/etc/cn-egress-wss/ca.key ]] || fail 'private CA key included in node bundle'
    [[ $(mode_of "$WORK/bundle/$role/etc/cn-egress-wss/node.key") == 640 ]] || fail 'node key mode'
    [[ $(mode_of "$WORK/bundle/$role/usr/local/sbin/cn-egress-node") == 755 ]] || fail 'node script mode'
    bash -n "$WORK/bundle/$role/usr/local/sbin/cn-egress-net"
    bash -n "$WORK/bundle/$role/usr/local/sbin/cn-egress-obfs"
done
[[ $(mode_of "$WORK/bundle/pki/ca.key") == 600 ]] || fail 'private CA mode'
[[ $(mode_of "$WORK/bundle/hk/etc/wireguard/cne-users.conf") == 600 ]] || fail 'WireGuard config mode'
openssl x509 -in "$WORK/bundle/pki/sh.crt" -text -noout > "$WORK/sh-cert"
openssl x509 -in "$WORK/bundle/pki/hk.crt" -text -noout > "$WORK/hk-cert"
assert_contains "$WORK/sh-cert" 'IP Address:198.51.100.20'
assert_contains "$WORK/sh-cert" 'TLS Web Server Authentication'
assert_contains "$WORK/hk-cert" 'TLS Web Client Authentication'
for client in iPhone Android Windows; do
    assert_contains "$WORK/bundle/clients/$client.conf" 'AllowedIPs = 0.0.0.0/0, ::/0'
    assert_contains "$WORK/bundle/clients/$client.conf" 'Endpoint = 203.0.113.10:51820'
    assert_contains "$WORK/bundle/clients/$client.conf" "PublicKey = $(cat "$WORK/bundle/keys/hk_users.pub")"
    [[ $(mode_of "$WORK/bundle/clients/$client.conf") == 600 ]] || fail 'client profile mode'
done
assert_contains "$WORK/bundle/hk/etc/wireguard/cne-cn.conf" "PublicKey = $(cat "$WORK/bundle/keys/sh_cn.pub")"
assert_contains "$WORK/bundle/sh/etc/wireguard/cne-cn.conf" "PublicKey = $(cat "$WORK/bundle/keys/hk_cn.pub")"
assert_contains "$WORK/bundle/exit/etc/cn-egress/firewall.nft" 'iifname "cne-exit" ip saddr 10.77.10.0/24 oifname "eth0" counter masquerade'
assert_contains "$WORK/bundle/exit/etc/cn-egress/firewall.nft" 'iifname "cne-exit" meta nfproto ipv6 counter reject'
assert_contains shell/assets/cn-egress-net.sh 'net sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1'
if grep -Eq '^[[:space:]]*sysctl .*net\.(ipv4\.ip_forward|ipv6\.conf\.all\.forwarding)=' shell/assets/cn-egress-net.sh; then fail 'host-wide forwarding modified by network script'; fi
if grep -Erq 'python|\.py([[:space:]]|$)' "$WORK/bundle/hk" "$WORK/bundle/sh" "$WORK/bundle/exit"; then fail 'Python runtime artifact present'; fi
printf 'PASS: bundle structure, real mTLS chain/SAN/EKU, permissions and routing scope\n'

if cne_render_bundle "$WORK/bundle" 203.0.113.10 198.51.100.20 51820 443 eth0 2>/dev/null; then fail 'existing output overwritten'; fi
for bad_host in '999.1.1.1' '01.1.1.1' 'bad..example' '-bad.example' 'bad;id'; do
    if cne_render_bundle "$WORK/invalid" "$bad_host" 198.51.100.20 51820 443 eth0 2>/dev/null; then fail 'invalid host accepted'; fi
    [[ ! -e $WORK/invalid ]] || fail 'created files before input validation'
done
if cne_render_bundle "$WORK/invalid" 203.0.113.10 198.51.100.20 65536 443 eth0 2>/dev/null; then fail 'invalid port accepted'; fi
if cne_render_bundle "$WORK/invalid" 203.0.113.10 198.51.100.20 51820 443 'eth0;id' 2>/dev/null; then fail 'invalid WAN accepted'; fi
printf 'PASS: input validation and overwrite guard\n'

# Exercise the conditional call path: Bash must not swallow a failed PKI step.
mkdir "$WORK/failure-bin"
cat > "$WORK/failure-bin/openssl" <<'SH'
#!/usr/bin/env bash
exit 93
SH
chmod 700 "$WORK/failure-bin/openssl"
if PATH="$WORK/failure-bin:$PATH" cne_render_bundle "$WORK/failure" 203.0.113.10 198.51.100.20 51820 443 eth0; then fail 'OpenSSL failure swallowed in conditional call'; fi
[[ ! -e $WORK/failure/hk ]] || fail 'continued generating nodes after PKI failure'
printf 'PASS: conditional failure stops generation\n'
printf 'Renderer tests passed. WireGuard is stubbed; OpenSSL signing and validation are real.\n'
