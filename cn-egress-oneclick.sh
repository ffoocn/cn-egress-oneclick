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
    local state=absent role version=unknown service=inactive wan='' user_port='' user_transport deployment=none
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
    cne_n_safe_path /etc/cn-egress/deployment-id || return 1
    if [[ -f /etc/cn-egress/deployment-id ]]; then deployment=$(cat /etc/cn-egress/deployment-id); [[ $deployment =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || deployment=unknown; fi
    printf 'state=%s\nrole=%s\narch=%s\nwan=%s\nforwarding=%s\nservice=%s\nversion=%s\nuser_port=%s\nuser_transport=%s\ndeployment=%s\n' "$state" "$role" "$(uname -m)" "$wan" "$(cne_n_forwarding)" "$service" "$version" "$user_port" "$user_transport" "$deployment"
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
cne_n_kernel_fallback() {
    local name=$1 kind details flags addresses routes
    case $name in
        tunl0) kind=ipip;; gre0) kind=gre;; gretap0) kind=gretap;; erspan0) kind=erspan;;
        ip_vti0) kind=vti;; ip6_vti0) kind=vti6;; sit0) kind=sit;; ip6tnl0) kind=ip6tnl;; ip6gre0) kind=ip6gre;;
        *) return 1;;
    esac
    details=$(ip -n cn-egress-relay -o -d link show dev "$name" 2>/dev/null) || return 1
    [[ $details == *' state DOWN '* && $details != *' master '* && $details != *' alias '* ]] || return 1
    flags=${details#*<}; [[ $flags != "$details" ]] || return 1; flags=${flags%%>*}
    [[ ,$flags, != *,UP,* && ,$flags, != *,LOWER_UP,* ]] || return 1
    grep -Eq "[[:space:]]$kind([[:space:]]+(any|ip6ip|ip6ip6))?[[:space:]]+remote[[:space:]]+any[[:space:]]+local[[:space:]]+any([[:space:]]|$)" <<< "$details" || return 1
    addresses=$(ip -n cn-egress-relay -o address show dev "$name" 2>/dev/null) || return 1
    [[ -z $addresses ]] || return 1
    routes=$(ip -n cn-egress-relay -4 route show table all dev "$name" 2>/dev/null) || return 1
    [[ -z $routes ]] || return 1
    routes=$(ip -n cn-egress-relay -6 route show table all dev "$name" 2>/dev/null) || return 1
    [[ -z $routes ]]
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
                case "$name" in lo|cne-users|cne-cn|cne-exit) :;; *) cne_n_kernel_fallback "$name" || { cne_n_error "cn-egress-relay 内含其他网卡 ${name}，不能覆盖。"; return 1; };; esac
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
    local archive=$1 destination=$2 directory=/root/cn-egress-backups
    [[ $archive == "$directory/"* && ${archive##*/} =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{8}\.tar\.gz$ && ${archive%/*} == "$directory" ]] || { cne_n_error '只能恢复本节点 root 备份目录内的备份。'; return 1; }
    cne_n_safe_path "$archive" || return 1
    [[ -d $directory && -f $archive && ! -L $archive ]] || { cne_n_error '备份不是普通文件。'; return 1; }
    [[ $(stat -c %u "$directory") == 0 && $(stat -c %a "$directory") == 700 && $(stat -c %u "$archive") == 0 && $(stat -c %a "$archive") == 600 && $(stat -c %h "$archive") == 1 ]] || { cne_n_error '备份归属、权限或链接数量不符合要求。'; return 1; }
    cne_n_validate_backup_contents "$archive" "$destination" "${archive##*/}"
}
cne_n_validate_backup_contents() {
    local archive=$1 destination=$2 basename=$3 path list verbose count=0 expected node
    [[ $basename =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{8}\.tar\.gz$ ]] || { cne_n_error '备份文件名无效。'; return 1; }
    cne_n_private_upload "$archive" 104857600 || return 1
    list=$(tar -tzf "$archive") && verbose=$(tar -tvzf "$archive") || { cne_n_error '备份无法读取。'; return 1; }
    [[ -n $list && -n $verbose ]] || return 1
    [[ -z $(printf '%s\n' "$list" | sort | uniq -d) ]] || { cne_n_error '备份包含重复路径。'; return 1; }
    if grep -qv '^-' <<< "$verbose"; then cne_n_error '备份仅允许普通文件。'; return 1; fi
    cne_n_tar_size_check "$verbose" 104857600 || { cne_n_error '备份解压后过大或成员大小无效。'; return 1; }
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
    expected=$(printf 'format=cn-egress-node-backup-v1\narchive=%s\nnode=%s\n' "$basename" "$node")
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
    local temporary=$1 override_id=${2:-} file unit state enabled failures=0 marker
    [[ -z $override_id || $override_id =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '恢复操作编号无效。'; return 1; }
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
    # Extraction intentionally assigns ownership to root. Re-establish the
    # dedicated transport group used by generated unprivileged WSS units.
    if [[ -f /etc/systemd/system/cn-egress-obfs.service ]] && grep -Eq '^[[:space:]]*User[[:space:]]*=[[:space:]]*cn-egress-wss[[:space:]]*$' /etc/systemd/system/cn-egress-obfs.service; then
        cne_n_transport_user || failures=1
        while IFS= read -r file; do
            case $file in etc/cn-egress-wss/*) [[ ! -f /$file ]] || chown root:cn-egress-wss "/$file" || failures=1;; esac
        done < <(cne_n_all_files)
    fi
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
    # Starting the main unit also starts Wants/Requires dependencies. Enforce
    # archived stopped states after these implicit starts, particularly obfs.
    for unit in cn-egress-dns.service cn-egress-obfs.service cn-egress.service cn-egress-users.service; do
        [[ -f /etc/systemd/system/$unit ]] || continue
        if ! awk -F'\t' -v u="$unit" '$1==u && $2=="active"{found=1}END{exit !found}' "$temporary/.cn-egress-services.tsv" && systemctl is-active --quiet "$unit"; then
            systemctl stop "$unit" >&2 || failures=1
        fi
    done
    for unit in cn-egress-users.service cn-egress.service cn-egress-obfs.service cn-egress-dns.service; do
        [[ -f /etc/systemd/system/$unit ]] || continue
        if awk -F'\t' -v u="$unit" '$1==u && $2=="active"{found=1}END{exit !found}' "$temporary/.cn-egress-services.tsv"; then
            systemctl is-active --quiet "$unit" || failures=1
        fi
    done
    ((failures==0)) || { cne_n_error '恢复未完全成功，请保留备份并检查本工具服务。'; return 1; }
    if [[ -n $override_id ]]; then
        cne_n_deployment_mark "$override_id" || return 1
    elif [[ -f $temporary/etc/cn-egress/deployment-id ]]; then
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
cne_n_private_upload() {
    local file=$1 maximum=$2 size
    cne_n_safe_path "$file" || return 1
    [[ -f $file && ! -L $file && $(stat -c %u "$file") == 0 && $(stat -c %a "$file") == 600 && $(stat -c %h "$file") == 1 ]] || { cne_n_error '上传文件必须是 root 私有普通文件，不能包含链接。'; return 1; }
    size=$(stat -c %s "$file") || return 1
    [[ $size =~ ^[0-9]+$ ]] && ((size>0 && size<=maximum)) || { cne_n_error '上传文件为空或过大。'; return 1; }
}
cne_n_tar_size_check() {
    # GNU tar uses mode,owner/group,size; BSD tar additionally prints a link
    # count and separate owner/group columns. Both list ordinary files here.
    LC_ALL=C awk -v maximum="$2" '{size=$3;if($2~/^[0-9]+$/ && $5~/^[0-9]+$/)size=$5;if(size!~/^[0-9]+$/)bad=1;total+=size}END{exit bad || total>maximum}' <<< "$1"
}
cne_n_deployment_read() {
    cne_n_safe_path /etc/cn-egress/deployment-id || return 1
    if [[ ! -f /etc/cn-egress/deployment-id ]]; then printf 'none\n'; return; fi
    local deployment
    deployment=$(cat /etc/cn-egress/deployment-id) || return 1
    [[ $deployment =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '现有部署编号无效。'; return 1; }
    printf '%s\n' "$deployment"
}
cne_n_deployment_mark() {
    local operation=$1 marker
    [[ $operation =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '维护操作编号无效。'; return 1; }
    cne_n_safe_path /etc/cn-egress/deployment-id || return 1
    mkdir -p /etc/cn-egress || return 1
    marker=$(mktemp /etc/cn-egress/.deployment.XXXXXXXX) || return 1
    if ! printf '%s\n' "$operation" > "$marker" || ! chmod 600 "$marker" || ! mv "$marker" /etc/cn-egress/deployment-id; then rm -f "$marker"; return 1; fi
}
cne_n_maintenance_guard() {
    local role=$1 expected=$2 absent=${3:-} current unit transport
    [[ $expected == none || $expected =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '预期部署编号无效。'; return 1; }
    cne_n_scope_check || return 1
    if cne_n_exists; then
        cne_n_require_role "$role" || { cne_n_error '维护要求本节点已有同角色的本工具部署。'; return 1; }
        [[ -f /etc/cn-egress/role && -f /etc/cn-egress-wss/role ]] || { cne_n_error '节点部署不完整，不能进行维护，请先修复安装。'; return 1; }
        transport=$(cne_n_user_transport) || return 1
        for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do
            [[ $unit != cn-egress-dns.service || $role == exit ]] || continue
            [[ $unit != cn-egress-users.service || ( $role == hk && $transport == awg2 ) ]] || continue
            [[ -f /etc/systemd/system/$unit ]] || { cne_n_error "节点部署缺少服务 ${unit}，请先修复安装。"; return 1; }
        done
    elif [[ $absent != allow-absent || $expected != none ]]; then
        cne_n_error '维护要求本节点已有同角色的本工具部署。'; return 1
    fi
    current=$(cne_n_deployment_read) || return 1
    [[ $current == "$expected" ]] || { cne_n_error '节点部署已改变，请重新检查后再操作。'; return 1; }
}
cne_n_config_records() {
    local mode=${1:-config} file hash
    while IFS= read -r file; do
        case $file in
            etc/cn-egress/deployment-id) continue;;
            etc/cn-egress-wss/ca.crt|etc/cn-egress-wss/node.crt|etc/cn-egress-wss/node.key) [[ $mode == tls ]] || continue;;
            *) [[ $mode != tls ]] || continue;;
        esac
        cne_n_safe_path "/$file" || return 1
        if [[ -f /$file ]]; then
            hash=$(sha256sum "/$file") || return 1
            printf '%s\t%s\n' "$file" "${hash%% *}"
        else printf '%s\tabsent\n' "$file"; fi
    done < <(cne_n_all_files)
}
cne_n_config_fingerprint() {
    local mode=${1:-config} records
    records=$(cne_n_config_records "$mode") || return 1
    printf '%s\n' "$records" | sha256sum | awk '{print $1}'
}
cne_n_maintenance_info() {
    local role=$1 state=absent actual=unknown deployment=none ca=none host=none config tls unit label active enabled cert_due=1 ca_due=1
    cne_n_scope_check || return 1
    if cne_n_exists; then
        state=present; actual=$(cne_n_existing_role) || return 1
        [[ $actual == "$role" ]] || { cne_n_error '节点角色与维护配置不符。'; return 1; }
        deployment=$(cne_n_deployment_read) || return 1
    fi
    cne_n_safe_path /etc/cn-egress-wss/ca.crt && cne_n_safe_path /etc/cn-egress-wss/sh-host || return 1
    if [[ -f /etc/cn-egress-wss/ca.crt ]]; then ca=$(sha256sum /etc/cn-egress-wss/ca.crt) || return 1; ca=${ca%% *}; fi
    if [[ -f /etc/cn-egress-wss/sh-host ]]; then
        host=$(cat /etc/cn-egress-wss/sh-host) || return 1
        [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && ${#host} -le 253 ]] || { cne_n_error '现有传输主机地址无效。'; return 1; }
    fi
    config=$(cne_n_config_fingerprint config) && tls=$(cne_n_config_fingerprint tls) || return 1
    cne_n_safe_path /etc/cn-egress-wss/node.crt || return 1
    openssl x509 -in /etc/cn-egress-wss/node.crt -noout -checkend 2592000 >/dev/null 2>&1 && cert_due=0
    openssl x509 -in /etc/cn-egress-wss/ca.crt -noout -checkend 2592000 >/dev/null 2>&1 && ca_due=0
    printf 'state=%s\nrole=%s\ndeployment=%s\nca_sha256=%s\nconfig_sha256=%s\ntls_sha256=%s\nwss_host=%s\ncert_due=%s\nca_due=%s\n' "$state" "$actual" "$deployment" "$ca" "$config" "$tls" "$host" "$cert_due" "$ca_due"
    for label in main obfs dns users; do
        case $label in main) unit=cn-egress.service;; *) unit="cn-egress-$label.service";; esac
        active=$(systemctl is-active "$unit" 2>/dev/null) || :
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null) || :
        [[ $active =~ ^(active|inactive|failed|activating|deactivating|reloading|maintenance|refreshing|unknown)$ ]] || active=inactive
        [[ $enabled =~ ^(enabled|enabled-runtime|disabled|static|indirect|generated|masked|masked-runtime|transient|linked|linked-runtime|alias|bad|not-found|unknown)$ ]] || enabled=not-found
        printf '%s_active=%s\n%s_enabled=%s\n' "$label" "$active" "$label" "$enabled"
    done
}
cne_n_backup_export() {
    local role=$1 archive=$2 stage
    cne_n_scope_check && cne_n_backup_directory || return 1
    stage=$(mktemp -d /root/cn-egress-backups/.export.XXXXXXXX) || return 1
    if ! cne_n_validate_backup "$archive" "$stage"; then rm -rf "$stage"; return 1; fi
    if [[ -f $stage/etc/cn-egress/role && $(cat "$stage/etc/cn-egress/role") != "$role" ]]; then rm -rf "$stage"; cne_n_error '备份节点角色与请求不符。'; return 1; fi
    rm -rf "$stage"
    base64 < "$archive"
}
cne_n_restore_target_check() (
    local stage=$1 role=$2 unit file content transport=wireguard wan mode
    [[ -f $stage/etc/cn-egress/role && $(cat "$stage/etc/cn-egress/role") == "$role" && -f $stage/etc/cn-egress-wss/role && $(cat "$stage/etc/cn-egress-wss/role") == "$role" ]] || { cne_n_error '历史恢复需要同角色的完整部署备份，不能恢复为空节点。'; exit 1; }
    if [[ -f $stage/etc/cn-egress/user-transport ]]; then transport=$(cat "$stage/etc/cn-egress/user-transport"); fi
    [[ $transport == wireguard || ( $role == hk && $transport == awg2 ) ]] || { cne_n_error '备份客户端传输类型无效。'; exit 1; }
    cne_n_user_transport() { printf '%s\n' "$transport"; }
    while IFS= read -r file; do
        [[ -f $stage/$file ]] || continue
        mode=$(stat -c %a "$stage/$file") || exit 1
        [[ $(stat -c %u "$stage/$file") == 0 && $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022)==0 )) || { cne_n_error "历史备份文件可被其他用户修改：$file"; exit 1; }
    done < <(cne_n_all_files)
    for unit in cn-egress.service cn-egress-obfs.service cn-egress-dns.service cn-egress-users.service; do
        file="$stage/etc/systemd/system/$unit"
        if [[ -f $file ]]; then cne_n_unit_file_check "$file" "$unit" "$role" || exit 1
        elif [[ $unit == cn-egress.service || $unit == cn-egress-obfs.service || ( $unit == cn-egress-dns.service && $role == exit ) || ( $unit == cn-egress-users.service && $role == hk && $transport == awg2 ) ]]; then
            cne_n_error "历史备份服务缺失：$unit"; exit 1
        fi
    done
    for file in obfs.conf users.conf; do
        [[ -f $stage/etc/systemd/system/cn-egress.service.d/$file ]] || continue
        content=$(sed -E '/^[[:space:]]*([#;]|$)/d; s/^[[:space:]]+//; s/[[:space:]]+$//' "$stage/etc/systemd/system/cn-egress.service.d/$file") || exit 1
        case $file in
            obfs.conf) [[ $content == $'[Unit]\nWants=cn-egress-obfs.service\nAfter=cn-egress-obfs.service' ]] || exit 1;;
            users.conf) [[ $role == hk && $transport == awg2 && ( $content == $'[Unit]\nRequires=cn-egress-users.service\nBindsTo=cn-egress-users.service\nAfter=cn-egress-users.service' || $content == $'[Unit]\nRequires=cn-egress-users.service\nAfter=cn-egress-users.service' ) ]] || exit 1;;
        esac
    done
    if [[ $role == exit ]]; then
        [[ -f $stage/etc/cn-egress/wan-interface ]] || { cne_n_error '出口备份缺少上联网卡。'; exit 1; }
        wan=$(cne_n_wan) || exit 1
        [[ -n $wan && $(cat "$stage/etc/cn-egress/wan-interface") == "$wan" ]] || { cne_n_error '出口上联网卡已改变，不能直接恢复该备份。'; exit 1; }
    fi
)
cne_n_restore_import() {
    local role=$1 upload=$2 basename=$3 expected=$4 operation=$5 stage archive incoming
    [[ $operation =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '恢复操作编号无效。'; return 1; }
    cne_n_maintenance_guard "$role" "$expected" allow-absent && cne_n_private_upload "$upload" 104857600 || return 1
    cne_n_backup_directory || return 1
    stage=$(mktemp -d /root/cn-egress-backups/.import.XXXXXXXX) || return 1
    if ! cne_n_validate_backup_contents "$upload" "$stage" "$basename" || ! cne_n_restore_target_check "$stage" "$role"; then rm -rf "$stage"; return 1; fi
    archive="/root/cn-egress-backups/$basename"
    cne_n_safe_path "$archive" || { rm -rf "$stage"; return 1; }
    if [[ -f $archive ]]; then
        if ! cne_n_private_upload "$archive" 104857600 || ! cmp -s "$upload" "$archive"; then rm -rf "$stage"; cne_n_error '本节点已有同名但内容不同的备份，已停止。'; return 1; fi
    else
        incoming=$(mktemp /root/cn-egress-backups/.incoming.XXXXXXXX) || { rm -rf "$stage"; return 1; }
        if ! cp "$upload" "$incoming" || ! chmod 600 "$incoming" || ! mv "$incoming" "$archive"; then rm -f "$incoming"; rm -rf "$stage"; return 1; fi
    fi
    # Re-check identity while still holding the node lock, then keep this operation
    # identity throughout a partial restore so the manager can undo every node.
    if ! cne_n_maintenance_guard "$role" "$expected" allow-absent || ! cne_n_deployment_mark "$operation"; then rm -rf "$stage"; return 1; fi
    if ! cne_n_restore_apply "$stage" "$operation"; then rm -rf "$stage"; return 1; fi
    rm -rf "$stage"
    printf '历史备份已恢复。\n'
}
cne_n_certificate_validate() {
    local role=$1 archive=$2 stage=$3 list verbose host purpose usage key_public cert_public ca_public subject
    cne_n_private_upload "$archive" 65536 || return 1
    list=$(tar -tzf "$archive") && verbose=$(tar -tvzf "$archive") || { cne_n_error '证书更新包无法读取。'; return 1; }
    [[ $(printf '%s\n' "$list" | LC_ALL=C sort) == $'ca.crt\nnode.crt\nnode.key' ]] && ! grep -qv '^-' <<< "$verbose" || { cne_n_error '证书更新包只允许 ca.crt、node.crt、node.key 三个普通文件。'; return 1; }
    cne_n_tar_size_check "$verbose" 65536 || { cne_n_error '证书更新包解压后过大。'; return 1; }
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$stage" || return 1
    for subject in ca.crt node.crt; do
        [[ $(awk '/-----BEGIN CERTIFICATE-----/{n++}END{print n+0}' "$stage/$subject") == 1 ]] && ! grep -q 'PRIVATE KEY' "$stage/$subject" && openssl x509 -in "$stage/$subject" -noout -checkend 2592000 >/dev/null 2>&1 || { cne_n_error '证书无效、包含私钥或将在 30 天内到期。'; return 1; }
    done
    subject=$(openssl x509 -in "$stage/ca.crt" -noout -ext basicConstraints 2>/dev/null) || return 1
    [[ $subject == *'CA:TRUE'* ]] || { cne_n_error '更新包中的 CA 不是有效 CA 证书。'; return 1; }
    subject=$(openssl x509 -in "$stage/node.crt" -noout -ext basicConstraints 2>/dev/null) || return 1
    [[ $subject == *'CA:FALSE'* ]] || { cne_n_error '节点证书不能作为 CA 使用。'; return 1; }
    key_public=$(openssl pkey -in "$stage/node.key" -passin pass: -pubout 2>/dev/null) || { cne_n_error '节点私钥无效，不能使用加密或损坏的私钥。'; return 1; }
    cert_public=$(openssl x509 -in "$stage/node.crt" -pubkey -noout 2>/dev/null) || return 1
    [[ $key_public == "$cert_public" ]] || { cne_n_error '证书与节点私钥不匹配。'; return 1; }
    ca_public=$(openssl x509 -in "$stage/ca.crt" -pubkey -noout 2>/dev/null) || return 1
    [[ $key_public != "$ca_public" ]] || { cne_n_error '节点私钥不能与 CA 私钥相同。'; return 1; }
    subject=$(openssl x509 -in "$stage/node.crt" -noout -subject -nameopt RFC2253 2>/dev/null) || return 1
    [[ $subject == "subject=CN=cn-egress-$role" || $subject == "subject= CN=cn-egress-$role" ]] || { cne_n_error '节点证书角色不符。'; return 1; }
    purpose=sslclient; usage='TLS Web Client Authentication'
    [[ $role != sh ]] || { purpose=sslserver; usage='TLS Web Server Authentication'; }
    subject=$(openssl x509 -in "$stage/node.crt" -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//') || return 1
    [[ $subject == "$usage" ]] || { cne_n_error '节点证书用途与角色不符。'; return 1; }
    openssl verify -CAfile "$stage/ca.crt" -check_ss_sig "$stage/ca.crt" >/dev/null 2>&1 && openssl verify -CAfile "$stage/ca.crt" -purpose "$purpose" "$stage/node.crt" >/dev/null 2>&1 || { cne_n_error '证书 CA 或签名链无效。'; return 1; }
    if [[ $role == sh ]]; then
        cne_n_safe_path /etc/cn-egress-wss/sh-host || return 1
        host=$(cat /etc/cn-egress-wss/sh-host) || return 1
        [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && ${#host} -le 253 ]] || return 1
        if [[ $host =~ ^[0-9.]+$ ]]; then
            openssl verify -CAfile "$stage/ca.crt" -purpose sslserver -verify_ip "$host" "$stage/node.crt" >/dev/null 2>&1
        else openssl verify -CAfile "$stage/ca.crt" -purpose sslserver -verify_hostname "$host" "$stage/node.crt" >/dev/null 2>&1; fi || { cne_n_error '大陆中转证书不包含当前传输地址。'; return 1; }
    fi
}
cne_n_certificate_apply() {
    local role=$1 archive=$2 expected=$3 operation=$4 stage file destination replacement active enabled mode
    [[ $operation =~ ^[a-zA-Z0-9_-]{8,80}$ ]] || { cne_n_error '证书更新操作编号无效。'; return 1; }
    cne_n_maintenance_guard "$role" "$expected" || return 1
    for file in ca.crt node.crt node.key; do
        destination="/etc/cn-egress-wss/$file"
        cne_n_safe_path "$destination" || return 1
        [[ -f $destination && $(stat -c %u "$destination") == 0 ]] || { cne_n_error '现有证书文件归属无效或缺失。'; return 1; }
        mode=$(stat -c %a "$destination") || return 1
        [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022)==0 )) || { cne_n_error '现有证书可被其他用户修改。'; return 1; }
    done
    stage=$(mktemp -d /etc/cn-egress-wss/.renew.XXXXXXXX) || return 1
    if ! cne_n_certificate_validate "$role" "$archive" "$stage"; then rm -rf "$stage"; return 1; fi
    active=$(systemctl is-active cn-egress-obfs.service 2>/dev/null) || :
    enabled=$(systemctl is-enabled cn-egress-obfs.service 2>/dev/null) || :
    [[ $active == active || $active == inactive || $active == failed ]] || { rm -rf "$stage"; cne_n_error '传输服务正在切换状态，请稍后重试。'; return 1; }
    systemctl daemon-reload >&2 && cne_n_maintenance_guard "$role" "$expected" || { rm -rf "$stage"; return 1; }
    cne_n_deployment_mark "$operation" || { rm -rf "$stage"; return 1; }
    if [[ $active == active ]]; then systemctl stop cn-egress-obfs.service >&2 || { rm -rf "$stage"; return 1; }; fi
    for file in ca.crt node.crt node.key; do
        destination="/etc/cn-egress-wss/$file"
        replacement=$(mktemp /etc/cn-egress-wss/.certificate.XXXXXXXX) || { rm -rf "$stage"; return 1; }
        # Preserve the existing certificate permissions and transport group while
        # publishing each file atomically. WireGuard/AWG configuration is untouched.
        if ! cp -p "$destination" "$replacement" || ! cat "$stage/$file" > "$replacement" || ! mv "$replacement" "$destination"; then rm -f "$replacement"; rm -rf "$stage"; return 1; fi
    done
    rm -rf "$stage"
    if [[ $active == active ]]; then systemctl start cn-egress-obfs.service >&2 && systemctl is-active --quiet cn-egress-obfs.service || return 1; fi
    [[ $(systemctl is-enabled cn-egress-obfs.service 2>/dev/null || :) == "$enabled" ]] || { cne_n_error '传输服务启用状态已改变，更新未完成。'; return 1; }
    printf '传输证书已更新，设备配置保持不变。\n'
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
    printf '2.2.1\n' > /etc/cn-egress/version || return 1
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
    [[ $actual == "$role" ]] || { cne_n_error "当前节点角色为 ${actual}，期望 ${role}。请选择备份后覆盖安装以修复不完整配置。"; return 1; }
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
        maintenance-info) (($#==0)) || return 2; cne_n_maintenance_info "$role";;
        preflight) cne_n_preflight "$role" "$@";;
        prepare) cne_n_prepare "$role" "${1:-wireguard}";;
        backup) cne_n_scope_check && cne_n_backup;;
        backup-export) (($#==1)) || return 2; cne_n_backup_export "$role" "$@";;
        restore) (($#>=1 && $#<=2)) || return 2; cne_n_restore "$@";;
        restore-import) (($#==4)) || return 2; cne_n_restore_import "$role" "$@";;
        certificate-apply) (($#==3)) || return 2; cne_n_certificate_apply "$role" "$@";;
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

relay_users_up() {
    local mode=wireguard attempt ready=0
    [[ ! -f "$config_dir/user-transport" ]] || IFS= read -r mode < "$config_dir/user-transport"
    case $mode in
        wireguard) relay_wg_up cne-users 10.77.10.1/24 fd77:77:10::1/64; return;;
        awg2) ;;
        *) printf '入口协议无效，已停止。\n' >&2; return 1;;
    esac
    if ! ip -n "$relay_ns" link show cne-users >/dev/null 2>&1; then
        # The separate foreground daemon stays in the host namespace. Both
        # startup and later UDP rebinds therefore use the host's normal route.
        # A pathname Unix UAPI socket is accessible across network namespaces.
        for attempt in $(seq 1 100); do
            if [[ -S /var/run/amneziawg/cne-users.sock ]] && \
                ip link show cne-users >/dev/null 2>&1 && \
                /opt/cn-egress/awg-0.2.16/awg show cne-users >/dev/null 2>&1; then
                ready=1; break
            fi
            sleep 0.1
        done
        [[ $ready == 1 ]] || { printf 'AmneziaWG 用户态入口未就绪，已停止。\n' >&2; return 1; }
        relay_pending+=(cne-users)
        wg-quick strip /etc/wireguard/cne-users.conf | /opt/cn-egress/awg-0.2.16/awg setconf cne-users /dev/stdin
        # The daemon observes MTU changes in its host namespace. Configure MTU
        # before moving the TUN; its polling listener handles Up across netns.
        ip link set cne-users mtu 1380
        ip link set cne-users netns "$relay_ns"
        relay_pending=()
        net ip address add 10.77.10.1/24 dev cne-users
        net ip -6 address add fd77:77:10::1/64 dev cne-users
        net ip link set cne-users up
    fi
    net sysctl -q -w net.ipv4.conf.cne-users.rp_filter=2
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
    relay_users_up
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

cne_users_source() {
cat <<'CNE_EMBEDDED_cne_users_source_V2'
#!/usr/bin/env bash
# Keep the first-hop UDP sockets in the host namespace. cn-egress-net moves
# only the TUN into the isolated relay after configuring the userspace daemon.
set -Eeuo pipefail
[[ ${1:-start} == start ]] || { printf '用法：cn-egress-users start\n' >&2; exit 2; }
[[ $(cat /etc/cn-egress/user-transport) == awg2 ]]
[[ -c /dev/net/tun ]] || { printf 'AmneziaWG 需要 /dev/net/tun。\n' >&2; exit 1; }
exec env WG_PROCESS_FOREGROUND=1 LOG_LEVEL=error \
    /opt/cn-egress/awg-0.2.16/amneziawg-go -f cne-users

CNE_EMBEDDED_cne_users_source_V2
}

cne_probe_source() {
cat <<'CNE_EMBEDDED_cne_probe_source_V2'
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

CNE_EMBEDDED_cne_probe_source_V2
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

# APT may configure pending packages even when no upgrade/removal was requested.
# Only configure packages that this plan also installs for the first time.
cne_install_plan_safe() {
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

cne_bootstrap() {
    local mode=${1:-all} item tool package installed audit plan
    local packages=() tools=() requirements=()
    [[ $(uname -s) == Linux ]] || { cne_error '请在 Debian 12+ 或 Ubuntu 22.04+ 的 Linux 管理机运行。'; return 1; }
    command -v apt-get >/dev/null 2>&1 || { cne_error '当前版本支持 Debian / Ubuntu 的 APT 系统。'; return 1; }
    case $mode in
        ui) requirements=('flock:util-linux') ;;
        ssh) requirements=('ssh:openssh-client' 'sshpass:sshpass' 'flock:util-linux') ;;
        client) requirements=('wg:wireguard-tools' 'ssh:openssh-client' 'sshpass:sshpass' 'flock:util-linux' 'sha256sum:coreutils') ;;
        maintenance) requirements=('ssh:openssh-client' 'sshpass:sshpass' 'flock:util-linux' 'openssl:openssl' 'tar:tar' 'gzip:gzip' 'base64:coreutils' 'sha256sum:coreutils') ;;
        all|install)
            requirements=('ssh:openssh-client' 'sshpass:sshpass' 'openssl:openssl' 'curl:curl' 'wg:wireguard-tools' 'flock:util-linux' 'tar:tar' 'base64:coreutils' 'sha256sum:coreutils' 'gzip:gzip' 'timeout:coreutils') ;;
        *) cne_error "未知的依赖准备类型：$mode"; return 1 ;;
    esac
    # Merely opening the menu or viewing a saved profile must not prepare VPN
    # build/download tools. Prepare each operation's prerequisites when needed.
    for item in "${requirements[@]}"; do
        tool=${item%%:*}; package=${item#*:}
        tools+=("$tool")
        if ! command -v "$tool" >/dev/null 2>&1; then
            case " ${packages[*]:-} " in *" $package "*) ;; *) packages+=("$package");; esac
        fi
    done
    if [[ $mode == all || $mode == install ]]; then
        installed=$(dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null) || installed=''
        [[ $installed == 'install ok installed' ]] || packages+=(ca-certificates)
    fi
    [[ ${#packages[@]} -gt 0 ]] || return 0
    [[ ${CNE_NONINTERACTIVE:-0} != 1 ]] || { cne_error "自动维护缺少依赖：${packages[*]}。请手动运行脚本补齐依赖。"; return 1; }
    audit=$(LC_ALL=C dpkg --audit 2>&1) || {
        cne_error '无法检查系统软件包状态，依赖安装已停止。'
        [[ -z $audit ]] || printf '%s\n' "$audit" >&2
        return 1
    }
    [[ -z $audit ]] || {
        cne_error '系统存在未完成的软件包操作，依赖安装已停止。请先处理以下 dpkg 状态：'
        printf '%s\n' "$audit" >&2
        return 1
    }
    if [[ $(id -u) != 0 ]]; then
        command -v sudo >/dev/null 2>&1 || { cne_error '自动安装依赖需要 root 或 sudo。'; return 1; }
        sudo -v || return 1
    fi
    printf '\n首次准备：安装缺少的依赖 %s\n' "${packages[*]}"
    cne_root apt-get -qq update || { cne_error '软件源更新失败，请检查网络。'; return 1; }
    plan=$(cne_root apt-get -s --no-install-recommends --no-upgrade --no-remove install "${packages[@]}" 2>&1) || {
        cne_error '无法确认依赖安装计划，安装已停止。'
        [[ -z $plan ]] || printf '%s\n' "$plan" >&2
        return 1
    }
    cne_install_plan_safe "$plan" || {
        cne_error '安装依赖会升级、删除或配置已有软件，已停止。请先处理以下软件包计划：'
        printf '%s\n' "$plan" >&2
        return 1
    }
    cne_root apt-get -y -qq --no-install-recommends --no-upgrade --no-remove install "${packages[@]}" || {
        cne_error '依赖安装失败，请检查上方软件包错误。'; return 1;
    }
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || { cne_error "安装后仍缺少 ${tool}。"; return 1; }
    done
    printf '依赖准备完成。\n'
}

# QR rendering is optional. Never prepare it while opening the management menu.
cne_ensure_qrencode() {
    local audit plan
    command -v qrencode >/dev/null 2>&1 && return 0
    [[ $(uname -s) == Linux ]] && command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1 || {
        cne_note '二维码工具暂不可用：当前系统无法自动安装 qrencode。'; return 1;
    }
    # Audit before sudo: a broken package database must not even request a
    # privilege escalation for this optional feature.
    audit=$(LC_ALL=C dpkg --audit 2>&1) || {
        cne_note '二维码工具暂不可用：无法检查系统软件包状态。'
        [[ -z $audit ]] || printf '%s\n' "$audit" >&2
        return 1
    }
    [[ -z $audit ]] || {
        cne_note '二维码工具暂不可用：系统有未完成的软件包操作，请先处理以下 dpkg 状态：'
        printf '%s\n' "$audit" >&2
        return 1
    }
    if [[ $(id -u) != 0 ]]; then
        command -v sudo >/dev/null 2>&1 || { cne_note '二维码工具暂不可用：自动安装需要 root 或 sudo。'; return 1; }
        sudo -v || { cne_note '二维码工具暂不可用：未获得安装权限。'; return 1; }
    fi
    cne_note '正在准备可选的二维码工具…'
    cne_root apt-get -qq update || { cne_note '二维码工具暂不可用：软件源更新失败。'; return 1; }
    plan=$(cne_root apt-get -s --no-install-recommends --no-upgrade --no-remove install qrencode 2>&1) || {
        cne_note '二维码工具暂不可用：无法确认安装计划。'
        [[ -z $plan ]] || printf '%s\n' "$plan" >&2
        return 1
    }
    cne_install_plan_safe "$plan" || {
        cne_note '二维码工具暂不可用：安装会升级、删除或配置已有软件，已停止。'
        printf '%s\n' "$plan" >&2
        return 1
    }
    cne_root apt-get -y -qq --no-install-recommends --no-upgrade --no-remove install qrencode || {
        cne_note '二维码工具暂不可用：安装失败。'; return 1;
    }
    command -v qrencode >/dev/null 2>&1 || { cne_note '二维码工具暂不可用：安装后仍未找到 qrencode。'; return 1; }
}
#!/usr/bin/env bash
# HTTPS download settings and portable, checksum-verified component caches.
# Configuration is data only; nothing is sourced or evaluated as Shell code.
CNE_DOWNLOAD_GITHUB_PREFIX=''
CNE_DOWNLOAD_GO_BASE=https://go.dev/dl
CNE_DOWNLOAD_GOPROXY=https://proxy.golang.org

cne_download_https() {
    [[ ${#1} -le 512 && $1 =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+:-]*)?$ && $1 != *'/../'* && $1 != */.. ]]
}

cne_download_load() {
    local file=$CNE_STATE/downloads.tsv key value extra seen=' ' github='' go=https://go.dev/dl proxy=https://proxy.golang.org
    CNE_DOWNLOAD_GITHUB_PREFIX=''; CNE_DOWNLOAD_GO_BASE=https://go.dev/dl; CNE_DOWNLOAD_GOPROXY=https://proxy.golang.org
    [[ -e $file || -L $file ]] || return 0
    [[ -f $file && ! -L $file && -O $file ]] || { cne_error '下载设置文件不安全。'; return 1; }
    while IFS=$'\t' read -r key value extra; do
        [[ -z $extra && $seen != *" $key "* ]] || { cne_error '下载设置含重复或无效字段。'; return 1; }
        seen+="$key "
        case $key in
            github_prefix) [[ $value == - ]] || cne_download_https "$value" || return 1; [[ $value != - ]] || value=''; github=$value;;
            go_base) cne_download_https "$value" || return 1; go=${value%/};;
            goproxy) cne_download_https "$value" || return 1; proxy=${value%/};;
            *) cne_error '下载设置含未知字段。'; return 1;;
        esac
    done < "$file"
    [[ $seen == *' github_prefix '* && $seen == *' go_base '* && $seen == *' goproxy '* ]] || { cne_error '下载设置不完整。'; return 1; }
    CNE_DOWNLOAD_GITHUB_PREFIX=$github; CNE_DOWNLOAD_GO_BASE=$go; CNE_DOWNLOAD_GOPROXY=$proxy
}

