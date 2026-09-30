#!/usr/bin/env bash
# 一键安装与管理 — standalone Bash release
set -uo pipefail

cne_node_source() {
cat <<'CNE_EMBEDDED_cne_node_source_V2'
#!/usr/bin/env bash
# Remote node operations. Only the fixed cn-egress files and network objects below are owned.
# Source with CNE_NODE_LIBRARY=1, then invoke cne_node_main ACTION ROLE [ARGS].

cne_n_error() { printf '错误：%s\n' "$*" >&2; return 1; }
cne_n_has() { command -v "$1" >/dev/null 2>&1; }
cne_n_role_ok() { [[ $1 == hk || $1 == sh || $1 == exit ]]; }
cne_n_safe_path() {
    local path=$1 current='' piece
    [[ $path == /* && $path != *'..'* && $path != *$'\n'* ]] || return 1
    local -a pieces
    IFS=/ read -r -a pieces <<< "$path"
    for piece in "${pieces[@]}"; do
        [[ -z $piece ]] && continue
        current="$current/$piece"
        [[ ! -L $current ]] || { cne_n_error "拒绝符号链接：$current"; return 1; }
    done
    [[ ! -e $path || -f $path ]] || { cne_n_error "预留文件路径不是普通文件：$path"; return 1; }
}
cne_n_all_files() {
    cat <<'FILES'
etc/cn-egress/role
etc/cn-egress/version
etc/cn-egress/deployment-id
etc/cn-egress/clients.tsv
etc/cn-egress/server-public
etc/cn-egress/wan-interface
etc/cn-egress/firewall.nft
etc/cn-egress/dnsmasq.conf
etc/cn-egress/oneclick-manifest.json
etc/cn-egress/oneclick-clients.json
etc/cn-egress/oneclick-node.py
etc/cn-egress/forwarding-before
etc/cn-egress/forwarding-settings
etc/cn-egress-wss/role
etc/cn-egress-wss/node.crt
etc/cn-egress-wss/node.key
etc/cn-egress-wss/ca.crt
etc/cn-egress-wss/sh-host
etc/cn-egress-wss/port
etc/cn-egress-wss/restrictions.yaml
etc/cn-egress-wss/guard.nft
etc/wireguard/cne-users.conf
etc/wireguard/cne-cn.conf
etc/wireguard/cne-exit.conf
etc/systemd/system/cn-egress.service
etc/systemd/system/cn-egress-obfs.service
etc/systemd/system/cn-egress-dns.service
etc/systemd/system/cn-egress.service.d/obfs.conf
etc/sysctl.d/90-cn-egress.conf
etc/sysctl.d/90-cn-egress-forwarding.conf
usr/local/sbin/cn-egress
usr/local/sbin/cn-egress-node
usr/local/sbin/cn-egress-net
usr/local/sbin/cn-egress-obfs
opt/cn-egress/wstunnel-11.0.0/wstunnel
FILES
}
cne_n_payload_allowed() {
    local role=$1 path=$2
    case "$path" in
        etc/cn-egress/role|etc/cn-egress/version|etc/cn-egress/deployment-id|etc/cn-egress/firewall.nft|etc/cn-egress-wss/role|etc/cn-egress-wss/node.crt|etc/cn-egress-wss/node.key|etc/cn-egress-wss/ca.crt|etc/cn-egress-wss/sh-host|etc/cn-egress-wss/port|etc/systemd/system/cn-egress.service|etc/systemd/system/cn-egress-obfs.service|etc/systemd/system/cn-egress.service.d/obfs.conf|usr/local/sbin/cn-egress|usr/local/sbin/cn-egress-node|usr/local/sbin/cn-egress-net|usr/local/sbin/cn-egress-obfs|opt/cn-egress/wstunnel-11.0.0/wstunnel) return 0;;
        etc/wireguard/cne-users.conf|etc/cn-egress/clients.tsv|etc/cn-egress/server-public) [[ $role == hk ]];;
        etc/wireguard/cne-cn.conf) [[ $role == hk || $role == sh ]];;
        etc/wireguard/cne-exit.conf) [[ $role == sh || $role == exit ]];;
        etc/cn-egress-wss/restrictions.yaml|etc/cn-egress-wss/guard.nft) [[ $role == sh ]];;
        etc/cn-egress/wan-interface|etc/cn-egress/dnsmasq.conf|etc/systemd/system/cn-egress-dns.service) [[ $role == exit ]];;
        *) return 1;;
    esac
}
cne_n_existing_role() {
    local found='' value file line
    for file in /etc/cn-egress/role /etc/cn-egress-wss/role; do
        cne_n_safe_path "$file" || return 1
        if [[ -f $file ]]; then
            value=$(cat "$file")
            if cne_n_role_ok "$value"; then
                [[ -z $found || $found == "$value" ]] || { printf 'unknown\n'; return; }
                found=$value
            elif [[ -n $value ]]; then printf 'unknown\n'; return; fi
        fi
    done
    if [[ -n $found ]]; then printf '%s\n' "$found"; return; fi
    file=/etc/systemd/system/cn-egress.service
    cne_n_safe_path "$file" || return 1
    if [[ -f $file ]]; then
        value=$(sed -nE 's@^ExecStart=/usr/local/sbin/cn-egress-net start (hk|sh|exit)[[:space:]]*$@\1@p' "$file")
        if cne_n_role_ok "$value"; then printf '%s\n' "$value"; return; fi
    fi
    local users=0 cn=0 exit_node=0
    [[ -f /etc/wireguard/cne-users.conf ]] && users=1
    [[ -f /etc/wireguard/cne-cn.conf ]] && cn=1
    [[ -f /etc/wireguard/cne-exit.conf ]] && exit_node=1
    case "$users$cn$exit_node" in 110) printf 'hk\n';; 011) printf 'sh\n';; 001) printf 'exit\n';; *) printf 'unknown\n';; esac
}
cne_n_exists() {
    local file
    while IFS= read -r file; do
        case $file in etc/cn-egress/forwarding-before|etc/cn-egress/forwarding-settings|etc/sysctl.d/90-cn-egress-forwarding.conf) continue;; esac
        [[ -e /$file || -L /$file ]] && return 0
    done < <(cne_n_all_files)
    if cne_n_has ip; then
        ip netns list 2>/dev/null | awk '{print $1}' | grep -qx cn-egress-relay && return 0
        for file in cne-users cne-cn cne-exit; do ip link show dev "$file" >/dev/null 2>&1 && return 0; done
    fi
    if cne_n_has nft; then
        nft list table inet cn_egress >/dev/null 2>&1 && return 0
        nft list table inet cne_wss_input >/dev/null 2>&1 && return 0
    fi
    if cne_n_has iptables; then iptables -S CNE_VPN >/dev/null 2>&1 && return 0; fi
    return 1
}
cne_n_wan() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
cne_n_forwarding() { if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then cat /proc/sys/net/ipv4/ip_forward; else printf 'unknown\n'; fi; }
cne_n_inspect() {
    local state=absent role version=unknown service=inactive wan='' user_port=''
    cne_n_exists && state=present
    role=$(cne_n_existing_role) || return 1
    if [[ -f /etc/cn-egress/version ]]; then read -r version < /etc/cn-egress/version; [[ $version =~ ^[a-zA-Z0-9._-]+$ ]] || version=unknown; fi
    cne_n_has systemctl && systemctl is-active --quiet cn-egress.service && service=active
    cne_n_has ip && wan=$(cne_n_wan)
    if [[ -f /etc/wireguard/cne-users.conf ]]; then
        user_port=$(sed -nE 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' /etc/wireguard/cne-users.conf)
        [[ $user_port =~ ^[0-9]{1,5}$ ]] && ((user_port>=1 && user_port<=65535)) || user_port=''
    fi
    printf 'state=%s\nrole=%s\narch=%s\nwan=%s\nforwarding=%s\nservice=%s\nversion=%s\nuser_port=%s\n' "$state" "$role" "$(uname -m)" "$wan" "$(cne_n_forwarding)" "$service" "$version" "$user_port"
}
cne_n_os_check() {
    [[ $(id -u) == 0 ]] || { cne_n_error '需要 root 权限。'; return 1; }
    [[ $(uname -s) == Linux ]] || { cne_n_error '节点需要 Linux。'; return 1; }
    case $(uname -m) in x86_64|amd64|aarch64|arm64) :;; *) cne_n_error '本版支持 Linux x86_64 或 arm64 节点。'; return 1;; esac
    local os
    os=$(sed -nE 's/^ID="?([^" ]+)"?$/\1/p' /etc/os-release 2>/dev/null)
    [[ $os == debian || $os == ubuntu ]] || { cne_n_error '节点需要 Debian 或 Ubuntu。'; return 1; }
    [[ -d /run/systemd/system ]] && cne_n_has systemctl || { cne_n_error '节点需要正在运行的 systemd。'; return 1; }
}
cne_n_scope_check() {
    local file name type links
    while IFS= read -r file; do cne_n_safe_path "/$file" || return 1; done < <(cne_n_all_files)
    for file in /etc/systemd/system/cn-egress.service /etc/systemd/system/cn-egress-obfs.service /etc/systemd/system/cn-egress-dns.service; do
        [[ -f $file ]] || continue
        while IFS= read -r type; do
            case $type in
                'ExecStart=/usr/local/sbin/cn-egress-net start '*|'ExecStop=/usr/local/sbin/cn-egress-net stop '*|'ExecStart=/usr/local/sbin/cn-egress-obfs'|'ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/cn-egress/dnsmasq.conf') :;;
                *) cne_n_error "预留服务包含非本工具的执行命令：$file"; return 1;;
            esac
        done < <(grep -E '^Exec(Start|Stop|Reload|StartPre|StartPost|StopPost)=' "$file")
    done
    if cne_n_has ip; then
        if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx cn-egress-relay; then
            links=$(ip -n cn-egress-relay -o link show 2>/dev/null) || { cne_n_error '无法确认预留网络命名空间的归属。'; return 1; }
            while IFS= read -r name; do
                case "$name" in lo|cne-users|cne-cn|cne-exit) :;; *) cne_n_error "cn-egress-relay 内含其他网卡 $name，不能覆盖。"; return 1;; esac
            done < <(printf '%s\n' "$links" | awk -F': ' '{split($2,a,"@");print a[1]}')
        fi
        for name in cne-users cne-cn cne-exit; do
            if ip link show dev "$name" >/dev/null 2>&1; then
                ip -d link show dev "$name" | grep -qw wireguard || { cne_n_error "$name 已被其他类型网卡占用。"; return 1; }
            fi
        done
    fi
}
cne_n_port_owned() {
    local role=$1 proto=$2 port=$3 line=$4 iface unit pid group
    if [[ $proto == udp ]] && cne_n_has wg; then
        for iface in cne-users cne-cn cne-exit; do
            [[ $(wg show "$iface" listen-port 2>/dev/null) == "$port" ]] && return 0
            [[ $(ip netns exec cn-egress-relay wg show "$iface" listen-port 2>/dev/null) == "$port" ]] && return 0
        done
    fi
    while IFS= read -r pid; do
        [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cgroup ]] || continue
        if grep -Eq '(^|/)cn-egress-(obfs|dns)\.service($|/)' "/proc/$pid/cgroup"; then return 0; fi
    done < <(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | cut -d= -f2)
    return 1
}
cne_n_ports_check() {
    local role=$1 mode=$2 users=$3 wss=$4 proto port line local_address rest needed=''
    cne_n_has ss || return 0
    case $role in hk) needed="udp:$users udp:51831";; sh) needed="tcp:$wss udp:51821 udp:51822";; exit) needed='udp:51832 udp:5354 tcp:5354';; esac
    while IFS= read -r line; do
        proto=${line%% *}; proto=${proto%6}
        local_address=$(awk '{print $5}' <<< "$line"); port=${local_address##*:}
        case " $needed " in *" $proto:$port "*) :;; *) continue;; esac
        if [[ $mode != fresh ]] && cne_n_port_owned "$role" "$proto" "$port" "$line"; then continue; fi
        cne_n_error "端口 $proto/$port 已被其他服务占用；请调整安装端口。"; return 1
    done < <(ss -H -lntup 2>/dev/null)
}
cne_n_routes_check() {
    local mode=$1
    cne_n_has ip || return 0
    # Match all IPv4 prefixes, including supernets; only this tool's existing interfaces may be skipped.
    if ! ip -4 route show table all | awk -v mode="$mode" '
      function n(s,a){split(s,a,".");return a[1]*16777216+a[2]*65536+a[3]*256+a[4]}
      function overlap(ip,prefix,base,bits,lo,hi){lo=int(ip/2^(32-prefix))*2^(32-prefix);hi=lo+2^(32-prefix)-1;return lo<=base+2^(32-bits)-1 && hi>=base}
      {if($1=="default")next;owned=0;for(i=1;i<NF;i++)if($i=="dev" && $(i+1)~/^cne-(users|cn|exit)$/)owned=1;if(mode!="fresh"&&owned)next;
       dest=$1;if(dest=="local"||dest=="broadcast"||dest=="unreachable"||dest=="prohibit"||dest=="blackhole")dest=$2;
       split(dest,a,"/");if(a[1]!~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)next;p=(a[2]==""?32:a[2]);if(p==0)next;
       if(overlap(n(a[1]),p,n("10.77.10.0"),24)||overlap(n(a[1]),p,n("10.77.20.0"),30)||overlap(n(a[1]),p,n("10.77.30.0"),30))bad=1}
      END{exit bad?1:0}'; then cne_n_error '现有 IPv4 路由与 VPN 使用的 10.77.10/20/30 网段重叠。'; return 1; fi
    # Any route in the chosen ULA /48 is a conflict unless attached to an owned VPN interface.
    if ! ip -6 route show table all | awk -v mode="$mode" '{owned=0;for(i=1;i<NF;i++)if($i=="dev" && $(i+1)~/^cne-(users|cn|exit)$/)owned=1;if(mode!="fresh"&&owned)next;if($0~/fd77:0*77:(0*10|0*20|0*30):/)bad=1}END{exit bad?1:0}'; then cne_n_error '现有 IPv6 路由与 VPN 网段重叠。'; return 1; fi
}
cne_n_preflight() {
    local role=$1 mode=${2:-fresh} users=${3:-51820} wss=${4:-443}
    cne_n_os_check || return 1
    [[ $mode == fresh || $mode == replace || $mode == manage ]] || { cne_n_error '安装模式无效。'; return 1; }
    [[ $users =~ ^[0-9]+$ && $wss =~ ^[0-9]+$ ]] && (( users>=1 && users<=65535 && wss>=1 && wss<=65535 && users!=51831 )) || { cne_n_error '端口无效。'; return 1; }
    if [[ $mode == fresh ]] && cne_n_exists; then cne_n_error '检测到已有文件；请选择保留管理或备份后覆盖安装。'; return 1; fi
    cne_n_scope_check || return 1
    cne_n_ports_check "$role" "$mode" "$users" "$wss" || return 1
    cne_n_routes_check "$mode" || return 1
    printf '检查通过\n'
}
cne_n_prepare() {
    local role=$1 tool package audit plan
    cne_n_os_check || return 1
    local -a packages=()
    local pairs='ip:iproute2 ss:iproute2 wg:wireguard-tools wg-quick:wireguard-tools nft:nftables sysctl:procps openssl:openssl flock:util-linux tar:tar gzip:gzip base64:coreutils install:coreutils stat:coreutils getent:libc-bin useradd:passwd groupadd:passwd'
    [[ $role == exit ]] && pairs="$pairs iptables:iptables dnsmasq:dnsmasq-base"
    for package in $pairs; do
        tool=${package%%:*}; package=${package#*:}
        if ! cne_n_has "$tool"; then
            case " ${packages[*]-} " in *" $package "*) :;; *) packages+=("$package");; esac
        fi
    done
    ((${#packages[@]})) || { printf '依赖已齐全\n'; return 0; }
    cne_n_has apt-get && cne_n_has dpkg || { cne_n_error '未找到 apt-get/dpkg。'; return 1; }
    audit=$(LC_ALL=C dpkg --audit 2>&1) || { cne_n_error '现有软件包状态未完成，请先处理 dpkg。'; return 1; }
    [[ -z $audit ]] || { cne_n_error '现有软件包状态未完成，请先处理 dpkg。'; return 1; }
    printf '安装缺少的依赖：%s\n' "${packages[*]}" >&2
    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get update </dev/null >&2 || return 1
    plan=$(LC_ALL=C apt-get -s --no-remove --no-upgrade --no-install-recommends install "${packages[@]}" 2>&1) || { cne_n_error '无法生成依赖安装方案。'; return 1; }
    if grep -Eq '^(Remv |Inst [^ ]+ \[)' <<< "$plan"; then cne_n_error '依赖安装会升级或删除已有软件，已停止。'; return 1; fi
    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove --no-upgrade --no-install-recommends install "${packages[@]}" </dev/null >&2 || return 1
    for package in $pairs; do cne_n_has "${package%%:*}" || { cne_n_error "依赖安装后仍找不到 ${package%%:*}。"; return 1; }; done
}
cne_n_services() { printf '%s\n' cn-egress.service cn-egress-obfs.service cn-egress-dns.service; }
cne_n_backup() {
    local directory temporary file state enabled archive stamp
    directory=/root/cn-egress-backups
    [[ ! -L $directory ]] || { cne_n_error '备份目录不能是符号链接。'; return 1; }
    mkdir -p -m 700 "$directory" || return 1
    chmod 700 "$directory" || return 1
    temporary=$(mktemp -d "$directory/.stage.XXXXXXXX") || return 1
    while IFS= read -r file; do
        cne_n_safe_path "/$file" || { rm -rf "$temporary"; return 1; }
        if [[ -f /$file ]]; then
            mkdir -p "$temporary/${file%/*}" && cp -p "/$file" "$temporary/$file" || { rm -rf "$temporary"; return 1; }
        fi
    done < <(cne_n_all_files)
    : > "$temporary/.cn-egress-services.tsv"
    while IFS= read -r file; do
        state=$(systemctl is-active "$file" 2>/dev/null) || :
        enabled=$(systemctl is-enabled "$file" 2>/dev/null) || :
        printf '%s\t%s\t%s\n' "$file" "$state" "$enabled" >> "$temporary/.cn-egress-services.tsv"
    done < <(cne_n_services)
    stamp=$(date -u +%Y%m%d-%H%M%S)
    archive="$directory/$stamp-${temporary##*.}.tar.gz"
    tar -C "$temporary" -czf "$archive" . || { rm -rf "$temporary"; return 1; }
    chmod 600 "$archive" || return 1
    rm -rf "$temporary"
    printf '%s\n' "$archive"
}
cne_n_cleanup_network() {
    local iface chain
    # Namespace was checked for unrelated devices before entering any mutating action.
    if cne_n_has ip; then
        for iface in cne-users cne-cn cne-exit; do
            ip -n cn-egress-relay link delete "$iface" >/dev/null 2>&1 || :
            ip link delete "$iface" >/dev/null 2>&1 || :
        done
        ip netns delete cn-egress-relay >/dev/null 2>&1 || :
    fi
    if cne_n_has nft; then
        nft delete table inet cn_egress >/dev/null 2>&1 || :
        nft delete table inet cne_wss_input >/dev/null 2>&1 || :
    fi
    if cne_n_has iptables; then
        for chain in DOCKER-USER FORWARD; do
            while iptables -C "$chain" -j CNE_VPN >/dev/null 2>&1; do iptables -D "$chain" -j CNE_VPN >/dev/null 2>&1 || break; done
        done
        iptables -F CNE_VPN >/dev/null 2>&1 || :
        iptables -X CNE_VPN >/dev/null 2>&1 || :
    fi
}
cne_n_stop_owned() {
    local unit
    # Units are fixed, never stop a generic dnsmasq, nginx, Docker or networking unit.
    for unit in cn-egress-dns.service cn-egress-obfs.service cn-egress.service; do
        if [[ -f /etc/systemd/system/$unit ]]; then systemctl stop "$unit" >&2 || return 1; fi
    done
    cne_n_cleanup_network
}
cne_n_remove_files() {
    local file
    while IFS= read -r file; do
        # Forwarding is a separate explicit user setting, not an installation side effect.
        case $file in etc/sysctl.d/90-cn-egress-forwarding.conf|etc/cn-egress/forwarding-before|etc/cn-egress/forwarding-settings) continue;; esac
        cne_n_safe_path "/$file" && rm -f "/$file" || return 1
    done < <(cne_n_all_files)
}
cne_n_rollback() {
    local archive=$1 temporary file unit state enabled failures=0
    printf '安装未完成，正在恢复本节点原有配置和服务状态。备份：%s\n' "$archive" >&2
    cne_n_stop_owned || failures=1
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
        [[ ! -f /etc/systemd/system/$unit ]] || systemctl disable "$unit" >&2 || failures=1
    done
    cne_n_remove_files || failures=1
    temporary=$(mktemp -d /root/cn-egress-backups/.restore.XXXXXXXX) || return 1
    tar -xzf "$archive" -C "$temporary" || { rm -rf "$temporary"; return 1; }
    while IFS= read -r file; do
        if [[ -f $temporary/$file ]]; then
            cne_n_safe_path "/$file" && mkdir -p "/${file%/*}" && cp -p "$temporary/$file" "/$file" || failures=1
        fi
    done < <(cne_n_all_files)
    systemctl daemon-reload >&2 || failures=1
    while IFS=$'\t' read -r unit state enabled; do
        [[ -f /etc/systemd/system/$unit ]] || continue
        case $enabled in enabled) systemctl enable "$unit" >&2 || failures=1;; disabled) systemctl disable "$unit" >&2 || failures=1;; esac
    done < "$temporary/.cn-egress-services.tsv"
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
        if awk -F'\t' -v u="$unit" '$1==u && $2=="active"{found=1}END{exit !found}' "$temporary/.cn-egress-services.tsv"; then systemctl start "$unit" >&2 || failures=1; fi
    done
    rm -rf "$temporary"
    ((failures==0)) || { cne_n_error '自动回滚未完全成功，请保留上述备份并检查本工具服务。'; return 1; }
    printf '已恢复本节点安装前的文件及服务状态。\n' >&2
}
cne_n_validate_archive() {
    local role=$1 archive=$2 destination=$3 list verbose path number
    [[ -f $archive && ! -L $archive ]] || { cne_n_error '安装包不存在或不是普通文件。'; return 1; }
    [[ $(stat -c %s "$archive") -le 104857600 ]] || { cne_n_error '安装包过大。'; return 1; }
    list=$(tar -tzf "$archive") || { cne_n_error '安装包无法读取。'; return 1; }
    [[ -n $list ]] || return 1
    number=0
    while IFS= read -r path; do
        ((number+=1))
        cne_n_payload_allowed "$role" "$path" || { cne_n_error "安装包包含非预期路径：$path"; return 1; }
        cne_n_safe_path "/$path" || return 1
    done <<< "$list"
    ((number<=40)) || { cne_n_error '安装包文件数量异常。'; return 1; }
    [[ -z $(printf '%s\n' "$list" | sort | uniq -d) ]] || { cne_n_error '安装包包含重复文件。'; return 1; }
    verbose=$(tar -tvzf "$archive") || return 1
    if grep -qv '^-' <<< "$verbose"; then cne_n_error '安装包仅允许普通文件，不能含目录、链接或设备。'; return 1; fi
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$destination" || return 1
    local expected actual interface local_port required='etc/cn-egress/firewall.nft etc/cn-egress-wss/role etc/cn-egress-wss/node.crt etc/cn-egress-wss/node.key etc/cn-egress-wss/ca.crt etc/cn-egress-wss/port etc/systemd/system/cn-egress.service etc/systemd/system/cn-egress-obfs.service usr/local/sbin/cn-egress-net usr/local/sbin/cn-egress-obfs opt/cn-egress/wstunnel-11.0.0/wstunnel'
    case $role in hk) required="$required etc/wireguard/cne-users.conf etc/wireguard/cne-cn.conf";; sh) required="$required etc/wireguard/cne-cn.conf etc/wireguard/cne-exit.conf etc/cn-egress-wss/guard.nft etc/cn-egress-wss/restrictions.yaml";; exit) required="$required etc/wireguard/cne-exit.conf etc/cn-egress/wan-interface etc/cn-egress/dnsmasq.conf etc/systemd/system/cn-egress-dns.service";; esac
    for path in $required; do [[ -s $destination/$path ]] || { cne_n_error "安装包缺少 $path"; return 1; }; done
    [[ $(cat "$destination/etc/cn-egress-wss/role") == "$role" ]] || { cne_n_error '安装包节点角色不匹配。'; return 1; }
    for path in "$destination"/etc/wireguard/*.conf; do
        [[ $(grep -Eic '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off[[:space:]]*$' "$path") == 1 ]] || { cne_n_error 'WireGuard 必须使用 Table = off。'; return 1; }
        if grep -Eiq '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig|DNS)[[:space:]]*=' "$path"; then cne_n_error 'WireGuard 配置不能含路由脚本或系统 DNS 修改。'; return 1; fi
    done
    case $role in hk) interface=cne-cn; local_port=51831;; exit) interface=cne-exit; local_port=51832;; *) interface='';; esac
    if [[ -n $interface ]]; then
        actual=$(sed -nE 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$destination/etc/wireguard/$interface.conf")
        [[ $actual == "127.0.0.1:$local_port" ]] || { cne_n_error '节点隧道必须使用本机加密传输端点。'; return 1; }
    fi
    for path in "$destination"/etc/wireguard/*.conf; do
        interface=${path##*/}; interface=${interface%.conf}
        case $role:$interface in
            hk:cne-users) expected='10.77.10.1/24,fd77:77:10::1/64';;
            hk:cne-cn) expected='10.77.20.1/30,fd77:77:20::1/64';;
            sh:cne-cn) expected='10.77.20.2/30,fd77:77:20::2/64';;
            sh:cne-exit) expected='10.77.30.1/30,fd77:77:30::1/64';;
            exit:cne-exit) expected='10.77.30.2/30,fd77:77:30::2/64';;
            *) return 1;;
        esac
        actual=$(sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$path" | tr -d ' \t')
        [[ $actual == "$expected" ]] || { cne_n_error '安装包使用了非预期的 VPN 地址。'; return 1; }
    done
    [[ $role != exit || $(cat "$destination/etc/cn-egress/wan-interface") == "$(cne_n_wan)" ]] || { cne_n_error '出口网卡与当前默认路由不一致。'; return 1; }
}
cne_n_transport_user() {
    getent group cn-egress-wss >/dev/null || groupadd --system cn-egress-wss || return 1
    getent passwd cn-egress-wss >/dev/null || useradd --system --gid cn-egress-wss --home-dir /nonexistent --shell /usr/sbin/nologin cn-egress-wss || return 1
    [[ $(id -u cn-egress-wss) != 0 && $(id -gn cn-egress-wss) == cn-egress-wss ]] || { cne_n_error 'cn-egress-wss 账号属性不符合预期。'; return 1; }
    [[ ! -L /etc/cn-egress-wss && ! -L /etc/cn-egress-wss/empty-ca ]] || return 1
    mkdir -p /etc/cn-egress-wss/empty-ca || return 1
    chown root:cn-egress-wss /etc/cn-egress-wss /etc/cn-egress-wss/empty-ca || return 1
    chmod 750 /etc/cn-egress-wss /etc/cn-egress-wss/empty-ca
}
cne_n_route_snapshot() {
    local role=$1
    printf 'routes4\n'
    if [[ $role == exit ]]; then ip -4 route show table all | awk '{owned=0;for(i=1;i<NF;i++)if($i=="dev"&&$(i+1)=="cne-exit")owned=1;if(!owned)print}'; else ip -4 route show table all; fi | sed -E 's/ expires [0-9]+(sec)?//g' | sort
    printf 'routes6\n'
    if [[ $role == exit ]]; then ip -6 route show table all | awk '{owned=0;for(i=1;i<NF;i++)if($i=="dev"&&$(i+1)=="cne-exit")owned=1;if(!owned)print}'; else ip -6 route show table all; fi | sed -E 's/ expires [0-9]+(sec)?//g' | sort
    printf 'rules4\n'; ip -4 rule show
    printf 'rules6\n'; ip -6 rule show
    printf 'forwarding4\n'; cat /proc/sys/net/ipv4/ip_forward
    printf 'forwarding6\n'; cat /proc/sys/net/ipv6/conf/all/forwarding
}

