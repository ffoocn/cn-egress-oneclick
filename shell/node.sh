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
etc/cn-egress/user-transport
etc/cn-egress/awg-params
etc/cn-egress/probe.conf
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
etc/systemd/system/cn-egress-users.service
etc/systemd/system/cn-egress.service.d/obfs.conf
etc/systemd/system/cn-egress.service.d/users.conf
etc/sysctl.d/90-cn-egress-forwarding.conf
usr/local/sbin/cn-egress
usr/local/sbin/cn-egress-node
usr/local/sbin/cn-egress-net
usr/local/sbin/cn-egress-obfs
usr/local/sbin/cn-egress-probe
usr/local/sbin/cn-egress-users
opt/cn-egress/wstunnel-11.0.0/wstunnel
opt/cn-egress/awg-0.2.16/amneziawg-go
opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz
opt/cn-egress/awg-0.2.16/awg
FILES
}
cne_n_payload_allowed() {
    local role=$1 path=$2
    case "$path" in
        etc/cn-egress/role|etc/cn-egress/version|etc/cn-egress/deployment-id|etc/cn-egress/firewall.nft|etc/cn-egress-wss/role|etc/cn-egress-wss/node.crt|etc/cn-egress-wss/node.key|etc/cn-egress-wss/ca.crt|etc/cn-egress-wss/sh-host|etc/cn-egress-wss/port|etc/systemd/system/cn-egress.service|etc/systemd/system/cn-egress-obfs.service|etc/systemd/system/cn-egress.service.d/obfs.conf|usr/local/sbin/cn-egress|usr/local/sbin/cn-egress-node|usr/local/sbin/cn-egress-net|usr/local/sbin/cn-egress-obfs|opt/cn-egress/wstunnel-11.0.0/wstunnel) return 0;;
        etc/wireguard/cne-users.conf|etc/cn-egress/clients.tsv|etc/cn-egress/server-public) [[ $role == hk ]];;
        etc/cn-egress/user-transport|etc/cn-egress/awg-params|etc/cn-egress/probe.conf|etc/systemd/system/cn-egress-users.service|etc/systemd/system/cn-egress.service.d/users.conf|usr/local/sbin/cn-egress-probe|usr/local/sbin/cn-egress-users|opt/cn-egress/awg-0.2.16/amneziawg-go|opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz) [[ $role == hk ]];;
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
cne_n_user_transport() {
    local transport=wireguard
    cne_n_safe_path /etc/cn-egress/user-transport || return 1
    if [[ -f /etc/cn-egress/user-transport ]]; then transport=$(cat /etc/cn-egress/user-transport); fi
    [[ $transport == wireguard || $transport == awg2 ]] || { cne_n_error '客户端入口传输类型无效。'; return 1; }
    printf '%s\n' "$transport"
}
cne_n_inspect() {
    local state=absent role version=unknown service=inactive wan='' user_port='' user_transport
    cne_n_exists && state=present
    role=$(cne_n_existing_role) || return 1
    if [[ -f /etc/cn-egress/version ]]; then read -r version < /etc/cn-egress/version; [[ $version =~ ^[a-zA-Z0-9._-]+$ ]] || version=unknown; fi
    cne_n_has systemctl && systemctl is-active --quiet cn-egress.service && service=active
    cne_n_has ip && wan=$(cne_n_wan)
    if [[ -f /etc/wireguard/cne-users.conf ]]; then
        user_port=$(sed -nE 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' /etc/wireguard/cne-users.conf)
        [[ $user_port =~ ^[0-9]{1,5}$ ]] && ((user_port>=1 && user_port<=65535)) || user_port=''
    fi
    user_transport=$(cne_n_user_transport) || user_transport=unknown
    printf 'state=%s\nrole=%s\narch=%s\nwan=%s\nforwarding=%s\nservice=%s\nversion=%s\nuser_port=%s\nuser_transport=%s\n' "$state" "$role" "$(uname -m)" "$wan" "$(cne_n_forwarding)" "$service" "$version" "$user_port" "$user_transport"
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
cne_n_unit_relationship() {
    local unit=$1 key=$2 value=$3 target allowed=' '
    case "$unit:$key" in
        cn-egress.service:Wants) allowed=' network-online.target cn-egress-obfs.service ';;
        cn-egress.service:After) allowed=' network-online.target docker.service cn-egress-obfs.service cn-egress-users.service ';;
        cn-egress.service:Requires|cn-egress.service:BindsTo) allowed=' cn-egress-users.service ';;
        cn-egress-obfs.service:Wants|cn-egress-users.service:Wants) allowed=' network-online.target ';;
        cn-egress-obfs.service:After|cn-egress-users.service:After) allowed=' network-online.target ';;
        cn-egress-obfs.service:PartOf|cn-egress-users.service:PartOf|cn-egress-users.service:Before|cn-egress-dns.service:Requires|cn-egress-dns.service:After|cn-egress-dns.service:PartOf) allowed=' cn-egress.service ';;
        *:WantedBy) allowed=' multi-user.target ';;
    esac
    for target in $value; do [[ $allowed == *" $target "* ]] || return 1; done
}
cne_n_unit_file_check() {
    local file=$1 unit=$2 role=$3 line key value section='' starts=0 stops=0 mode
    cne_n_safe_path "$file" || return 1
    [[ -f $file && $(stat -c %u "$file") == 0 ]] || { cne_n_error "预留服务文件必须属于 root：$file"; return 1; }
    mode=$(stat -c %a "$file") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022)==0 )) || { cne_n_error "预留服务文件可被其他用户修改：$file"; return 1; }
    # Partial installs may have lost or conflicting role markers. Ownership is
    # proven by the exact command here; replacement need not adopt broken roles.
    if [[ $unit == cn-egress.service && $role == unknown ]]; then
        role=$(sed -nE 's@^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*/usr/local/sbin/cn-egress-net start (hk|sh|exit)[[:space:]]*$@\1@p' "$file")
        cne_n_role_ok "$role" || { cne_n_error "预留服务缺少可确认的角色启动命令：$file"; return 1; }
    fi
    case "$unit:$role" in cn-egress.service:hk|cn-egress.service:sh|cn-egress.service:exit|cn-egress-obfs.service:hk|cn-egress-obfs.service:sh|cn-egress-obfs.service:exit|cn-egress-obfs.service:unknown|cn-egress-dns.service:exit|cn-egress-dns.service:unknown|cn-egress-users.service:unknown) :;;
        cn-egress-users.service:hk) [[ $(cne_n_user_transport) == awg2 ]] || return 1;;
        *) cne_n_error "预留服务与节点角色不符：$file"; return 1;;
    esac
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in ''|'#'*|';'*) continue;; *\\) cne_n_error "预留服务包含无法确认的续行：$file"; return 1;;
            '[Unit]'|'[Service]'|'[Install]') section=$line; continue;; '['*) cne_n_error "预留服务包含未知区段：$file"; return 1;; esac
        [[ $line =~ ^([A-Za-z][A-Za-z0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || { cne_n_error "预留服务包含无法识别的设置：$file"; return 1; }
        key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
        case $key in
            Exec*)
                [[ $section == '[Service]' ]] || { cne_n_error "服务执行命令不在 Service 区段：$file"; return 1; }
                case "$unit:$key:$value" in
                    "cn-egress.service:ExecStart:/usr/local/sbin/cn-egress-net start $role"|"cn-egress-obfs.service:ExecStart:/usr/local/sbin/cn-egress-obfs"|"cn-egress-users.service:ExecStart:/usr/local/sbin/cn-egress-users start"|"cn-egress-dns.service:ExecStart:/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/cn-egress/dnsmasq.conf") ((starts+=1));;
                    "cn-egress.service:ExecStop:/usr/local/sbin/cn-egress-net stop $role"|"cn-egress-users.service:ExecStop:/usr/local/sbin/cn-egress-users stop") ((stops+=1));;
                    *) cne_n_error "预留服务包含非本工具的执行命令：$file"; return 1;;
                esac;;
            Conflicts|OnFailure|OnSuccess|FailureAction|SuccessAction|StartLimitAction|PropagatesStopTo|StopPropagatedFrom|PropagatesReloadTo|ReloadPropagatedFrom|Upholds|RequiredBy|UpheldBy|Also|Alias)
                [[ -z $value ]] || { cne_n_error "预留服务包含影响其他服务或系统的动作 ${key}：$file"; return 1; };;
            Wants|Requires|Requisite|BindsTo|PartOf|Before|After|WantedBy)
                cne_n_unit_relationship "$unit" "$key" "$value" || { cne_n_error "预留服务关联了其他服务：$file ($key)"; return 1; };;
        esac
    done < <(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$file")
    ((starts==1 && stops<=1)) || { cne_n_error "预留服务缺少唯一的已知启动命令：$file"; return 1; }
}
cne_n_unit_dropin_check() {
    local file=$1 role=$2 content mode
    cne_n_safe_path "$file" || return 1
    [[ -f $file && $(stat -c %u "$file") == 0 ]] || { cne_n_error "服务覆盖配置必须属于 root：$file"; return 1; }
    mode=$(stat -c %a "$file") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022)==0 )) || { cne_n_error "服务覆盖配置可被其他用户修改：$file"; return 1; }
    content=$(sed -E '/^[[:space:]]*([#;]|$)/d; s/^[[:space:]]+//; s/[[:space:]]+$//' "$file") || return 1
    case $file in
        /etc/systemd/system/cn-egress.service.d/obfs.conf) [[ $content == $'[Unit]\nWants=cn-egress-obfs.service\nAfter=cn-egress-obfs.service' ]];;
        /etc/systemd/system/cn-egress.service.d/users.conf)
            [[ ( $role == unknown || ( $role == hk && $(cne_n_user_transport) == awg2 ) ) && ( $content == $'[Unit]\nRequires=cn-egress-users.service\nBindsTo=cn-egress-users.service\nAfter=cn-egress-users.service' || $content == $'[Unit]\nRequires=cn-egress-users.service\nAfter=cn-egress-users.service' ) ]];;
        *) return 1;;
    esac || { cne_n_error "预留服务包含未经确认的覆盖配置：$file"; return 1; }
}
cne_n_unit_scope_check() {
    local unit=$1 role=$2 file="/etc/systemd/system/$1" loaded line fragment='' dropins='' seen_fragment=0 seen_dropins=0 path directory base prefix component
    if [[ -f $file ]]; then cne_n_unit_file_check "$file" "$unit" "$role" || return 1; fi
    # A same-named vendor/runtime unit or administrator drop-in is never ours.
    # Check both what systemd loaded and on-disk drop-ins awaiting daemon-reload.
    if cne_n_has systemctl; then
        loaded=$(systemctl show --property=FragmentPath --property=DropInPaths "$unit" 2>/dev/null) || {
            [[ -n $loaded ]] || { cne_n_error "无法确认预留服务的加载来源：$unit"; return 1; }
        }
        while IFS= read -r line; do
            case $line in FragmentPath=*) fragment=${line#*=}; ((seen_fragment+=1));; DropInPaths=*) dropins=${line#*=}; ((seen_dropins+=1));; *) cne_n_error "无法识别预留服务的加载来源：$unit"; return 1;; esac
        done <<< "$loaded"
        ((seen_fragment==1 && seen_dropins==1)) || { cne_n_error "预留服务的加载来源不完整：$unit"; return 1; }
        [[ -z $fragment || ( $fragment == "$file" && -f $file ) ]] || { cne_n_error "预留服务名已被其他服务占用：$unit ($fragment)"; return 1; }
        for path in $dropins; do cne_n_unit_dropin_check "$path" "$role" || return 1; done
    fi
    for base in /etc/systemd/system /etc/systemd/system.control /run/systemd/system /run/systemd/system.control /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        prefix=${unit%.service}
        local -a components=("$unit.d" service.d)
        while [[ $prefix == *-* ]]; do prefix=${prefix%-*}; components+=("$prefix-.service.d"); done
        for component in "${components[@]}"; do
            directory=$base/$component
            [[ ! -L $directory ]] || { cne_n_error "预留服务覆盖目录是符号链接：$directory"; return 1; }
            for path in "$directory"/*.conf; do
                [[ ! -e $path && ! -L $path ]] && continue
                cne_n_unit_dropin_check "$path" "$role" || return 1
            done
        done
    done
}
cne_n_scope_check() {
    local file name type links role
    while IFS= read -r file; do cne_n_safe_path "/$file" || return 1; done < <(cne_n_all_files)
    role=$(cne_n_existing_role) || return 1
    for file in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do cne_n_unit_scope_check "$file" "$role" || return 1; done
    if cne_n_has ip; then
        if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx cn-egress-relay; then
            links=$(ip -n cn-egress-relay -o link show 2>/dev/null) || { cne_n_error '无法确认预留网络命名空间的归属。'; return 1; }
            while IFS= read -r name; do
                case "$name" in lo|cne-users|cne-cn|cne-exit) :;; *) cne_n_error "cn-egress-relay 内含其他网卡 $name，不能覆盖。"; return 1;; esac
            done < <(printf '%s\n' "$links" | awk -F': ' '{split($2,a,"@");print a[1]}')
        fi
        for name in cne-users cne-cn cne-exit; do
            if ip link show dev "$name" >/dev/null 2>&1; then
                type=$(ip -d link show dev "$name") || return 1
                if ! grep -qw wireguard <<< "$type"; then
                    [[ $name == cne-users && $(cne_n_user_transport) == awg2 && -f /etc/systemd/system/cn-egress-users.service ]] && grep -qw tun <<< "$type" || { cne_n_error "$name 已被其他类型网卡占用。"; return 1; }
                fi
            fi
        done
    fi
}
cne_n_port_owned() {
    local role=$1 proto=$2 port=$3 line=$4 iface unit pid group
    if [[ $proto == udp ]] && cne_n_has wg; then
        for iface in cne-users cne-cn cne-exit; do
            if [[ $iface == cne-users && $(cne_n_user_transport) == awg2 ]]; then
                [[ $(/opt/cn-egress/awg-0.2.16/awg show "$iface" listen-port 2>/dev/null) == "$port" ]] && return 0
            else
                [[ $(wg show "$iface" listen-port 2>/dev/null) == "$port" ]] && return 0
                [[ $(ip netns exec cn-egress-relay wg show "$iface" listen-port 2>/dev/null) == "$port" ]] && return 0
            fi
        done
    fi
    while IFS= read -r pid; do
        [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cgroup ]] || continue
        if grep -Eq '(^|/)cn-egress-(obfs|dns|users)\.service($|/)' "/proc/$pid/cgroup"; then return 0; fi
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
cne_n_install_plan_safe() {
    local line package installed=' '
    while IFS= read -r line; do
        if [[ $line == Remv\ * || $line =~ ^Inst[[:space:]]+[^[:space:]]+[[:space:]]+\[ ]]; then return 1; fi
        if [[ $line =~ ^Inst[[:space:]]+([^[:space:]]+) ]]; then installed+="${BASH_REMATCH[1]} "; fi
    done <<< "$1"
    while IFS= read -r line; do
        if [[ $line =~ ^Conf[[:space:]]+([^[:space:]]+) ]]; then
            package=${BASH_REMATCH[1]}
            [[ $installed == *" $package "* ]] || return 1
        fi
    done <<< "$1"
}
cne_n_prepare() {
    local role=$1 transport=${2:-wireguard} tool package audit plan ca_missing=0
    [[ $transport == wireguard || $transport == awg2 ]] || { cne_n_error '客户端传输类型无效。'; return 1; }
    cne_n_os_check || return 1
    local -a packages=()
    local pairs='ip:iproute2 ss:iproute2 wg:wireguard-tools wg-quick:wireguard-tools nft:nftables sysctl:procps openssl:openssl flock:util-linux tar:tar gzip:gzip base64:coreutils install:coreutils stat:coreutils getent:libc-bin useradd:passwd groupadd:passwd'
    [[ $role == exit ]] && pairs="$pairs iptables:iptables dnsmasq:dnsmasq-base dig:dnsutils"
    [[ $role == hk ]] && pairs="$pairs curl:curl dig:dnsutils timeout:coreutils"
    if [[ $role == hk ]] && [[ $(dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null) != 'install ok installed' || ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        packages+=(ca-certificates); ca_missing=1
    fi
    if [[ $role == hk && $transport == awg2 ]]; then
        pairs="$pairs gcc:gcc make:make sha256sum:coreutils"
        if ! cne_n_has gcc || ! printf '#include <sys/socket.h>\n#include <linux/netlink.h>\n' | gcc -x c -fsyntax-only - >/dev/null 2>&1; then packages+=(libc6-dev); fi
    fi
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
    cne_n_install_plan_safe "$plan" || { cne_n_error '依赖安装会升级、删除或配置已有软件，已停止。'; return 1; }
    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove --no-upgrade --no-install-recommends install "${packages[@]}" </dev/null >&2 || return 1
    for package in $pairs; do cne_n_has "${package%%:*}" || { cne_n_error "依赖安装后仍找不到 ${package%%:*}。"; return 1; }; done
    if ((ca_missing)); then
        [[ $(dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null) == 'install ok installed' && -s /etc/ssl/certs/ca-certificates.crt ]] || { cne_n_error 'CA 证书依赖安装后仍不可用。'; return 1; }
    fi
}
cne_n_services() { printf '%s\n' cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; }
cne_n_backup_directory() {
    local directory=/root/cn-egress-backups
    # Checking a child also checks every ancestor without requiring the directory
    # itself to be a regular file. Keep backups private to root on the node.
    cne_n_safe_path "$directory/.permission-check" || return 1
    [[ ! -e $directory || -d $directory ]] || { cne_n_error '备份目录不是目录。'; return 1; }
    if [[ -d $directory ]]; then
        [[ $(stat -c %u "$directory") == 0 ]] || { cne_n_error '备份目录必须属于 root。'; return 1; }
    fi
    mkdir -p -m 700 "$directory" && chmod 700 "$directory" || return 1
}
cne_n_backup_node_id() {
    local identifier
    identifier=$(cat /etc/machine-id 2>/dev/null) || return 1
    [[ $identifier =~ ^[a-f0-9]{32}$ ]] || { cne_n_error '无法读取节点标识。'; return 1; }
    printf '%s\n' "$identifier"
}
cne_n_backup() {
    local directory temporary file state enabled archive stamp node
    directory=/root/cn-egress-backups
    cne_n_backup_directory || return 1
    node=$(cne_n_backup_node_id) || return 1
    temporary=$(mktemp -d "$directory/.stage.XXXXXXXX") || return 1
    : > "$temporary/.files"
    while IFS= read -r file; do
        cne_n_safe_path "/$file" || { rm -rf "$temporary"; return 1; }
        if [[ -f /$file ]]; then
            mkdir -p "$temporary/${file%/*}" && cp -p "/$file" "$temporary/$file" || { rm -rf "$temporary"; return 1; }
            printf '%s\n' "$file" >> "$temporary/.files" || { rm -rf "$temporary"; return 1; }
        fi
    done < <(cne_n_all_files)
    : > "$temporary/.cn-egress-services.tsv"
    while IFS= read -r file; do
        state=$(systemctl is-active "$file" 2>/dev/null) || :
        enabled=$(systemctl is-enabled "$file" 2>/dev/null) || :
        [[ -n $state ]] || state=unknown
        [[ -n $enabled ]] || enabled=unknown
        printf '%s\t%s\t%s\n' "$file" "$state" "$enabled" >> "$temporary/.cn-egress-services.tsv"
    done < <(cne_n_services)
    stamp=$(date -u +%Y%m%d-%H%M%S)
    archive="$directory/$stamp-${temporary##*.}.tar.gz"
    printf 'format=cn-egress-node-backup-v1\narchive=%s\nnode=%s\n' "${archive##*/}" "$node" > "$temporary/.cn-egress-backup" || { rm -rf "$temporary"; return 1; }
    printf '%s\n' .cn-egress-services.tsv .cn-egress-backup >> "$temporary/.files"
    # Listing files explicitly avoids directory, link and device members. A failed
    # archive is removed so it can never be mistaken for a usable rollback point.
    tar -C "$temporary" -czf "$archive" -T "$temporary/.files" && chmod 600 "$archive" || { rm -f "$archive"; rm -rf "$temporary"; return 1; }
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
    # Align the loaded commands with the verified on-disk definitions. A cached
    # old ExecStop must not run after an administrator changed the unit file.
    cne_n_scope_check || return 1
    systemctl daemon-reload >&2 && cne_n_scope_check || return 1
    # Units are fixed, never stop a generic dnsmasq, nginx, Docker or networking unit.
    for unit in cn-egress-dns.service cn-egress-obfs.service cn-egress.service cn-egress-users.service; do
        if [[ -f /etc/systemd/system/$unit ]]; then systemctl stop "$unit" >&2 || return 1; fi
    done
    cne_n_cleanup_network
}
cne_n_remove_files() {
    local file keep_deployment=${1:-}
    while IFS= read -r file; do
        # Forwarding is a separate explicit user setting, not an installation side effect.
        case $file in etc/sysctl.d/90-cn-egress-forwarding.conf|etc/cn-egress/forwarding-before|etc/cn-egress/forwarding-settings) continue;; esac
        if [[ $file == etc/cn-egress/deployment-id && $keep_deployment == keep-deployment ]]; then continue; fi
        cne_n_safe_path "/$file" && rm -f "/$file" || return 1
    done < <(cne_n_all_files)
}
cne_n_validate_backup() {
    local archive=$1 destination=$2 directory=/root/cn-egress-backups path list verbose count=0 expected node
    [[ $archive == "$directory/"* && ${archive##*/} =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{8}\.tar\.gz$ && ${archive%/*} == "$directory" ]] || { cne_n_error '只能恢复本节点 root 备份目录内的备份。'; return 1; }
    cne_n_safe_path "$archive" || return 1
    [[ -d $directory && -f $archive && ! -L $archive ]] || { cne_n_error '备份不是普通文件。'; return 1; }
    [[ $(stat -c %u "$directory") == 0 && $(stat -c %a "$directory") == 700 && $(stat -c %u "$archive") == 0 && $(stat -c %a "$archive") == 600 && $(stat -c %h "$archive") == 1 ]] || { cne_n_error '备份归属、权限或链接数量不符合要求。'; return 1; }
    [[ $(stat -c %s "$archive") -le 104857600 ]] || { cne_n_error '备份过大。'; return 1; }
    list=$(tar -tzf "$archive") && verbose=$(tar -tvzf "$archive") || { cne_n_error '备份无法读取。'; return 1; }
    [[ -n $list && -n $verbose ]] || return 1
    [[ -z $(printf '%s\n' "$list" | sort | uniq -d) ]] || { cne_n_error '备份包含重复路径。'; return 1; }
    if grep -qv '^-' <<< "$verbose"; then cne_n_error '备份仅允许普通文件。'; return 1; fi
    while IFS= read -r path; do
        ((count+=1))
        case $path in .cn-egress-backup|.cn-egress-services.tsv) :;; *)
            cne_n_all_files | grep -Fxq "$path" || { cne_n_error "备份包含非预期路径：$path"; return 1; }
            cne_n_safe_path "/$path" || return 1;;
        esac
    done <<< "$list"
    ((count<=60)) || { cne_n_error '备份文件数量异常。'; return 1; }
    printf '%s\n' "$list" | grep -Fxq .cn-egress-backup && printf '%s\n' "$list" | grep -Fxq .cn-egress-services.tsv || { cne_n_error '备份缺少来源和服务状态。'; return 1; }
    node=$(cne_n_backup_node_id) || return 1
    expected=$(printf 'format=cn-egress-node-backup-v1\narchive=%s\nnode=%s\n' "${archive##*/}" "$node")
    [[ $(tar -xOzf "$archive" .cn-egress-backup) == "$expected" ]] || { cne_n_error '备份来源与本节点不匹配。'; return 1; }
    # Validate before extraction, stopping path/link attacks before any mutation.
    tar -xzf "$archive" --no-same-owner -C "$destination" || return 1
    awk -F'\t' '
      NF!=3 {bad=1}
      $1!="cn-egress.service" && $1!="cn-egress-obfs.service" && $1!="cn-egress-dns.service" && $1!="cn-egress-users.service" {bad=1}
      ++seen[$1]!=1 {bad=1}
      $2!~/^(active|inactive|failed|activating|deactivating|reloading|maintenance|refreshing|unknown)$/ {bad=1}
      $3!~/^(enabled|enabled-runtime|disabled|static|indirect|generated|masked|masked-runtime|transient|linked|linked-runtime|alias|bad|not-found|unknown)$/ {bad=1}
      END {if(NR!=4)bad=1;exit bad?1:0}' "$destination/.cn-egress-services.tsv" || { cne_n_error '备份服务状态无效。'; return 1; }
    if [[ -f $destination/etc/cn-egress/deployment-id ]]; then
        [[ $(cat "$destination/etc/cn-egress/deployment-id") =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '备份部署编号无效。'; return 1; }
    fi
}
cne_n_restore_apply() {
    local temporary=$1 file unit state enabled failures=0 marker
    cne_n_stop_owned || return 1
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do
        [[ ! -f /etc/systemd/system/$unit ]] || systemctl disable "$unit" >&2 || failures=1
    done
    # Keep the interrupted install identity until every restoration step has
    # succeeded. A lost SSH connection must remain recoverable with the same ID.
    cne_n_remove_files keep-deployment || failures=1
    while IFS= read -r file; do
        # Forwarding was enabled through separate explicit consent, so a rollback
        # does not silently undo or overwrite that operator setting.
        case $file in etc/cn-egress/deployment-id|etc/sysctl.d/90-cn-egress-forwarding.conf|etc/cn-egress/forwarding-before|etc/cn-egress/forwarding-settings) continue;; esac
        if [[ -f $temporary/$file ]]; then
            cne_n_safe_path "/$file" && mkdir -p "/${file%/*}" && cp -p "$temporary/$file" "/$file" || failures=1
        fi
    done < <(cne_n_all_files)
    systemctl daemon-reload >&2 || failures=1
    cne_n_scope_check || { cne_n_error '恢复后的服务归属检查未通过，未启动服务。'; return 1; }
    while IFS=$'\t' read -r unit state enabled; do
        [[ -f /etc/systemd/system/$unit ]] || continue
        case $enabled in enabled) systemctl enable "$unit" >&2 || failures=1;; enabled-runtime) systemctl enable --runtime "$unit" >&2 || failures=1;; disabled) systemctl disable "$unit" >&2 || failures=1;; esac
    done < "$temporary/.cn-egress-services.tsv"
    for unit in cn-egress-users.service cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
        [[ -f /etc/systemd/system/$unit ]] || continue
        if awk -F'\t' -v u="$unit" '$1==u && $2=="active"{found=1}END{exit !found}' "$temporary/.cn-egress-services.tsv"; then systemctl start "$unit" >&2 || failures=1; fi
    done
    ((failures==0)) || { cne_n_error '恢复未完全成功，请保留备份并检查本工具服务。'; return 1; }
    if [[ -f $temporary/etc/cn-egress/deployment-id ]]; then
        mkdir -p /etc/cn-egress || return 1
        marker=$(mktemp /etc/cn-egress/.deployment.XXXXXXXX) || return 1
        if ! cp "$temporary/etc/cn-egress/deployment-id" "$marker" || ! chmod 600 "$marker" || ! mv "$marker" /etc/cn-egress/deployment-id; then rm -f "$marker"; return 1; fi
    else rm -f /etc/cn-egress/deployment-id || return 1; fi
}
cne_n_restore() {
    local archive=$1 expected_id=${2:-} temporary current_id='' archived_id='' file
    [[ -z $expected_id || $expected_id =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '恢复部署编号无效。'; return 1; }
    # Archive provenance, every destination and the entire backup are checked
    # before stopping a service or deleting a file.
    while IFS= read -r file; do cne_n_safe_path "/$file" || return 1; done < <(cne_n_all_files)
    cne_n_safe_path /root/cn-egress-backups/.permission-check || return 1
    [[ -d /root/cn-egress-backups && $(stat -c %u /root/cn-egress-backups) == 0 && $(stat -c %a /root/cn-egress-backups) == 700 ]] || { cne_n_error '备份目录归属或权限不符合要求。'; return 1; }
    temporary=$(mktemp -d /root/cn-egress-backups/.restore.XXXXXXXX) || return 1
    if ! cne_n_validate_backup "$archive" "$temporary"; then rm -rf "$temporary"; return 1; fi
    if [[ -f /etc/cn-egress/deployment-id ]]; then current_id=$(cat /etc/cn-egress/deployment-id); fi
    if [[ -f $temporary/etc/cn-egress/deployment-id ]]; then archived_id=$(cat "$temporary/etc/cn-egress/deployment-id"); fi
    if [[ -n $expected_id && $current_id != "$expected_id" && $current_id != "$archived_id" ]]; then
        rm -rf "$temporary"; cne_n_error '节点已有其他部署，拒绝恢复旧事务备份。'; return 1
    fi
    # An interrupted restore may have removed an owned fragment/drop-in while
    # systemd still lists it. Refresh only after backup provenance and the
    # transaction guard pass, then reject any vendor/runtime fallback as usual.
    if ! systemctl daemon-reload >&2 || ! cne_n_scope_check; then rm -rf "$temporary"; return 1; fi
    printf '正在恢复本节点文件和服务状态。备份：%s\n' "$archive" >&2
    if ! cne_n_restore_apply "$temporary"; then rm -rf "$temporary"; return 1; fi
    rm -rf "$temporary"
    printf '已恢复本节点安装前的文件及服务状态。\n' >&2
}
cne_n_rollback() {
    cne_n_restore "$1"
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
    ((number<=55)) || { cne_n_error '安装包文件数量异常。'; return 1; }
    [[ -z $(printf '%s\n' "$list" | sort | uniq -d) ]] || { cne_n_error '安装包包含重复文件。'; return 1; }
    verbose=$(tar -tvzf "$archive") || return 1
    if grep -qv '^-' <<< "$verbose"; then cne_n_error '安装包仅允许普通文件，不能含目录、链接或设备。'; return 1; fi
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$destination" || return 1
    local expected actual interface local_port required='etc/cn-egress/firewall.nft etc/cn-egress-wss/role etc/cn-egress-wss/node.crt etc/cn-egress-wss/node.key etc/cn-egress-wss/ca.crt etc/cn-egress-wss/port etc/systemd/system/cn-egress.service etc/systemd/system/cn-egress-obfs.service usr/local/sbin/cn-egress-net usr/local/sbin/cn-egress-obfs opt/cn-egress/wstunnel-11.0.0/wstunnel'
    case $role in hk) required="$required etc/wireguard/cne-users.conf etc/wireguard/cne-cn.conf";; sh) required="$required etc/wireguard/cne-cn.conf etc/wireguard/cne-exit.conf etc/cn-egress-wss/guard.nft etc/cn-egress-wss/restrictions.yaml";; exit) required="$required etc/wireguard/cne-exit.conf etc/cn-egress/wan-interface etc/cn-egress/dnsmasq.conf etc/systemd/system/cn-egress-dns.service";; esac
    if [[ $role == hk && -f $destination/etc/cn-egress/user-transport ]]; then
        actual=$(cat "$destination/etc/cn-egress/user-transport")
        [[ $actual == wireguard || $actual == awg2 ]] || { cne_n_error '安装包客户端传输类型无效。'; return 1; }
        if [[ $actual == awg2 ]]; then
            required="$required etc/cn-egress/awg-params etc/cn-egress/probe.conf etc/systemd/system/cn-egress-users.service etc/systemd/system/cn-egress.service.d/users.conf usr/local/sbin/cn-egress-users usr/local/sbin/cn-egress-probe opt/cn-egress/awg-0.2.16/amneziawg-go opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz"
            cne_n_validate_awg_params "$destination/etc/cn-egress/awg-params" || return 1
        fi
    fi
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
cne_n_compile_tools() {
    local role=$1 stage=$2 source archive
    [[ $role == hk && -f $stage/etc/cn-egress/user-transport && $(cat "$stage/etc/cn-egress/user-transport") == awg2 ]] || return 0
    archive="$stage/opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz"
    cne_n_has gcc && cne_n_has make && cne_n_has sha256sum || { cne_n_error '缺少 AmneziaWG 编译依赖，请先准备节点。'; return 1; }
    printf '%s  %s\n' e79a3c7f2def315d052a3648b49058a268c4b63cdb5e082b696d2a4a0a2367f0 "$archive" | sha256sum -c - >/dev/null 2>&1 || { cne_n_error 'AmneziaWG 工具源代码校验失败。'; return 1; }
    source=$(mktemp -d "$stage/.awg-build.XXXXXXXX") || return 1
    if ! tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions -C "$source" || ! make -C "$source/src" -j2 CC=gcc >&2 || ! install -m 755 "$source/src/wg" "$stage/opt/cn-egress/awg-0.2.16/awg"; then
        rm -rf "$source"; cne_n_error 'AmneziaWG 工具编译失败，节点服务尚未修改。'; return 1
    fi
    rm -rf "$source"
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
    local role=$1 stage=$2 id=$3 file mode marker
    cne_n_stop_owned || return 1
    # Keep a transaction identity even if applying files fails halfway through.
    # Atomic replacement retains the old identity if writing the marker fails.
    mkdir -p /etc/cn-egress && chmod 700 /etc/cn-egress || return 1
    marker=$(mktemp /etc/cn-egress/.deployment.XXXXXXXX) || return 1
    if ! printf '%s\n' "$id" > "$marker" || ! chmod 600 "$marker" || ! mv "$marker" /etc/cn-egress/deployment-id; then rm -f "$marker"; return 1; fi
    for file in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do
        [[ ! -f /etc/systemd/system/$file ]] || systemctl disable "$file" >&2 || return 1
    done
    cne_n_remove_files keep-deployment || return 1
    cne_n_transport_user || return 1
    while IFS= read -r file; do
        [[ $file != etc/cn-egress/deployment-id ]] || continue
        [[ -f $stage/$file ]] || continue
        mode=600
        case $file in usr/local/sbin/*|opt/cn-egress/*/wstunnel|opt/cn-egress/awg-0.2.16/awg|opt/cn-egress/awg-0.2.16/amneziawg-go) mode=755;; etc/systemd/*) mode=644;; etc/cn-egress-wss/node.*|etc/cn-egress-wss/ca.crt|etc/cn-egress-wss/role|etc/cn-egress-wss/port|etc/cn-egress-wss/sh-host|etc/cn-egress-wss/restrictions.yaml) mode=640;; esac
        mkdir -p "/${file%/*}" && install -m "$mode" "$stage/$file" "/$file" || return 1
        case $file in etc/cn-egress-wss/*) chown root:cn-egress-wss "/$file" || return 1;; esac
    done < <(cne_n_all_files)
    mkdir -p /etc/cn-egress && chmod 700 /etc/cn-egress || return 1
    chmod 755 /opt/cn-egress /opt/cn-egress/wstunnel-11.0.0 || return 1
    [[ ! -d /opt/cn-egress/awg-0.2.16 ]] || chmod 755 /opt/cn-egress/awg-0.2.16 || return 1
    printf '%s\n' "$role" > /etc/cn-egress/role || return 1
    printf '2.1.1\n' > /etc/cn-egress/version || return 1
    chmod 600 /etc/cn-egress/{role,version,deployment-id} || return 1
    systemctl daemon-reload >&2 || return 1
    cne_n_scope_check || return 1
    systemctl enable cn-egress.service cn-egress-obfs.service >&2 || return 1
    [[ $role != hk || $(cne_n_user_transport) != awg2 ]] || systemctl enable cn-egress-users.service >&2 || return 1
    systemctl start cn-egress.service >&2 || return 1
    systemctl start cn-egress-obfs.service >&2 || return 1
    if [[ $role == exit ]]; then systemctl enable cn-egress-dns.service >&2 && systemctl start cn-egress-dns.service >&2 || return 1; fi
    systemctl is-active --quiet cn-egress.service && systemctl is-active --quiet cn-egress-obfs.service || return 1
    [[ $role != exit ]] || systemctl is-active --quiet cn-egress-dns.service || return 1
    [[ $role != hk || $(cne_n_user_transport) != awg2 ]] || systemctl is-active --quiet cn-egress-users.service || return 1
}
cne_n_install() {
    local role=$1 mode=$2 archive=$3 id=$4 stage backup before after user_port=51820 wss_port
    [[ $mode == fresh || $mode == replace ]] || { cne_n_error '安装模式必须为 fresh 或 replace。'; return 1; }
    [[ $id =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '部署编号无效。'; return 1; }
    cne_n_os_check && cne_n_scope_check || return 1
    if [[ $role == exit && $(cne_n_forwarding) != 1 ]]; then cne_n_error '出口机尚未启用 IPv4 转发。请在安装向导确认开启后继续。'; return 1; fi
    stage=$(mktemp -d /root/.cn-egress-install.XXXXXXXX) || return 1
    if ! cne_n_validate_archive "$role" "$archive" "$stage"; then rm -rf "$stage"; return 1; fi
    if ! cne_n_compile_tools "$role" "$stage"; then rm -rf "$stage"; return 1; fi
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
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do
        [[ $unit != cn-egress-dns.service || $role == exit ]] || continue
        [[ $unit != cn-egress-users.service || ( $role == hk && $(cne_n_user_transport) == awg2 ) ]] || continue
        state=$(systemctl is-active "$unit" 2>/dev/null) || :
        case $unit in cn-egress.service) printf 'VPN：%s\n' "$state";; cn-egress-obfs.service) printf '传输：%s\n' "$state";; cn-egress-users.service) printf '客户端混淆入口：%s\n' "$state";; *) printf 'DNS：%s\n' "$state";; esac
    done
    now=$(date +%s)
    for iface in cne-users cne-cn cne-exit; do
        while read -r _ stamp; do
            [[ $stamp =~ ^[0-9]+$ ]] || continue
            available=1
            if ((stamp==0)); then printf '握手 %-10s 尚未建立\n' "$iface"; else age=$((now-stamp)); printf '握手 %-10s %s 秒前\n' "$iface" "$age"; fi
        done < <(cne_n_show_handshakes "$role" "$iface" 2>/dev/null)
    done
    ((available)) || printf '握手：暂无数据\n'
}
cne_n_show_handshakes() {
    local role=$1 iface=$2
    if [[ $role == hk && $iface == cne-users && $(cne_n_user_transport) == awg2 ]]; then
        /opt/cn-egress/awg-0.2.16/awg show "$iface" latest-handshakes
    else cne_n_net "$role" wg show "$iface" latest-handshakes; fi
}
cne_n_handshake_check() {
    local role=$1 iface now stamp key output count=0 failed=0 interfaces=''
    now=$(date +%s) || return 1
    case $role in hk) interfaces=cne-cn;; sh) interfaces='cne-cn cne-exit';; exit) interfaces=cne-exit;; *) return 1;; esac
    # Only server-to-server peers are required to stay active. Phones can be idle
    # without making the deployed chain unhealthy.
    for iface in $interfaces; do
        output=$(cne_n_net "$role" wg show "$iface" latest-handshakes 2>/dev/null) || output=''
        count=0
        while read -r key stamp; do
            [[ -n $key ]] || continue
            ((count+=1))
            if [[ ! $stamp =~ ^[0-9]+$ ]] || ((stamp==0 || stamp>now || now-stamp>180)); then failed=1; printf '异常：%s 节点握手未建立或已超过 180 秒。\n' "$iface"; fi
        done <<< "$output"
        if ((count!=1)); then failed=1; printf '异常：%s 节点握手数据缺失或节点对等数量异常。\n' "$iface"; fi
    done
    return "$failed"
}
cne_n_dns_check() {
    local response
    if ! awk '/^[[:space:]]*nameserver[[:space:]]+/{if($2!="0.0.0.0" && $2!="::" && $2~/^[A-Fa-f0-9:.%_-]+$/)found=1}END{exit !found}' /etc/resolv.conf; then
        cne_n_error '出口机没有可用的系统 DNS 上游。'; return 1
    fi
    cne_n_has dig || { cne_n_error '缺少 dig，无法验证出口 DNS；请先准备依赖。'; return 1; }
    response=$(dig +time=3 +tries=1 +noall +comments +answer @10.77.30.2 -p 5354 api.ipify.org A 2>/dev/null) || { cne_n_error '出口 DNS 查询失败。'; return 1; }
    if [[ $response != *'status: NOERROR,'* ]] || ! awk '$4=="A" && $5~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{found=1}END{exit !found}' <<< "$response"; then
        cne_n_error '出口 DNS 未返回有效 IPv4 应答。'; return 1
    fi
    printf '出口 DNS：UDP 查询已通过。\n'
}
cne_n_chain_probe() {
    local helper=/usr/local/sbin/cn-egress-probe
    cne_n_safe_path "$helper" || return 1
    [[ -f $helper && -x $helper ]] || { cne_n_error '缺少全链探测器，客户端至住宅出口的 DNS 和访问路径尚未验证。'; return 1; }
    "$helper"
}
cne_n_doctor() {
    local role=$1 issue=0 certificate iface
    cne_n_status "$role"
    for iface in cn-egress.service cn-egress-obfs.service; do systemctl is-active --quiet "$iface" || issue=1; done
    [[ $role != hk || $(cne_n_user_transport) != awg2 ]] || systemctl is-active --quiet cn-egress-users.service || issue=1
    [[ $role != exit ]] || systemctl is-active --quiet cn-egress-dns.service || issue=1
    if [[ $role == exit && $(cne_n_forwarding) != 1 ]]; then printf '异常：出口机 IPv4 转发未开启。\n'; issue=1; fi
    for certificate in node.crt ca.crt; do
        if ! openssl x509 -in "/etc/cn-egress-wss/$certificate" -noout -checkend 2592000 >/dev/null 2>&1; then printf '异常：%s 无效或将在 30 天内到期。\n' "$certificate"; issue=1; fi
    done
    if [[ $role == hk ]]; then cne_n_chain_probe || issue=1; fi
    cne_n_handshake_check "$role" || issue=1
    if [[ $role == exit ]]; then cne_n_dns_check || issue=1; fi
    if ((issue==0)); then
        if [[ $role == hk ]]; then printf '节点检查和全链 DNS、访问探测通过。\n'; else printf '本节点检查通过；请从 HK 执行诊断验证客户端至住宅出口全链。\n'; fi
    else printf '诊断发现异常或验证未完成；请检查上述结果和本工具日志。\n'; fi
    return "$issue"
}
cne_n_logs() {
    journalctl --no-pager -o short-iso -n 60 -u cn-egress.service -u cn-egress-obfs.service -u cn-egress-dns.service -u cn-egress-users.service 2>&1 |
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
        systemctl daemon-reload >&2 && cne_n_scope_check || return 1
        for unit in cn-egress-users.service cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
            [[ $unit != cn-egress-dns.service || $role == exit ]] || continue
            [[ $unit != cn-egress-users.service || ( $role == hk && $(cne_n_user_transport) == awg2 ) ]] || continue
            [[ -f /etc/systemd/system/$unit ]] || { cne_n_error "预留服务文件缺失：$unit"; return 1; }
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
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do [[ ! -f /etc/systemd/system/$unit ]] || systemctl disable "$unit" >&2 || return 1; done
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
cne_n_validate_awg_params() {
    local file=$1
    [[ -f $file && ! -L $file ]] || { cne_n_error '未找到客户端混淆参数。'; return 1; }
    awk -F'=' '
      NF!=2 {bad=1;next}
      {key=$1;value=$2;gsub(/^[[:space:]]+|[[:space:]]+$/,"",key);gsub(/^[[:space:]]+|[[:space:]]+$/,"",value)}
      key!~/^(Jc|Jmin|Jmax|S[1-4]|H[1-4])$/ || ++seen[key]!=1 {bad=1;next}
      key~/^H/ {n=split(value,a,"-");if(n<1||n>2||a[1]!~/^[0-9]+$/||(n==2&&a[2]!~/^[0-9]+$/)){bad=1;next};lo[key]=a[1]+0;hi[key]=(n==2?a[2]:a[1])+0;if(lo[key]<1||hi[key]>4294967295||lo[key]>hi[key])bad=1;next}
      value!~/^[0-9]+$/ {bad=1;next}
      {v[key]=value+0;if(key=="Jc" && v[key]>12)bad=1;if(key~/^J(min|max)$/ && (v[key]<1||v[key]>1399))bad=1;if(key~/^S/ && (v[key]<1||v[key]>128))bad=1}
      END {if(NR!=11||v["Jmin"]>v["Jmax"])bad=1;for(i=1;i<=4;i++)for(j=i+1;j<=4;j++)if(lo["H"i]<=hi["H"j]&&lo["H"j]<=hi["H"i])bad=1;exit bad?1:0}' "$file" || { cne_n_error '客户端混淆参数无效。'; return 1; }
}
cne_n_client_params() {
    cne_n_safe_path /etc/cn-egress/awg-params || return 1
    [[ $(cne_n_user_transport) == awg2 ]] || return 0
    cne_n_validate_awg_params /etc/cn-egress/awg-params && cat /etc/cn-egress/awg-params
}
cne_n_client_list() {
    local config=/etc/wireguard/cne-users.conf temporary public address name number index=0 registry=/etc/cn-egress/clients.tsv
    [[ -f $config ]] || return 0
    # Existing v1 peers need no imported metadata: derive a stable name from their address.
    while IFS=$'\t' read -r public address; do
        [[ $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || continue
        if [[ $address =~ ^10\.77\.10\.[0-9]+/32$ ]]; then
            number=${address##*.}; number=${number%%/*}; name="legacy-$number"
            # The reserved .250 peer belongs to the isolated diagnosis client.
            [[ $number != 250 ]] || continue
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
cne_n_client_verify() {
    local role=$1 public=$2 expected_server=$3 expected_hash=$4 config=/etc/wireguard/cne-users.conf server_public psk actual_hash live transport
    [[ $role == hk ]] && cne_n_require_role hk || return 1
    [[ $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ && $expected_server =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ && $expected_hash =~ ^[a-f0-9]{64}$ ]] || { cne_n_error '客户端核验参数无效。'; return 1; }
    cne_n_safe_path "$config" && [[ -f $config ]] || { cne_n_error '未找到客户端入口配置。'; return 1; }
    server_public=$(cne_n_server_public) || return 1
    [[ $expected_server == "$server_public" ]] || { cne_n_error '服务端公钥已变化，客户端核验未通过。'; return 1; }
    # This action runs under the node lock. Extract only one exact saved peer;
    # duplicate key/PSK directives or duplicate peers cannot prove registration.
    psk=$(awk -v target="$public" '
      function emit(){if(peer&&matched){count++;if(pub_count!=1||psk_count!=1||allowed_count!=1||allowed=="")bad=1;chosen=psk}
        pub_count=0;psk_count=0;allowed_count=0;matched=0;psk="";allowed=""}
      /^[[:space:]]*\[Peer\][[:space:]]*$/ {emit();peer=1;next}
      /^[[:space:]]*\[/ {emit();peer=0;next}
      peer&&/^[[:space:]]*(PublicKey|PresharedKey|AllowedIPs)[[:space:]]*=/ {
        line=$0;key=line;sub(/[[:space:]]*=.*/,"",key);gsub(/^[[:space:]]+|[[:space:]]+$/,"",key)
        sub(/^[^=]*=[[:space:]]*/,"",line);gsub(/[[:space:]]+$/,"",line)
        if(key=="PublicKey"){pub_count++;if(line==target)matched=1}
        if(key=="PresharedKey"){psk_count++;psk=line}
        if(key=="AllowedIPs"){allowed_count++;allowed=line}}
      END{emit();if(count!=1||bad)exit 1;print chosen}' "$config") || { cne_n_error '未找到唯一的已登记客户端配置。'; return 1; }
    [[ $psk =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '已登记客户端的预共享密钥无效。'; return 1; }
    actual_hash=$(printf '%s\n' "$psk" | sha256sum) || { cne_n_error '无法核验客户端预共享密钥。'; return 1; }
    actual_hash=${actual_hash%% *}
    [[ $actual_hash == "$expected_hash" ]] || { unset psk; cne_n_error '客户端预共享密钥核验未通过。'; return 1; }
    unset psk
    # A stopped entry retains its saved registration. When the interface exists,
    # also verify its live PSK so an incomplete sync cannot be called verified.
    if cne_n_has ip && ip -n cn-egress-relay link show cne-users >/dev/null 2>&1; then
        transport=$(cne_n_user_transport) || return 1
        if [[ $transport == awg2 ]]; then
            server_public=$(/opt/cn-egress/awg-0.2.16/awg show cne-users public-key 2>/dev/null) || { cne_n_error '无法核验运行中的服务端公钥。'; return 1; }
            live=$(/opt/cn-egress/awg-0.2.16/awg show cne-users preshared-keys 2>/dev/null) || { cne_n_error '无法核验运行中的客户端配置。'; return 1; }
        else
            server_public=$(cne_n_net hk wg show cne-users public-key 2>/dev/null) || { cne_n_error '无法核验运行中的服务端公钥。'; return 1; }
            live=$(cne_n_net hk wg show cne-users preshared-keys 2>/dev/null) || { cne_n_error '无法核验运行中的客户端配置。'; return 1; }
        fi
        [[ $server_public == "$expected_server" ]] || { unset live; cne_n_error '运行中服务端公钥核验未通过。'; return 1; }
        psk=$(awk -F'\t' -v target="$public" '$1==target{count++;if(NF!=2)bad=1;value=$2}END{if(count!=1||bad)exit 1;print value}' <<< "$live") || { unset live; cne_n_error '运行中未找到唯一的已登记客户端。'; return 1; }
        unset live
        [[ $psk =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { unset psk; cne_n_error '运行中客户端的预共享密钥无效。'; return 1; }
        actual_hash=$(printf '%s\n' "$psk" | sha256sum) || { unset psk; return 1; }
        unset psk
        actual_hash=${actual_hash%% *}
        [[ $actual_hash == "$expected_hash" ]] || { cne_n_error '运行中客户端的预共享密钥核验未通过。'; return 1; }
    fi
    printf '客户端登记配置核验通过。\n'
}
cne_n_client_sync() {
    if ip -n cn-egress-relay link show cne-users >/dev/null 2>&1; then
        local stripped result
        stripped=$(mktemp /etc/wireguard/.cne-sync.XXXXXXXX) || return 1
        chmod 600 "$stripped"
        if [[ $(cne_n_user_transport) == awg2 ]]; then
            # Keep AWG packet parameters; discard only wg-quick interface helpers.
            if ! awk '!/^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=/' /etc/wireguard/cne-users.conf > "$stripped"; then rm -f "$stripped"; return 1; fi
            /opt/cn-egress/awg-0.2.16/awg syncconf cne-users "$stripped"; result=$?
        else
            if ! wg-quick strip /etc/wireguard/cne-users.conf > "$stripped"; then rm -f "$stripped"; return 1; fi
            cne_n_net hk wg syncconf cne-users "$stripped"; result=$?
        fi
        rm -f "$stripped"
        return "$result"
    fi
}
cne_n_client_add() {
    local role=$1 name=$2 address=$3 public=$4 expected_server=${5:-} server_public psk=${CNE_CLIENT_PSK:-} config=/etc/wireguard/cne-users.conf registry=/etc/cn-egress/clients.tsv saved temporary registry_new existing
    [[ $role == hk ]] && cne_n_require_role hk || return 1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ && $address =~ ^[0-9]+$ && $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] && ((address>=2 && address<=249)) || { cne_n_error '客户端名称、地址或公钥无效。'; return 1; }
    [[ -z $expected_server || $expected_server =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '期望的服务端公钥无效。'; return 1; }
    server_public=$(cne_n_server_public) || return 1
    # The controller may have fetched the key before another manager replaced
    # the deployment. Compare again while cne_node_main holds the node lock.
    [[ -z $expected_server || $expected_server == "$server_public" ]] || { cne_n_error '服务端公钥已变化，拒绝添加旧部署的客户端配置。'; return 1; }
    [[ $public != "$server_public" ]] || { cne_n_error '客户端公钥不能使用服务端公钥。'; return 1; }
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
    local role=$1 name=$2 expected_public=${3:-} expected_server=${4:-} server_public existing public config=/etc/wireguard/cne-users.conf registry=/etc/cn-egress/clients.tsv saved temporary registry_new=''
    [[ $role == hk ]] && cne_n_require_role hk || return 1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || return 1
    [[ -z $expected_public || $expected_public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '期望的客户端公钥无效。'; return 1; }
    [[ -z $expected_server || $expected_server =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '期望的服务端公钥无效。'; return 1; }
    # Check server identity even when the named peer is already absent. Otherwise
    # a lost reply followed by a reinstall could falsely finalize an old revoke.
    if [[ -n $expected_server ]]; then
        server_public=$(cne_n_server_public) || return 1
        [[ $expected_server == "$server_public" ]] || { cne_n_error '服务端公钥已变化，拒绝撤销其他部署的客户端。'; return 1; }
    fi
    existing=$(cne_n_client_list) || return 1
    public=$(awk -F'\t' -v n="$name" '$1==n{print $3;exit}' <<< "$existing")
    if [[ -z $public && -n $expected_public && -n $expected_server ]]; then printf '客户端已不存在：%s\n' "$name"; return 0; fi
    [[ $public =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { cne_n_error '未找到该客户端。'; return 1; }
    [[ -z $expected_public || $expected_public == "$public" ]] || { cne_n_error '同名客户端公钥已变化，拒绝撤销其他客户端。'; return 1; }
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
        prepare) cne_n_prepare "$role" "${1:-wireguard}";;
        backup) cne_n_scope_check && cne_n_backup;;
        restore) (($#>=1 && $#<=2)) || return 2; cne_n_restore "$@";;
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
        client-params) [[ $role == hk ]] && cne_n_client_params;;
        client-verify) (($#==3)) || return 2; cne_n_client_verify "$role" "$@";;
        client-add) (($#==3 || $#==4)) || return 2; cne_n_client_add "$role" "$@";;
        client-remove) (($#>=1 && $#<=3)) || return 2; cne_n_client_remove "$role" "$@";;
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