cne_download_setup() {
    local file=$CNE_STATE/downloads.tsv github go proxy temporary default
    [[ ! -L $file && ( ! -e $file || -f $file && -O $file ) ]] || { cne_error '下载设置文件不安全。'; return 1; }
    cne_download_load || cne_note '原下载设置无效，下面按默认值重新填写。'
    printf '\n下载来源设置\n只接受 HTTPS 地址；所有组件仍核对固定 SHA-256，Go 仍核对 go.sum。输入 0 可取消。\n'
    default=${CNE_DOWNLOAD_GITHUB_PREFIX:--}
    while :; do
        cne_prompt 'GitHub/codeload 镜像前缀（- 使用官方来源）' "$default" || return 1
        github=$CNE_ANSWER
        [[ $github != 0 ]] || { printf '已取消。\n'; return 0; }
        [[ $github == - ]] || cne_download_https "$github" || { cne_note '请填写 HTTPS 镜像前缀或 -；不要包含用户名、密码或查询参数。'; continue; }
        break
    done
    while :; do cne_prompt 'Go 工具链下载目录' "$CNE_DOWNLOAD_GO_BASE" || return 1; go=$CNE_ANSWER; [[ $go != 0 ]] || { printf '已取消。\n'; return 0; }; cne_download_https "$go" && break; cne_note '请填写 HTTPS 下载目录，文件名会自动附加。'; done
    while :; do cne_prompt 'Go 模块 GOPROXY' "$CNE_DOWNLOAD_GOPROXY" || return 1; proxy=$CNE_ANSWER; [[ $proxy != 0 ]] || { printf '已取消。\n'; return 0; }; cne_download_https "$proxy" && break; cne_note '请填写单个 HTTPS Go 模块代理地址。'; done
    temporary=$(mktemp "$CNE_TEMP/download-settings.XXXXXXXX") || return 1
    printf 'github_prefix\t%s\ngo_base\t%s\ngoproxy\t%s\n' "$github" "${go%/}" "${proxy%/}" > "$temporary" && chmod 600 "$temporary" && mv "$temporary" "$file" || return 1
    cne_download_load || return 1
    printf '下载设置已保存。镜像前缀会放在原 GitHub/codeload URL 前；不改变组件校验值。\n'
}

cne_download_url() {
    local url=$1
    case $url in
        https://github.com/*|https://codeload.github.com/*)
            [[ -z $CNE_DOWNLOAD_GITHUB_PREFIX ]] || url=${CNE_DOWNLOAD_GITHUB_PREFIX%/}/$url;;
        https://go.dev/dl/*) url=${CNE_DOWNLOAD_GO_BASE%/}/${url#https://go.dev/dl/};;
    esac
    printf '%s\n' "$url"
}

cne_download_verified() {
    local official=$1 expected=$2 archive=$3 label=${4:-组件} actual url temporary
    [[ $expected =~ ^[0-9a-f]{64}$ && ! -L $archive && ( ! -e $archive || -f $archive && -O $archive ) ]] || { cne_error '组件校验参数或缓存文件无效。'; return 1; }
    cne_safe_directory "${archive%/*}" || return 1
    if [[ -f $archive ]]; then
        actual=$(sha256sum "$archive" | awk '{print $1}') || return 1
        [[ $actual != "$expected" ]] || return 0
    fi
    cne_download_load || return 1
    url=$(cne_download_url "$official") || return 1
    temporary=$(mktemp "$CNE_TEMP/component-download.XXXXXXXX") || return 1
    cne_note "下载${label}…"
    if ! curl -fL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$temporary"; then
        rm -f "$temporary"
        cne_error "${label}下载失败：${url}。请在菜单 18 设置下载来源，或在菜单 19 导入已校验缓存后重试。"
        return 1
    fi
    actual=$(sha256sum "$temporary" | awk '{print $1}') || { rm -f "$temporary"; return 1; }
    if [[ $actual != "$expected" ]]; then
        rm -f "$temporary"
        cne_error "${label}的 SHA-256 校验失败，未使用下载结果；请检查下载来源。"
        return 1
    fi
    chmod 600 "$temporary" && mv "$temporary" "$archive"
}

cne_download_component_specs() {
    cat <<'COMPONENTS'
go1.24.4.linux-amd64.tar.gz	77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717	https://go.dev/dl/go1.24.4.linux-amd64.tar.gz
go1.24.4.linux-arm64.tar.gz	d5501ee5aca0f258d5fe9bfaed401958445014495dc115f202d43d5210b45241	https://go.dev/dl/go1.24.4.linux-arm64.tar.gz
amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz	e26d13e5229f0976353008d78d1359bbdb000c9688b17a1d065ba1f61cbd872a	https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/730d6c39d0c4e348a3d080bebe496664215e5c99
amneziawg-tools-5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079.tar.gz	e79a3c7f2def315d052a3648b49058a268c4b63cdb5e082b696d2a4a0a2367f0	https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079
wstunnel_11.0.0_linux_amd64.tar.gz	9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e	https://github.com/erebe/wstunnel/releases/download/v11.0.0/wstunnel_11.0.0_linux_amd64.tar.gz
wstunnel_11.0.0_linux_arm64.tar.gz	b86abf73e340ed0c3ff9a77a5458aa27213784920ec65513132b36def45edc94	https://github.com/erebe/wstunnel/releases/download/v11.0.0/wstunnel_11.0.0_linux_arm64.tar.gz
COMPONENTS
}

cne_download_component_sha() {
    cne_download_component_specs | awk -F'\t' -v name="$1" '$1==name{print $2;found=1}END{exit !found}'
}

cne_download_size() { wc -c < "$1" | tr -d '[:space:]'; }