cne_n_install_apply() {
    local role=$1 stage=$2 id=$3 file mode
    cne_n_stop_owned || return 1
    for file in cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
        [[ ! -f /etc/systemd/system/$file ]] || systemctl disable "$file" >&2 || return 1
    done
    cne_n_remove_files || return 1
    cne_n_transport_user || return 1
    while IFS= read -r file; do
        [[ -f $stage/$file ]] || continue
        mode=600
        case $file in usr/local/sbin/*|opt/cn-egress/*/wstunnel) mode=755;; etc/systemd/*) mode=644;; etc/cn-egress-wss/node.*|etc/cn-egress-wss/ca.crt|etc/cn-egress-wss/role|etc/cn-egress-wss/port|etc/cn-egress-wss/sh-host|etc/cn-egress-wss/restrictions.yaml) mode=640;; esac
        mkdir -p "/${file%/*}" && install -m "$mode" "$stage/$file" "/$file" || return 1
        case $file in etc/cn-egress-wss/*) chown root:cn-egress-wss "/$file" || return 1;; esac
    done < <(cne_n_all_files)
    mkdir -p /etc/cn-egress && chmod 700 /etc/cn-egress || return 1
    chmod 755 /opt/cn-egress /opt/cn-egress/wstunnel-11.0.0 || return 1
    printf '%s\n' "$role" > /etc/cn-egress/role || return 1
    printf '2.0.0\n' > /etc/cn-egress/version || return 1
    printf '%s\n' "$id" > /etc/cn-egress/deployment-id || return 1
    chmod 600 /etc/cn-egress/{role,version,deployment-id} || return 1
    systemctl daemon-reload >&2 || return 1
    systemctl enable cn-egress.service cn-egress-obfs.service >&2 || return 1
    systemctl start cn-egress.service >&2 || return 1
    systemctl start cn-egress-obfs.service >&2 || return 1
    if [[ $role == exit ]]; then systemctl enable cn-egress-dns.service >&2 && systemctl start cn-egress-dns.service >&2 || return 1; fi
    systemctl is-active --quiet cn-egress.service && systemctl is-active --quiet cn-egress-obfs.service || return 1
    [[ $role != exit ]] || systemctl is-active --quiet cn-egress-dns.service || return 1
}
cne_n_install() {
    local role=$1 mode=$2 archive=$3 id=$4 stage backup before after user_port=51820 wss_port
    [[ $mode == fresh || $mode == replace ]] || { cne_n_error '安装模式必须为 fresh 或 replace。'; return 1; }
    [[ $id =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '部署编号无效。'; return 1; }
    cne_n_os_check && cne_n_scope_check || return 1
    if [[ $role == exit && $(cne_n_forwarding) != 1 ]]; then cne_n_error '出口机尚未启用 IPv4 转发。请在安装向导确认开启后继续。'; return 1; fi
    stage=$(mktemp -d /root/.cn-egress-install.XXXXXXXX) || return 1
    if ! cne_n_validate_archive "$role" "$archive" "$stage"; then rm -rf "$stage"; return 1; fi
    wss_port=$(cat "$stage/etc/cn-egress-wss/port")
    if [[ $role == hk ]]; then user_port=$(sed -nE 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$stage/etc/wireguard/cne-users.conf"); fi
    if ! cne_n_preflight "$role" "$mode" "$user_port" "$wss_port" >&2; then rm -rf "$stage"; return 1; fi
    backup=$(cne_n_backup) || { rm -rf "$stage"; return 1; }
    before=$(cne_n_route_snapshot "$role") || { rm -rf "$stage"; return 1; }
    trap 'cne_n_rollback "$backup" >&2; rm -rf "$stage"; exit 130' HUP INT TERM
    if cne_n_install_apply "$role" "$stage" "$id"; then
        after=$(cne_n_route_snapshot "$role")
        if [[ $before == "$after" ]]; then trap - HUP INT TERM; rm -rf "$stage"; printf '安装完成；原配置备份：%s\n' "$backup"; return 0; fi
        cne_n_error '检测到宿主路由、策略规则或转发设置变化，正在回滚。' || :
    fi
    trap - HUP INT TERM
    cne_n_rollback "$backup" || :
    rm -rf "$stage"
    return 1
}
cne_n_require_role() {
    local role=$1 actual
    actual=$(cne_n_existing_role) || return 1
    [[ $actual == "$role" ]] || { cne_n_error "当前节点角色为 $actual，期望 $role。请选择备份后覆盖安装以修复不完整配置。"; return 1; }
}
cne_n_net() { local role=$1; shift; if [[ $role == hk || $role == sh ]]; then ip netns exec cn-egress-relay "$@"; else "$@"; fi; }
cne_n_status() {
    local role=$1 unit state iface stamp now age available=0
    if ! cne_n_exists; then printf '尚未安装\n'; return 0; fi
    printf '角色：%s\n' "$(cne_n_existing_role)"
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
        [[ $unit != cn-egress-dns.service || $role == exit ]] || continue
        state=$(systemctl is-active "$unit" 2>/dev/null) || :
        case $unit in cn-egress.service) printf 'VPN：%s\n' "$state";; cn-egress-obfs.service) printf '传输：%s\n' "$state";; *) printf 'DNS：%s\n' "$state";; esac
    done
    now=$(date +%s)
    for iface in cne-users cne-cn cne-exit; do
        while read -r _ stamp; do
            [[ $stamp =~ ^[0-9]+$ ]] || continue
            available=1
            if ((stamp==0)); then printf '握手 %-10s 尚未建立\n' "$iface"; else age=$((now-stamp)); printf '握手 %-10s %s 秒前\n' "$iface" "$age"; fi
        done < <(cne_n_net "$role" wg show "$iface" latest-handshakes 2>/dev/null)
    done
    ((available)) || printf '握手：暂无数据\n'
}
cne_n_doctor() {
    local role=$1 issue=0 certificate iface
    cne_n_status "$role"
    for iface in cn-egress.service cn-egress-obfs.service; do systemctl is-active --quiet "$iface" || issue=1; done
    [[ $role != exit ]] || systemctl is-active --quiet cn-egress-dns.service || issue=1
    if [[ $role == exit && $(cne_n_forwarding) != 1 ]]; then printf '异常：出口机 IPv4 转发未开启。\n'; issue=1; fi
    for certificate in node.crt ca.crt; do
        if ! openssl x509 -in "/etc/cn-egress-wss/$certificate" -noout -checkend 2592000 >/dev/null 2>&1; then printf '异常：%s 无效或将在 30 天内到期。\n' "$certificate"; issue=1; fi
    done
    if ((issue==0)); then printf '本机检查通过，请连接客户端测试实际访问。\n'; else printf '请用「查看日志」检查异常服务。\n'; fi
    return "$issue"
}
cne_n_logs() {
    journalctl --no-pager -o short-iso -n 60 -u cn-egress.service -u cn-egress-obfs.service -u cn-egress-dns.service 2>&1 |
      sed -E '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/c\[私钥已隐藏]' |
      sed -E '/PrivateKey|PresharedKey|password[[:space:]]*[=:]/Ic\[敏感内容已隐藏]' |
      sed -E 's#[A-Za-z0-9+/]{43}=#[密钥已隐藏]#g'
}
cne_n_service_action() {
    local action=$1 role=$2 unit
    cne_n_require_role "$role" && cne_n_scope_check || return 1
    if [[ $action == stop ]]; then cne_n_stop_owned || return 1
    else
        if [[ $action == restart ]]; then cne_n_stop_owned || return 1; fi
        for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
            [[ $unit != cn-egress-dns.service || $role == exit ]] || continue
            systemctl start "$unit" >&2 || return 1
        done
    fi
    printf '操作完成\n'
}
cne_n_uninstall() {
    local role=$1 confirmation=${2:-} backup unit
    [[ $confirmation == confirm ]] || { cne_n_error '卸载需要明确确认。'; return 1; }
    cne_n_scope_check || return 1
    backup=$(cne_n_backup) || return 1
    cne_n_stop_owned || return 1
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do [[ ! -f /etc/systemd/system/$unit ]] || systemctl disable "$unit" >&2 || return 1; done
    cne_n_remove_files || return 1
    systemctl daemon-reload >&2 || return 1
    printf '已卸载 VPN 服务；备份：%s\n' "$backup"
}
cne_n_enable_forwarding() {
    local confirmation=${1:-} current path relative value temporary failed=0
    [[ $confirmation == confirm ]] || { cne_n_error '启用出口机 IPv4 转发需要明确确认。'; return 1; }
    cne_n_os_check || return 1
    current=$(cne_n_forwarding)
    [[ $current == 0 || $current == 1 ]] || return 1
    [[ $current != 1 ]] || { printf 'IPv4 转发已开启。\n'; return 0; }
    cne_n_safe_path /etc/cn-egress/forwarding-before && cne_n_safe_path /etc/cn-egress/forwarding-settings && cne_n_safe_path /etc/sysctl.d/90-cn-egress-forwarding.conf || return 1
    mkdir -p -m 700 /etc/cn-egress || return 1
    temporary=$(mktemp /etc/cn-egress/.forwarding.XXXXXXXX) || return 1
    # Changing ip_forward resets IPv4 device defaults in the kernel. Preserve every
    # existing non-forwarding setting, including rp_filter and ICMP redirect policy.
    for path in /proc/sys/net/ipv4/conf/*/*; do
        [[ -f $path && -r $path && -w $path ]] || continue
        [[ ${path##*/} != forwarding ]] || continue
        relative=${path#/proc/sys/}
        value=$(cat "$path") || { rm -f "$temporary"; return 1; }
        [[ $relative =~ ^net/ipv4/conf/[A-Za-z0-9_.:-]+/[A-Za-z0-9_]+$ && $value =~ ^-?[0-9]+$ ]] || { rm -f "$temporary"; cne_n_error '无法安全保存现有 IPv4 参数。'; return 1; }
        printf '%s\t%s\n' "$relative" "$value" >> "$temporary" || { rm -f "$temporary"; return 1; }
    done
    [[ -s $temporary ]] || { rm -f "$temporary"; return 1; }
    if ! sysctl -q -w net.ipv4.ip_forward=1; then rm -f "$temporary"; return 1; fi
    while IFS=$'\t' read -r relative value; do
        [[ -f /proc/sys/$relative ]] || continue
        printf '%s\n' "$value" > "/proc/sys/$relative" || failed=1
    done < "$temporary"
    if ((failed)); then
        sysctl -q -w "net.ipv4.ip_forward=$current" || :
        while IFS=$'\t' read -r relative value; do [[ ! -f /proc/sys/$relative ]] || printf '%s\n' "$value" > "/proc/sys/$relative" || :; done < "$temporary"
        rm -f "$temporary"
        cne_n_error '恢复现有 IPv4 参数失败，已撤回转发设置。'; return 1
    fi
    if [[ ! -f /etc/cn-egress/forwarding-before ]]; then printf '%s\n' "$current" > /etc/cn-egress/forwarding-before || return 1; chmod 600 /etc/cn-egress/forwarding-before; fi
    cp "$temporary" /etc/cn-egress/forwarding-settings && chmod 600 /etc/cn-egress/forwarding-settings || return 1
    {
        printf '# Explicitly enabled by cn-egress; preserve existing IPv4 device settings.\nnet.ipv4.ip_forward = 1\n'
        while IFS=$'\t' read -r relative value; do printf '%s = %s\n' "$relative" "$value"; done < "$temporary"
    } > /etc/sysctl.d/90-cn-egress-forwarding.conf || return 1
    chmod 644 /etc/sysctl.d/90-cn-egress-forwarding.conf || return 1
    rm -f "$temporary"
    printf '已启用出口机 IPv4 转发，并保留原有其他 IPv4 参数。\n'
}

cne_n_server_public() {
    local public
    [[ -f /etc/wireguard/cne-users.conf ]] || { cne_n_error '未找到客户端入口配置。'; return 1; }
    public=$(sed -nE 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' /etc/wireguard/cne-users.conf | wg pubkey) || return 1
    [[ $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || return 1
    printf '%s\n' "$public"
}
cne_n_client_list() {
    local config=/etc/wireguard/cne-users.conf temporary public address name number index=0 registry=/etc/cn-egress/clients.tsv
    [[ -f $config ]] || return 0
    # Existing v1 peers need no imported metadata: derive a stable name from their address.
    while IFS=$'\t' read -r public address; do
        [[ $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || continue
        if [[ $address =~ ^10\.77\.10\.[0-9]+/32$ ]]; then
            number=${address##*.}; number=${number%%/*}; name="legacy-$number"
        else
            ((index+=1)); number=$address; name="legacy-range-$index"
        fi
        if [[ -f $registry ]]; then
            temporary=$(awk -F'\t' -v k="$public" '$3==k{print $1;exit}' "$registry")
            [[ $temporary =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] && name=$temporary
        fi
        printf '%s\t%s\t%s\n' "$name" "$number" "$public"
    done < <(awk '
      function emit(){if(pub!=""&&addr!="")print pub "\t" addr;pub="";addr=""}
      /^\[Peer\]/{emit();peer=1;next}
      /^\[/{emit();peer=0}
      peer && /^[[:space:]]*PublicKey[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");gsub(/[[:space:]]+$/,"");pub=$0}
      peer && /^[[:space:]]*AllowedIPs[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");split($0,a,",");gsub(/[[:space:]]/,"",a[1]);addr=a[1]}
      END{emit()}' "$config")
}
cne_n_client_sync() {
    if ip -n cn-egress-relay link show cne-users >/dev/null 2>&1; then
        local stripped result
        stripped=$(mktemp /etc/wireguard/.cne-sync.XXXXXXXX) || return 1
        chmod 600 "$stripped"
        if ! wg-quick strip /etc/wireguard/cne-users.conf > "$stripped"; then rm -f "$stripped"; return 1; fi
        cne_n_net hk wg syncconf cne-users "$stripped"; result=$?
        rm -f "$stripped"
        return "$result"
    fi
}
cne_n_client_add() {
    local role=$1 name=$2 address=$3 public=$4 psk=${CNE_CLIENT_PSK:-} config=/etc/wireguard/cne-users.conf registry=/etc/cn-egress/clients.tsv saved temporary registry_new existing
    [[ $role == hk ]] && cne_n_require_role hk || return 1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ && $address =~ ^[0-9]+$ && $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] && ((address>=2 && address<=249)) || { cne_n_error '客户端名称、地址或公钥无效。'; return 1; }
    [[ -n $psk ]] || IFS= read -r psk
    [[ $psk =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '客户端预共享密钥无效。'; return 1; }
    # A legacy peer may own a range rather than one client. Do not allocate into an
    # unparseable or wider range based only on registry metadata.
    if ! awk '
      /^[[:space:]]*AllowedIPs[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,"");n=split($0,a,",");v4=0;
        for(i=1;i<=n;i++){gsub(/[[:space:]]/,"",a[i]);if(a[i]~/^10[.]77[.]10[.][0-9]+\/32$/)v4++;else if(a[i]!~/^fd77:77:10::[0-9]+\/128$/)bad=1}
        if(v4!=1)bad=1}
      END{exit bad?1:0}' "$config"; then cne_n_error '已有客户端包含范围地址或非标准网段，请先处理地址分配后新增。'; return 1; fi
    existing=$(cne_n_client_list)
    if awk -F'\t' -v n="$name" -v a="$address" -v k="$public" '$1==n||$2==a||$3==k{found=1}END{exit !found}' <<< "$existing"; then cne_n_error '客户端名称、地址或公钥已存在。'; return 1; fi
    [[ $public != "$(cne_n_server_public)" ]] || { cne_n_error '客户端公钥不能使用服务端公钥。'; return 1; }
    cne_n_safe_path "$config" && cne_n_safe_path "$registry" || return 1
    mkdir -p -m 700 /etc/cn-egress || return 1
    registry_new=$(mktemp /etc/cn-egress/.clients.XXXXXXXX) || return 1
    if [[ -f $registry ]]; then cat "$registry" > "$registry_new" || { rm -f "$registry_new"; return 1; }; fi
    printf '%s\t%s\t%s\n' "$name" "$address" "$public" >> "$registry_new" && chmod 600 "$registry_new" || { rm -f "$registry_new"; return 1; }
    saved=$(mktemp /etc/wireguard/.cne-before.XXXXXXXX) && cp -p "$config" "$saved" || { rm -f "$registry_new"; return 1; }
    temporary=$(mktemp /etc/wireguard/.cne-new.XXXXXXXX) || { rm -f "$saved" "$registry_new"; return 1; }
    cat "$config" > "$temporary" || { rm -f "$temporary" "$saved" "$registry_new"; return 1; }
    printf '\n[Peer]\n# client: %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.77.10.%s/32, fd77:77:10::%s/128\n' "$name" "$public" "$psk" "$address" "$address" >> "$temporary" || return 1
    unset psk CNE_CLIENT_PSK
    chmod 600 "$temporary" && mv "$temporary" "$config" || return 1
    if ! cne_n_client_sync || ! mv "$registry_new" "$registry"; then
        cp -p "$saved" "$config" && cne_n_client_sync || { cne_n_error "客户端回滚未完成，原配置保留在 $saved"; return 1; }
        rm -f "$saved" "$registry_new"; cne_n_error '客户端更新失败，已恢复原配置。'; return 1
    fi
    rm -f "$saved"
    printf '客户端已添加：%s\n' "$name"
}
cne_n_client_remove() {
    local role=$1 name=$2 public config=/etc/wireguard/cne-users.conf registry=/etc/cn-egress/clients.tsv saved temporary registry_new=''
    [[ $role == hk ]] && cne_n_require_role hk || return 1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || return 1
    public=$(cne_n_client_list | awk -F'\t' -v n="$name" '$1==n{print $3;exit}')
    [[ $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '未找到该客户端。'; return 1; }
    cne_n_safe_path "$config" && cne_n_safe_path "$registry" || return 1
    if [[ -f $registry ]]; then
        registry_new=$(mktemp /etc/cn-egress/.clients.XXXXXXXX) || return 1
        awk -F'\t' -v k="$public" '$3!=k' "$registry" > "$registry_new" && chmod 600 "$registry_new" || { rm -f "$registry_new"; return 1; }
    fi
    saved=$(mktemp /etc/wireguard/.cne-before.XXXXXXXX) && cp -p "$config" "$saved" || return 1
    temporary=$(mktemp /etc/wireguard/.cne-new.XXXXXXXX) || return 1
    awk -v key="$public" '
      function emit(){if(!remove)printf "%s",block;block="";remove=0}
      /^\[/{emit()}
      {block=block $0 "\n";line=$0;if(line~/^[[:space:]]*PublicKey[[:space:]]*=/){sub(/^[^=]*=[[:space:]]*/,"",line);gsub(/[[:space:]]+$/,"",line);if(line==key)remove=1}}
      END{emit()}' "$config" > "$temporary" || return 1
    chmod 600 "$temporary" && mv "$temporary" "$config" || return 1
    if ! cne_n_client_sync || { [[ -n $registry_new ]] && ! mv "$registry_new" "$registry"; }; then
        cp -p "$saved" "$config" && cne_n_client_sync || { cne_n_error "撤销回滚未完成，原配置保留在 $saved"; return 1; }
        rm -f "$saved" "$registry_new"; cne_n_error '撤销失败，已恢复原配置。'; return 1
    fi
    rm -f "$saved"
    printf '客户端已撤销：%s\n' "$name"
}
cne_n_dispatch() {
    local action=$1 role=$2; shift 2
    case $action in
        inspect) cne_n_inspect;;
        preflight) cne_n_preflight "$role" "$@";;
        prepare) cne_n_prepare "$role";;
        backup) cne_n_scope_check && cne_n_backup;;
        install) (($#==3)) || return 2; cne_n_install "$role" "$@";;
        status) cne_n_status "$role";;
        doctor) cne_n_doctor "$role";;
        logs) cne_n_logs;;
        start|stop|restart) cne_n_service_action "$action" "$role";;
        manage) cne_n_require_role "$role" && cne_n_status "$role";;
        uninstall) cne_n_uninstall "$role" "${1:-}";;
        enable-forwarding) [[ $role == exit ]] && cne_n_enable_forwarding "${1:-}";;
        server-public) [[ $role == hk ]] && cne_n_server_public;;
        client-list) [[ $role == hk ]] && cne_n_client_list;;
        client-add) (($#==3)) || return 2; cne_n_client_add "$role" "$@";;
        client-remove) (($#==1)) || return 2; cne_n_client_remove "$role" "$@";;
        keygen)
            local count=${1:-1} private public i
            [[ $count =~ ^[0-9]+$ ]] && ((count>=1 && count<=32)) || return 2
            for ((i=0;i<count;i++)); do private=$(wg genkey) && public=$(printf '%s\n' "$private" | wg pubkey) || return 1; printf '%s\t%s\n' "$private" "$public"; done
            unset private;;
        *) cne_n_error '未知节点操作。'; return 2;;
    esac
}
cne_node_main() (
    # The subshell prevents locks, umask and traps from leaking into a sourced controller.
    umask 077
    export LC_ALL=C
    local action=${1:-} role=${2:-} status lock
    cne_n_role_ok "$role" || { cne_n_error '节点角色无效。'; return 2; }
    [[ $(id -u) == 0 ]] || { cne_n_error '节点操作需要 root 权限。'; return 1; }
    # util-linux/flock is present on supported Debian/Ubuntu base systems. A prepare run
    # can install it if absent, then all subsequent modifying actions take the lock.
    if cne_n_has flock; then
        cne_n_safe_path /run/lock/cn-egress.lock || return 1
        exec 9>/run/lock/cn-egress.lock || return 1
        flock -w 30 9 || { cne_n_error '另一个安装或管理操作正在运行。'; return 1; }
    elif [[ $action != inspect && $action != preflight && $action != prepare && $action != status ]]; then cne_n_error '缺少 flock，请先安装依赖。'; return 1; fi
    cne_n_dispatch "$@"
)
if [[ ${CNE_NODE_LIBRARY:-0} != 1 && ${BASH_SOURCE[0]:-} == "$0" ]]; then cne_node_main "$@"; fi

CNE_EMBEDDED_cne_node_source_V2
}

cne_net_source() {
cat <<'CNE_EMBEDDED_cne_net_source_V2'
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
    relay_wg_up cne-users 10.77.10.1/24 fd77:77:10::1/64
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

CNE_EMBEDDED_cne_net_source_V2
}

cne_obfs_source() {
cat <<'CNE_EMBEDDED_cne_obfs_source_V2'
#!/usr/bin/env bash
# Run the authenticated transport without modifying host routes or trust stores.
set -euo pipefail
config=/etc/cn-egress-wss
IFS= read -r role < "$config/role"
IFS= read -r host < "$config/sh-host"
IFS= read -r port < "$config/port"
[[ $role == hk || $role == sh || $role == exit ]] || { printf 'Invalid transport role\n' >&2; exit 1; }
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && ${#host} -le 253 ]] || { printf 'Invalid transport host\n' >&2; exit 1; }
[[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { printf 'Invalid transport port\n' >&2; exit 1; }
binary=/opt/cn-egress/wstunnel-11.0.0/wstunnel
mode=client
[[ $role != sh ]] || mode=server
args=("$binary" "$mode" --no-color --log-lvl INFO --nb-worker-threads 2
    --tls-certificate "$config/node.crt" --tls-private-key "$config/node.key")
if [[ $role == sh ]]; then
    args+=(--tls-client-ca-certs "$config/ca.crt" --restrict-config "$config/restrictions.yaml" "wss://0.0.0.0:$port")
else
    export SSL_CERT_FILE="$config/ca.crt" SSL_CERT_DIR="$config/empty-ca"
    if [[ $role == hk ]]; then local_port=51831; remote_port=51821; else local_port=51832; remote_port=51822; fi
    args+=(--tls-verify-certificate --http-upgrade-path-prefix "cn-egress-$role" -L
        "udp://127.0.0.1:$local_port:127.0.0.1:$remote_port?timeout_sec=0" "wss://$host:$port")
fi
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
exec "${args[@]}"

CNE_EMBEDDED_cne_obfs_source_V2
}

cne_restrictions_source() {
cat <<'CNE_EMBEDDED_cne_restrictions_source_V2'
restrictions:
  - name: hk-wireguard
    match:
      - !PathPrefix "^cn-egress-hk$"
    allow:
      - !Tunnel
        protocol: [Udp]
        port: ["51821"]
        host: "^$"
        cidr: ["127.0.0.1/32"]

  - name: exit-wireguard
    match:
      - !PathPrefix "^cn-egress-exit$"
    allow:
      - !Tunnel
        protocol: [Udp]
        port: ["51822"]
        host: "^$"
        cidr: ["127.0.0.1/32"]

CNE_EMBEDDED_cne_restrictions_source_V2
}
#!/usr/bin/env bash
# Management prerequisites for supported Debian / Ubuntu hosts.
cne_root() {
    if [[ $(id -u) == 0 ]]; then env LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@" </dev/null
    else sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@" </dev/null; fi
}
cne_bootstrap() {
    local item tool package installed audit plan line
    local packages=()
    [[ $(uname -s) == Linux ]] || { cne_error '请在 Debian 12+ 或 Ubuntu 22.04+ 的 Linux 管理机运行。'; return 1; }
    command -v apt-get >/dev/null 2>&1 || { cne_error '当前版本支持 Debian / Ubuntu 的 APT 系统。'; return 1; }
    for item in 'ssh:openssh-client' 'sshpass:sshpass' 'openssl:openssl' 'curl:curl' 'wg:wireguard-tools' 'flock:util-linux' 'qrencode:qrencode' 'tar:tar' 'base64:coreutils' 'sha256sum:coreutils' 'gzip:gzip'; do
        tool=${item%%:*}; package=${item#*:}
        if ! command -v "$tool" >/dev/null 2>&1; then
            case " ${packages[*]:-} " in *" $package "*) ;; *) packages+=("$package");; esac
        fi
    done
    installed=$(dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null) || installed=''
    [[ $installed == 'install ok installed' ]] || packages+=(ca-certificates)
    [[ ${#packages[@]} -gt 0 ]] || return 0
    if [[ $(id -u) != 0 ]]; then
        command -v sudo >/dev/null 2>&1 || { cne_error '自动安装依赖需要 root 或 sudo。'; return 1; }
        sudo -v || return 1
    fi
    printf '\n首次准备：安装缺少的依赖 %s\n' "${packages[*]}"
    audit=$(cne_root dpkg --audit) || return 1
    [[ -z $audit ]] || { cne_error '系统存在未完成的软件包操作，请先处理 dpkg 状态。'; return 1; }
    cne_root apt-get -qq update || { cne_error '软件源更新失败，请检查网络。'; return 1; }
    plan=$(cne_root apt-get -s --no-install-recommends --no-upgrade --no-remove install "${packages[@]}") || return 1
    while IFS= read -r line; do
        if [[ $line == Remv\ * || $line =~ ^Inst[[:space:]]+[^[:space:]]+[[:space:]]+\[ ]]; then
            cne_error '安装依赖需要升级或删除已有软件，已停止。请先处理系统软件包版本。'; return 1
        fi
    done <<< "$plan"
    cne_root apt-get -y -qq --no-install-recommends --no-upgrade --no-remove install "${packages[@]}" || return 1
    for tool in ssh sshpass openssl curl wg flock qrencode tar base64 sha256sum gzip; do
        command -v "$tool" >/dev/null 2>&1 || { cne_error "安装后仍缺少 $tool。"; return 1; }
    done
    printf '依赖准备完成。\n'
}
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

# FILE ADDRESS PRIVATE_KEY SERVER_PUBLIC_KEY PSK HK_HOST USER_PORT
cne_render_client() (
    set -euo pipefail
    umask 077
    local file=$1 number=$2 private=$3 public=$4 psk=$5 host=$6 port=$7
    [[ $number =~ ^[0-9]{1,3}$ ]] && (( 10#$number >= 2 && 10#$number <= 249 )) || { cne_render_error '客户端地址须为 2 到 249'; exit 1; }
    number=$((10#$number))
    cne_render_key "$private" && cne_render_key "$public" && cne_render_key "$psk" || { cne_render_error 'WireGuard 密钥格式无效'; exit 1; }
    cne_render_host "$host" && cne_render_port "$port" || { cne_render_error '香港地址或端口无效'; exit 1; }
    [[ ! -e $file && ! -L $file ]] || { cne_render_error '客户端配置已存在'; exit 1; }
    set -o noclobber
    cat > "$file" <<EOF
[Interface]
PrivateKey = $private
Address = 10.77.10.$number/32, fd77:77:10::$number/128
DNS = 10.77.30.2
MTU = 1380

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
    cat <<EOF
table inet cn_egress {
  chain input_guard {
    type filter hook input priority -5; policy accept;
    iifname "cne-exit" ip saddr 10.77.10.0/24 udp dport 5354 counter accept
    iifname "cne-exit" ip saddr 10.77.10.0/24 tcp dport 5354 counter accept
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
    iifname "cne-exit" ip saddr 10.77.10.0/24 ip daddr 10.77.30.2 udp dport 53 counter redirect to :5354
    iifname "cne-exit" ip saddr 10.77.10.0/24 ip daddr 10.77.30.2 tcp dport 53 counter redirect to :5354
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
    local root=$1 role=$2 after=network-online.target
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
    chmod 644 "$root/etc/systemd/system/"*.service "$root/etc/systemd/system/cn-egress.service.d/obfs.conf"
}

# Run the renderer in a fresh Bash process so a caller's `if`/`!` cannot disable
# errexit halfway through certificate generation. No source file is unpacked.
# OUT HK_IP SH_IP USER_PORT WSS_PORT WAN
cne_render_bundle() {
    local definitions
    definitions=$(declare -f cne_render_error cne_render_host cne_render_port \
        cne_render_key cne_render_client cne_render_interface cne_render_peer \
        cne_render_relay_firewall cne_render_exit_firewall cne_render_pki \
        cne_render_services cne_render_bundle_impl cne_net_source \
        cne_obfs_source cne_restrictions_source cne_node_source) || return 1
    printf '%s\ncne_render_bundle_impl "$@"\n' "$definitions" | bash -euo pipefail -s -- "$@"
}

cne_render_bundle_impl() (
    set -euo pipefail
    umask 077
    local out=$1 hk=$2 sh=$3 user_port=$4 wss_port=$5 wan=$6
    local role root key private public psk name number pair
    cne_render_host "$hk" && cne_render_host "$sh" || { cne_render_error '节点地址无效'; exit 1; }
    cne_render_port "$user_port" && cne_render_port "$wss_port" || { cne_render_error '监听端口无效'; exit 1; }
    [[ $wan =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { cne_render_error '出口网卡名无效'; exit 1; }
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
        cp "$out/pki/ca.crt" "$root/etc/cn-egress-wss/ca.crt"
        cp "$out/pki/$role.key" "$root/etc/cn-egress-wss/node.key"
        cp "$out/pki/$role.crt" "$root/etc/cn-egress-wss/node.crt"
        chmod 640 "$root/etc/cn-egress-wss/"{role,sh-host,port,ca.crt,node.key,node.crt}
        cne_render_services "$root" "$role"
    done
    cne_render_interface "$(cat "$out/keys/hk_users.key")" '10.77.10.1/24, fd77:77:10::1/64' "$user_port" > "$out/hk/etc/wireguard/cne-users.conf"
    cp "$out/keys/hk_users.pub" "$out/hk/etc/cn-egress/server-public"
    : > "$out/client-registry.tsv"
    for pair in iPhone:10 Android:20 Windows:30; do
        name=${pair%:*}; number=${pair#*:}
        private=$(wg genkey); public=$(printf '%s\n' "$private" | wg pubkey); psk=$(wg genpsk)
        cne_render_client "$out/clients/$name.conf" "$number" "$private" "$(cat "$out/keys/hk_users.pub")" "$psk" "$hk" "$user_port"
        cne_render_peer "$public" "$psk" "10.77.10.$number/32, fd77:77:10::$number/128" >> "$out/hk/etc/wireguard/cne-users.conf"
        printf '%s\t%s\t%s\n' "$name" "$number" "$public" >> "$out/client-registry.tsv"
    done
    cp "$out/client-registry.tsv" "$out/hk/etc/cn-egress/clients.tsv"
    cne_render_interface "$(cat "$out/keys/hk_cn.key")" '10.77.20.1/30, fd77:77:20::1/64' > "$out/hk/etc/wireguard/cne-cn.conf"
    cne_render_peer "$(cat "$out/keys/sh_cn.pub")" "$(cat "$out/keys/hk_sh.psk")" '0.0.0.0/0, ::/0' '127.0.0.1:51831' >> "$out/hk/etc/wireguard/cne-cn.conf"
    cne_render_interface "$(cat "$out/keys/sh_cn.key")" '10.77.20.2/30, fd77:77:20::2/64' 51821 > "$out/sh/etc/wireguard/cne-cn.conf"
    cne_render_peer "$(cat "$out/keys/hk_cn.pub")" "$(cat "$out/keys/hk_sh.psk")" '10.77.20.1/32, fd77:77:20::1/128, 10.77.10.0/24, fd77:77:10::/64' >> "$out/sh/etc/wireguard/cne-cn.conf"
    cne_render_interface "$(cat "$out/keys/sh_exit.key")" '10.77.30.1/30, fd77:77:30::1/64' 51822 > "$out/sh/etc/wireguard/cne-exit.conf"
    cne_render_peer "$(cat "$out/keys/exit.pub")" "$(cat "$out/keys/sh_exit.psk")" '0.0.0.0/0, ::/0' >> "$out/sh/etc/wireguard/cne-exit.conf"
    cne_render_interface "$(cat "$out/keys/exit.key")" '10.77.30.2/30, fd77:77:30::2/64' > "$out/exit/etc/wireguard/cne-exit.conf"
    cne_render_peer "$(cat "$out/keys/sh_exit.pub")" "$(cat "$out/keys/sh_exit.psk")" '10.77.30.1/32, fd77:77:30::1/128, 10.77.10.0/24, fd77:77:10::/64' '127.0.0.1:51832' >> "$out/exit/etc/wireguard/cne-exit.conf"
    cne_render_relay_firewall cne-users cne-cn > "$out/hk/etc/cn-egress/firewall.nft"
    cne_render_relay_firewall cne-cn cne-exit > "$out/sh/etc/cn-egress/firewall.nft"
    cne_render_exit_firewall "$wan" > "$out/exit/etc/cn-egress/firewall.nft"
    printf '%s\n' "$wan" > "$out/exit/etc/cn-egress/wan-interface"
    cne_restrictions_source > "$out/sh/etc/cn-egress-wss/restrictions.yaml"
    chmod 640 "$out/sh/etc/cn-egress-wss/restrictions.yaml"
    cat > "$out/sh/etc/cn-egress-wss/guard.nft" <<'EOF'
table inet cne_wss_input {
  chain input_guard {
    type filter hook input priority -10; policy accept;
    iifname != "lo" udp dport { 51821, 51822 } counter drop
  }
}
EOF
    cat > "$out/exit/etc/cn-egress/dnsmasq.conf" <<'EOF'
interface=cne-exit
listen-address=10.77.30.2
bind-dynamic
port=5354
cache-size=1000
domain-needed
bogus-priv
filter-AAAA
user=nobody
group=nogroup
pid-file=
EOF
)
#!/usr/bin/env bash
# Bash controller. The release builder embeds all required Shell sources.
CNE_VERSION=2.0.0
CNE_ROLES=(hk sh exit)
CNE_LABELS=('香港入口' '大陆中转' '国内出口')
CNE_HOSTS=('' '' '')
CNE_USERS=(root root root)
CNE_PORTS=(22 22 22)
CNE_IDENTITIES=(- - -)
CNE_PASSWORDS=('' '' '')
CNE_SUDOS=('' '' '')
CNE_AUTH_READY=(0 0 0)
CNE_USER_PORT=51820
CNE_WSS_PORT=443

cne_error() { printf '\n错误：%s\n' "$*" >&2; return 1; }
cne_note() { printf '%s\n' "$*" >&2; }
cne_line() { printf '%s\n' '----------------------------------------'; }
cne_field() { printf '%s\n' "$1" | awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/, "");print;exit}'; }
cne_ipv4() {
    local a b c d part
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for part in "$a" "$b" "$c" "$d"; do
        [[ ${#part} -le 3 && $part =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
}
cne_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
cne_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; }
cne_key() { [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
cne_prompt() {
    local label=$1 default=${2:-} answer
    if [[ -n $default ]]; then printf '%s [%s]：' "$label" "$default" >&2; else printf '%s：' "$label" >&2; fi
    IFS= read -r answer || return 1
    CNE_ANSWER=${answer:-$default}
}
cne_secret() {
    printf '%s：' "$1" >&2
    IFS= read -r -s CNE_ANSWER || return 1
    printf '\n' >&2
}
cne_safe_directory() {
    local directory=$1 component parent
    [[ $directory = /* && $directory != / ]] || { cne_error '管理目录必须是绝对路径。'; return 1; }
    component=$directory
    while [[ $component != / ]]; do
        [[ ! -L $component ]] || { cne_error '管理目录不能经过符号链接。'; return 1; }
        component=${component%/*}; [[ -n $component ]] || component=/
    done
    [[ ! -e $directory || -d $directory && -O $directory ]] || { cne_error '管理目录不属于当前用户。'; return 1; }
    mkdir -p -- "$directory" && chmod 700 -- "$directory"
}
cne_initialize() {
    umask 077
    CNE_STATE=${CNE_HOME:-${HOME:?}/.local/share/cn-egress-shell}
    cne_safe_directory "$CNE_STATE" || return 1
    [[ ! -L $CNE_STATE/lock ]] || return 1
    exec 8>"$CNE_STATE/lock"
    flock -n 8 || { cne_error '已有管理菜单运行，请先退出那个窗口。'; return 1; }
    mkdir -p "$CNE_STATE/cache" "$CNE_STATE/clients" "$CNE_STATE/history" || return 1
    CNE_TEMP=$(mktemp -d "$CNE_STATE/.session.XXXXXX") || return 1
    [[ ! -L $CNE_STATE/known_hosts ]] || return 1
    touch "$CNE_STATE/known_hosts" && chmod 600 "$CNE_STATE/known_hosts" || return 1
    trap 'cne_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cne_load_config
}
cne_cleanup() {
    CNE_PASSWORDS=(); CNE_SUDOS=(); unset CNE_ANSWER
    if [[ -n ${CNE_TEMP:-} && $CNE_TEMP == "$CNE_STATE"/.session.* && -d $CNE_TEMP && ! -L $CNE_TEMP ]]; then
        rm -rf -- "$CNE_TEMP"
    fi
}
cne_load_config() {
    local role host user port identity idx=0 line
    [[ -e $CNE_STATE/nodes.tsv ]] || return 0
    [[ -f $CNE_STATE/nodes.tsv && ! -L $CNE_STATE/nodes.tsv && -O $CNE_STATE/nodes.tsv ]] || { cne_error '节点配置文件不安全。'; return 1; }
    while IFS=$'\t' read -r role host user port identity; do
        (( idx < 3 )) || { cne_error '节点配置仅允许三个角色。'; return 1; }
        [[ $role == "${CNE_ROLES[$idx]}" ]] && cne_ipv4 "$host" && cne_port "$port" && [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || { cne_error '节点配置格式无效，请移走 nodes.tsv 后重新设置。'; return 1; }
        [[ $identity == - || $identity == /* && -f $identity ]] || { cne_error 'SSH 私钥路径无效。'; return 1; }
        CNE_HOSTS[$idx]=$host; CNE_USERS[$idx]=$user; CNE_PORTS[$idx]=$port; CNE_IDENTITIES[$idx]=$identity
        idx=$((idx+1))
    done < "$CNE_STATE/nodes.tsv"
    [[ $idx == 3 && ${CNE_HOSTS[0]} != "${CNE_HOSTS[1]}" && ${CNE_HOSTS[0]} != "${CNE_HOSTS[2]}" && ${CNE_HOSTS[1]} != "${CNE_HOSTS[2]}" ]] || { cne_error '请配置三个不同的节点。'; return 1; }
    if [[ -f $CNE_STATE/ports ]]; then
        read -r CNE_USER_PORT CNE_WSS_PORT < "$CNE_STATE/ports"
        cne_port "$CNE_USER_PORT" && cne_port "$CNE_WSS_PORT" || return 1
    fi
}
cne_setup() {
    local idx host user port identity
    local hosts=() users=() ports=() identities=()
    printf '\n配置安装节点\n大陆中转只填写一台，上海或北京任选其一。\n'
    for idx in 0 1 2; do
        printf '\n%s\n' "${CNE_LABELS[$idx]}"
        while :; do cne_prompt '  IPv4 地址' "${CNE_HOSTS[$idx]}" || return 1; host=$CNE_ANSWER; cne_ipv4 "$host" && break; cne_note '  地址格式不正确。'; done
        while :; do cne_prompt '  SSH 用户' "${CNE_USERS[$idx]}" || return 1; user=$CNE_ANSWER; [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] && break; cne_note '  用户名格式不正确。'; done
        while :; do cne_prompt '  SSH 端口' "${CNE_PORTS[$idx]}" || return 1; port=$CNE_ANSWER; cne_port "$port" && break; cne_note '  端口范围为 1–65535。'; done
        while :; do
            cne_prompt '  SSH 私钥绝对路径（- 使用密码）' "${CNE_IDENTITIES[$idx]}" || return 1; identity=$CNE_ANSWER
            [[ $identity != *$'\t'* && $identity != *$'\n'* && ( $identity == - || $identity == /* && -f $identity ) ]] && break
            cne_note '  文件不存在，请填写绝对路径或 -。'
        done
        hosts[$idx]=$host; users[$idx]=$user; ports[$idx]=$port; identities[$idx]=$identity
    done
    [[ ${hosts[0]} != "${hosts[1]}" && ${hosts[0]} != "${hosts[2]}" && ${hosts[1]} != "${hosts[2]}" ]] || { cne_error '三个角色需要不同机器，大陆中转只填一台。'; return 1; }
    while :; do cne_prompt '客户端 UDP 端口' "$CNE_USER_PORT" || return 1; cne_port "$CNE_ANSWER" && break; done
    CNE_USER_PORT=$CNE_ANSWER
    while :; do cne_prompt '中转 TLS 端口' "$CNE_WSS_PORT" || return 1; cne_port "$CNE_ANSWER" && break; done
    CNE_WSS_PORT=$CNE_ANSWER
    CNE_HOSTS=("${hosts[@]}"); CNE_USERS=("${users[@]}"); CNE_PORTS=("${ports[@]}"); CNE_IDENTITIES=("${identities[@]}")
    for idx in 0 1 2; do printf '%s\t%s\t%s\t%s\t%s\n' "${CNE_ROLES[$idx]}" "${hosts[$idx]}" "${users[$idx]}" "${ports[$idx]}" "${identities[$idx]}" || return 1; done > "$CNE_TEMP/nodes.tsv" || return 1
    mv "$CNE_TEMP/nodes.tsv" "$CNE_STATE/nodes.tsv" || return 1
    printf '%s %s\n' "$CNE_USER_PORT" "$CNE_WSS_PORT" > "$CNE_STATE/ports" || return 1
    CNE_AUTH_READY=(0 0 0)
    printf '\n节点已保存。SSH 密码仅在本次运行期间使用。\n'
}
cne_require_config() { [[ -n ${CNE_HOSTS[0]} && -n ${CNE_HOSTS[1]} && -n ${CNE_HOSTS[2]} ]] || cne_setup; }
cne_authenticate() {
    local idx=$1
    [[ ${CNE_AUTH_READY[$idx]} == 1 ]] && return 0
    if [[ ${CNE_IDENTITIES[$idx]} == - ]]; then
        cne_secret "${CNE_LABELS[$idx]} ${CNE_HOSTS[$idx]} SSH 密码" || return 1
    else
        cne_secret "${CNE_LABELS[$idx]} SSH 私钥口令（无则回车）" || return 1
    fi
    CNE_PASSWORDS[$idx]=$CNE_ANSWER
    if [[ ${CNE_USERS[$idx]} != root ]]; then
        cne_secret "${CNE_LABELS[$idx]} sudo 密码（回车使用 SSH 密码）" || return 1
        CNE_SUDOS[$idx]=${CNE_ANSWER:-${CNE_PASSWORDS[$idx]}}
    fi
    unset CNE_ANSWER
    CNE_AUTH_READY[$idx]=1
}
cne_send_script() {
    local idx=$1 script=$2 command
    local args=(-T -F /dev/null -p "${CNE_PORTS[$idx]}" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$CNE_STATE/known_hosts" -o LogLevel=ERROR -o NumberOfPasswordPrompts=1)
    local password_args=(-d 9)
    if [[ ${CNE_IDENTITIES[$idx]} == - ]]; then args+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive)
    else args+=(-i "${CNE_IDENTITIES[$idx]}" -o IdentitiesOnly=yes); password_args+=(-P passphrase); fi
    if [[ ${CNE_USERS[$idx]} == root ]]; then command='/bin/bash -s'
    else command='/bin/bash -c '\''IFS= read -r cne_sudo_password; sudo -S -p "" -v <<< "$cne_sudo_password" || exit; unset cne_sudo_password; sudo -n /bin/bash -s'\'''; fi
    args+=("${CNE_USERS[$idx]}@${CNE_HOSTS[$idx]}" "$command")
    { [[ ${CNE_USERS[$idx]} == root ]] || printf '%s\n' "${CNE_SUDOS[$idx]}"; cat "$script"; } |
        sshpass "${password_args[@]}" ssh "${args[@]}" 9<<< "${CNE_PASSWORDS[$idx]}"
}
cne_remote() {
    local idx=$1 action=$2 script
    shift 2
    script=$(mktemp "$CNE_TEMP/rpc.XXXXXX") || return 1
    {
        printf 'set -Eeuo pipefail\nexport LC_ALL=C\nCNE_NODE_LIBRARY=1\n'
        cne_node_source
        printf '\n'
        if [[ $action == client-add ]]; then printf 'CNE_CLIENT_PSK=%q\n' "${CNE_CLIENT_PSK:?}"; fi
        printf 'cne_node_main %q %q' "$action" "${CNE_ROLES[$idx]}"
        if [[ $# -gt 0 ]]; then printf ' %q' "$@"; fi
        printf '\n'
    } > "$script" || return 1
    cne_send_script "$idx" "$script"
    local result=$?
    rm -f "$script"
    return "$result"
}
cne_remote_install() {
    local idx=$1 mode=$2 archive=$3 deployment=$4 script result
    script=$(mktemp "$CNE_TEMP/install.XXXXXX") || return 1
    {
        printf 'set -Eeuo pipefail\nexport LC_ALL=C\nCNE_NODE_LIBRARY=1\n'
        cne_node_source
        printf '\ncne_upload=$(mktemp /root/.cn-egress-upload.XXXXXX)\ntrap '\''rm -f "$cne_upload"'\'' EXIT\n'
        printf 'base64 -d > "$cne_upload" <<'\''CNE_PAYLOAD_V2'\''\n'
        base64 < "$archive"
        printf '\nCNE_PAYLOAD_V2\n'
        printf 'cne_node_main install %q %q "$cne_upload" %q\n' "${CNE_ROLES[$idx]}" "$mode" "$deployment"
    } > "$script" || return 1
    cne_send_script "$idx" "$script"
    result=$?; rm -f "$script"; return "$result"
}
cne_inspect_all() {
    local idx state role
    CNE_INSPECTIONS=()
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
    printf '\n安装检查\n'; cne_line
    for idx in 0 1 2; do
        if ! CNE_INSPECTIONS[$idx]=$(cne_remote "$idx" inspect); then
            printf '  %s  %s  连接或检查失败\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}"
            CNE_AUTH_READY[$idx]=0
            return 1
        fi
        state=$(cne_field "${CNE_INSPECTIONS[$idx]}" state)
        role=$(cne_field "${CNE_INSPECTIONS[$idx]}" role)
        case $state in
            absent) state='未安装，可新装' ;;
            present) state='发现旧配置'; [[ $role == "${CNE_ROLES[$idx]}" ]] || state="$state（角色：${role:-未知}）" ;;
            *) cne_error '节点返回了无法识别的检查结果。'; return 1 ;;
        esac
        printf '  %s\n    地址：%s\n    状态：%s\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}" "$state"
    done
    cne_line
}
cne_existing_choice() {
    local choice
    printf '\n发现旧配置。请选择：\n\n'
    printf '  1. 保留现有配置，进入管理\n'
    printf '  2. 备份后重新安装整套服务\n'
    printf '  0. 取消\n\n'
    printf '选择 2 会为三台节点生成新密钥，旧客户端需重新导入配置。\n'
    while :; do
        cne_prompt '请选择' 0 || return 1
        case $CNE_ANSWER in 0|1|2) CNE_INSTALL_CHOICE=$CNE_ANSWER; return 0 ;; *) cne_note '请输入 0、1 或 2。' ;; esac
    done
}
cne_fetch_binary() {
    local arch=$1 checksum cache archive dir
    case $arch in
        x86_64|amd64) arch=amd64; checksum=9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e ;;
        aarch64|arm64) arch=arm64; checksum=b86abf73e340ed0c3ff9a77a5458aa27213784920ec65513132b36def45edc94 ;;
        *) cne_error "不支持的节点架构：$arch"; return 1 ;;
    esac
    archive=$CNE_STATE/cache/wstunnel_11.0.0_linux_$arch.tar.gz
    [[ ! -L $archive ]] || return 1
    if [[ ! -f $archive ]] || [[ $(sha256sum "$archive" | awk '{print $1}') != "$checksum" ]]; then
        cne_note "下载传输组件（$arch）…"
        curl -fL --retry 2 --connect-timeout 15 --max-time 180 "https://github.com/erebe/wstunnel/releases/download/v11.0.0/wstunnel_11.0.0_linux_$arch.tar.gz" -o "$CNE_TEMP/download.tar.gz" || return 1
        [[ $(sha256sum "$CNE_TEMP/download.tar.gz" | awk '{print $1}') == "$checksum" ]] || { cne_error '下载组件校验失败。'; return 1; }
        mv "$CNE_TEMP/download.tar.gz" "$archive" || return 1
    fi
    dir=$CNE_TEMP/binary-$arch; mkdir -p "$dir" || return 1
    # Only the named, checksum-verified executable is extracted.
    tar -xzf "$archive" -C "$dir" wstunnel || return 1
    chmod 755 "$dir/wstunnel" || return 1
    CNE_BINARY=$dir/wstunnel
}
cne_install() {
    local idx role state mode wan arch deployment directory backup_path refreshed token
    cne_require_config || return 1
    cne_inspect_all || return 1
    CNE_INSTALL_CHOICE=2
    for idx in 0 1 2; do
        if [[ $(cne_field "${CNE_INSPECTIONS[$idx]}" state) == present ]]; then cne_existing_choice || return 1; break; fi
    done
    case $CNE_INSTALL_CHOICE in
        0) printf '已取消。\n'; return 0 ;;
        1) printf '\n已保留现有配置。未安装的节点可下次选择“备份后重新安装整套服务”。\n'; cne_status; return ;;
    esac
    # Complete the installation plan before changing any VPN service.
    for idx in 0 1 2; do
        state=$(cne_field "${CNE_INSPECTIONS[$idx]}" state); mode=fresh; [[ $state != present ]] || mode=replace
        cne_note "检查${CNE_LABELS[$idx]}的安装条件…"
        cne_remote "$idx" preflight "$mode" "$CNE_USER_PORT" "$CNE_WSS_PORT" || return 1
    done
    if [[ $(cne_field "${CNE_INSPECTIONS[2]}" forwarding) != 1 ]]; then
        printf '\n出口机未开启 IPv4 转发，VPN 出口需要此设置。\n'
        cne_prompt '是否允许在出口机启用（y/N）' N || return 1
        [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消安装。\n'; return 0; }
        CNE_ENABLE_FORWARDING=1
    else CNE_ENABLE_FORWARDING=0; fi
    cne_note '准备节点依赖…'
    for idx in 0 1 2; do cne_remote "$idx" prepare || return 1; done
    # Recheck with all inspection tools available, before rendering or replacement.
    for idx in 0 1 2; do
        state=$(cne_field "${CNE_INSPECTIONS[$idx]}" state); mode=fresh; [[ $state != present ]] || mode=replace
        refreshed=$(cne_remote "$idx" inspect) || return 1
        [[ $(cne_field "$refreshed" state) == "$state" ]] || { cne_error '检查期间节点部署发生变化，请重新执行安装。'; return 1; }
        CNE_INSPECTIONS[$idx]=$refreshed
        cne_remote "$idx" preflight "$mode" "$CNE_USER_PORT" "$CNE_WSS_PORT" || return 1
    done
    wan=$(cne_field "${CNE_INSPECTIONS[2]}" wan)
    [[ $wan =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { cne_error '无法识别出口机出网网卡。'; return 1; }
    token=$(openssl rand -hex 6) || return 1
    deployment=$(date -u +%Y%m%dT%H%M%SZ)-$token
    directory=$CNE_STATE/history/$deployment
    mkdir -m 700 "$directory" || return 1
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/ports" "$directory/" || return 1
    cne_note '生成安装配置和客户端文件…'
    ( set -Eeuo pipefail; cne_render_bundle "$directory/bundle" "${CNE_HOSTS[0]}" "${CNE_HOSTS[1]}" "$CNE_USER_PORT" "$CNE_WSS_PORT" "$wan" ) || return 1
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        arch=$(cne_field "${CNE_INSPECTIONS[$idx]}" arch)
        cne_fetch_binary "$arch" || return 1
        mkdir -p "$directory/bundle/$role/opt/cn-egress/wstunnel-11.0.0" || return 1
        cp "$CNE_BINARY" "$directory/bundle/$role/opt/cn-egress/wstunnel-11.0.0/wstunnel" || return 1
        printf '%s\n' "$deployment" > "$directory/bundle/$role/etc/cn-egress/deployment-id" || return 1
        (cd "$directory/bundle/$role" && find . -type f | sed 's#^./##' | LC_ALL=C sort > "$directory/$role.files" && tar -czf "$directory/$role.tar.gz" -T "$directory/$role.files") || return 1
    done
    for idx in 0 1 2; do
        if [[ $(cne_field "${CNE_INSPECTIONS[$idx]}" state) == present ]]; then
            cne_note "备份${CNE_LABELS[$idx]}旧配置…"
            backup_path=$(cne_remote "$idx" backup) || return 1
            printf '%s\t%s\n' "${CNE_ROLES[$idx]}" "$backup_path" >> "$directory/backups.tsv" || return 1
            printf '  %s备份：%s\n' "${CNE_LABELS[$idx]}" "$backup_path"
        fi
    done
    if [[ $CNE_ENABLE_FORWARDING == 1 ]]; then cne_remote 2 enable-forwarding confirm || return 1; fi
    printf '\n开始安装\n'; cne_line
    for idx in 1 2 0; do
        role=${CNE_ROLES[$idx]}; mode=fresh
        [[ $(cne_field "${CNE_INSPECTIONS[$idx]}" state) != present ]] || mode=replace
        printf '正在安装：%s（%s）\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}"
        if ! cne_remote_install "$idx" "$mode" "$directory/$role.tar.gz" "$deployment"; then
            printf '\n安装在%s停止。该节点已尝试恢复安装前配置。\n' "${CNE_LABELS[$idx]}" >&2
            printf '本次记录：%s\n已完成节点见 completed.txt；旧配置备份见 backups.tsv。\n' "$directory" >&2
            printf '可查看状态后重新选择安装；下次仍会提供保留或覆盖选项。\n' >&2
            return 1
        fi
        printf '%s\n' "$role" >> "$directory/completed.txt" || return 1
    done
    # Publish clients only when all nodes have been installed successfully.
    if [[ -n $(find "$CNE_STATE/clients" -type f -name '*.conf' -print -quit) ]]; then
        mkdir "$directory/previous-clients" && cp "$CNE_STATE"/clients/*.conf "$directory/previous-clients/" || return 1
    fi
    rm -f "$CNE_STATE"/clients/*.conf || return 1
    cp "$directory/bundle/clients/"*.conf "$CNE_STATE/clients/" || return 1
    printf '%s\n' "$deployment" > "$CNE_STATE/current-deployment" || return 1
    printf '\n安装完成。\n客户端配置目录：%s\n\n' "$CNE_STATE/clients"
    cne_status
}
cne_status() {
    local idx info state result=0
    cne_require_config || return 1
    printf '\n节点状态\n'; cne_line
    for idx in 0 1 2; do
        cne_authenticate "$idx" || return 1
        printf '\n%s · %s\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}"
        if ! cne_remote "$idx" status; then result=1; CNE_AUTH_READY[$idx]=0; fi
    done
    cne_line
    return "$result"
}
cne_action_all() {
    local action=$1 idx result=0
    local order=(0 1 2)
    cne_require_config || return 1
    case $action in start|restart) order=(1 2 0);; stop|uninstall) order=(0 2 1);; esac
    for idx in "${order[@]}"; do cne_authenticate "$idx" || return 1; done
    for idx in "${order[@]}"; do
        printf '\n%s · %s\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}"
        if [[ $action == uninstall ]]; then cne_remote "$idx" uninstall confirm || result=1
        else cne_remote "$idx" "$action" || result=1; fi
    done
    return "$result"
}
cne_clients_list() {
    cne_require_config && cne_authenticate 0 || return 1
    local name address public data
    data=$(cne_remote 0 client-list) || return 1
    printf '\n客户端列表\n'; cne_line
    if [[ -z $data ]]; then printf '暂无客户端。\n'; return 0; fi
    while IFS=$'\t' read -r name address public; do
        if [[ $address =~ ^[0-9]+$ ]]; then address=10.77.10.$address; fi
        printf '  %s  %s\n' "$name" "$address"
    done <<< "$data"
}
cne_profile_field() {
    awk -v section="$2" -v field="$3" '
      /^\[/{active=($0=="[" section "]");next}
      active && index($0,"="){key=$0;sub(/[[:space:]]*=.*/,"",key);gsub(/^[[:space:]]*/,"",key);
        if(key==field){sub(/^[^=]*=[[:space:]]*/,"");gsub(/[[:space:]]+$/,"");print;exit}}' "$1"
}
cne_client_add() {
    local name address public private psk server data current index pending user_port existing
    cne_require_config && cne_authenticate 0 || return 1
    cne_prompt '客户端名称（英文或数字）' || return 1; name=$CNE_ANSWER
    cne_name "$name" || { cne_error '名称只允许 1–32 位英文、数字、下划线或短横线。'; return 1; }
    [[ ! -e $CNE_STATE/clients/$name.conf ]] || { cne_error '该名称已有本地配置，请换一个名称。'; return 1; }
    data=$(cne_remote 0 client-list) || return 1
    server=$(cne_remote 0 server-public) || return 1; cne_key "$server" || return 1
    current=$(cne_remote 0 inspect) || return 1
    user_port=$(cne_field "$current" user_port)
    cne_port "$user_port" || { cne_error '无法读取现有入口端口。'; return 1; }
    pending=$CNE_STATE/clients/$name.conf.pending
    existing=$(printf '%s\n' "$data" | awk -F '\t' -v name="$name" '$1==name {print;exit}')
    if [[ -e $pending || -L $pending ]]; then
        [[ -f $pending && ! -L $pending && -O $pending ]] || return 1
        [[ $(cne_profile_field "$pending" Peer PublicKey) == "$server" && $(cne_profile_field "$pending" Peer Endpoint) == "${CNE_HOSTS[0]}:$user_port" ]] || { cne_error '待用配置属于不同部署，请使用新的客户端名称。'; return 1; }
        private=$(cne_profile_field "$pending" Interface PrivateKey)
        psk=$(cne_profile_field "$pending" Peer PresharedKey)
        address=$(cne_profile_field "$pending" Interface Address)
        address=${address%%/*}; address=${address##*.}
        [[ $address =~ ^[0-9]{1,3}$ ]] && ((10#$address>=2 && 10#$address<=249)) && cne_key "$private" && cne_key "$psk" || return 1
        public=$(printf '%s\n' "$private" | wg pubkey) || return 1
        if [[ -n $existing ]]; then
            [[ $existing == "$name"$'\t'"$address"$'\t'"$public" ]] || { cne_error '服务器已有同名但不同密钥的客户端，请使用新名称。'; return 1; }
            mv "$pending" "$CNE_STATE/clients/$name.conf" || return 1
            unset private psk
            printf '客户端已存在，配置已取回：%s\n' "$CNE_STATE/clients/$name.conf"
            return 0
        fi
        printf '继续提交上次生成的客户端配置。\n'
    else
        [[ -z $existing ]] || { cne_error '该客户端名称已经存在。'; return 1; }
        address=''
        for index in $(seq 2 249); do
            if ! printf '%s\n' "$data" | awk -F '\t' -v address="$index" '$2==address {found=1} END{exit !found}'; then address=$index; break; fi
        done
        [[ -n $address ]] || { cne_error '客户端地址已用完。'; return 1; }
        private=$(wg genkey) || return 1; public=$(printf '%s\n' "$private" | wg pubkey) || return 1; psk=$(wg genpsk) || return 1
        cne_render_client "$pending" "$address" "$private" "$server" "$psk" "${CNE_HOSTS[0]}" "$user_port" || return 1
    fi
    CNE_CLIENT_PSK=$psk
    if ! cne_remote 0 client-add "$name" "$address" "$public"; then unset CNE_CLIENT_PSK private psk; cne_error "添加未完成，本地待用配置保留在 $CNE_STATE/clients/$name.conf.pending。请检查客户端列表。"; return 1; fi
    unset CNE_CLIENT_PSK private psk
    mv "$pending" "$CNE_STATE/clients/$name.conf" || return 1
    printf '客户端已添加：%s\n配置：%s\n' "$name" "$CNE_STATE/clients/$name.conf"
}
cne_client_export() {
    local name file
    cne_prompt '客户端名称' || return 1; name=$CNE_ANSWER
    cne_name "$name" || return 1
    file=$CNE_STATE/clients/$name.conf
    [[ -f $file && ! -L $file ]] || { cne_error '本机没有这个客户端的私钥配置。旧客户端请使用原文件，或新增一个客户端。'; return 1; }
    printf '\n配置文件：%s\n' "$file"
    if command -v qrencode >/dev/null 2>&1; then
        printf '在 WireGuard 中选择“扫描二维码”：\n'
        qrencode -t ANSIUTF8 < "$file"
    fi
}
cne_client_remove() {
    local name
    cne_require_config && cne_authenticate 0 || return 1
    cne_prompt '要撤销的客户端名称' || return 1; name=$CNE_ANSWER; cne_name "$name" || return 1
    cne_prompt "撤销 $name，是否继续（y/N）" N || return 1
    [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || return 0
    cne_remote 0 client-remove "$name" || return 1
    [[ ! -f $CNE_STATE/clients/$name.conf ]] || mv "$CNE_STATE/clients/$name.conf" "$CNE_STATE/clients/$name.conf.revoked"
    printf '客户端已撤销。\n'
}
cne_menu() {
    local choice
    while :; do
        printf '\n'; cne_line
        printf '  一键安装与管理  v%s\n' "$CNE_VERSION"
        cne_line
        printf '\n  1. 一键安装\n  2. 修改节点\n  3. 查看状态\n  4. 连接诊断\n\n'
        printf '  5. 启动服务\n  6. 停止服务\n  7. 重启服务\n  8. 查看日志\n  9. 备份配置\n\n'
        printf '  10. 客户端列表\n  11. 添加客户端\n  12. 显示配置与二维码\n  13. 撤销客户端\n\n'
        printf '  14. 卸载服务\n  0. 退出\n\n'
        cne_prompt '请选择' || return 0; choice=$CNE_ANSWER
        case $choice in
            0) return 0;;
            1) cne_install || cne_note '操作未完成，具体原因见上方。';;
            2) cne_setup || cne_note '节点设置未完成。';;
            3) cne_status || cne_note '部分节点不可用。';;
            4) cne_action_all doctor || cne_note '部分检查未通过。';;
            5) cne_action_all start || cne_note '部分节点启动失败。';;
            6) cne_action_all stop || cne_note '部分节点停止失败。';;
            7) cne_action_all restart || cne_note '部分节点重启失败。';;
            8) cne_action_all logs || cne_note '部分日志读取失败。';;
            9) cne_action_all backup || cne_note '部分备份失败。';;
            10) cne_clients_list || cne_note '客户端列表读取失败。';;
            11) cne_client_add || cne_note '客户端添加未完成。';;
            12) cne_client_export || cne_note '配置导出未完成。';;
            13) cne_client_remove || cne_note '客户端撤销未完成。';;
            14)
                printf '\n将卸载三个节点的本工具服务，并先保存配置备份。\n'
                cne_prompt '确认卸载请输入 UNINSTALL' || return 0
                [[ $CNE_ANSWER != UNINSTALL ]] || cne_action_all uninstall || cne_note '部分节点卸载未完成。';;
            *) cne_note '请输入菜单中的编号。';;
        esac
    done
}
cne_main() {
    case ${1:-menu} in
        --help|-h) printf '一键安装与管理（纯 Bash）\n用法：bash cn-egress-oneclick.sh [menu|install|status|doctor]\n支持 Debian 12+、Ubuntu 22.04+，无需 Python。\n'; return 0 ;;
        --version) printf '%s\n' "$CNE_VERSION"; return 0 ;;
        menu|install|status|doctor) ;;
        *) cne_error '未知命令，可用 --help 查看用法。'; return 1 ;;
    esac
    cne_bootstrap || return 1
    cne_initialize || return 1
    case ${1:-menu} in menu) cne_menu;; install) cne_install;; status) cne_status;; doctor) cne_action_all doctor;; esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then cne_main "$@"; fi
