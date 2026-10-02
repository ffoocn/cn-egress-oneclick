#!/usr/bin/env bash
# Bash controller. The release builder embeds all required Shell sources.
CNE_VERSION=2.2.2
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
    printf '\n'
    if [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then printf '节点设置无效。菜单 2 重新填写，原文件会保留。\n'
    else printf '节点尚未配置。菜单 1 安装 / 2 修改节点。\n'; fi
    printf '管理目录：%s\n' "$CNE_STATE"
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
cne_menu_show() {
    printf '\n'; cne_line
    printf '  一键安装与管理  v%s\n' "$CNE_VERSION"
    cne_line
    printf '\n  1. 一键安装\n  2. 修改节点\n  3. 查看状态\n  4. 连接诊断\n\n'
    printf '  5. 启动服务\n  6. 停止服务\n  7. 重启服务\n  8. 查看日志\n  9. 备份配置\n\n'
    printf '  10. 客户端列表\n  11. 添加客户端\n  12. 显示配置与二维码\n  13. 撤销客户端\n\n'
    printf '  14. 卸载服务\n'
    [[ ! -e $CNE_STATE/active-transaction && ! -L $CNE_STATE/active-transaction ]] || printf '  15. 重试恢复上次未完成操作\n'
    printf '  16. 恢复历史备份\n  17. 证书续期与自动维护\n  18. 配置下载来源\n  19. 组件离线包\n'
    printf '  m. 显示菜单\n  0. 退出\n\n'
}
cne_menu() {
    local choice prompt
    cne_menu_show
    while :; do
        prompt='请选择（m 菜单 / 0 退出）'
        [[ ! -e $CNE_STATE/active-transaction && ! -L $CNE_STATE/active-transaction ]] || prompt='请选择（15 恢复未完成操作 / m 菜单 / 0 退出）'
        cne_prompt "$prompt" || return 0; choice=$CNE_ANSWER
        case $choice in
            0) return 0;;
            m|M) cne_menu_show;;
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
            *) cne_note '请输入编号，或输入 m 查看菜单。';;
        esac
        printf '\n'
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