# Only artifacts for modules listed in the pinned upstream go.sum can travel.
# Existing .ziphash files are deliberately excluded: Go must recompute hashes
# of portable ZIP files before comparing them with the pinned source go.sum.
cne_download_module_allowlist() {
    local archive=$1 expected actual member
    member=amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99/go.sum
    expected=$(cne_download_component_sha "${archive##*/}") || return 1
    actual=$(sha256sum "$archive" | awk '{print $1}') || return 1
    [[ $actual == "$expected" ]] || { cne_error 'Go 模块名单的固定源码校验失败。'; return 1; }
    tar -xOzf "$archive" "$member" | awk '
      function escape(v, out,i,c){out="";for(i=1;i<=length(v);i++){c=substr(v,i,1);out=out (c~/[A-Z]/?"!" tolower(c):c)}return out}
      NF==3&&$3~/^h1:/ {v=$2;sub(/\/go.mod$/,"",v);p=escape($1) "/@v/" escape(v);if(p!~/^[A-Za-z0-9.!_+\/-]+\/@v\/[A-Za-z0-9.!_+-]+$/){bad=1;next};if(!seen[p]++){print p ".mod";print p ".info";print p ".zip"}}
      END{exit bad?1:0}' | LC_ALL=C sort
}

cne_download_module_name_ok() {
    [[ $1 =~ ^[A-Za-z0-9.!_+/-]+/@v/[A-Za-z0-9.!_+-]+\.(mod|info|zip)$ && $1 != /* && $1 != *'../'* && $1 != *'/..'* ]] && grep -Fqx -- "$1" "$2"
}

cne_download_file_url() {
    printf 'file://'
    printf '%s\n' "$1" | sed 's/%/%25/g;s/ /%20/g;s/#/%23/g;s/?/%3F/g'
}

cne_download_modules_seed() {
    local work=$1 target=$2 source=$3 cache=$CNE_STATE/cache/gomod-download file relative allowlist ready
    cne_download_load || return 1
    CNE_GO_PROXY=$CNE_DOWNLOAD_GOPROXY
    [[ ${CNE_AWG_REFRESH_MODULE_CACHE:-0} != 1 ]] || return 0
    [[ -e $cache || -L $cache ]] || return 0
    cne_safe_directory "$cache" || return 1
    [[ -z $(find "$cache" -type l -print -quit) ]] || { cne_error 'Go 依赖缓存不能含符号链接。'; return 1; }
    allowlist=$work/module-allowlist
    cne_download_module_allowlist "$source" > "$allowlist" || return 1
    mkdir -p "$work/gomodcache/cache/download" || return 1
    while IFS= read -r file; do
        relative=${file#"$cache"/}
        [[ $relative != .ready.* ]] || continue
        cne_download_module_name_ok "$relative" "$allowlist" || { cne_error 'Go 缓存包含来源名单之外的文件。'; return 1; }
        mkdir -p "$work/gomodcache/cache/download/${relative%/*}" && cp "$file" "$work/gomodcache/cache/download/$relative" || return 1
    done < <(find "$cache" -type f -print | LC_ALL=C sort)
    ready=$cache/.ready.$target
    if [[ -f $ready && ! -L $ready ]] && [[ $(cat "$ready") == "730d6c39d0c4e348a3d080bebe496664215e5c99 $target" ]]; then
        CNE_GO_PROXY=$(cne_download_file_url "$work/gomodcache/cache/download") || return 1
        cne_note '使用已完成编译的 Go 依赖缓存；本次编译不从模块代理下载。'
    fi
}

cne_download_modules_publish() {
    local work=$1 target=$2 source=$3 from=$1/gomodcache/cache/download stage cache=$CNE_STATE/cache/gomod-download file relative allowlist previous=''
    allowlist=$work/module-allowlist
    [[ -f $allowlist ]] || cne_download_module_allowlist "$source" > "$allowlist" || return 1
    [[ -d $from ]] || return 0
    [[ -z $(find "$from" -type l -print -quit) ]] || return 1
    stage=$(mktemp -d "$CNE_STATE/cache/.gomod-publish.XXXXXXXX") || return 1
    while IFS= read -r file; do
        relative=${file#"$from"/}
        case $relative in *.mod|*.info|*.zip) ;; *) continue;; esac
        cne_download_module_name_ok "$relative" "$allowlist" || continue
        mkdir -p "$stage/${relative%/*}" && cp "$file" "$stage/$relative" || { rm -rf "$stage"; return 1; }
    done < <(find "$from" -type f -print | LC_ALL=C sort)
    if [[ ${CNE_AWG_REFRESH_MODULE_CACHE:-0} != 1 && -d $cache && ! -L $cache ]]; then
        for relative in .ready.amd64 .ready.arm64; do
            if [[ -f $cache/$relative && ! -L $cache/$relative ]] && [[ $(cat "$cache/$relative") == "730d6c39d0c4e348a3d080bebe496664215e5c99 ${relative#.ready.}" ]]; then
                cp "$cache/$relative" "$stage/$relative" || { rm -rf "$stage"; return 1; }
            fi
        done
    fi
    printf '%s %s\n' 730d6c39d0c4e348a3d080bebe496664215e5c99 "$target" > "$stage/.ready.$target" || { rm -rf "$stage"; return 1; }
    chmod -R go-rwx "$stage" || { rm -rf "$stage"; return 1; }
    if [[ -e $cache || -L $cache ]]; then
        cne_safe_directory "$cache" || { rm -rf "$stage"; return 1; }
        previous=$(mktemp -d "$CNE_STATE/cache/.gomod-previous.XXXXXXXX") && rmdir "$previous" && mv "$cache" "$previous" || { rm -rf "$stage"; return 1; }
    fi
    if ! mv "$stage" "$cache"; then [[ -z $previous ]] || mv "$previous" "$cache"; rm -rf "$stage"; return 1; fi
    [[ -z $previous ]] || rm -rf "$previous"
}

cne_download_bundle_tools() {
    local tool
    for tool in tar gzip sha256sum find wc head awk sort uniq; do command -v "$tool" >/dev/null 2>&1 || { cne_error "缓存管理缺少 ${tool}；请先在可联网环境准备依赖。"; return 1; }; done
    cne_safe_directory "$CNE_STATE/cache"
}

cne_download_tar() {
    # Linux coreutils provides timeout. Tests on other hosts use small archives.
    if command -v timeout >/dev/null 2>&1; then timeout --signal=TERM --kill-after=5s 60s tar "$@"; else tar "$@"; fi
}

cne_download_bundle_name_ok() {
    local name=$1 component
    case $name in
        manifest.tsv) return 0;;
        archives/*) component=${name#archives/}; cne_download_component_sha "$component" >/dev/null;;
        modules/.ready.amd64|modules/.ready.arm64) return 0;;
        modules/*) [[ ${name#modules/} =~ ^[A-Za-z0-9.!_+/-]+/@v/[A-Za-z0-9.!_+-]+\.(mod|info|zip)$ && $name != *'../'* && $name != *'/..'* ]];;
        *) return 1;;
    esac
}

cne_download_bundle_extract() {
    local bundle=$1 member=$2 destination=$3 maximum=$4 size
    # Stream one allowlisted regular member; never extract an archive tree.
    cne_download_tar -xOzf "$bundle" "$member" | head -c "$((maximum+1))" > "$destination" || return 1
    size=$(cne_download_size "$destination") || return 1
    ((size<=maximum))
}

cne_download_cache_publish() {
    local stage=$1 replacement previous file cache=$CNE_STATE/cache
    cne_safe_directory "$cache" || return 1
    [[ -z $(find "$cache" -type l -print -quit) ]] || { cne_error '现有组件缓存含符号链接，未导入。'; return 1; }
    replacement=$(mktemp -d "$CNE_STATE/.cache-new.XXXXXXXX") || return 1
    # Preserve locally built engines, but never accept engines from a bundle.
    cp -a "$cache/." "$replacement/" || { rm -rf "$replacement"; return 1; }
    if [[ -d $stage/archives ]]; then
        while IFS= read -r file; do chmod 600 "$file" && mv "$file" "$replacement/${file##*/}" || { rm -rf "$replacement"; return 1; }; done < <(find "$stage/archives" -type f -print)
    fi
    if [[ -d $stage/modules ]]; then
        chmod -R go-rwx "$stage/modules" || { rm -rf "$replacement"; return 1; }
        if [[ -d $replacement/gomod-download ]]; then chmod -R u+w "$replacement/gomod-download" && rm -rf "$replacement/gomod-download" || { rm -rf "$replacement"; return 1; }; fi
        mv "$stage/modules" "$replacement/gomod-download" || { rm -rf "$replacement"; return 1; }
    fi
    previous=$(mktemp -d "$CNE_STATE/.cache-before-import.XXXXXXXX") && rmdir "$previous" || { rm -rf "$replacement"; return 1; }
    mv "$cache" "$previous" || { rm -rf "$replacement"; return 1; }
    if ! mv "$replacement" "$cache"; then
        if ! mv "$previous" "$cache"; then cne_error "缓存发布和恢复均未完成，原缓存保留在 ${previous}。"; fi
        rm -rf "$replacement"; return 1
    fi
    chmod -R u+w "$previous" && rm -rf "$previous" || cne_note "缓存已导入，但旧临时目录尚未清理：$previous"
}

cne_download_bundle_export() {
    local output=$1 stage name expected url source=$CNE_STATE/cache/amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz file relative size hash count=0 module_count=0 allowlist list temporary
    cne_download_bundle_tools || return 1
    [[ $output == /* && ! -e $output && ! -L $output && -d ${output%/*} && ! -L ${output%/*} ]] || { cne_error '请填写尚不存在的绝对输出文件路径。'; return 1; }
    stage=$(mktemp -d "$CNE_TEMP/cache-export.XXXXXXXX") || return 1
    mkdir "$stage/archives" "$stage/modules" || return 1
    while IFS=$'\t' read -r name expected url; do
        file=$CNE_STATE/cache/$name
        [[ -e $file || -L $file ]] || continue
        [[ -f $file && ! -L $file && -O $file ]] && [[ $(sha256sum "$file" | awk '{print $1}') == "$expected" ]] || { cne_error "缓存组件未通过校验：$name"; return 1; }
        cp "$file" "$stage/archives/$name" || return 1
        count=$((count+1))
    done < <(cne_download_component_specs)
    ((count)) || { cne_error '还没有已校验组件缓存，请先选择“准备完整缓存”。'; return 1; }
    if [[ -d $CNE_STATE/cache/gomod-download ]]; then
        cne_safe_directory "$CNE_STATE/cache/gomod-download" || return 1
        [[ -z $(find "$CNE_STATE/cache/gomod-download" -type l -print -quit) ]] || { cne_error 'Go 缓存不能含符号链接。'; return 1; }
        allowlist=$stage/module-allowlist
        cne_download_module_allowlist "$source" > "$allowlist" || return 1
        while IFS= read -r file; do
            relative=${file#"$CNE_STATE/cache/gomod-download"/}
            case $relative in
                .ready.amd64|.ready.arm64)
                    [[ $(cat "$file") == "730d6c39d0c4e348a3d080bebe496664215e5c99 ${relative#.ready.}" ]] || { cne_error 'Go 缓存完成记录无效。'; return 1; };;
                *) cne_download_module_name_ok "$relative" "$allowlist" || { cne_error 'Go 缓存含非固定源码所需的文件。'; return 1; }; module_count=$((module_count+1));;
            esac
            if [[ $relative == */* ]]; then mkdir -p "$stage/modules/${relative%/*}" || return 1; fi
            cp "$file" "$stage/modules/$relative" || return 1
        done < <(find "$CNE_STATE/cache/gomod-download" -type f -print | LC_ALL=C sort)
    fi
    : > "$stage/manifest.tsv"
    list=$stage/files
    printf 'manifest.tsv\n' > "$list"
    while IFS= read -r file; do
        relative=${file#"$stage"/}
        size=$(cne_download_size "$file") || return 1
        [[ $size =~ ^[0-9]{1,10}$ ]] && ((size<=268435456)) || { cne_error '缓存文件超过允许大小。'; return 1; }
        hash=$(sha256sum "$file" | awk '{print $1}') || return 1
        printf '%s\t%s\t%s\n' "$relative" "$hash" "$size" >> "$stage/manifest.tsv" && printf '%s\n' "$relative" >> "$list" || return 1
    done < <(find "$stage/archives" "$stage/modules" -type f -print | LC_ALL=C sort)
    temporary=$(mktemp "${output%/*}/.cn-egress-cache.XXXXXXXX") || return 1
    if ! (cd "$stage" && tar -czf "$temporary" -T files); then rm -f "$temporary"; return 1; fi
    [[ ! -e $output && ! -L $output ]] && chmod 600 "$temporary" && mv "$temporary" "$output" || { rm -f "$temporary"; return 1; }
    printf '缓存已导出：%s\n包含 %s/6 个固定组件、%s 个 Go 依赖文件；不包含私钥、节点设置或编译后的程序。\n' "$output" "$count" "$module_count"
    if ((count<6 || module_count==0)) || [[ ! -f $stage/modules/.ready.amd64 || ! -f $stage/modules/.ready.arm64 ]]; then
        printf '这是部分缓存。导入后缺少的组件或 Go 依赖仍需联网；可先选择“准备完整缓存”再导出。\n'
    else printf '包含两个目标架构的已完成编译依赖缓存；导入后仍会用固定源码重新编译并核对 go.sum。系统软件包需另行准备。\n'; fi
}

cne_download_bundle_import() {
    local bundle=$1 stage list manifest name hash size extra actual expected total=0 count=0 source allowlist file relative cache previous=''
    cne_download_bundle_tools || return 1
    [[ $bundle == /* && -f $bundle && ! -L $bundle ]] || { cne_error '请填写缓存包的绝对文件路径，不能使用符号链接。'; return 1; }
    size=$(cne_download_size "$bundle") || return 1
    [[ $size =~ ^[0-9]{1,10}$ ]] && ((size<=1073741824)) || { cne_error '缓存包超过允许大小。'; return 1; }
    stage=$(mktemp -d "$CNE_TEMP/cache-import.XXXXXXXX") || return 1
    list=$stage/list
    cne_download_tar -P -tzf "$bundle" > "$list" || { cne_error '无法读取缓存包。'; return 1; }
    [[ -z $(LC_ALL=C sort "$list" | uniq -d) ]] && [[ $(wc -l < "$list") -le 4096 ]] || { cne_error '缓存包含重复文件或文件数过多。'; return 1; }
    while IFS= read -r name; do cne_download_bundle_name_ok "$name" || { cne_error '缓存包含不允许的文件名。'; return 1; }; done < "$list"
    cne_download_tar -P -tvzf "$bundle" | awk 'substr($0,1,1)!="-"{bad=1}END{exit bad?1:0}' || { cne_error '缓存包仅允许普通文件，不能含目录、链接或设备文件。'; return 1; }
    grep -Fqx manifest.tsv "$list" || { cne_error '缓存包缺少清单。'; return 1; }
    manifest=$stage/manifest.tsv
    cne_download_bundle_extract "$bundle" manifest.tsv "$manifest" 262144 || { cne_error '缓存清单无效或过大。'; return 1; }
    : > "$stage/expected-list"
    printf 'manifest.tsv\n' >> "$stage/expected-list"
    while IFS=$'\t' read -r name hash size extra; do
        [[ -z $extra && $name != manifest.tsv && $hash =~ ^[0-9a-f]{64}$ && $size =~ ^[0-9]{1,10}$ ]] && ((10#$size<=268435456)) && cne_download_bundle_name_ok "$name" || { cne_error '缓存清单格式无效。'; return 1; }
        count=$((count+1)); total=$((total+10#$size))
        ((count<=4095 && total<=1073741824)) || { cne_error '缓存展开大小超过限制。'; return 1; }
        printf '%s\n' "$name" >> "$stage/expected-list"
        mkdir -p "$stage/${name%/*}" || return 1
        cne_download_bundle_extract "$bundle" "$name" "$stage/$name" "$((10#$size))" || { cne_error '缓存文件大小不符。'; return 1; }
        actual=$(sha256sum "$stage/$name" | awk '{print $1}') || return 1
        [[ $actual == "$hash" && $(cne_download_size "$stage/$name") == "$size" ]] || { cne_error '缓存文件校验失败。'; return 1; }
        case $name in
            archives/*) expected=$(cne_download_component_sha "${name#archives/}") || return 1; [[ $actual == "$expected" ]] || { cne_error '缓存组件不符合脚本固定 SHA-256。'; return 1; };;
            modules/.ready.*) [[ $(cat "$stage/$name") == "730d6c39d0c4e348a3d080bebe496664215e5c99 ${name#modules/.ready.}" ]] || { cne_error 'Go 缓存完成记录无效。'; return 1; };;
        esac
    done < "$manifest"
    ((count)) && [[ -z $(LC_ALL=C sort "$stage/expected-list" | uniq -d) ]] || { cne_error '缓存清单为空或含重复项目。'; return 1; }
    LC_ALL=C sort "$list" > "$stage/sorted-list"; LC_ALL=C sort "$stage/expected-list" > "$stage/sorted-expected"
    cmp -s "$stage/sorted-list" "$stage/sorted-expected" || { cne_error '缓存文件与清单不一致。'; return 1; }
    if [[ -d $stage/modules ]]; then
        source=$stage/archives/amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz
        [[ -f $source ]] || { cne_error 'Go 依赖缓存必须同时包含固定源码包。'; return 1; }
        allowlist=$stage/module-allowlist
        cne_download_module_allowlist "$source" > "$allowlist" || return 1
        while IFS= read -r file; do
            relative=${file#"$stage/modules"/}
            [[ $relative == .ready.amd64 || $relative == .ready.arm64 ]] || cne_download_module_name_ok "$relative" "$allowlist" || { cne_error '缓存模块不属于固定源码的 go.sum。'; return 1; }
        done < <(find "$stage/modules" -type f -print)
    fi
    # Every member and existing destination passes validation before replacing
    # the cache directory. A failed publication restores the whole old cache.
    if [[ -d $stage/archives ]]; then
        while IFS= read -r file; do
            relative=$CNE_STATE/cache/${file##*/}
            [[ ! -L $relative && ( ! -e $relative || -f $relative && -O $relative ) ]] || { cne_error '现有组件缓存路径不安全，未导入。'; return 1; }
        done < <(find "$stage/archives" -type f -print)
    fi
    cne_download_cache_publish "$stage" || return 1
    printf '缓存已导入。固定组件已核对脚本内的 SHA-256；Go 依赖会在重新编译时按固定源码 go.sum 再校验。\n未导入编译后的程序、私钥或节点配置；缓存不足时仍需联网。\n'
}

cne_download_prepare_cache() (
    local name expected url target
    cne_bootstrap install && cne_download_bundle_tools && cne_download_load || return 1
    while IFS=$'\t' read -r name expected url; do cne_download_verified "$url" "$expected" "$CNE_STATE/cache/$name" "$name" || return 1; done < <(cne_download_component_specs)
    CNE_AWG_FORCE_MODULE_CACHE=1
    CNE_AWG_REFRESH_MODULE_CACHE=1
    for target in amd64 arm64; do cne_fetch_awg "$target" || return 1; CNE_AWG_REFRESH_MODULE_CACHE=0; done
    printf '固定组件和两个目标架构的 Go 编译依赖缓存已准备，可导出。APT 系统依赖需在目标管理机和节点另行准备。\n'
)

cne_download_bundle_menu() {
    local choice file
    printf '\n组件缓存\n  1. 导出当前缓存\n  2. 导入缓存包\n  3. 准备完整缓存（需联网下载并编译）\n  0. 取消\n'
    cne_prompt '请选择' 0 || return 1; choice=$CNE_ANSWER
    case $choice in
        0) return 0;;
        1) cne_prompt '输出绝对路径' "$CNE_STATE/component-cache-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" || return 1; file=$CNE_ANSWER; cne_download_bundle_export "$file";;
        2) cne_prompt '缓存包绝对路径' || return 1; file=$CNE_ANSWER; cne_download_bundle_import "$file";;
        3) cne_download_prepare_cache;;
        *) cne_error '请输入 0、1、2 或 3。'; return 1;;
    esac
}
#!/usr/bin/env bash
# Pinned, userspace-only AmneziaWG 2.0 build. Sourcing has no side effects.
# The upstream Go repository publishes source tags, not Linux release binaries.
CNE_AWG_GO_COMMIT=730d6c39d0c4e348a3d080bebe496664215e5c99
CNE_AWG_GO_SHA256=e26d13e5229f0976353008d78d1359bbdb000c9688b17a1d065ba1f61cbd872a
CNE_AWG_TOOLS_COMMIT=5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079
CNE_AWG_TOOLS_SHA256=e79a3c7f2def315d052a3648b49058a268c4b63cdb5e082b696d2a4a0a2367f0

cne_awg_arch() {
    case $1 in x86_64|amd64) printf 'amd64\n';; aarch64|arm64) printf 'arm64\n';; *) return 1;; esac
}

# Go extracts its module cache with read-only directories. A non-root manager
# must regain owner write permission before deleting its private build tree.
cne_awg_cleanup() {
    local work=$1
    [[ $work == "$CNE_TEMP"/awg-build.* && -d $work && ! -L $work && -O $work ]] || { cne_error '拒绝清理管理会话之外的编译目录。'; return 1; }
    chmod -R u+w "$work" && rm -rf -- "$work"
}

# URL SHA256 CACHE_FILE; publish only a completely verified download.
cne_awg_download() {
    cne_download_verified "$1" "$2" "$3" 'AmneziaWG 组件'
}

