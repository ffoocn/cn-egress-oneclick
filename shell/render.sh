#!/usr/bin/env bash
# Pure Bash configuration renderer. Sourcing this file has no side effects.

cne_render_error() { printf '配置生成失败：%s\n' "$*" >&2; return 1; }

cne_render_host() {
    local value=$1 label octet
    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && ${#value} -le 253 ]] || return 1
    if [[ $value =~ ^[0-9.]+$ ]]; then
        [[ $value =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
        local IFS=.
        for octet in $value; do
            (( 10#$octet <= 255 )) || return 1
            [[ $octet == 0 || $octet != 0* ]] || return 1
        done
    else
        [[ $value != *. && $value != *..* ]] || return 1
        local IFS=.
        for label in $value; do
            [[ ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
        done
    fi
}

cne_render_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

cne_render_key() { [[ $1 =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; }

# Validate and normalize the complete shared AWG2 block without evaluating it.
cne_render_awg_params() (
    local file=$1 line key value seen=' ' count=0 minimum='' maximum='' index other start end
    local starts=() ends=()
    [[ -f $file && ! -L $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^(Jc|Jmin|Jmax|S[1-4]|H[1-4])[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]] || return 1
        key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
        [[ $seen != *" $key "* ]] || return 1
        seen+="$key "; count=$((count+1))
        case $key in
            H*)
                [[ $value =~ ^([1-9][0-9]{0,9})(-([1-9][0-9]{0,9}))?$ ]] || return 1
                start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[3]:-$start}
                (( start <= end && end <= 4294967295 )) || return 1
                index=${key#H}; starts[$index]=$start; ends[$index]=$end
                ;;
            *)
                [[ $value =~ ^(0|[1-9][0-9]{0,3})$ ]] || return 1
                case $key in
                    Jc) (( value <= 12 )) || return 1;;
                    Jmin) (( value >= 1 && value < 1400 )) || return 1; minimum=$value;;
                    Jmax) (( value >= 1 && value < 1400 )) || return 1; maximum=$value;;
                    S*) (( value >= 1 && value <= 128 )) || return 1;;
                esac
                ;;
        esac
    done < "$file"
    [[ $count == 11 ]] && (( minimum <= maximum )) || return 1
    for index in 1 2 3 4; do
        for other in 1 2 3 4; do
            (( index >= other )) && continue
            (( ends[index] < starts[other] || ends[other] < starts[index] )) || return 1
        done
    done
    # Only the validated data block is passed to awg and client importers.
    cat "$file"
)

cne_render_awg_generate() {
    local index random start
    printf 'Jc = 6\nJmin = 40\nJmax = 700\n'
    for index in 1 2 3 4; do
        random=$(openssl rand -hex 4) || return 1
        case $index in
            1|2) printf 'S%s = %s\n' "$index" "$((16#$random % 49 + 32))";;
            3) printf 'S3 = %s\n' "$((16#$random % 17 + 16))";;
            4) printf 'S4 = %s\n' "$((16#$random % 9 + 8))";;
        esac
    done
    for index in 1 2 3 4; do
        random=$(openssl rand -hex 4) || return 1
        start=$(( (index-1) * 1000000000 + 100000000 + 16#$random % 600000000 ))
        printf 'H%s = %s-%s\n' "$index" "$start" "$((start+1023))"
    done
}

# FILE ADDRESS PRIVATE_KEY SERVER_PUBLIC_KEY PSK HK_HOST USER_PORT [MODE PARAM_FILE]
cne_render_client() (
    set -euo pipefail
    umask 077
    local file=$1 number=$2 private=$3 public=$4 psk=$5 host=$6 port=$7 mode=${8:-wireguard} params=${9:-} block=''
    [[ $number =~ ^[0-9]{1,3}$ ]] && (( 10#$number >= 2 && 10#$number <= 250 )) || { cne_render_error '客户端地址须为 2 到 250（250 保留给诊断）'; exit 1; }
    number=$((10#$number))
    cne_render_key "$private" && cne_render_key "$public" && cne_render_key "$psk" || { cne_render_error 'WireGuard 密钥格式无效'; exit 1; }
    cne_render_host "$host" && cne_render_port "$port" || { cne_render_error '香港地址或端口无效'; exit 1; }
    case $mode in
        wireguard) ;;
        awg2) block=$(cne_render_awg_params "$params") || { cne_render_error 'AmneziaWG 参数无效'; exit 1; };;
        *) cne_render_error '入口协议无效'; exit 1;;
    esac
    [[ ! -e $file && ! -L $file ]] || { cne_render_error '客户端配置已存在'; exit 1; }
    set -o noclobber
    cat > "$file" <<EOF
[Interface]
PrivateKey = $private
Address = 10.77.10.$number/32, fd77:77:10::$number/128
DNS = 10.77.30.2
MTU = 1380
EOF
    [[ -z $block ]] || printf '%s\n' "$block" >> "$file"
    cat >> "$file" <<EOF

[Peer]
PublicKey = $public
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $host:$port
PersistentKeepalive = 25
EOF
)

cne_render_interface() {
    local private=$1 addresses=$2 port=${3:-}
    printf '[Interface]\nPrivateKey = %s\nAddress = %s\nMTU = 1380\nTable = off\n' "$private" "$addresses"
    [[ -z $port ]] || printf 'ListenPort = %s\n' "$port"
    return 0
}

cne_render_peer() {
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\n' "$1" "$2" "$3"
    [[ -z ${4:-} ]] || printf 'Endpoint = %s\nPersistentKeepalive = 25\n' "$4"
    return 0
}

cne_render_relay_firewall() {
    cat <<EOF
table inet cn_egress {
  chain input_guard {
    type filter hook input priority -5; policy accept;
    iifname { "$1", "$2" } meta l4proto { icmp, ipv6-icmp } accept
    iifname { "$1", "$2" } counter drop
  }
  chain forward_guard {
    type filter hook forward priority -5; policy accept;
    iifname "$1" meta nfproto ipv4 ip saddr != 10.77.10.0/24 counter drop
    iifname "$1" meta nfproto ipv6 ip6 saddr != fd77:77:10::/64 counter drop
    iifname "$1" oifname "$2" counter accept
    iifname "$2" oifname "$1" ct state established,related counter accept
    iifname { "$1", "$2" } counter drop
    oifname { "$1", "$2" } counter drop
  }
}
EOF
}

cne_render_exit_firewall() {
    local dns=${2:-5354}
    cne_render_port "$dns" || return 1
    cat <<EOF
table inet cn_egress {
  chain input_guard {
    type filter hook input priority -5; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 udp dport $dns counter accept
    iifname "cne-exit" ip saddr 10.77.10.0/24 tcp dport $dns counter accept
    iifname "cne-exit" meta l4proto { icmp, ipv6-icmp } accept
    iifname "cne-exit" counter drop
  }
  chain forward_guard {
    type filter hook forward priority -5; policy accept;
    iifname "cne-exit" meta nfproto ipv6 counter reject with icmpv6 type admin-prohibited
    iifname "cne-exit" ip saddr != 10.77.10.0/24 counter drop
    iifname "cne-exit" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } counter reject with icmp type admin-prohibited
    iifname "cne-exit" oifname "$1" counter accept
    oifname "cne-exit" ct state established,related counter accept
    iifname "cne-exit" counter drop
    oifname "cne-exit" counter drop
  }
  chain nat_out {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 oifname "$1" counter masquerade
  }
  chain dns_redirect {
    type nat hook prerouting priority dstnat - 5; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 ip daddr 10.77.30.2 udp dport 53 counter redirect to :$dns
    iifname "cne-exit" ip saddr 10.77.10.0/24 ip daddr 10.77.30.2 tcp dport 53 counter redirect to :$dns
  }
}
EOF
}

cne_render_pki() (
    set -euo pipefail
    umask 077
    local directory=$1 host=$2 role serial san usage
    mkdir "$directory"
    cat > "$directory/ca.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
x509_extensions = ca
[subject]
CN = cn-egress-private-ca
[ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$directory/ca.key" 2>/dev/null
    openssl req -new -x509 -sha256 -days 3650 -key "$directory/ca.key" -out "$directory/ca.crt" -config "$directory/ca.cnf" -extensions ca 2>/dev/null
    for role in hk sh exit; do
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$directory/$role.key" 2>/dev/null
        openssl req -new -sha256 -key "$directory/$role.key" -out "$directory/$role.csr" -subj "/CN=cn-egress-$role" 2>/dev/null
        usage=clientAuth
        [[ $role != sh ]] || usage=serverAuth
        cat > "$directory/$role.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
extendedKeyUsage = $usage
EOF
        if [[ $role == sh ]]; then
            san=DNS
            [[ ! $host =~ ^[0-9.]+$ ]] || san=IP
            printf 'subjectAltName = %s:%s\n' "$san" "$host" >> "$directory/$role.cnf"
        fi
        serial=$(openssl rand -hex 19)
        openssl x509 -req -sha256 -days 730 -in "$directory/$role.csr" -CA "$directory/ca.crt" -CAkey "$directory/ca.key" -set_serial "0x$serial" -extfile "$directory/$role.cnf" -out "$directory/$role.crt" 2>/dev/null
        rm -f "$directory/$role.csr" "$directory/$role.cnf"
    done
    rm -f "$directory/ca.cnf"
)

cne_render_services() {
    local root=$1 role=$2 mode=${3:-wireguard} after=network-online.target
    [[ $role != exit ]] || after='network-online.target docker.service'
    cat > "$root/etc/systemd/system/cn-egress.service" <<EOF
[Unit]
Description=CN Egress VPN ($role)
Wants=network-online.target
After=$after

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cn-egress-net start $role
ExecStop=/usr/local/sbin/cn-egress-net stop $role
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    cat > "$root/etc/systemd/system/cn-egress-obfs.service" <<'EOF'
[Unit]
Description=CN Egress authenticated WSS transport
Wants=network-online.target
After=network-online.target
PartOf=cn-egress.service

[Service]
Type=simple
User=cn-egress-wss
Group=cn-egress-wss
ExecStart=/usr/local/sbin/cn-egress-obfs
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
EOF
    if [[ $role == sh ]]; then
        printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n' >> "$root/etc/systemd/system/cn-egress-obfs.service"
    else
        printf 'CapabilityBoundingSet=\n' >> "$root/etc/systemd/system/cn-egress-obfs.service"
    fi
    printf '\n[Install]\nWantedBy=multi-user.target\n' >> "$root/etc/systemd/system/cn-egress-obfs.service"
    printf '[Unit]\nWants=cn-egress-obfs.service\nAfter=cn-egress-obfs.service\n' > "$root/etc/systemd/system/cn-egress.service.d/obfs.conf"
    if [[ $role == hk && $mode == awg2 ]]; then
        cat > "$root/etc/systemd/system/cn-egress-users.service" <<'EOF'
[Unit]
Description=CN Egress AmneziaWG 2.0 first hop
Wants=network-online.target
After=network-online.target
Before=cn-egress.service
PartOf=cn-egress.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/cn-egress-users start
Restart=no
UMask=0077
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=full
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
        printf '[Unit]\nRequires=cn-egress-users.service\nBindsTo=cn-egress-users.service\nAfter=cn-egress-users.service\n' > "$root/etc/systemd/system/cn-egress.service.d/users.conf"
    fi
    if [[ $role == exit ]]; then
        cat > "$root/etc/systemd/system/cn-egress-dns.service" <<'EOF'
[Unit]
Description=DNS for CN Egress VPN clients
Requires=cn-egress.service
After=cn-egress.service
PartOf=cn-egress.service

[Service]
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/cn-egress/dnsmasq.conf
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    fi
    chmod 644 "$root/etc/systemd/system/"*.service "$root/etc/systemd/system/cn-egress.service.d/"*.conf
}

# Run the renderer in a fresh Bash process so a caller's `if`/`!` cannot disable
# errexit halfway through certificate generation. No source file is unpacked.
# OUT HK_IP SH_IP USER_PORT WSS_PORT WAN [USER_TRANSPORT]
cne_render_bundle() {
    local definitions
    definitions=$(declare -f cne_render_error cne_render_host cne_render_port \
        cne_render_key cne_render_awg_params cne_render_awg_generate \
        cne_render_client cne_render_interface cne_render_peer \
        cne_render_relay_firewall cne_render_exit_firewall cne_render_pki \
        cne_render_services cne_render_bundle_impl cne_net_source \
        cne_obfs_source cne_restrictions_source cne_node_source) || return 1
    if declare -F cne_users_source >/dev/null; then definitions+=$'\n'"$(declare -f cne_users_source)"; fi
    if declare -F cne_probe_source >/dev/null; then definitions+=$'\n'"$(declare -f cne_probe_source)"; fi
    printf '%s\ncne_render_bundle_impl "$@"\n' "$definitions" | bash -euo pipefail -s -- "$@"
}

cne_render_bundle_impl() (
    set -euo pipefail
    umask 077
    local out=$1 hk=$2 sh=$3 user_port=$4 wss_port=$5 wan=$6 mode=${7:-awg2}
    local hk_local=${8:-51831} sh_hk=${9:-51821} sh_exit=${10:-51822} exit_local=${11:-51832} dns=${12:-5354}
    local role root key private public psk name number pair internal
    cne_render_host "$hk" && cne_render_host "$sh" || { cne_render_error '节点地址无效'; exit 1; }
    cne_render_port "$user_port" && cne_render_port "$wss_port" || { cne_render_error '监听端口无效'; exit 1; }
    for internal in "$hk_local" "$sh_hk" "$sh_exit" "$exit_local" "$dns"; do
        [[ $internal =~ ^[1-9][0-9]{0,4}$ ]] && cne_render_port "$internal" || { cne_render_error '内部端口无效'; exit 1; }
    done
    [[ $user_port != "$hk_local" && $sh_hk != "$sh_exit" && $exit_local != "$dns" ]] || { cne_render_error '同一节点内部端口重复'; exit 1; }
    [[ $wan =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { cne_render_error '出口网卡名无效'; exit 1; }
    [[ $mode == awg2 || $mode == wireguard ]] || { cne_render_error '入口协议无效'; exit 1; }
    [[ ! -e $out && ! -L $out ]] || { cne_render_error '目标目录已存在，请使用新的临时目录'; exit 1; }
    command -v wg >/dev/null && command -v openssl >/dev/null || { cne_render_error '缺少 wg 或 openssl'; exit 1; }
    mkdir -m 700 "$out"
    mkdir -m 700 "$out/clients" "$out/keys"
    cne_render_pki "$out/pki" "$sh"
    for key in hk_users hk_cn sh_cn sh_exit exit; do
        wg genkey > "$out/keys/$key.key"
        wg pubkey < "$out/keys/$key.key" > "$out/keys/$key.pub"
    done
    wg genpsk > "$out/keys/hk_sh.psk"
    wg genpsk > "$out/keys/sh_exit.psk"
    for role in hk sh exit; do
        root=$out/$role
        mkdir -p "$root/etc/cn-egress" "$root/etc/cn-egress-wss/empty-ca" "$root/etc/wireguard" "$root/etc/systemd/system/cn-egress.service.d" "$root/usr/local/sbin"
        cne_net_source > "$root/usr/local/sbin/cn-egress-net"
        cne_obfs_source > "$root/usr/local/sbin/cn-egress-obfs"
        cne_node_source > "$root/usr/local/sbin/cn-egress-node"
        chmod 700 "$root/usr/local/sbin/cn-egress-net"
        chmod 755 "$root/usr/local/sbin/cn-egress-obfs" "$root/usr/local/sbin/cn-egress-node"
        printf '%s\n' "$role" > "$root/etc/cn-egress/role"
        printf '2\n' > "$root/etc/cn-egress/version"
        printf '%s\n' "$role" > "$root/etc/cn-egress-wss/role"
        printf '%s\n' "$sh" > "$root/etc/cn-egress-wss/sh-host"
        printf '%s\n' "$wss_port" > "$root/etc/cn-egress-wss/port"
        printf '%s %s %s %s %s\n' "$hk_local" "$sh_hk" "$sh_exit" "$exit_local" "$dns" > "$root/etc/cn-egress-wss/internal-ports"
        cp "$out/pki/ca.crt" "$root/etc/cn-egress-wss/ca.crt"
        cp "$out/pki/$role.key" "$root/etc/cn-egress-wss/node.key"
        cp "$out/pki/$role.crt" "$root/etc/cn-egress-wss/node.crt"
        chmod 640 "$root/etc/cn-egress-wss/"{role,sh-host,port,internal-ports,ca.crt,node.key,node.crt}
        cne_render_services "$root" "$role" "$mode"
    done
    printf '%s\n' "$mode" > "$out/hk/etc/cn-egress/user-transport"
    if declare -F cne_probe_source >/dev/null; then
        cne_probe_source > "$out/hk/usr/local/sbin/cn-egress-probe"
        chmod 755 "$out/hk/usr/local/sbin/cn-egress-probe"
    fi
    if [[ $mode == awg2 ]]; then
        cne_render_awg_generate > "$out/hk/etc/cn-egress/awg-params"
        cne_render_awg_params "$out/hk/etc/cn-egress/awg-params" >/dev/null
        # Standalone release embeds this source. Direct renderer tests may
        # provide it explicitly, just like the existing net/obfs assets.
        if declare -F cne_users_source >/dev/null; then
            cne_users_source > "$out/hk/usr/local/sbin/cn-egress-users"
        else
            cne_render_error '缺少 AmneziaWG 入口服务脚本'; exit 1
        fi
        chmod 755 "$out/hk/usr/local/sbin/cn-egress-users"
    fi
    cne_render_interface "$(cat "$out/keys/hk_users.key")" '10.77.10.1/24, fd77:77:10::1/64' "$user_port" > "$out/hk/etc/wireguard/cne-users.conf"
    if [[ $mode == awg2 ]]; then cat "$out/hk/etc/cn-egress/awg-params" >> "$out/hk/etc/wireguard/cne-users.conf"; fi
    cp "$out/keys/hk_users.pub" "$out/hk/etc/cn-egress/server-public"
    : > "$out/client-registry.tsv"
    for pair in iPhone:10 Android:20 Windows:30; do
        name=${pair%:*}; number=${pair#*:}
        private=$(wg genkey); public=$(printf '%s\n' "$private" | wg pubkey); psk=$(wg genpsk)
        cne_render_client "$out/clients/$name.conf" "$number" "$private" "$(cat "$out/keys/hk_users.pub")" "$psk" "$hk" "$user_port" "$mode" "$out/hk/etc/cn-egress/awg-params"
        cne_render_peer "$public" "$psk" "10.77.10.$number/32, fd77:77:10::$number/128" >> "$out/hk/etc/wireguard/cne-users.conf"
        printf '%s\t%s\t%s\n' "$name" "$number" "$public" >> "$out/client-registry.tsv"
    done
    cp "$out/client-registry.tsv" "$out/hk/etc/cn-egress/clients.tsv"
    private=$(wg genkey); public=$(printf '%s\n' "$private" | wg pubkey); psk=$(wg genpsk)
    cne_render_client "$out/hk/etc/cn-egress/probe.conf" 250 "$private" "$(cat "$out/keys/hk_users.pub")" "$psk" '127.0.0.1' "$user_port" "$mode" "$out/hk/etc/cn-egress/awg-params"
    cne_render_peer "$public" "$psk" '10.77.10.250/32, fd77:77:10::250/128' >> "$out/hk/etc/wireguard/cne-users.conf"
    cne_render_interface "$(cat "$out/keys/hk_cn.key")" '10.77.20.1/30, fd77:77:20::1/64' > "$out/hk/etc/wireguard/cne-cn.conf"
    cne_render_peer "$(cat "$out/keys/sh_cn.pub")" "$(cat "$out/keys/hk_sh.psk")" '0.0.0.0/0, ::/0' "127.0.0.1:$hk_local" >> "$out/hk/etc/wireguard/cne-cn.conf"
    cne_render_interface "$(cat "$out/keys/sh_cn.key")" '10.77.20.2/30, fd77:77:20::2/64' "$sh_hk" > "$out/sh/etc/wireguard/cne-cn.conf"
    cne_render_peer "$(cat "$out/keys/hk_cn.pub")" "$(cat "$out/keys/hk_sh.psk")" '10.77.20.1/32, fd77:77:20::1/128, 10.77.10.0/24, fd77:77:10::/64' >> "$out/sh/etc/wireguard/cne-cn.conf"
    cne_render_interface "$(cat "$out/keys/sh_exit.key")" '10.77.30.1/30, fd77:77:30::1/64' "$sh_exit" > "$out/sh/etc/wireguard/cne-exit.conf"
    cne_render_peer "$(cat "$out/keys/exit.pub")" "$(cat "$out/keys/sh_exit.psk")" '0.0.0.0/0, ::/0' >> "$out/sh/etc/wireguard/cne-exit.conf"
    cne_render_interface "$(cat "$out/keys/exit.key")" '10.77.30.2/30, fd77:77:30::2/64' > "$out/exit/etc/wireguard/cne-exit.conf"
    cne_render_peer "$(cat "$out/keys/sh_exit.pub")" "$(cat "$out/keys/sh_exit.psk")" '10.77.30.1/32, fd77:77:30::1/128, 10.77.10.0/24, fd77:77:10::/64' "127.0.0.1:$exit_local" >> "$out/exit/etc/wireguard/cne-exit.conf"
    cne_render_relay_firewall cne-users cne-cn > "$out/hk/etc/cn-egress/firewall.nft"
    cne_render_relay_firewall cne-cn cne-exit > "$out/sh/etc/cn-egress/firewall.nft"
    cne_render_exit_firewall "$wan" "$dns" > "$out/exit/etc/cn-egress/firewall.nft"
    printf '%s\n' "$wan" > "$out/exit/etc/cn-egress/wan-interface"
    cne_restrictions_source | sed -e "s/\"51821\"/\"$sh_hk\"/g" -e "s/\"51822\"/\"$sh_exit\"/g" > "$out/sh/etc/cn-egress-wss/restrictions.yaml"
    chmod 640 "$out/sh/etc/cn-egress-wss/restrictions.yaml"
    cat > "$out/sh/etc/cn-egress-wss/guard.nft" <<EOF
table inet cne_wss_input {
  chain input_guard {
    type filter hook input priority -10; policy accept;
    iifname != "lo" udp dport { $sh_hk, $sh_exit } counter drop
  }
}
EOF
    cat > "$out/exit/etc/cn-egress/dnsmasq.conf" <<EOF
interface=cne-exit
listen-address=10.77.30.2
bind-dynamic
port=$dns
cache-size=1000
domain-needed
bogus-priv
filter-AAAA
user=nobody
group=nogroup
pid-file=
EOF
)
