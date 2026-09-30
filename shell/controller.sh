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