# TARGET_ARCH -> CNE_AWG_ENGINE and CNE_AWG_TOOLS_SOURCE. Build on the manager;
# no host Go installation, C compiler, kernel module or system upgrade is used.
cne_fetch_awg() {
    local target manager checksum go_archive engine_archive tools_archive work engine digest existing
    target=$(cne_awg_arch "$1") || { cne_error "不支持的 AmneziaWG 架构：$1"; return 1; }
    [[ $(uname -s) == Linux ]] || { cne_error 'AmneziaWG 编译需要 Linux 管理机。'; return 1; }
    manager=$(cne_awg_arch "$(uname -m)") || { cne_error '管理机须使用 amd64 或 arm64 架构。'; return 1; }
    case $manager in
        amd64) checksum=77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717;;
        arm64) checksum=d5501ee5aca0f258d5fe9bfaed401958445014495dc115f202d43d5210b45241;;
    esac
    go_archive=$CNE_STATE/cache/go1.24.4.linux-$manager.tar.gz
    engine_archive=$CNE_STATE/cache/amneziawg-go-$CNE_AWG_GO_COMMIT.tar.gz
    tools_archive=$CNE_STATE/cache/amneziawg-tools-$CNE_AWG_TOOLS_COMMIT.tar.gz
    cne_note '准备 AmneziaWG 2.0 用户态组件（首次会下载 Go 并编译）…'
    cne_awg_download "https://go.dev/dl/go1.24.4.linux-$manager.tar.gz" "$checksum" "$go_archive" || return 1
    cne_awg_download "https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/$CNE_AWG_GO_COMMIT" "$CNE_AWG_GO_SHA256" "$engine_archive" || return 1
    cne_awg_download "https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/$CNE_AWG_TOOLS_COMMIT" "$CNE_AWG_TOOLS_SHA256" "$tools_archive" || return 1
    engine=$CNE_STATE/cache/amneziawg-go-0.2.16-linux-$target
    digest=$engine.sha256
    [[ ! -L $engine && ! -L $digest ]] || return 1
    if [[ ${CNE_AWG_FORCE_MODULE_CACHE:-0} != 1 && -x $engine && -f $digest ]]; then
        IFS= read -r existing < "$digest" || return 1
        if [[ $existing =~ ^[0-9a-f]{64}$ && $(sha256sum "$engine" | awk '{print $1}') == "$existing" ]]; then
            CNE_AWG_ENGINE=$engine; CNE_AWG_TOOLS_SOURCE=$tools_archive
            return 0
        fi
    fi
    work=$(mktemp -d "$CNE_TEMP/awg-build.XXXXXXXX") || return 1
    mkdir "$work/source" "$work/gocache" "$work/gomodcache" || return 1
    tar -xzf "$go_archive" -C "$work" || return 1
    tar -xzf "$engine_archive" --strip-components=1 -C "$work/source" || return 1
    cne_download_modules_seed "$work" "$target" "$engine_archive" || { cne_awg_cleanup "$work" || :; return 1; }
    # GOTOOLCHAIN=local prevents a source directive from fetching another Go.
    # Go verifies dependencies against the source's go.sum and checksum database.
    (cd "$work/source" && timeout --signal=TERM --kill-after=10s 600s env CGO_ENABLED=0 GOOS=linux GOARCH="$target" \
        GOENV=off GOTOOLCHAIN=local GOWORK=off GOFLAGS= GOAMD64=v1 GOARM64=v8.0 \
        GOPRIVATE= GONOSUMDB= GONOPROXY= GOINSECURE= GOCACHE="$work/gocache" \
        GOMODCACHE="$work/gomodcache" GOPROXY="$CNE_GO_PROXY" \
        GOSUMDB=sum.golang.org "$work/go/bin/go" build -mod=readonly -trimpath \
        -buildvcs=false -o "$work/amneziawg-go" .) || { cne_awg_cleanup "$work" || :; cne_error 'AmneziaWG 编译或 Go 依赖下载失败（最长等待 10 分钟）。配置尚未替换；请在菜单 18 检查 Go 模块代理，或在菜单 19 准备/导入完整缓存后重试。'; return 1; }
    cne_download_modules_publish "$work" "$target" "$engine_archive" || { cne_awg_cleanup "$work" || :; return 1; }
    chmod 755 "$work/amneziawg-go" || return 1
    existing=$(sha256sum "$work/amneziawg-go" | awk '{print $1}') || return 1
    printf '%s\n' "$existing" > "$work/engine.sha256" || return 1
    mv "$work/amneziawg-go" "$engine" && mv "$work/engine.sha256" "$digest" || return 1
    CNE_AWG_ENGINE=$engine; CNE_AWG_TOOLS_SOURCE=$tools_archive
    cne_awg_cleanup "$work"
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
    local role root key private public psk name number pair
    cne_render_host "$hk" && cne_render_host "$sh" || { cne_render_error '节点地址无效'; exit 1; }
    cne_render_port "$user_port" && cne_render_port "$wss_port" || { cne_render_error '监听端口无效'; exit 1; }
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
        cp "$out/pki/ca.crt" "$root/etc/cn-egress-wss/ca.crt"
        cp "$out/pki/$role.key" "$root/etc/cn-egress-wss/node.key"
        cp "$out/pki/$role.crt" "$root/etc/cn-egress-wss/node.crt"
        chmod 640 "$root/etc/cn-egress-wss/"{role,sh-host,port,ca.crt,node.key,node.crt}
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
CNE_VERSION=2.2.1
CNE_ROLES=(hk sh exit)
CNE_LABELS=('香港入口' '大陆中转' '国内出口')
CNE_HOSTS=('' '' '')
CNE_USERS=(root root root)
CNE_PORTS=(22 22 22)
CNE_IDENTITIES=(- - -)
CNE_CONNECTIONS=(ssh ssh ssh)
CNE_PASSWORDS=('' '' '')
CNE_SUDOS=('' '' '')
CNE_AUTH_READY=(0 0 0)
CNE_CONFIG_INVALID=0
CNE_USER_PORT=51820
CNE_WSS_PORT=443
CNE_TRANSACTION_ACTIVE=0
CNE_TRANSACTION_DIRECTORY=''
CNE_TRANSACTION_ID=''
CNE_TRANSACTION_ATTEMPTED=()
CNE_TRANSACTION_BACKUPS=('' '' '')

cne_error() { printf '\n错误：%s\n' "$*" >&2; return 1; }
cne_note() { printf '%s\n' "$*" >&2; }
cne_line() { printf '%s\n' '----------------------------------------'; }
cne_field() { printf '%s\n' "$1" | awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/, "");print;exit}'; }
cne_nodes_canonical() {
    awk -F'\t' 'NF==5 {print $0 "\tssh";next} NF==6 {print;next} {bad=1} END{exit (bad||NR!=3)?1:0}' "$1"
}
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
cne_setup_prompt() {
    cne_prompt "$@" || return 1
    [[ $CNE_ANSWER != 0 ]] || { cne_note '已取消节点设置，配置未保存。'; return 1; }
}
cne_mutation_guard() {
    [[ ! -e $CNE_STATE/active-transaction && ! -L $CNE_STATE/active-transaction ]] || {
        cne_error '存在尚未完成恢复的操作。请先选择“15. 重试恢复”，恢复前可以查看状态、日志和诊断。'
        return 1
    }
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
    local child
    umask 077
    CNE_STATE=${CNE_HOME:-${HOME:?}/.local/share/cn-egress-shell}
    cne_safe_directory "$CNE_STATE" || return 1
    [[ ! -L $CNE_STATE/lock ]] || return 1
    exec 8>"$CNE_STATE/lock"
    if ! flock -n 8; then
        if [[ ${CNE_NONINTERACTIVE:-0} == 1 ]]; then cne_note '管理菜单或其他维护正在运行，本次自动检查延后 15 分钟。'; return 75; fi
        cne_error '已有管理菜单运行，请先退出那个窗口。'; return 1
    fi
    for child in cache clients history backups; do cne_safe_directory "$CNE_STATE/$child" || return 1; done
    CNE_TEMP=$(mktemp -d "$CNE_STATE/.session.XXXXXX") || return 1
    [[ ! -L $CNE_STATE/known_hosts ]] || return 1
    touch "$CNE_STATE/known_hosts" && chmod 600 "$CNE_STATE/known_hosts" || return 1
    trap 'cne_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if ! cne_load_config; then
        CNE_CONFIG_INVALID=1
        CNE_HOSTS=('' '' ''); CNE_USERS=(root root root); CNE_PORTS=(22 22 22)
        CNE_IDENTITIES=(- - -); CNE_CONNECTIONS=(ssh ssh ssh)
        CNE_USER_PORT=51820; CNE_WSS_PORT=443
        CNE_AUTH_READY=(0 0 0); CNE_PASSWORDS=('' '' ''); CNE_SUDOS=('' '' '')
        cne_note '原节点设置未加载；可选择“2. 修改节点”修复，或离线查看已保存的设备文件。'
    fi
    return 0
}
cne_cleanup() {
    if [[ ${CNE_TRANSACTION_ACTIVE:-0} == 1 ]]; then cne_transaction_abort || :; fi
    CNE_PASSWORDS=(); CNE_SUDOS=(); unset CNE_ANSWER
    if [[ -n ${CNE_TEMP:-} && $CNE_TEMP == "$CNE_STATE"/.session.* && -d $CNE_TEMP && ! -L $CNE_TEMP && -O $CNE_TEMP ]]; then
        # Failed Go builds can leave read-only modules in this private session.
        # Recursive chmod does not follow symlinks encountered in the tree.
        if ! chmod -R u+w "$CNE_TEMP" || ! rm -rf -- "$CNE_TEMP"; then
            cne_note "临时目录未能清理：${CNE_TEMP}。请保密其中的临时文件。"
            return 1
        fi
    fi
}
cne_load_config() {
    local line role host user port identity connection extra idx=0 local_count=0 port_rows=0 user_port=$CNE_USER_PORT wss_port=$CNE_WSS_PORT
    local hosts=() users=() ports=() identities=() connections=()
    [[ -e $CNE_STATE/nodes.tsv || -L $CNE_STATE/nodes.tsv ]] || return 0
    [[ -f $CNE_STATE/nodes.tsv && ! -L $CNE_STATE/nodes.tsv && -O $CNE_STATE/nodes.tsv ]] || { cne_error '节点配置文件不安全，请检查 nodes.tsv 的归属或链接。'; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        (( idx < 3 )) || { cne_error '节点配置仅允许三个角色。'; return 1; }
        IFS=$'\t' read -r role host user port identity connection extra <<< "$line"
        connection=${connection:-ssh}
        [[ -z $extra && ( $connection == ssh || $connection == local ) ]] || { cne_error '节点连接方式无效。'; return 1; }
        [[ $role == "${CNE_ROLES[$idx]}" ]] && cne_ipv4 "$host" && cne_port "$port" && [[ $user =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { cne_error '节点配置格式无效，请选择“2. 修改节点”重新填写。'; return 1; }
        [[ $identity == - || $identity == /* ]] || { cne_error 'SSH 私钥路径必须是绝对路径或 -。'; return 1; }
        if [[ $connection == local ]]; then
            local_count=$((local_count+1))
            [[ $identity == - ]] && ((local_count<=1)) || { cne_error '本机只能对应一个节点角色。'; return 1; }
        fi
        hosts[$idx]=$host; users[$idx]=$user; ports[$idx]=$port; identities[$idx]=$identity; connections[$idx]=$connection
        idx=$((idx+1))
    done < "$CNE_STATE/nodes.tsv"
    [[ $idx == 3 && ${hosts[0]} != "${hosts[1]}" && ${hosts[0]} != "${hosts[2]}" && ${hosts[1]} != "${hosts[2]}" ]] || { cne_error '请配置三个不同的节点。'; return 1; }
    if [[ -e $CNE_STATE/ports || -L $CNE_STATE/ports ]]; then
        [[ -f $CNE_STATE/ports && ! -L $CNE_STATE/ports && -O $CNE_STATE/ports ]] || { cne_error '端口配置文件不安全。'; return 1; }
        while IFS= read -r line || [[ -n $line ]]; do
            (( port_rows == 0 )) || { cne_error '端口配置仅允许一行。'; return 1; }
            read -r user_port wss_port extra <<< "$line"
            cne_port "$user_port" && cne_port "$wss_port" && [[ $user_port != 51831 && -z $extra ]] || { cne_error '端口配置格式无效，请重新填写节点。'; return 1; }
            port_rows=$((port_rows+1))
        done < "$CNE_STATE/ports"
        (( port_rows == 1 )) || { cne_error '端口配置格式无效。'; return 1; }
    fi
    # Publish only after every node and the ports have passed validation.
    CNE_HOSTS=("${hosts[@]}"); CNE_USERS=("${users[@]}"); CNE_PORTS=("${ports[@]}")
    CNE_IDENTITIES=("${identities[@]}"); CNE_CONNECTIONS=("${connections[@]}")
    CNE_USER_PORT=$user_port; CNE_WSS_PORT=$wss_port; CNE_CONFIG_INVALID=0
}
cne_configured() {
    local idx local_count=0
    [[ ${CNE_CONFIG_INVALID:-0} == 0 ]] || return 1
    for idx in 0 1 2; do
        cne_ipv4 "${CNE_HOSTS[$idx]}" && cne_port "${CNE_PORTS[$idx]}" && [[ ${CNE_USERS[$idx]} =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && ( ${CNE_IDENTITIES[$idx]} == - || ${CNE_IDENTITIES[$idx]} == /* ) ]] || return 1
        case ${CNE_CONNECTIONS[$idx]:-ssh} in
            ssh) ;;
            local) local_count=$((local_count+1)); ((local_count<=1)) && [[ ${CNE_IDENTITIES[$idx]} == - ]] || return 1;;
            *) return 1;;
        esac
    done
    [[ ${CNE_HOSTS[0]} != "${CNE_HOSTS[1]}" && ${CNE_HOSTS[0]} != "${CNE_HOSTS[2]}" && ${CNE_HOSTS[1]} != "${CNE_HOSTS[2]}" ]]
}
cne_unconfigured_status() {
    local idx
    printf '\n节点状态\n'; cne_line
    for idx in 0 1 2; do printf '  %s：尚未配置\n' "${CNE_LABELS[$idx]}"; done
    printf '\n当前管理目录：%s\n' "$CNE_STATE"
    if [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then printf '原节点设置无效，未加载。请选择“2. 修改节点”修复；原文件会先保存。\n'
    else printf '请选择“1. 一键安装”或“2. 修改节点”填写节点。尚未配置表示当前管理目录没有节点设置。\n'; fi
    printf '若此前使用其他账号运行，请使用原账号，或用 CNE_HOME 指定原管理目录。\n'
}

cne_local_ipv4() {
    local address=''
    if command -v ip >/dev/null 2>&1; then
        address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="src"){print $(i+1);exit}}') || address=''
    fi
    if cne_ipv4 "$address" && [[ $address != 127.* ]]; then printf '%s\n' "$address"; fi
    return 0
}
cne_public_ipv4_candidate() {
    local a b c d
    cne_ipv4 "$1" || return 1
    IFS=. read -r a b c d <<< "$1"
    # A private/NAT/interface address cannot serve as a public endpoint default.
    ((a!=0 && a!=10 && a!=127 && a<224)) || return 1
    (( !(a==100 && b>=64 && b<=127) && !(a==169 && b==254) && !(a==172 && b>=16 && b<=31) && !(a==192 && b==168) && !(a==198 && (b==18 || b==19)) )) || return 1
    [[ $1 != 192.0.0.* && $1 != 192.0.2.* && $1 != 198.51.100.* && $1 != 203.0.113.* ]]
}
cne_display_host() {
    printf '%s' "${CNE_HOSTS[$1]}"
    [[ ${CNE_CONNECTIONS[$1]:-ssh} != local ]] || printf '（本机）'
}
cne_setup() {
    local idx host user port identity connection default candidate local_count=0 user_port wss_port had_ports=0 changed=0 previous=''
    local hosts=() users=() ports=() identities=() connections=()
    cne_mutation_guard || return 1
    for identity in nodes.tsv ports; do
        [[ ! -L $CNE_STATE/$identity && ( ! -e $CNE_STATE/$identity || -f $CNE_STATE/$identity && -O $CNE_STATE/$identity ) ]] || { cne_error "原设置文件不安全：${identity}。请检查文件归属或链接。"; return 1; }
    done
    printf '\n配置安装节点\n大陆中转只填写一台，上海或北京任选其一。输入 0 取消，留空使用提示中的默认值。\n'
    for idx in 0 1 2; do
        printf '\n%s\n' "${CNE_LABELS[$idx]}"
        default=1; [[ ${CNE_CONNECTIONS[$idx]:-ssh} != local ]] || default=2
        while :; do
            cne_setup_prompt '  连接方式（1 SSH / 2 本机）' "$default" || return 1
            case $CNE_ANSWER in
                1) connection=ssh; break;;
                2) if ((local_count==0)); then connection=local; local_count=1; break; fi; cne_note '  本机已经用于另一个角色，请为此节点选择 SSH。';;
                *) cne_note '  请输入 1 或 2。';;
            esac
        done
        default=${CNE_HOSTS[$idx]}
        if [[ $connection == local ]]; then
            cne_note '  本机直接执行管理命令，不需要填写 SSH 登录信息。'
            if [[ -z $default ]]; then
                candidate=$(cne_local_ipv4)
                if [[ $idx == 2 ]] || cne_public_ipv4_candidate "$candidate"; then default=$candidate
                elif [[ -n $candidate ]]; then cne_note "  检测到本机网卡地址：${candidate}。公网入口请填写云服务器公网地址或路由器映射地址。"; fi
            fi
        fi
        case $idx in
            0) cne_note '  此地址用于手机和电脑连接香港入口；选择本机管理仍需对外连接地址。';;
            1) cne_note '  此地址用于其他节点连接大陆中转，并写入传输证书。';;
            2) [[ $connection != local ]] || cne_note '  此地址记录国内出口的节点身份，可使用本机局域网地址。';;
        esac
        while :; do cne_setup_prompt '  IPv4 地址' "$default" || return 1; host=$CNE_ANSWER; cne_ipv4 "$host" && break; cne_note '  地址格式不正确。'; done
        if [[ $connection == local ]]; then
            user=$(id -un) || return 1; port=22; identity=-
            hosts[$idx]=$host; users[$idx]=$user; ports[$idx]=$port; identities[$idx]=$identity; connections[$idx]=local
            cne_note '  使用本机管理，不需要 SSH 登录。'
            continue
        fi
        while :; do cne_setup_prompt '  SSH 用户' "${CNE_USERS[$idx]}" || return 1; user=$CNE_ANSWER; [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] && break; cne_note '  用户名格式不正确。'; done
        while :; do cne_setup_prompt '  SSH 端口' "${CNE_PORTS[$idx]}" || return 1; port=$CNE_ANSWER; cne_port "$port" && break; cne_note '  端口范围为 1–65535。'; done
        while :; do
            cne_setup_prompt '  SSH 私钥绝对路径（- 使用密码）' "${CNE_IDENTITIES[$idx]}" || return 1; identity=$CNE_ANSWER
            [[ $identity != *$'\t'* && $identity != *$'\n'* && ( $identity == - || $identity == /* && -f $identity ) ]] && break
            cne_note '  文件不存在，请填写绝对路径或 -。'
        done
        hosts[$idx]=$host; users[$idx]=$user; ports[$idx]=$port; identities[$idx]=$identity; connections[$idx]=ssh
    done
    [[ ${hosts[0]} != "${hosts[1]}" && ${hosts[0]} != "${hosts[2]}" && ${hosts[1]} != "${hosts[2]}" ]] || { cne_error '三个角色需要不同机器，大陆中转只填一台。'; return 1; }
    while :; do
        cne_setup_prompt '客户端 UDP 端口' "$CNE_USER_PORT" || return 1
        if [[ $CNE_ANSWER == 51831 ]]; then cne_note '51831 用于内部隧道，请选择其他客户端端口。'
        elif cne_port "$CNE_ANSWER"; then break
        else cne_note '端口范围为 1–65535。'; fi
    done
    user_port=$CNE_ANSWER
    while :; do cne_setup_prompt '中转 TLS 端口' "$CNE_WSS_PORT" || return 1; cne_port "$CNE_ANSWER" && break; done
    wss_port=$CNE_ANSWER
    if [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then
        printf '\n原节点设置无法加载。保存新设置前会先保留原文件。\n'
        for idx in 0 1 2; do printf '  %s：%s（%s）\n' "${CNE_LABELS[$idx]}" "${hosts[$idx]}" "${connections[$idx]}"; done
        cne_prompt '是否保存这些新设置（y/N）' N || return 1
        [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消，原文件保留。\n'; return 0; }
        previous=$(mktemp -d "$CNE_STATE/history/node-settings.XXXXXXXX") || return 1
        for identity in nodes.tsv ports; do [[ ! -f $CNE_STATE/$identity ]] || cp -p "$CNE_STATE/$identity" "$previous/$identity" || return 1; done
        printf '原设置已保存：%s\n' "$previous"
    fi
    if [[ -f $CNE_STATE/nodes.tsv && -n ${CNE_HOSTS[0]} ]]; then
        for idx in 0 1 2; do [[ ${hosts[$idx]} == "${CNE_HOSTS[$idx]}" ]] || changed=1; done
        [[ $user_port == "$CNE_USER_PORT" && $wss_port == "$CNE_WSS_PORT" ]] || changed=1
        if ((changed)); then
            printf '\n将修改以下连接地址或服务端口：\n'
            for idx in 0 1 2; do
                [[ ${hosts[$idx]} == "${CNE_HOSTS[$idx]}" ]] || printf '  %s：%s → %s\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}" "${hosts[$idx]}"
            done
            [[ $user_port == "$CNE_USER_PORT" ]] || printf '  客户端 UDP 端口：%s → %s\n' "$CNE_USER_PORT" "$user_port"
            [[ $wss_port == "$CNE_WSS_PORT" ]] || printf '  中转 TLS 端口：%s → %s\n' "$CNE_WSS_PORT" "$wss_port"
            printf '保存设置不会迁移或停止旧服务器服务。此后菜单操作将使用新地址。\n请通过“1. 一键安装”部署新的整套配置；旧服务器需使用旧设置单独停止或卸载。\n'
            cne_prompt '是否保存这些变更（y/N）' N || return 1
            [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消，原节点设置保留。\n'; return 0; }
            previous=$(mktemp -d "$CNE_STATE/history/node-settings.XXXXXXXX") || return 1
            cp "$CNE_STATE/nodes.tsv" "$previous/nodes.tsv" || return 1
            [[ ! -f $CNE_STATE/ports ]] || cp "$CNE_STATE/ports" "$previous/ports" || return 1
            printf '旧节点设置已保存：%s\n' "$previous"
        fi
    fi
    for idx in 0 1 2; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${CNE_ROLES[$idx]}" "${hosts[$idx]}" "${users[$idx]}" "${ports[$idx]}" "${identities[$idx]}" "${connections[$idx]}" || return 1; done > "$CNE_TEMP/nodes.tsv" || return 1
    printf '%s %s\n' "$user_port" "$wss_port" > "$CNE_TEMP/ports" || return 1
    [[ ! -f $CNE_STATE/ports ]] || { cp "$CNE_STATE/ports" "$CNE_TEMP/ports.before" || return 1; had_ports=1; }
    mv "$CNE_TEMP/ports" "$CNE_STATE/ports" || return 1
    if ! mv "$CNE_TEMP/nodes.tsv" "$CNE_STATE/nodes.tsv"; then
        if ((had_ports)); then mv "$CNE_TEMP/ports.before" "$CNE_STATE/ports" || :; else rm -f "$CNE_STATE/ports"; fi
        return 1
    fi
    CNE_HOSTS=("${hosts[@]}"); CNE_USERS=("${users[@]}"); CNE_PORTS=("${ports[@]}"); CNE_IDENTITIES=("${identities[@]}")
    CNE_CONNECTIONS=("${connections[@]}"); CNE_USER_PORT=$user_port; CNE_WSS_PORT=$wss_port
    CNE_CONFIG_INVALID=0
    CNE_AUTH_READY=(0 0 0)
    CNE_PASSWORDS=('' '' ''); CNE_SUDOS=('' '' '')
    printf '\n节点已保存。SSH 密码仅在本次运行期间使用。\n'
}
cne_require_config() {
    cne_configured && return 0
    if [[ ${CNE_NONINTERACTIVE:-0} == 1 ]]; then cne_error '自动维护缺少三个节点的配置，请先运行管理菜单。'
    else cne_error "尚未配置有效节点。请选择“1. 一键安装”或“2. 修改节点”。当前管理目录：$CNE_STATE"; fi
    return 1
}
cne_authenticate() {
    local idx=$1
    if [[ -f $CNE_TEMP/auth-failed-$idx ]]; then
        CNE_AUTH_READY[$idx]=0
        rm -f "$CNE_TEMP/auth-failed-$idx" || return 1
    fi
    if [[ ${CNE_CONNECTIONS[$idx]:-ssh} == local ]]; then
        CNE_PASSWORDS[$idx]=''; CNE_SUDOS[$idx]=''
        if [[ $(id -u) != 0 ]]; then
            command -v sudo >/dev/null 2>&1 || { cne_error '管理本机服务需要 root 或 sudo。'; return 1; }
            if [[ ${CNE_NONINTERACTIVE:-0} != 1 ]]; then
                [[ ${CNE_AUTH_READY[$idx]} == 1 ]] || cne_note '本机管理需要管理员权限，请完成 sudo 验证。'
                sudo -v || return 1
            fi
        fi
        CNE_AUTH_READY[$idx]=1
        return 0
    fi
    if [[ ${CNE_IDENTITIES[$idx]} != - ]] && [[ ${CNE_IDENTITIES[$idx]} != /* || ! -f ${CNE_IDENTITIES[$idx]} || ! -r ${CNE_IDENTITIES[$idx]} ]]; then
        CNE_AUTH_READY[$idx]=0
        cne_error "${CNE_LABELS[$idx]}的 SSH 私钥文件不存在或不可读，请选择“2. 修改节点”更新私钥路径。"
        return 1
    fi
    cne_bootstrap ssh || return 1
    if [[ ${CNE_NONINTERACTIVE:-0} == 1 ]]; then
        [[ ${CNE_IDENTITIES[$idx]} != - ]] || { cne_error "${CNE_LABELS[$idx]}自动维护需要 SSH 密钥登录。"; return 1; }
        ssh-keygen -y -P '' -f "${CNE_IDENTITIES[$idx]}" </dev/null >/dev/null 2>&1 || { cne_error "${CNE_LABELS[$idx]}自动维护需要无需口令的 SSH 私钥。"; return 1; }
        CNE_PASSWORDS[$idx]=''; CNE_SUDOS[$idx]=''; CNE_AUTH_READY[$idx]=1
        return 0
    fi
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
    if [[ ${CNE_CONNECTIONS[$idx]:-ssh} == local ]]; then
        if [[ $(id -u) == 0 ]]; then /bin/bash "$script" </dev/null
        else
            if [[ ${CNE_NONINTERACTIVE:-0} == 1 ]]; then
                sudo -n -k /bin/bash "$script" </dev/null
                return $?
            fi
            # Refresh valid sudo timestamps between operations. A long build
            # can outlive the cache; revalidate before executing the RPC file.
            if ! sudo -n -v 2>/dev/null; then
                [[ ${CNE_NONINTERACTIVE:-0} != 1 ]] || { cne_error '自动维护的本机 sudo 验证失败。'; return 1; }
                cne_note '本机管理员授权已过期，请重新完成 sudo 验证。'
                sudo -v || return 1
            fi
            sudo -n /bin/bash "$script" </dev/null
        fi
        return $?
    fi
    local args=(-T -F /dev/null -p "${CNE_PORTS[$idx]}" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$CNE_STATE/known_hosts" -o LogLevel=ERROR -o NumberOfPasswordPrompts=1)
    if [[ ${CNE_NONINTERACTIVE:-0} == 1 ]]; then
        args+=(-i "${CNE_IDENTITIES[$idx]}" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no)
        command='/bin/bash -s'; [[ ${CNE_USERS[$idx]} == root ]] || command='sudo -n -k /bin/bash -s'
        args+=("${CNE_USERS[$idx]}@${CNE_HOSTS[$idx]}" "$command")
        ssh "${args[@]}" < "$script"
        return $?
    fi
    local password_args=(-d 9)
    if [[ ${CNE_IDENTITIES[$idx]} == - ]]; then args+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive)
    else args+=(-i "${CNE_IDENTITIES[$idx]}" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no); password_args+=(-P passphrase); fi
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
    if [[ $result != 0 ]]; then CNE_AUTH_READY[$idx]=0; : > "$CNE_TEMP/auth-failed-$idx"; fi
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
    result=$?; rm -f "$script"
    if [[ $result != 0 ]]; then CNE_AUTH_READY[$idx]=0; : > "$CNE_TEMP/auth-failed-$idx"; fi
    return "$result"
}
cne_remote_payload() {
    local idx=$1 action=$2 archive=$3 script result
    shift 3
    [[ $action == certificate-apply || $action == restore-import ]] && [[ -f $archive && ! -L $archive && -O $archive ]] || return 1
    script=$(mktemp "$CNE_TEMP/payload.XXXXXX") || return 1
    {
        printf 'set -Eeuo pipefail\nexport LC_ALL=C\nCNE_NODE_LIBRARY=1\n'
        cne_node_source
        printf '\ncne_upload=$(mktemp /root/.cn-egress-maintenance.XXXXXXXX)\ntrap '\''rm -f "$cne_upload"'\'' EXIT\n'
        printf 'base64 -d > "$cne_upload" <<'\''CNE_MAINTENANCE_PAYLOAD_V3'\''\n'
        base64 < "$archive"
        printf '\nCNE_MAINTENANCE_PAYLOAD_V3\n'
        printf 'cne_node_main %q %q "$cne_upload"' "$action" "${CNE_ROLES[$idx]}"
        [[ $# == 0 ]] || printf ' %q' "$@"
        printf '\n'
    } > "$script" || return 1
    cne_send_script "$idx" "$script"; result=$?
    rm -f "$script"
    if [[ $result != 0 ]]; then CNE_AUTH_READY[$idx]=0; : > "$CNE_TEMP/auth-failed-$idx"; fi
    return "$result"
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
        printf '  %s\n    地址：%s\n    状态：%s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")" "$state"
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
    cne_download_verified "https://github.com/erebe/wstunnel/releases/download/v11.0.0/wstunnel_11.0.0_linux_$arch.tar.gz" "$checksum" "$archive" "传输组件（$arch）" || return 1
    dir=$CNE_TEMP/binary-$arch; mkdir -p "$dir" || return 1
    # Only the named, checksum-verified executable is extracted.
    tar -xzf "$archive" -C "$dir" wstunnel || return 1
    chmod 755 "$dir/wstunnel" || return 1
    CNE_BINARY=$dir/wstunnel
}
cne_transaction_abort() {
    [[ ${CNE_TRANSACTION_ACTIVE:-0} == 1 ]] || return 0
    local position idx failures=0 directory=$CNE_TRANSACTION_DIRECTORY
    if [[ -f $directory/transaction-status && $(cat "$directory/transaction-status") == committed ]]; then
        CNE_TRANSACTION_ACTIVE=0
        rm -f "$CNE_STATE/active-transaction"
        return
    fi
    cne_note '本次操作未完成，正在逆序恢复涉及的节点…'
    for ((position=${#CNE_TRANSACTION_ATTEMPTED[@]}-1; position>=0; position--)); do
        idx=${CNE_TRANSACTION_ATTEMPTED[$position]}
        if cne_remote "$idx" restore "${CNE_TRANSACTION_BACKUPS[$idx]}" "$CNE_TRANSACTION_ID"; then
            printf '%s\n' "${CNE_ROLES[$idx]}" >> "$directory/restored.txt" || failures=1
        else
            cne_note "${CNE_LABELS[$idx]}恢复失败，记录和备份已保留。"
            failures=1
        fi
    done
    if [[ -f $directory/local-publish.started ]]; then
        if [[ -d $directory/previous-clients && ! -L $directory/previous-clients ]]; then
            if [[ ! -L $CNE_STATE/clients ]]; then
                rm -rf -- "$CNE_STATE/clients" && mv "$directory/previous-clients" "$CNE_STATE/clients" || failures=1
            else failures=1; fi
        fi
        if [[ -f $directory/previous-deployment ]]; then
            cp "$directory/previous-deployment" "$CNE_STATE/current-deployment" || failures=1
        else rm -f "$CNE_STATE/current-deployment" || failures=1; fi
        if [[ -f $directory/previous-ports && ! -L $directory/previous-ports ]]; then
            cp "$directory/previous-ports" "$CNE_STATE/ports" || failures=1
            read -r CNE_USER_PORT CNE_WSS_PORT < "$CNE_STATE/ports" || failures=1
        fi
    fi
    CNE_TRANSACTION_ACTIVE=0
    if ((failures)); then
        printf 'rollback-incomplete\n' > "$directory/transaction-status"
        cne_error "恢复未全部完成；请选择“15. 重试恢复”后再进行其他操作。记录：$directory"
        return 1
    fi
    printf 'rolled-back\n' > "$directory/transaction-status" || return 1
    rm -f "$CNE_STATE/active-transaction" || return 1
    cne_note '本次涉及的节点和客户端配置已恢复到操作前状态。'
}

cne_transaction_recover() {
    local journal=$CNE_STATE/active-transaction id role backup idx line current_nodes previous_nodes
    [[ -e $journal || -L $journal ]] || return 0
    [[ -f $journal && ! -L $journal && -O $journal ]] || { cne_error '未完成操作记录不安全。'; return 1; }
    IFS= read -r id < "$journal" || return 1
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}$ ]] || { cne_error '未完成操作编号无效。'; return 1; }
    CNE_TRANSACTION_DIRECTORY=$CNE_STATE/history/$id
    CNE_TRANSACTION_ID=$id
    [[ -d $CNE_TRANSACTION_DIRECTORY ]] && cne_safe_directory "$CNE_TRANSACTION_DIRECTORY" || return 1
    for line in transaction-status nodes.tsv backups.tsv; do
        [[ -f $CNE_TRANSACTION_DIRECTORY/$line && ! -L $CNE_TRANSACTION_DIRECTORY/$line && -O $CNE_TRANSACTION_DIRECTORY/$line ]] || return 1
    done
    if [[ -f $CNE_TRANSACTION_DIRECTORY/transaction-status ]] && [[ $(cat "$CNE_TRANSACTION_DIRECTORY/transaction-status") == committed ]]; then
        rm -f "$journal"
        return
    fi
    current_nodes=$(cne_nodes_canonical "$CNE_STATE/nodes.tsv") && previous_nodes=$(cne_nodes_canonical "$CNE_TRANSACTION_DIRECTORY/nodes.tsv") || { cne_error '当前节点已改变，或保存的节点格式无效。请恢复该次记录中的节点设置后重试。'; return 1; }
    [[ $current_nodes == "$previous_nodes" ]] || { cne_error '存在未完成操作，但当前节点已改变。请恢复该次记录中的节点设置后重试，避免恢复到另一台机器。'; return 1; }
    CNE_TRANSACTION_BACKUPS=('' '' '')
    while IFS=$'\t' read -r role backup; do
        case $role in hk) idx=0;; sh) idx=1;; exit) idx=2;; *) return 1;; esac
        [[ $backup =~ ^/root/cn-egress-backups/[A-Za-z0-9._-]+\.tar\.gz$ ]] || return 1
        CNE_TRANSACTION_BACKUPS[$idx]=$backup
    done < "$CNE_TRANSACTION_DIRECTORY/backups.tsv"
    CNE_TRANSACTION_ATTEMPTED=()
    if [[ -f $CNE_TRANSACTION_DIRECTORY/attempted.txt ]]; then
        while IFS= read -r idx; do
            [[ $idx == 0 || $idx == 1 || $idx == 2 ]] && [[ -n ${CNE_TRANSACTION_BACKUPS[$idx]} ]] || return 1
            CNE_TRANSACTION_ATTEMPTED+=("$idx")
            cne_authenticate "$idx" || return 1
        done < "$CNE_TRANSACTION_DIRECTORY/attempted.txt"
    fi
    CNE_TRANSACTION_ACTIVE=1
    cne_note '发现上次中断的操作，先恢复原有配置。'
    cne_transaction_abort
}

cne_transaction_begin() {
    CNE_TRANSACTION_DIRECTORY=$1
    CNE_TRANSACTION_ID=$2
    CNE_TRANSACTION_ATTEMPTED=()
    CNE_TRANSACTION_ACTIVE=0
    # Metadata must exist before the journal becomes visible to recovery.
    printf 'prepared\n' > "$1/transaction-status" || return 1
    printf '%s\n' "$2" > "$CNE_TEMP/active-transaction" && mv "$CNE_TEMP/active-transaction" "$CNE_STATE/active-transaction" || return 1
    CNE_TRANSACTION_ACTIVE=1
}
cne_maintenance_commit() {
    local directory=$1 id=$2
    [[ $directory == "$CNE_TRANSACTION_DIRECTORY" && $id == "$CNE_TRANSACTION_ID" && $CNE_TRANSACTION_ACTIVE == 1 ]] || return 1
    printf 'committed\n' > "$directory/transaction-status" || return 1
    CNE_TRANSACTION_ACTIVE=0
    rm -f "$CNE_STATE/active-transaction" || cne_note '维护已提交；残留记录将在下次运行时清理。'
    return 0
}

cne_transaction_publish() {
    local directory=$CNE_TRANSACTION_DIRECTORY prepared
    [[ ! -L $CNE_STATE/clients && ! -L $CNE_STATE/current-deployment ]] || return 1
    prepared=$(mktemp -d "$CNE_TEMP/new-clients.XXXXXX") || return 1
    cp "$directory/bundle/clients/"*.conf "$prepared/" || return 1
    if [[ -f $CNE_STATE/current-deployment ]]; then cp "$CNE_STATE/current-deployment" "$directory/previous-deployment" || return 1; fi
    : > "$directory/local-publish.started" || return 1
    mv "$CNE_STATE/clients" "$directory/previous-clients" && mv "$prepared" "$CNE_STATE/clients" || return 1
    printf '%s\n' "$CNE_TRANSACTION_ID" > "$CNE_TEMP/current-deployment" && mv "$CNE_TEMP/current-deployment" "$CNE_STATE/current-deployment" || return 1
    printf 'committed\n' > "$directory/transaction-status" || return 1
    CNE_TRANSACTION_ACTIVE=0
    rm -f "$CNE_STATE/active-transaction" || cne_note '安装已提交；残留记录将在下次安装时清理。'
    return 0
}

cne_verify_install() {
    local attempt idx good
    cne_note '验证节点握手、DNS 和实际转发路径…'
    for attempt in 1 2 3; do
        good=1
        for idx in 1 2 0; do
            if ! cne_remote "$idx" doctor; then good=0; fi
        done
        ((good)) && return 0
        [[ $attempt == 3 ]] || sleep 2
    done
    cne_error '链路验证未通过，不能交付客户端配置。'
}

cne_install() {
    local idx role state mode wan arch deployment directory backup_path refreshed token
    if ! cne_configured; then
        [[ ${CNE_NONINTERACTIVE:-0} != 1 ]] || { cne_require_config; return 1; }
        cne_setup || return 1
    fi
    cne_require_config || return 1
    cne_transaction_recover || return 1
    cne_inspect_all || return 1
    CNE_INSTALL_CHOICE=2
    for idx in 0 1 2; do
        if [[ $(cne_field "${CNE_INSPECTIONS[$idx]}" state) == present ]]; then cne_existing_choice || return 1; break; fi
    done
    case $CNE_INSTALL_CHOICE in
        0) printf '已取消。\n'; return 0 ;;
        1) printf '\n已保留现有配置。未安装的节点可下次选择“备份后重新安装整套服务”。\n'; cne_status; return ;;
    esac
    cne_bootstrap install || return 1
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
    for idx in 0 1 2; do cne_remote "$idx" prepare awg2 || return 1; done
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
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
    ( set -Eeuo pipefail; cne_render_bundle "$directory/bundle" "${CNE_HOSTS[0]}" "${CNE_HOSTS[1]}" "$CNE_USER_PORT" "$CNE_WSS_PORT" "$wan" awg2 ) || return 1
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        arch=$(cne_field "${CNE_INSPECTIONS[$idx]}" arch)
        cne_fetch_binary "$arch" || return 1
        mkdir -p "$directory/bundle/$role/opt/cn-egress/wstunnel-11.0.0" || return 1
        cp "$CNE_BINARY" "$directory/bundle/$role/opt/cn-egress/wstunnel-11.0.0/wstunnel" || return 1
        if [[ $role == hk ]]; then
            cne_fetch_awg "$arch" || return 1
            mkdir -p "$directory/bundle/hk/opt/cn-egress/awg-0.2.16" || return 1
            cp "$CNE_AWG_ENGINE" "$directory/bundle/hk/opt/cn-egress/awg-0.2.16/amneziawg-go" || return 1
            cp "$CNE_AWG_TOOLS_SOURCE" "$directory/bundle/hk/opt/cn-egress/awg-0.2.16/amneziawg-tools.tar.gz" || return 1
        fi
        printf '%s\n' "$deployment" > "$directory/bundle/$role/etc/cn-egress/deployment-id" || return 1
        (cd "$directory/bundle/$role" && find . -type f | sed 's#^./##' | LC_ALL=C sort > "$directory/$role.files" && tar -czf "$directory/$role.tar.gz" -T "$directory/$role.files") || return 1
    done
    CNE_TRANSACTION_BACKUPS=('' '' '')
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
    for idx in 0 1 2; do
        cne_note "保存${CNE_LABELS[$idx]}安装前状态…"
        backup_path=$(cne_remote "$idx" backup) || return 1
        [[ $backup_path =~ ^/root/cn-egress-backups/[A-Za-z0-9._-]+\.tar\.gz$ ]] || { cne_error '节点返回的备份路径无效。'; return 1; }
        CNE_TRANSACTION_BACKUPS[$idx]=$backup_path
        printf '%s\t%s\n' "${CNE_ROLES[$idx]}" "$backup_path" >> "$directory/backups.tsv" || return 1
        printf '  %s备份：%s\n' "${CNE_LABELS[$idx]}" "$backup_path"
    done
    if [[ $CNE_ENABLE_FORWARDING == 1 ]]; then cne_remote 2 enable-forwarding confirm || return 1; fi
    cne_transaction_begin "$directory" "$deployment" || return 1
    printf '\n开始安装\n'; cne_line
    for idx in 1 2 0; do
        role=${CNE_ROLES[$idx]}; mode=fresh
        [[ $(cne_field "${CNE_INSPECTIONS[$idx]}" state) != present ]] || mode=replace
        printf '正在安装：%s（%s）\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"
        CNE_TRANSACTION_ATTEMPTED+=("$idx")
        printf '%s\n' "$idx" >> "$directory/attempted.txt" || { cne_transaction_abort || :; return 1; }
        if ! cne_remote_install "$idx" "$mode" "$directory/$role.tar.gz" "$deployment"; then
            printf '\n安装在%s停止。\n本次记录：%s\n' "${CNE_LABELS[$idx]}" "$directory" >&2
            cne_transaction_abort || :
            return 1
        fi
        printf '%s\n' "$role" >> "$directory/completed.txt" || { cne_transaction_abort || :; return 1; }
    done
    if ! cne_verify_install || ! cne_transaction_publish; then cne_transaction_abort || :; return 1; fi
    printf '\n安装和链路验证完成。\n客户端配置目录：%s\n' "$CNE_STATE/clients"
    cne_client_delivery_hint "$CNE_STATE/clients/iPhone.conf"
    printf '选择“12. 显示配置与二维码”，将对应设备的配置导入客户端。\n\n'
    cne_status
}
cne_status() {
    local idx result=0
    if ! cne_configured; then cne_unconfigured_status; return 0; fi
    printf '\n节点状态\n'; cne_line
    for idx in 0 1 2; do
        printf '\n%s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"
        if ! cne_authenticate "$idx"; then cne_note '此节点认证未完成，继续查看其他节点。'; result=1; continue; fi
        if ! cne_remote "$idx" status; then result=1; CNE_AUTH_READY[$idx]=0; fi
    done
    cne_line
    return "$result"
}
cne_action_all() {
    local action=$1 idx result=0
    local order=(0 1 2)
    case $action in
        doctor|logs)
            if ! cne_configured; then cne_unconfigured_status; return 0; fi
            for idx in "${order[@]}"; do
                printf '\n%s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"
                if ! cne_authenticate "$idx"; then cne_note '此节点认证未完成，继续查看其他节点。'; result=1; continue; fi
                if ! cne_remote "$idx" "$action"; then result=1; CNE_AUTH_READY[$idx]=0; fi
            done
            return "$result";;
        start|stop|restart|uninstall) cne_mutation_guard || return 1;;
        *) cne_error '未知的节点服务操作。'; return 1;;
    esac
    cne_require_config || return 1
    case $action in start|restart) order=(1 2 0);; stop|uninstall) order=(0 2 1);; esac
    for idx in "${order[@]}"; do cne_authenticate "$idx" || return 1; done
    if [[ $action == uninstall && ( -e $CNE_STATE/auto-renew || -L $CNE_STATE/auto-renew ) ]]; then cne_renew_timer_disable || return 1; fi
    for idx in "${order[@]}"; do
        printf '\n%s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"
        if [[ $action == uninstall ]]; then cne_remote "$idx" uninstall confirm || result=1
        else cne_remote "$idx" "$action" || result=1; fi
    done
    if [[ $action == start || $action == restart ]]; then
        if ((result)); then cne_note '部分服务操作失败，链路尚未确认恢复。'
        else
            printf '\n节点服务命令已完成，正在确认链路…\n'
            if cne_verify_install; then printf '节点链路已通过验证；设备的公网连接请在客户端确认。\n'
            else cne_note '服务命令已完成，但链路验证失败。请选择“4. 连接诊断”或“8. 查看日志”。'; result=1; fi
        fi
    fi
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
    local name address public private psk server data current index pending user_port existing transport params='' field
    cne_mutation_guard && cne_require_config && cne_bootstrap client && cne_authenticate 0 || return 1
    cne_prompt '客户端名称（每台设备独立命名，0 取消）' || return 1; name=$CNE_ANSWER
    [[ $name != 0 ]] || { printf '已取消。\n'; return 0; }
    cne_name "$name" || { cne_error '名称只允许 1–32 位英文、数字、下划线或短横线。'; return 1; }
    [[ ! -e $CNE_STATE/clients/$name.conf ]] || { cne_error '该名称已有本地配置，请换一个名称。'; return 1; }
    data=$(cne_remote 0 client-list) || return 1
    server=$(cne_remote 0 server-public) || return 1; cne_key "$server" || return 1
    current=$(cne_remote 0 inspect) || return 1
    user_port=$(cne_field "$current" user_port)
    cne_port "$user_port" || { cne_error '无法读取现有入口端口。'; return 1; }
    transport=$(cne_field "$current" user_transport); transport=${transport:-wireguard}
    case $transport in
        wireguard) ;;
        awg2)
            params=$CNE_TEMP/client-awg-params
            cne_remote 0 client-params > "$params" || return 1
            cne_render_awg_params "$params" >/dev/null || { cne_error '服务器混淆参数无效。'; return 1; }
            ;;
        *) cne_error '服务器入口协议未知。'; return 1;;
    esac
    pending=$CNE_STATE/clients/$name.conf.pending
    existing=$(printf '%s\n' "$data" | awk -F '\t' -v name="$name" '$1==name {print;exit}')
    if [[ -e $pending || -L $pending ]]; then
        [[ -f $pending && ! -L $pending && -O $pending ]] || return 1
        [[ $(cne_profile_field "$pending" Peer PublicKey) == "$server" && $(cne_profile_field "$pending" Peer Endpoint) == "${CNE_HOSTS[0]}:$user_port" ]] || { cne_error '待用配置属于不同部署，请使用新的客户端名称。'; return 1; }
        if [[ $transport == awg2 ]]; then
            for field in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4; do
                [[ $(cne_profile_field "$pending" Interface "$field") == "$(sed -nE "s/^$field[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\\1/p" "$params")" ]] || { cne_error '待用配置的混淆参数已经改变，请使用新的客户端名称。'; return 1; }
            done
        else
            [[ -z $(cne_profile_field "$pending" Interface Jc) ]] || { cne_error '待用配置的入口协议已经改变，请使用新的客户端名称。'; return 1; }
        fi
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
        cne_render_client "$pending" "$address" "$private" "$server" "$psk" "${CNE_HOSTS[0]}" "$user_port" "$transport" "$params" || return 1
    fi
    CNE_CLIENT_PSK=$psk
    if ! cne_remote 0 client-add "$name" "$address" "$public" "$server"; then unset CNE_CLIENT_PSK private psk; cne_error "添加未完成，本地待用配置保留在 $CNE_STATE/clients/$name.conf.pending。请检查客户端列表。"; return 1; fi
    unset CNE_CLIENT_PSK private psk
    mv "$pending" "$CNE_STATE/clients/$name.conf" || return 1
    printf '客户端已添加：%s\n配置：%s\n' "$name" "$CNE_STATE/clients/$name.conf"
    cne_client_delivery_hint "$CNE_STATE/clients/$name.conf"
    printf '选择“12. 显示配置与二维码”完成导入。\n'
}
cne_client_pick_local() {
    local file name index answer matched explicit_name names=()
    CNE_CLIENT_SELECTION=''
    printf '\n本机保存的设备配置\n'; cne_line
    for file in "$CNE_STATE/clients/"*.conf; do
        [[ -f $file && ! -L $file && -O $file ]] || continue
        name=${file##*/}; name=${name%.conf}; cne_name "$name" || continue
        names+=("$name")
        printf '  %s. %s\n' "${#names[@]}" "$name"
    done
    ((${#names[@]})) || { cne_error '本机没有设备配置。旧设备请使用原文件，或先添加一个客户端。'; return 1; }
    while :; do
        cne_prompt '请选择设备编号，或输入 n:设备名称（0 取消）' 1 || return 1
        answer=$CNE_ANSWER
        [[ $answer != 0 ]] || return 0
        explicit_name=0
        if [[ $answer == n:* ]]; then answer=${answer#n:}; explicit_name=1; fi
        if [[ $explicit_name == 0 && $answer =~ ^[1-9][0-9]{0,2}$ ]] && ((10#$answer<=${#names[@]})); then
            CNE_CLIENT_SELECTION=${names[$((10#$answer-1))]}; return 0
        fi
        matched=0
        if [[ $explicit_name == 1 || ! $answer =~ ^[0-9]+$ ]]; then
            for name in "${names[@]}"; do [[ $answer != "$name" ]] || { CNE_CLIENT_SELECTION=$name; matched=1; break; }; done
        fi
        ((matched)) && return 0
        cne_note '请选择列表中的设备，或输入 0 取消。'
    done
}

# A verified delivery must be one generated tunnel, without duplicate values,
# additional peers or executable wg-quick hook directives. Offline view remains
# available for historical/custom files that do not meet this contract.
cne_client_profile_shape() {
    awk -v mode="$2" '
      function trim(v){gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);return v}
      {line=trim($0);if(line==""||line~/^[#;]/)next}
      line=="[Interface]" {if(++sections["Interface"]!=1||sections["Peer"])bad=1;section="Interface";next}
      line=="[Peer]" {if(++sections["Peer"]!=1||sections["Interface"]!=1)bad=1;section="Peer";next}
      {p=index(line,"=");if(!p||section==""){bad=1;next};key=trim(substr(line,1,p-1));value=trim(substr(line,p+1));if(value==""||++seen[section,key]!=1){bad=1;next}}
      section=="Interface" {if(key!~/^(PrivateKey|Address|DNS|MTU)$/ && !(mode=="awg2" && key~/^(Jc|Jmin|Jmax|S[1-4]|H[1-4])$/))bad=1;next}
      section=="Peer" {if(key!~/^(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)$/)bad=1;next}
      END {
        if(sections["Interface"]!=1||sections["Peer"]!=1)bad=1;
        n=split("PrivateKey Address DNS MTU",required," ");for(i=1;i<=n;i++)if(seen["Interface",required[i]]!=1)bad=1;
        n=split("PublicKey PresharedKey AllowedIPs Endpoint PersistentKeepalive",required," ");for(i=1;i<=n;i++)if(seen["Peer",required[i]]!=1)bad=1;
        if(mode=="awg2"){n=split("Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4",required," ");for(i=1;i<=n;i++)if(seen["Interface",required[i]]!=1)bad=1}
        exit bad?1:0
      }' "$1" || { cne_error '配置格式不符合当前设备要求：存在缺失、重复、额外节点或不允许的设置。'; return 1; }
}

# Identity checks use the actual key, rather than an easily reused device name.
# Offline file viewing never calls this helper or needs WireGuard tools.
cne_client_profile_identity() {
    local file=$1 server=$2 private public
    [[ -f $file && ! -L $file && -O $file ]] || { cne_error '本机配置文件不安全。'; return 1; }
    [[ $(cne_profile_field "$file" Peer PublicKey) == "$server" ]] || { cne_error '本机配置属于另一套入口密钥，不能作为当前设备配置使用。'; return 1; }
    private=$(cne_profile_field "$file" Interface PrivateKey)
    cne_key "$private" || { cne_error '本机客户端私钥格式无效。'; return 1; }
    public=$(printf '%s\n' "$private" | wg pubkey) || { unset private; cne_error '无法读取客户端公钥。'; return 1; }
    unset private
    cne_key "$public" || return 1
    CNE_PROFILE_PUBLIC=$public
}

cne_client_verify_profile() {
    local file=$1 current server transport user_port params field actual expected address number data psk digest
    cne_require_config && cne_bootstrap client && cne_authenticate 0 || return 1
    current=$(cne_remote 0 inspect) || return 1
    [[ $(cne_field "$current" state) == present && $(cne_field "$current" role) == hk ]] || { cne_error '当前入口尚未安装或角色不正确。'; return 1; }
    server=$(cne_remote 0 server-public) || return 1
    cne_key "$server" && cne_client_profile_identity "$file" "$server" || return 1
    user_port=$(cne_field "$current" user_port)
    cne_port "$user_port" && [[ $(cne_profile_field "$file" Peer Endpoint) == "${CNE_HOSTS[0]}:$user_port" ]] || { cne_error '本机配置的入口地址或端口已改变。'; return 1; }
    transport=$(cne_field "$current" user_transport); transport=${transport:-wireguard}
    cne_client_profile_shape "$file" "$transport" || return 1
    case $transport in
        wireguard) [[ -z $(cne_profile_field "$file" Interface Jc) ]] || { cne_error '本机配置与当前入口协议不同。'; return 1; };;
        awg2)
            params=$(cne_remote 0 client-params) || return 1
            for field in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4; do
                actual=$(cne_profile_field "$file" Interface "$field")
                expected=$(awk -F= -v key="$field" '{k=$1;gsub(/^[[:space:]]+|[[:space:]]+$/,"",k);if(k==key){v=$2;gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);print v;count++}} END{if(count!=1)exit 1}' <<< "$params") || { cne_error '当前服务器混淆参数不完整。'; return 1; }
                [[ -n $expected && $actual == "$expected" ]] || { cne_error '本机配置的混淆参数已经改变。'; return 1; }
            done;;
        *) cne_error '当前入口协议未知。'; return 1;;
    esac
    address=$(cne_profile_field "$file" Interface Address | tr -d '[:space:]')
    [[ $address =~ ^10\.77\.10\.([1-9][0-9]{0,2})/32,fd77:77:10::([1-9][0-9]{0,2})/128$ ]] || { cne_error '客户端完整地址与当前设备网段不一致。'; return 1; }
    number=${BASH_REMATCH[1]}
    [[ $address == "10.77.10.$number/32,fd77:77:10::$number/128" ]] && ((10#$number>=2 && 10#$number<=249)) || { cne_error '客户端完整地址无效。'; return 1; }
    [[ $(cne_profile_field "$file" Interface DNS | tr -d '[:space:]') == 10.77.30.2 ]] || { cne_error '客户端 DNS 已改变，不能按当前配置发放。'; return 1; }
    [[ $(cne_profile_field "$file" Peer AllowedIPs | tr -d '[:space:]') == '0.0.0.0/0,::/0' ]] || { cne_error '客户端转发范围已改变，不能按当前配置发放。'; return 1; }
    [[ $(cne_profile_field "$file" Interface MTU) == 1380 && $(cne_profile_field "$file" Peer PersistentKeepalive) == 25 ]] || { cne_error '客户端连接参数已改变，不能按当前配置发放。'; return 1; }
    data=$(cne_remote 0 client-list) || return 1
    if ! awk -F'\t' -v key="$CNE_PROFILE_PUBLIC" -v address="$number" '$3==key && $2==address {found=1} END{exit !found}' <<< "$data"; then
        cne_error '此设备已撤销或未注册在当前入口，原文件不能作为有效配置发放。'; return 1
    fi
    psk=$(cne_profile_field "$file" Peer PresharedKey)
    cne_key "$psk" || { unset psk; cne_error '客户端预共享密钥格式无效。'; return 1; }
    digest=$(printf '%s\n' "$psk" | sha256sum) || { unset psk; return 1; }
    digest=${digest%% *}; unset psk
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    cne_remote 0 client-verify "$CNE_PROFILE_PUBLIC" "$server" "$digest" || { cne_error '服务器核对客户端密钥失败，原文件可能已经失效。'; return 1; }
    printf '已核对当前入口、协议参数和设备注册信息；公网连接还需在设备上验证。\n'
}

cne_client_delivery_hint() {
    local file=$1
    printf '每台设备使用独立配置；给另一台设备使用时，请新增客户端。\n'
    if [[ -n $(cne_profile_field "$file" Interface Jc) ]]; then
        printf '使用支持 AmneziaWG 2 的客户端导入配置，然后开启连接。\n'
        printf 'iPhone：https://apps.apple.com/app/amneziawg/id6478942365\nAndroid：https://github.com/amnezia-vpn/amneziawg-android/releases\nWindows：https://github.com/amnezia-vpn/amneziawg-windows-client/releases\n'
    else printf '使用 WireGuard 客户端导入配置，然后开启连接。\n'; fi
}

cne_client_export() {
    local name file mode verified=0 client='WireGuard'
    cne_client_pick_local || return 1
    name=$CNE_CLIENT_SELECTION; [[ -n $name ]] || { printf '已取消。\n'; return 0; }
    file=$CNE_STATE/clients/$name.conf
    printf '\n  1. 核对当前服务器后显示配置与二维码\n  2. 离线查看原文件（未验证是否仍有效）\n  0. 取消\n'
    while :; do
        cne_prompt '请选择' 1 || return 1; mode=$CNE_ANSWER
        case $mode in 0) printf '已取消。\n'; return 0;; 1|2) break;; *) cne_note '请输入 0、1 或 2。';; esac
    done
    if [[ $mode == 1 ]]; then
        if cne_client_verify_profile "$file"; then verified=1
        else
            cne_note '当前有效性未通过验证。'
            cne_prompt '是否仍离线查看原文件（y/N）' N || return 1
            [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || return 1
        fi
    fi
    [[ -z $(cne_profile_field "$file" Interface Jc) ]] || client='AmneziaWG 2 或更新版本'
    printf '\n配置文件：%s\n' "$file"
    if ((verified)); then
        cne_client_delivery_hint "$file"
        if cne_ensure_qrencode; then
            printf '在%s中选择“扫描二维码”：\n' "$client"
            if qrencode -t ANSIUTF8 < "$file"; then return 0; fi
        fi
        printf '二维码暂不可用。请导入上面的 .conf 文件，或保存以下配置内容（含私钥，请勿公开）：\n\n'
    else
        printf '离线原文件：尚未验证当前有效性，可能已经被撤销、替换或卸载。含私钥，请勿公开。\n'
        printf '离线查看不连接服务器，也不安装依赖。\n\n'
    fi
    cat "$file" || return 1
    return 0
}

cne_client_mark_revoked() {
    local file=$1 destination historical=''
    [[ -n $file && $file != *.revoked ]] || return 0
    [[ -f $file && ! -L $file && -O $file ]] || return 1
    destination=$file.revoked
    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination && -O $destination ]] || { cne_error '本机历史撤销配置不安全。'; return 1; }
        historical=$(mktemp "$destination.archive.XXXXXXXX") || return 1
        mv -- "$destination" "$historical" || { rm -f "$historical"; return 1; }
    fi
    if ! mv -- "$file" "$destination"; then
        [[ -z $historical ]] || mv -- "$historical" "$destination"
        return 1
    fi
    printf '本机原配置已标记撤销：%s\n' "$destination"
}

cne_client_remove() {
    local name data existing public server file='' candidate current remaining
    cne_mutation_guard || return 1
    cne_require_config && cne_bootstrap client && cne_authenticate 0 || return 1
    data=$(cne_remote 0 client-list) || return 1
    printf '\n当前入口的客户端\n'; cne_line
    if [[ -n $data ]]; then awk -F'\t' '{printf "  %s  10.77.10.%s\n",$1,$2}' <<< "$data"; else printf '暂无客户端。\n'; fi
    cne_prompt '要撤销的客户端名称（0 取消）' || return 1; name=$CNE_ANSWER
    [[ $name != 0 ]] || { printf '已取消。\n'; return 0; }
    cne_name "$name" || { cne_error '客户端名称格式不正确。'; return 1; }
    existing=$(awk -F'\t' -v name="$name" '$1==name {print;exit}' <<< "$data")
    public=$(awk -F'\t' '{print $3}' <<< "$existing")
    for candidate in "$CNE_STATE/clients/$name.conf" "$CNE_STATE/clients/$name.conf.pending" "$CNE_STATE/clients/$name.conf.revoked" "$CNE_STATE/clients/$name.conf.pending.revoked"; do
        if [[ -e $candidate || -L $candidate ]]; then file=$candidate; break; fi
    done
    if [[ -z $existing && -z $file ]]; then cne_error '当前入口和本机均没有此客户端，请检查名称。'; return 1; fi
    current=$(cne_remote 0 inspect) || return 1
    [[ $(cne_field "$current" state) == present && $(cne_field "$current" role) == hk ]] || { cne_error '当前入口尚未安装或角色不正确。'; return 1; }
    server=$(cne_remote 0 server-public) || return 1; cne_key "$server" || return 1
    if [[ -n $file ]]; then
        cne_client_profile_identity "$file" "$server" || return 1
        [[ -z $existing || $CNE_PROFILE_PUBLIC == "$public" ]] || { cne_error '服务器存在同名但不同密钥的客户端，未执行撤销；请先核对当前设备。'; return 1; }
    fi
    if [[ -z $existing ]]; then
        if awk -F'\t' -v key="$CNE_PROFILE_PUBLIC" '$3==key {found=1} END{exit !found}' <<< "$data"; then
            cne_error '此配置仍以其他名称注册在当前入口，请使用列表中的实际名称撤销。'; return 1
        fi
        cne_client_mark_revoked "$file" || return 1
        printf '该客户端已不在当前入口注册，无需再次撤销。\n'; return 0
    fi
    cne_key "$public" || return 1
    cne_prompt "撤销 ${name}，是否继续（y/N）" N || return 1
    [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消。\n'; return 0; }
    if ! cne_remote 0 client-remove "$name" "$public" "$server"; then
        cne_note '撤销请求未收到成功回复，正在核对服务器结果…'
        cne_authenticate 0 || return 1
        remaining=$(cne_remote 0 server-public) || return 1
        [[ $remaining == "$server" ]] || { cne_error '核对期间入口密钥已改变，无法确认原设备的撤销结果；本机配置保留。'; return 1; }
        remaining=$(cne_remote 0 client-list) || { cne_error '无法确认撤销结果，原配置保留；恢复连接后可重试。'; return 1; }
        if awk -F'\t' -v key="$public" '$3==key {found=1} END{exit !found}' <<< "$remaining"; then
            cne_error '客户端仍注册在当前入口，撤销未完成，可重试。'; return 1
        fi
        printf '已确认原客户端不再注册。\n'
    fi
    cne_client_mark_revoked "$file" || return 1
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
        printf '  14. 卸载服务\n'
        [[ ! -e $CNE_STATE/active-transaction ]] || printf '  15. 重试恢复上次未完成操作\n'
        printf '  16. 恢复历史备份\n  17. 证书续期与自动维护\n  18. 配置下载来源\n  19. 组件离线包\n'
        printf '  0. 退出\n\n'
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
            9) cne_backup_create || cne_note '备份未完成，具体原因见上方。';;
            10) cne_clients_list || cne_note '客户端列表读取失败。';;
            11) cne_client_add || cne_note '客户端添加未完成。';;
            12) cne_client_export || cne_note '配置导出未完成。';;
            13) cne_client_remove || cne_note '客户端撤销未完成。';;
            14)
                printf '\n将卸载三个节点的本工具服务，并先保存配置备份。\n'
                cne_prompt '确认卸载请输入 UNINSTALL' || return 0
                [[ $CNE_ANSWER != UNINSTALL ]] || cne_action_all uninstall || cne_note '部分节点卸载未完成。';;
            15) cne_require_config && cne_transaction_recover || cne_note '恢复尚未完成，原备份和记录已保留。';;
            16) cne_backup_restore || cne_note '恢复未完成，备份和记录已保留。';;
            17) cne_renew_menu || cne_note '证书维护未完成，具体原因见上方。';;
            18) cne_download_setup || cne_note '下载来源设置未完成。';;
            19) cne_download_bundle_menu || cne_note '组件离线包操作未完成。';;
            *) cne_note '请输入菜单中的编号。';;
        esac
    done
}
cne_main() {
    CNE_RUNNING_SCRIPT=${BASH_SOURCE[0]}
    case ${1:-menu} in
        --help|-h) printf '一键安装与管理（纯 Bash）\n用法：bash cn-egress-oneclick.sh [menu|install|status|doctor|backup|renew|renew-auto]\n支持 Debian 12+、Ubuntu 22.04+，无需 Python。\n'; return 0 ;;
        --version) printf '%s\n' "$CNE_VERSION"; return 0 ;;
        menu|install|status|doctor|backup|renew) ;;
        renew-auto) CNE_NONINTERACTIVE=1 ;;
        *) cne_error '未知命令，可用 --help 查看用法。'; return 1 ;;
    esac
    cne_bootstrap ui || return 1
    cne_initialize || return $?
    cne_download_load || cne_note '下载设置无效；状态和离线配置仍可查看，请通过“18. 配置下载来源”修正。'
    case ${1:-menu} in menu) cne_menu;; install) cne_install;; status) cne_status;; doctor) cne_action_all doctor;; backup) cne_backup_create;; renew) cne_renew_certificates;; renew-auto) cne_renew_auto || return 1;; esac
}
#!/usr/bin/env bash
# Private, portable backup sets. No saved file is sourced or executed.
cne_backup_id() {
    local random
    random=$(openssl rand -hex 6) || return 1
    [[ $random =~ ^[a-f0-9]{12}$ ]] || return 1
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$random"
}
cne_backup_regular() {
    [[ -f $1 && ! -L $1 && -O $1 && -r $1 ]] || { cne_error "备份文件不安全：${1##*/}"; return 1; }
}
cne_backup_client_files() {
    local source=$1 destination=$2 file name size count=0
    [[ -d $source && ! -L $source && -O $source && -r $source && -x $source ]] || return 1
    mkdir -m 700 "$destination" || return 1
    while IFS= read -r -d '' file; do
        name=${file##*/}
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$ ]] && cne_backup_regular "$file" || return 1
        size=$(wc -c < "$file") || return 1
        ((size<=1048576 && ++count<=1280)) || { cne_error '客户端备份文件过多或过大。'; return 1; }
        cp -p -- "$file" "$destination/$name" && chmod 600 "$destination/$name" || return 1
    done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)
}
cne_backup_info_valid() {
    local data=$1 role=$2 state deployment key value
    printf '%s\n' "$data" | awk -F= 'NF<2 || $1!~/^[a-z_][a-z0-9_]*$/ || ++seen[$1]!=1{bad=1} END{exit bad?1:0}' || return 1
    state=$(cne_field "$data" state); deployment=$(cne_field "$data" deployment)
    [[ $state == present || $state == absent ]] && [[ $deployment == none || $deployment =~ ^[A-Za-z0-9_-]{8,80}$ ]] || return 1
    if [[ $state == present ]]; then [[ $(cne_field "$data" role) == "$role" ]] || return 1
    else [[ $(cne_field "$data" role) == unknown || $(cne_field "$data" role) == "$role" ]] || return 1; fi
    for key in ca_sha256 config_sha256 tls_sha256; do
        value=$(cne_field "$data" "$key")
        [[ $value == none || $value =~ ^[a-f0-9]{64}$ ]] || return 1
    done
    for key in main obfs dns users; do
        value=$(cne_field "$data" "${key}_active")
        [[ $value =~ ^(active|inactive|failed|activating|deactivating|reloading|maintenance|refreshing|unknown)$ ]] || return 1
        value=$(cne_field "$data" "${key}_enabled")
        [[ $value =~ ^(enabled|enabled-runtime|disabled|static|indirect|generated|masked|masked-runtime|transient|linked|linked-runtime|alias|bad|not-found|unknown)$ ]] || return 1
    done
}
cne_backup_local_metadata() {
    local destination=$1
    cne_backup_regular "$CNE_STATE/nodes.tsv" && cne_backup_regular "$CNE_STATE/ports" || return 1
    cp -p "$CNE_STATE/nodes.tsv" "$CNE_STATE/ports" "$destination/" || return 1
    if [[ -e $CNE_STATE/current-deployment || -L $CNE_STATE/current-deployment ]]; then
        cne_backup_regular "$CNE_STATE/current-deployment" && cp -p "$CNE_STATE/current-deployment" "$destination/" || return 1
    fi
    cne_backup_client_files "$CNE_STATE/clients" "$destination/clients"
}
cne_backup_relative_valid() {
    case $1 in
        format|nodes.tsv|ports|backups.tsv|current-deployment) return 0;;
        info/hk.before|info/hk.after|info/sh.before|info/sh.after|info/exit.before|info/exit.after) return 0;;
        archives/hk-*|archives/sh-*|archives/exit-*) [[ ${1#archives/} =~ ^(hk|sh|exit)-[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.tar\.gz$ ]]; return;;
        clients/*) [[ ${1#clients/} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$ ]]; return;;
        *) return 1;;
    esac
}
cne_backup_manifest() {
    local directory=$1 file relative list=$CNE_TEMP/backup-files.$$
    : > "$list" || return 1
    while IFS= read -r -d '' file; do
        relative=${file#"$directory/"}
        [[ $relative == manifest.sha256 || $relative == complete ]] && continue
        cne_backup_relative_valid "$relative" && cne_backup_regular "$file" || { rm -f "$list"; return 1; }
        printf '%s\n' "$relative" >> "$list" || return 1
    done < <(find "$directory" -type f -print0)
    LC_ALL=C sort "$list" -o "$list" || return 1
    (cd "$directory" && while IFS= read -r relative; do sha256sum "$relative" || exit; done < "$list") > "$directory/manifest.sha256" || return 1
    rm -f "$list"
}
cne_backup_validate() {
    local directory=$1 file relative line digest entry idx role path extra user_port wss_port canonical count=0 size
    local roles=() observed=() expected=()
    [[ -d $CNE_STATE/backups && ! -L $CNE_STATE/backups && -O $CNE_STATE/backups && $directory == "$CNE_STATE/backups/"* && ${directory#"$CNE_STATE/backups/"} =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}$ && -d $directory && ! -L $directory && -O $directory ]] || return 1
    for file in complete manifest.sha256 format nodes.tsv ports backups.tsv; do cne_backup_regular "$directory/$file" || return 1; done
    [[ $(cat "$directory/complete") == complete && $(cat "$directory/format") == $'format=cn-egress-coherent-backup-v1\nid='"${directory##*/}" ]] || return 1
    while IFS= read -r -d '' file; do
        relative=${file#"$directory/"}
        if [[ -d $file && ! -L $file ]]; then
            [[ $relative == clients || $relative == info || $relative == archives ]] && [[ -O $file ]] || return 1
            continue
        fi
        cne_backup_regular "$file" || return 1
        size=$(wc -c < "$file") || return 1
        if [[ $relative == archives/* ]]; then ((size>0 && size<=104857600)) || return 1
        else ((size<=1048576)) || return 1; fi
        ((++count<=1300)) || return 1
        [[ $relative == manifest.sha256 || $relative == complete ]] && continue
        cne_backup_relative_valid "$relative" || return 1
        observed+=("$relative")
    done < <(find "$directory" -mindepth 1 -print0)
    while IFS= read -r line; do
        [[ $line =~ ^([a-f0-9]{64})\ \ (.+)$ ]] || return 1
        digest=${BASH_REMATCH[1]}; entry=${BASH_REMATCH[2]}
        cne_backup_relative_valid "$entry" && cne_backup_regular "$directory/$entry" || return 1
        if ((${#expected[@]})); then for relative in "${expected[@]}"; do [[ $relative != "$entry" ]] || return 1; done; fi
        [[ $(sha256sum "$directory/$entry" | awk '{print $1}') == "$digest" ]] || return 1
        expected+=("$entry")
    done < "$directory/manifest.sha256"
    [[ ${#expected[@]} == "${#observed[@]}" ]] || return 1
    canonical=$(cne_nodes_canonical "$directory/nodes.tsv") || return 1
    idx=0
    while IFS=$'\t' read -r role path user_port wss_port file relative extra; do
        [[ -z $extra && $role == "${CNE_ROLES[$idx]}" ]] && cne_ipv4 "$path" && cne_port "$wss_port" && [[ $user_port =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && ( $file == - || $file == /* ) && ( $relative == ssh || $relative == local ) ]] || return 1
        roles+=("$path"); idx=$((idx+1))
    done <<< "$canonical"
    [[ ${roles[0]} != "${roles[1]}" && ${roles[0]} != "${roles[2]}" && ${roles[1]} != "${roles[2]}" ]] || return 1
    IFS=' ' read -r user_port wss_port extra < "$directory/ports" || return 1
    cne_port "$user_port" && cne_port "$wss_port" && [[ -z $extra && $user_port != 51831 && $(wc -l < "$directory/ports") -eq 1 ]] || return 1
    idx=0
    while IFS=$'\t' read -r role path extra; do
        ((idx<3)) && [[ $role == "${CNE_ROLES[$idx]}" && -z $extra && $path =~ ^/root/cn-egress-backups/[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.tar\.gz$ ]] || return 1
        cne_backup_regular "$directory/archives/$role-${path##*/}" || return 1
        for file in before after; do
            cne_backup_info_valid "$(cat "$directory/info/$role.$file")" "$role" || return 1
        done
        cmp -s "$directory/info/$role.before" "$directory/info/$role.after" || return 1
        idx=$((idx+1))
    done < "$directory/backups.tsv"
    [[ $idx == 3 && -d $directory/clients && ! -L $directory/clients && -O $directory/clients ]] || return 1
    if [[ -f $directory/current-deployment ]]; then [[ $(cat "$directory/current-deployment") =~ ^[A-Za-z0-9_-]{8,80}$ ]] || return 1; fi
}
cne_backup_create() {
    local idx role id directory path info after exported size
    cne_mutation_guard && cne_require_config && cne_bootstrap maintenance || return 1
    cne_safe_directory "$CNE_STATE/backups" || return 1
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
    id=$(cne_backup_id) || return 1
    directory=$CNE_STATE/backups/$id
    mkdir -m 700 "$directory" && mkdir -m 700 "$directory/info" "$directory/archives" || return 1
    printf 'format=cn-egress-coherent-backup-v1\nid=%s\n' "$id" > "$directory/format" || return 1
    cne_backup_local_metadata "$directory" || return 1
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        info=$(cne_remote "$idx" maintenance-info) || return 1
        cne_backup_info_valid "$info" "$role" || { cne_error '节点返回的维护状态无效，备份未完成。'; return 1; }
        printf '%s\n' "$info" > "$directory/info/$role.before" || return 1
    done
    : > "$directory/backups.tsv" || return 1
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        cne_note "备份${CNE_LABELS[$idx]}配置与服务状态…"
        path=$(cne_remote "$idx" backup) || return 1
        [[ $path =~ ^/root/cn-egress-backups/[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.tar\.gz$ ]] || return 1
        exported=$CNE_TEMP/backup-export-$role
        cne_remote "$idx" backup-export "$path" > "$exported" || return 1
        base64 -d < "$exported" > "$directory/archives/$role-${path##*/}" || return 1
        size=$(wc -c < "$directory/archives/$role-${path##*/}") || return 1
        ((size>0 && size<=104857600)) || return 1
        printf '%s\t%s\n' "$role" "$path" >> "$directory/backups.tsv" || return 1
    done
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        after=$(cne_remote "$idx" maintenance-info) || return 1
        printf '%s\n' "$after" > "$directory/info/$role.after" || return 1
        cmp -s "$directory/info/$role.before" "$directory/info/$role.after" || { cne_error '备份过程中节点配置或服务状态发生变化。此备份未完成，请重试。'; return 1; }
    done
    cmp -s "$CNE_STATE/nodes.tsv" "$directory/nodes.tsv" && cmp -s "$CNE_STATE/ports" "$directory/ports" && diff -r "$CNE_STATE/clients" "$directory/clients" >/dev/null || { cne_error '备份过程中本机配置发生变化，请重试。'; return 1; }
    cne_backup_manifest "$directory" || return 1
    printf 'complete\n' > "$directory/complete" || return 1
    if ! cne_backup_validate "$directory"; then rm -f "$directory/complete"; cne_error '备份校验失败，未标记为可恢复。'; return 1; fi
    CNE_BACKUP_CREATED=$directory
    printf '\n备份完成：%s\n包含三台节点、设备配置和服务状态；含私钥，请保密整个目录。\n' "$directory"
    cne_backup_restorable "$directory" || printf '当前三台节点的服务不完整或不属于同一套证书，此备份仅保留状态，不会列为历史恢复目标。\n'
}
cne_backup_pick() {
    local directory answer index entries=()
    CNE_BACKUP_SELECTION=''
    printf '\n可恢复的历史备份\n'; cne_line
    for directory in "$CNE_STATE/backups/"*; do
        [[ -d $directory && ! -L $directory && -f $directory/complete ]] || continue
        if cne_backup_validate "$directory" && cne_backup_restorable "$directory"; then
            entries+=("$directory")
            printf '  %s. %s（UTC）\n' "${#entries[@]}" "${directory##*/}"
        else cne_note "跳过不完整、校验失败或缺少完整服务的备份：${directory##*/}"; fi
    done
    ((${#entries[@]})) || { cne_error '没有完整且通过校验的历史备份，请先使用“9. 备份配置”。'; return 1; }
    while :; do
        cne_prompt '请选择备份编号（0 取消）' || return 1; answer=$CNE_ANSWER
        [[ $answer != 0 ]] || return 0
        if [[ $answer =~ ^[1-9][0-9]{0,3}$ ]] && ((10#$answer<=${#entries[@]})); then
            index=$((10#$answer-1)); CNE_BACKUP_SELECTION=${entries[$index]}; return 0
        fi
        cne_note '请选择列表中的编号，或输入 0 取消。'
    done
}
cne_backup_restorable() {
    local directory=$1 role path extra archive data list transport ca expected_ca=''
    while IFS=$'\t' read -r role path extra; do
        data=$(cat "$directory/info/$role.before") || return 1
        [[ $(cne_field "$data" state) == present && $(cne_field "$data" role) == "$role" ]] || return 1
        ca=$(cne_field "$data" ca_sha256)
        [[ $ca =~ ^[a-f0-9]{64}$ ]] || return 1
        if [[ -z $expected_ca ]]; then expected_ca=$ca; else [[ $expected_ca == "$ca" ]] || return 1; fi
        archive=$directory/archives/$role-${path##*/}
        list=$(tar -tzf "$archive") || return 1
        [[ $(tar -xOzf "$archive" etc/cn-egress/role 2>/dev/null) == "$role" && $(tar -xOzf "$archive" etc/cn-egress-wss/role 2>/dev/null) == "$role" ]] || return 1
        for path in etc/systemd/system/cn-egress.service etc/systemd/system/cn-egress-obfs.service; do
            printf '%s\n' "$list" | grep -Fxq "$path" || return 1
        done
        if [[ $role == exit ]]; then printf '%s\n' "$list" | grep -Fxq etc/systemd/system/cn-egress-dns.service || return 1; fi
        if [[ $role == hk ]]; then
            transport=$(tar -xOzf "$archive" etc/cn-egress/user-transport 2>/dev/null) || transport=wireguard
            case $transport in awg2) printf '%s\n' "$list" | grep -Fxq etc/systemd/system/cn-egress-users.service || return 1;; wireguard) ;; *) return 1;; esac
        fi
    done < "$directory/backups.tsv"
}
cne_backup_active_chain() {
    local directory=$1 data idx role
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}; data=$(cat "$directory/info/$role.before") || return 1
        [[ $(cne_field "$data" state) == present && $(cne_field "$data" main_active) == active && $(cne_field "$data" obfs_active) == active ]] || return 1
        if [[ $role == exit ]]; then [[ $(cne_field "$data" dns_active) == active ]] || return 1; fi
        if [[ $role == hk ]] && [[ $(cne_field "$data" users_enabled) != not-found ]]; then [[ $(cne_field "$data" users_active) == active ]] || return 1; fi
    done
}
cne_backup_publish() {
    local source=$1 directory=$CNE_TRANSACTION_DIRECTORY prepared
    [[ ! -L $CNE_STATE/clients && ! -L $CNE_STATE/current-deployment && ! -L $CNE_STATE/ports ]] || return 1
    prepared=$(mktemp -d "$CNE_TEMP/restored-clients.XXXXXXXX") || return 1
    rmdir "$prepared" && cne_backup_client_files "$source/clients" "$prepared" || return 1
    if [[ -f $CNE_STATE/current-deployment ]]; then cp "$CNE_STATE/current-deployment" "$directory/previous-deployment" || return 1; fi
    cp "$CNE_STATE/ports" "$directory/previous-ports" || return 1
    : > "$directory/local-publish.started" || return 1
    mv "$CNE_STATE/clients" "$directory/previous-clients" && mv "$prepared" "$CNE_STATE/clients" || return 1
    cp "$source/ports" "$CNE_TEMP/restored-ports" && mv "$CNE_TEMP/restored-ports" "$CNE_STATE/ports" || return 1
    printf '%s\n' "$CNE_TRANSACTION_ID" > "$CNE_TEMP/restored-deployment" && mv "$CNE_TEMP/restored-deployment" "$CNE_STATE/current-deployment" || return 1
    read -r CNE_USER_PORT CNE_WSS_PORT < "$CNE_STATE/ports" || return 1
}
cne_backup_restore() {
    local source idx role host user port identity connection extra id directory current path original before refreshed
    local infos=() targets=() targets_paths=()
    cne_mutation_guard && cne_require_config && cne_bootstrap maintenance || return 1
    cne_backup_pick || return 1; source=$CNE_BACKUP_SELECTION
    [[ -n $source ]] || { printf '已取消。\n'; return 0; }
    cne_backup_validate "$source" && cne_backup_restorable "$source" || { cne_error '备份校验失败或缺少完整服务，未更改服务。'; return 1; }
    idx=0
    while IFS=$'\t' read -r role host user port identity connection extra; do
        [[ $role == "${CNE_ROLES[$idx]}" && $host == "${CNE_HOSTS[$idx]}" ]] || { cne_error '备份的节点地址与当前设置不一致。请先恢复同一组节点地址，避免覆盖另一台机器。'; return 1; }
        idx=$((idx+1))
    done < "$source/nodes.tsv"
    printf '\n将恢复备份：%s（UTC）\n' "${source##*/}"
    for idx in 0 1 2; do printf '  %s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"; done
    printf '设备列表、密钥、端口和服务启停状态将回到该备份。后来新增的设备将失效，后来撤销的设备可能重新生效。\n恢复时连接会短暂中断；当前状态会先另行备份，失败会自动恢复。\n'
    cne_prompt '确认恢复三台节点（y/N）' N || return 1
    [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消，服务与配置未改动。\n'; return 0; }
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
    id=$(cne_backup_id) || return 1; directory=$CNE_STATE/history/$id
    mkdir -m 700 "$directory" || return 1
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/ports" "$directory/" || return 1
    printf 'restore\n' > "$directory/operation" && printf '%s\n' "${source##*/}" > "$directory/source-backup" || return 1
    CNE_TRANSACTION_BACKUPS=('' '' '')
    : > "$directory/backups.tsv" || return 1
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        before=$(cne_remote "$idx" maintenance-info) || return 1
        cne_backup_info_valid "$before" "$role" || return 1
        infos[$idx]=$before
        path=$(cne_remote "$idx" backup) || return 1
        [[ $path =~ ^/root/cn-egress-backups/[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.tar\.gz$ ]] || return 1
        CNE_TRANSACTION_BACKUPS[$idx]=$path
        printf '%s\t%s\n' "$role" "$path" >> "$directory/backups.tsv" || return 1
    done
    for idx in 0 1 2; do
        refreshed=$(cne_remote "$idx" maintenance-info) || return 1
        [[ $refreshed == "${infos[$idx]}" ]] || { cne_error '备份当前状态时节点发生变化，未开始恢复。'; return 1; }
    done
    idx=0
    while IFS=$'\t' read -r role path; do targets_paths[$idx]=${path##*/}; targets[$idx]=$source/archives/$role-${path##*/}; idx=$((idx+1)); done < "$source/backups.tsv"
    cne_transaction_begin "$directory" "$id" || return 1
    for idx in 1 2 0; do
        cne_note "正在恢复${CNE_LABELS[$idx]}…"
        CNE_TRANSACTION_ATTEMPTED+=("$idx")
        printf '%s\n' "$idx" >> "$directory/attempted.txt" || { cne_transaction_abort || :; return 1; }
        current=$(cne_field "${infos[$idx]}" deployment)
        if ! cne_remote_payload "$idx" restore-import "${targets[$idx]}" "${targets_paths[$idx]}" "$current" "$id"; then cne_transaction_abort || :; return 1; fi
    done
    if cne_backup_active_chain "$source"; then
        if ! cne_verify_install; then cne_transaction_abort || :; return 1; fi
    else cne_note '备份中部分服务原本未运行，已保留该状态；链路未启动，未做连通性验证。'; fi
    if ! cne_backup_publish "$source" || ! cne_maintenance_commit "$directory" "$id"; then cne_transaction_abort || :; return 1; fi
    printf '\n历史备份恢复完成。设备配置目录：%s\n当前状态备份记录：%s\n' "$CNE_STATE/clients" "$directory"
}
#!/usr/bin/env bash
# Certificate-only transactions and an optional, password-free daily timer.
cne_renew_collect() {
    local idx role info ca expected='' host
    CNE_RENEW_INFOS=()
    for idx in 0 1 2; do
        cne_authenticate "$idx" || return 1
        info=$(cne_remote "$idx" maintenance-info) || return 1
        role=${CNE_ROLES[$idx]}
        cne_backup_info_valid "$info" "$role" && [[ $(cne_field "$info" state) == present ]] || { cne_error "${CNE_LABELS[$idx]}尚未完整安装，不能仅更新证书。"; return 1; }
        ca=$(cne_field "$info" ca_sha256); host=$(cne_field "$info" wss_host)
        [[ $ca =~ ^[a-f0-9]{64}$ && $host == "${CNE_HOSTS[1]}" ]] || { cne_error '节点的证书或中转地址不匹配，请先检查当前部署。'; return 1; }
        if [[ -z $expected ]]; then expected=$ca; else [[ $ca == "$expected" ]] || { cne_error '三台节点使用的证书不属于同一套部署。'; return 1; }; fi
        CNE_RENEW_INFOS[$idx]=$info
    done
}
cne_renew_state_same() {
    local before=$1 after=$2 key
    for key in role config_sha256 wss_host main_active main_enabled obfs_active obfs_enabled dns_active dns_enabled users_active users_enabled; do
        [[ $(cne_field "$before" "$key") == "$(cne_field "$after" "$key")" ]] || { cne_error "证书更新后 ${key} 发生了预期之外的变化。"; return 1; }
    done
}
cne_renew_certificates() {
    local automatic=${1:-manual} idx role id directory snapshot path extra before info ca payload stage
    local infos=()
    cne_mutation_guard && cne_require_config && cne_bootstrap maintenance && cne_renew_collect || return 1
    infos=("${CNE_RENEW_INFOS[@]}")
    if [[ $automatic != automatic ]]; then
        printf '\n将更新三台节点的传输证书，连接会短暂中断。手机和电脑的设备配置保持不变。\n更新前会保存完整备份，失败会恢复原状态。\n'
        cne_prompt '确认更新证书（y/N）' N || return 1
        [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消。\n'; return 0; }
    fi
    cne_backup_create || return 1; snapshot=$CNE_BACKUP_CREATED
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}
        [[ $(cat "$snapshot/info/$role.before") == "${infos[$idx]}" ]] || { cne_error '节点状态发生变化，请重新执行续期。'; return 1; }
    done
    id=$(cne_backup_id) || return 1; directory=$CNE_STATE/history/$id
    mkdir -m 700 "$directory" || return 1
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/ports" "$snapshot/backups.tsv" "$directory/" || return 1
    printf 'certificate-renewal\n' > "$directory/operation" || return 1
    cne_render_pki "$directory/pki" "${CNE_HOSTS[1]}" || return 1
    ca=$(sha256sum "$directory/pki/ca.crt" | awk '{print $1}') || return 1
    CNE_TRANSACTION_BACKUPS=('' '' ''); idx=0
    while IFS=$'\t' read -r role path extra; do
        [[ $role == "${CNE_ROLES[$idx]}" && -z $extra ]] || return 1
        CNE_TRANSACTION_BACKUPS[$idx]=$path; idx=$((idx+1))
    done < "$directory/backups.tsv"
    [[ $idx == 3 ]] || return 1
    for idx in 0 1 2; do
        role=${CNE_ROLES[$idx]}; stage=$directory/tls-$role
        mkdir -m 700 "$stage" || return 1
        cp "$directory/pki/ca.crt" "$stage/ca.crt" && cp "$directory/pki/$role.crt" "$stage/node.crt" && cp "$directory/pki/$role.key" "$stage/node.key" || return 1
        tar -czf "$directory/$role.tls.tar.gz" -C "$stage" ca.crt node.crt node.key || return 1
        info=$(cne_remote "$idx" maintenance-info) || return 1
        [[ $info == "${infos[$idx]}" ]] || { cne_error '生成证书时节点状态发生变化，未开始更新。'; return 1; }
    done
    cne_transaction_begin "$directory" "$id" || return 1
    for idx in 1 2 0; do
        role=${CNE_ROLES[$idx]}; before=$(cne_field "${infos[$idx]}" deployment)
        cne_note "更新${CNE_LABELS[$idx]}传输证书…"
        CNE_TRANSACTION_ATTEMPTED+=("$idx")
        printf '%s\n' "$idx" >> "$directory/attempted.txt" || { cne_transaction_abort || :; return 1; }
        if ! cne_remote_payload "$idx" certificate-apply "$directory/$role.tls.tar.gz" "$before" "$id"; then cne_transaction_abort || :; return 1; fi
    done
    for idx in 0 1 2; do
        info=$(cne_remote "$idx" maintenance-info) || { cne_transaction_abort || :; return 1; }
        if ! cne_backup_info_valid "$info" "${CNE_ROLES[$idx]}" || ! cne_renew_state_same "${infos[$idx]}" "$info" || [[ $(cne_field "$info" deployment) != "$id" || $(cne_field "$info" ca_sha256) != "$ca" ]]; then
            cne_transaction_abort || :; return 1
        fi
    done
    if cne_backup_active_chain "$snapshot"; then
        if ! cne_verify_install; then cne_transaction_abort || :; return 1; fi
    else cne_note '已保留原来的服务启停状态；存在未启动的服务，本次不宣称链路可用。'; fi
    if ! cne_renew_publish "$directory" "$id" || ! cne_maintenance_commit "$directory" "$id"; then cne_transaction_abort || :; return 1; fi
    printf '\n证书已更新，设备配置无需重新导入。\n节点证书有效期：'
    openssl x509 -in "$directory/pki/hk.crt" -noout -enddate || :
    printf '更新前备份：%s\n' "$snapshot"
}
cne_renew_publish() {
    local directory=$1 id=$2
    [[ ! -L $CNE_STATE/current-deployment ]] || return 1
    if [[ -e $CNE_STATE/current-deployment ]]; then cne_backup_regular "$CNE_STATE/current-deployment" && cp "$CNE_STATE/current-deployment" "$directory/previous-deployment" || return 1; fi
    : > "$directory/local-publish.started" || return 1
    printf '%s\n' "$id" > "$CNE_TEMP/renewed-deployment" && mv "$CNE_TEMP/renewed-deployment" "$CNE_STATE/current-deployment"
}
cne_renew_auto() {
    local idx due=0 field value
    CNE_NONINTERACTIVE=1
    cne_require_config && cne_bootstrap maintenance || return 1
    cne_transaction_recover || return 1
    cne_renew_collect || return 1
    for idx in 0 1 2; do
        for field in cert_due ca_due; do
            value=$(cne_field "${CNE_RENEW_INFOS[$idx]}" "$field")
            [[ $value == 0 || $value == 1 ]] || { cne_error '节点未提供有效的证书到期状态。'; return 1; }
            [[ $value != 1 ]] || due=1
        done
    done
    if ((due)); then cne_renew_certificates automatic
    else printf '证书有效期超过 30 天，无需更新。\n'; fi
}
cne_renew_noninteractive_probe() (
    local idx
    CNE_NONINTERACTIVE=1; CNE_AUTH_READY=(0 0 0); CNE_PASSWORDS=('' '' ''); CNE_SUDOS=('' '' '')
    for idx in 0 1 2; do
        cne_authenticate "$idx" && cne_remote "$idx" maintenance-info >/dev/null || { cne_error "${CNE_LABELS[$idx]}无法无交互维护。需要不带密码的 SSH 密钥及 root 或免密码 sudo；本机节点需要 root 或免密码 sudo。"; return 1; }
    done
)
cne_renew_timer_id() {
    [[ $CNE_STATE == /* && $CNE_STATE != *$'\n'* && $CNE_STATE != *$'\r'* && $HOME != *$'\n'* && $HOME != *$'\r'* ]] || return 1
    CNE_RENEW_TIMER_ID=$(printf '%s' "$CNE_STATE" | sha256sum | awk '{print substr($1,1,12)}') || return 1
    [[ $CNE_RENEW_TIMER_ID =~ ^[a-f0-9]{12}$ ]]
}
cne_renew_unit_quote() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//%/%%}
    printf '"%s"' "$value"
}
cne_renew_timer_files() {
    local directory=$1 unit=cn-egress-renew-$CNE_RENEW_TIMER_ID uid
    uid=$(id -u) || return 1
    [[ $uid =~ ^[0-9]+$ ]] || return 1
    cat > "$directory/service" <<EOF_SERVICE
# Managed by cn-egress-oneclick; owner $CNE_RENEW_TIMER_ID
[Unit]
Description=cn-egress certificate maintenance
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=$uid
UMask=0077
Environment=$(cne_renew_unit_quote "HOME=$HOME")
Environment=$(cne_renew_unit_quote "CNE_HOME=$CNE_STATE")
Environment=CNE_NONINTERACTIVE=1
ExecStart=/usr/local/lib/$unit/manager.sh renew-auto
TimeoutStartSec=40min
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=15min
EOF_SERVICE
    cat > "$directory/timer" <<EOF_TIMER
# Managed by cn-egress-oneclick; owner $CNE_RENEW_TIMER_ID
[Unit]
Description=cn-egress daily certificate check
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h
Unit=$unit.service
[Install]
WantedBy=timers.target
EOF_TIMER
}
# Runs only through cne_root. Names and root-owned receipts constrain all writes.
cne_renew_timer_root() {
    local action=$1 identifier=$2 input=${3:-} unit directory service timer receipt pending candidate file mode expected proposed actual path drops base suffix proof stage temporary
    cne_timer_publish_candidate() {
        local item destination permission staged
        for item in manager.sh service timer; do
            case $item in manager.sh) destination=$directory/manager.sh; permission=755;; service) destination=$service; permission=644;; timer) destination=$timer; permission=644;; esac
            staged=$(mktemp "${destination%/*}/.cn-egress-renew.XXXXXXXX") || return 1
            if ! install -o 0 -g 0 -m "$permission" "$candidate/$item" "$staged" || ! mv "$staged" "$destination"; then rm -f "$staged"; return 1; fi
        done
        mv "$pending" "$receipt" && rm -rf "$candidate"
    }
    [[ $(id -u) == 0 && $identifier =~ ^[a-f0-9]{12}$ && ( $action == enable || $action == disable ) ]] || return 1
    unit=cn-egress-renew-$identifier; directory=/usr/local/lib/$unit
    service=/etc/systemd/system/$unit.service; timer=/etc/systemd/system/$unit.timer
    receipt=$directory/ownership; pending=$directory/ownership.pending; candidate=$directory/candidate
    for path in /usr /usr/local /usr/local/lib /etc /etc/systemd /etc/systemd/system; do
        [[ -d $path && ! -L $path && -O $path ]] || return 1
        mode=$(stat -c %a "$path") || return 1; (( (8#$mode & 022)==0 )) || return 1
    done
    # systemd also applies global and dashed-prefix drop-ins to new units.
    for base in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        for suffix in service timer; do
            for file in "$suffix.d" "cn-.$suffix.d" "cn-egress-.$suffix.d" "cn-egress-renew-.$suffix.d" "$unit.$suffix.d"; do
                [[ ! -e $base/$file && ! -L $base/$file ]] || return 1
            done
        done
    done
    if [[ -e $directory || -L $directory ]]; then
        [[ -d $directory && ! -L $directory && -O $directory ]] || return 1
        mode=$(stat -c %a "$directory") || return 1; (( (8#$mode & 022)==0 )) || return 1
        if [[ -e $candidate || -L $candidate ]]; then
            [[ -d $candidate && ! -L $candidate && -O $candidate ]] || return 1
            mode=$(stat -c %a "$candidate") || return 1; (( (8#$mode & 022)==0 )) || return 1
            [[ $(find "$candidate" -mindepth 1 -maxdepth 1 | wc -l) == 4 ]] || return 1
            [[ -f $candidate/ownership && ! -L $candidate/ownership && -O $candidate/ownership && $(wc -l < "$candidate/ownership") == 4 && $(head -n 1 "$candidate/ownership") == "$unit" ]] || return 1
            for file in 2 3 4; do
                case $file in 2) path=$candidate/manager.sh;; 3) path=$candidate/service;; 4) path=$candidate/timer;; esac
                expected=$(sed -n "${file}p" "$candidate/ownership")
                [[ -f $path && ! -L $path && -O $path && $expected =~ ^[a-f0-9]{64}$ && $(sha256sum "$path" | awk '{print $1}') == "$expected" ]] || return 1
                mode=$(stat -c %a "$path") || return 1; (( (8#$mode & 022)==0 )) || return 1
            done
            if [[ ! -e $pending && ! -L $pending ]]; then
                temporary=$(mktemp "$directory/.pending.XXXXXXXX") || return 1
                cp "$candidate/ownership" "$temporary" && chmod 600 "$temporary" && mv "$temporary" "$pending" || return 1
            else cmp -s "$candidate/ownership" "$pending" || return 1; fi
        fi
        for proof in "$receipt" "$pending"; do
            [[ -e $proof || -L $proof ]] || continue
            [[ -f $proof && ! -L $proof && -O $proof && $(wc -l < "$proof") == 4 ]] || return 1
            mode=$(stat -c %a "$proof") || return 1; (( (8#$mode & 022)==0 )) || return 1
            [[ $(sed -n '1p' "$proof") == "$unit" ]] || return 1
            for file in 2 3 4; do expected=$(sed -n "${file}p" "$proof"); [[ $expected =~ ^[a-f0-9]{64}$ ]] || return 1; done
        done
        if [[ ! -f $receipt && ! -f $pending ]]; then
            # Only a completely empty reserved directory can be retried here.
            [[ $action == enable && -z $(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) && ! -e $service && ! -L $service && ! -e $timer && ! -L $timer ]] || return 1
        fi
        for file in 2 3 4; do
            case $file in 2) path=$directory/manager.sh;; 3) path=$service;; 4) path=$timer;; esac
            expected=''; proposed=''
            [[ ! -f $receipt ]] || expected=$(sed -n "${file}p" "$receipt")
            [[ ! -f $pending ]] || proposed=$(sed -n "${file}p" "$pending")
            if [[ ! -e $path && ! -L $path ]]; then
                [[ -z $expected && ( -n $proposed || ! -f $receipt && ! -f $pending ) ]] || return 1
                continue
            fi
            [[ -f $path && ! -L $path && -O $path ]] || return 1
            mode=$(stat -c %a "$path") || return 1; (( (8#$mode & 022)==0 )) || return 1
            actual=$(sha256sum "$path" | awk '{print $1}') || return 1
            [[ $actual == "$expected" || $actual == "$proposed" ]] || return 1
        done
        for file in "$unit.service" "$unit.timer"; do
            path=$(systemctl show "$file" -p FragmentPath --value 2>/dev/null) || path=''
            drops=$(systemctl show "$file" -p DropInPaths --value 2>/dev/null) || drops=''
            [[ ( -z $path || $path == "/etc/systemd/system/$file" ) && -z $drops ]] || return 1
        done
    else
        [[ $action == enable && ! -e $service && ! -L $service && ! -e $timer && ! -L $timer ]] || return 1
        for file in "$unit.service" "$unit.timer"; do
            path=$(systemctl show "$file" -p FragmentPath --value 2>/dev/null) || path=''
            drops=$(systemctl show "$file" -p DropInPaths --value 2>/dev/null) || drops=''
            [[ -z $path && -z $drops ]] || return 1
        done
    fi
    # Finish an interrupted publication before accepting another version.
    if [[ -f $pending ]]; then
        [[ -d $candidate && ! -L $candidate && -O $candidate ]] || return 1
        mode=$(stat -c %a "$candidate") || return 1; (( (8#$mode & 022)==0 )) || return 1
        [[ $(find "$candidate" -mindepth 1 -maxdepth 1 | wc -l) == 4 ]] || return 1
        for file in 2 3 4; do
            case $file in 2) path=$candidate/manager.sh;; 3) path=$candidate/service;; 4) path=$candidate/timer;; esac
            [[ -f $path && ! -L $path && -O $path ]] || return 1
            expected=$(sed -n "${file}p" "$pending")
            [[ $(sha256sum "$path" | awk '{print $1}') == "$expected" ]] || return 1
        done
        [[ -f $candidate/ownership && ! -L $candidate/ownership && -O $candidate/ownership ]] && cmp -s "$candidate/ownership" "$pending" || return 1
        cne_timer_publish_candidate || return 1
    fi
    if [[ $action == disable ]]; then
        systemctl daemon-reload && systemctl disable --now "$unit.timer" || return 1
        # Cancel only a deferred retry; an actual in-progress transaction finishes.
        if [[ $(systemctl show "$unit.service" -p SubState --value) == auto-restart ]]; then systemctl stop "$unit.service" || return 1; fi
        return 0
    fi
    [[ -d $input && ! -L $input ]] || return 1
    for file in service timer manager.sh; do [[ -f $input/$file && ! -L $input/$file ]] || return 1; done
    [[ $(head -n 1 "$input/service") == "# Managed by cn-egress-oneclick; owner $identifier" && $(head -n 1 "$input/timer") == "# Managed by cn-egress-oneclick; owner $identifier" ]] || return 1
    bash -n "$input/manager.sh" || return 1
    [[ ! -e $candidate && ! -L $candidate ]] || return 1
    stage=$(mktemp -d /usr/local/lib/.cn-egress-renew.XXXXXXXX) || return 1
    install -o 0 -g 0 -m 755 "$input/manager.sh" "$stage/manager.sh" && install -o 0 -g 0 -m 644 "$input/service" "$stage/service" && install -o 0 -g 0 -m 644 "$input/timer" "$stage/timer" || { rm -rf "$stage"; return 1; }
    { printf '%s\n' "$unit"; sha256sum "$stage/manager.sh" "$stage/service" "$stage/timer" | awk '{print $1}'; } > "$stage/ownership" || { rm -rf "$stage"; return 1; }
    chmod 600 "$stage/ownership" && mkdir -p "$directory" && chmod 755 "$directory" || { rm -rf "$stage"; return 1; }
    # Publish recovery evidence before any service/program file changes.
    mv "$stage" "$candidate" || return 1
    temporary=$(mktemp "$directory/.pending.XXXXXXXX") || return 1
    cp "$candidate/ownership" "$temporary" && chmod 600 "$temporary" && mv "$temporary" "$pending" || return 1
    cne_timer_publish_candidate || return 1
    systemctl daemon-reload && systemctl enable --now "$unit.timer"
}
cne_renew_timer_call() {
    local action=$1 input=${2:-} helper=$CNE_TEMP/renew-timer-helper
    { printf '#!/usr/bin/env bash\nset -uo pipefail\n'; declare -f cne_renew_timer_root; printf '\ncne_renew_timer_root "$@"\n'; } > "$helper" || return 1
    cne_root /bin/bash "$helper" "$action" "$CNE_RENEW_TIMER_ID" "$input" || { cne_error '定时维护设置未完成。若存在同名服务、外部修改或额外配置，脚本会停止以保护现有服务。'; return 1; }
}
cne_renew_timer_enable() {
    local directory script=${BASH_SOURCE[0]}
    cne_mutation_guard && cne_require_config && cne_bootstrap maintenance && cne_renew_timer_id || return 1
    [[ ! -L $CNE_STATE/auto-renew && ( ! -e $CNE_STATE/auto-renew || -f $CNE_STATE/auto-renew && -O $CNE_STATE/auto-renew ) ]] || { cne_error '自动维护记录不安全，未更改定时任务。'; return 1; }
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || { cne_error '自动维护需要运行 systemd 的 Linux 管理机；其他系统可以使用手动续期。'; return 1; }
    # The source module cannot be installed as a standalone scheduled command.
    script=${CNE_RUNNING_SCRIPT:-$script}
    [[ -f $script && ! -L $script && -r $script ]] && grep -Fq 'cne_node_source()' "$script" || { cne_error '请使用发布的单文件脚本设置自动续期。'; return 1; }
    cne_renew_noninteractive_probe || return 1
    printf '\n每天检查证书，仅在有效期不足 30 天时续期。不会保存 SSH 或 sudo 密码。\n管理机需保持运行；原来的设备配置保持不变。\n'
    cne_prompt '启用自动续期（y/N）' N || return 1
    [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消。\n'; return 0; }
    directory=$(mktemp -d "$CNE_TEMP/renew-timer.XXXXXXXX") || return 1
    cp "$script" "$directory/manager.sh" && cne_renew_timer_files "$directory" && cne_renew_timer_call enable "$directory" || return 1
    printf '%s\n' "$CNE_RENEW_TIMER_ID" > "$CNE_TEMP/auto-renew" && mv "$CNE_TEMP/auto-renew" "$CNE_STATE/auto-renew" || return 1
    printf '自动续期已启用。可在本菜单查看状态和日志。\n'
}
cne_renew_timer_disable() {
    cne_renew_timer_id || return 1
    if [[ ! -e $CNE_STATE/auto-renew && ! -L $CNE_STATE/auto-renew ]]; then printf '当前管理目录未启用自动续期。\n'; return 0; fi
    [[ -f $CNE_STATE/auto-renew && ! -L $CNE_STATE/auto-renew && -O $CNE_STATE/auto-renew && $(cat "$CNE_STATE/auto-renew") == "$CNE_RENEW_TIMER_ID" ]] || { cne_error '自动维护记录不安全，未更改定时任务。'; return 1; }
    cne_renew_timer_call disable || return 1
    rm -f "$CNE_STATE/auto-renew" || return 1
    printf '自动续期已关闭；已开始的维护会继续完成。\n'
}
cne_renew_timer_status() {
    cne_renew_timer_id || return 1
    if [[ ! -e $CNE_STATE/auto-renew && ! -L $CNE_STATE/auto-renew ]]; then printf '当前管理目录未启用自动续期。\n'; return 0; fi
    [[ -f $CNE_STATE/auto-renew && ! -L $CNE_STATE/auto-renew && -O $CNE_STATE/auto-renew && $(cat "$CNE_STATE/auto-renew") == "$CNE_RENEW_TIMER_ID" ]] || { cne_error '自动维护记录不安全。'; return 1; }
    systemctl --no-pager status "cn-egress-renew-$CNE_RENEW_TIMER_ID.timer" || :
    journalctl --no-pager -u "cn-egress-renew-$CNE_RENEW_TIMER_ID.service" -n 20 || cne_note '当前用户无权查看系统日志，请使用 sudo journalctl 查看该服务。'
}
cne_renew_menu() {
    while :; do
        printf '\n证书续期与自动维护\n'; cne_line
        printf '  1. 立即更新证书\n  2. 启用每天自动检查\n  3. 关闭自动检查\n  4. 查看定时维护状态和日志\n  0. 返回\n'
        cne_prompt '请选择' || return 0
        case $CNE_ANSWER in 1) cne_renew_certificates || cne_note '证书更新未完成。';; 2) cne_renew_timer_enable || :;; 3) cne_renew_timer_disable || :;; 4) cne_renew_timer_status || :;; 0) return 0;; *) cne_note '请输入菜单中的编号。';; esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then cne_main "$@"; fi
