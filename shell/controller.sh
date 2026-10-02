#!/usr/bin/env bash
# Bash controller. The release builder embeds all required Shell sources.
CNE_VERSION=2.4.0
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
CNE_INPUT_ENDED=0
CNE_USER_PORT=51820
CNE_WSS_PORT=443
CNE_TRANSACTION_ACTIVE=0
CNE_TRANSACTION_DIRECTORY=''
CNE_TRANSACTION_ID=''
CNE_TRANSACTION_ATTEMPTED=()
CNE_TRANSACTION_BACKUPS=('' '' '')

cne_error() { printf '\n错误：%s\n' "$*" >&2; cne_result_event '错误' "$*"; return 1; }
cne_note() { printf '%s\n' "$*" >&2; }
cne_line() { printf '%s\n' '----------------------------------------'; }
cne_ui_interactive() { [[ -t 0 && -t 1 ]]; }
cne_ui_clear() {
    # Clear the display and saved lines; web consoles can leave TERM unset.
    if cne_ui_interactive; then printf '\033[H\033[2J\033[3J'; fi
}
cne_prompt_print() {
    if cne_ui_interactive; then printf "$@"; else printf "$@" >&2; fi
}
cne_ui_header() {
    cne_ui_clear
    printf '%s  v%s\n' "$1" "$CNE_VERSION"
    cne_line
    printf '\n'
}
cne_ui_pause() {
    local answer
    [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 1
    cne_ui_interactive || return 0
    cne_prompt_print '\n按回车返回…'
    IFS= read -r answer || { CNE_INPUT_ENDED=1; cne_prompt_print '\n'; return 1; }
}
cne_ui_action() {
    local title=$1 failure=$2 CNE_UI_PAGE=$1 result=0
    shift 2
    cne_ui_header "$title"
    cne_result_begin "$title"
    if ! "$@"; then
        result=1
        if [[ ${CNE_INPUT_ENDED:-0} != 0 ]]; then cne_result_finish '输入已结束；已提交操作仍保持，未提交设置没有保存。'; return 1; fi
        cne_note "$failure"
    fi
    if ((result)); then cne_result_event '下一步' "$failure 请查看上方具体原因，或到状态与服务进行连接诊断。"; cne_result_finish '未全部完成'
    else cne_result_finish '操作已结束（取消或设备导入待完成时，以页面说明为准）'; fi
    cne_ui_pause
}
# Store structured controller events only. Never tee configuration, QR codes,
# prompts, passwords, remote logs or arbitrary command output into a report.
cne_result_event() {
    local kind=$1 message=${2:-} safe
    [[ -n ${CNE_RESULT_FILE:-} && -f $CNE_RESULT_FILE && ! -L $CNE_RESULT_FILE && -O $CNE_RESULT_FILE ]] || return 0
    safe=$(printf '%s\n' "$message" | LC_ALL=C sed -E 's/[A-Za-z0-9+\/]{43}=/[已隐藏密钥]/g; s/(PrivateKey|PresharedKey|password|Password|密码|口令)[[:space:]]*[:=：].*/\1：[已隐藏]/g; s/[[:cntrl:]]/ /g') || return 0
    printf '%s：%.2000s\n' "$kind" "$safe" >> "$CNE_RESULT_FILE" || :
}
cne_result_begin() {
    CNE_RESULT_FILE=''
    [[ -n ${CNE_TEMP:-} && -d $CNE_TEMP && -n ${CNE_STATE:-} ]] || return 0
    CNE_RESULT_FILE=$(mktemp "$CNE_TEMP/result.XXXXXXXX") || return 0
    chmod 600 "$CNE_RESULT_FILE" || { CNE_RESULT_FILE=''; return 0; }
    printf '操作：%s\n版本：%s\n时间：%s\n' "$1" "$CNE_VERSION" "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$CNE_RESULT_FILE"
}
cne_result_finish() {
    [[ -n ${CNE_RESULT_FILE:-} && -f $CNE_RESULT_FILE ]] || return 0
    cne_result_event '结果' "$1"
    if [[ ! -L $CNE_STATE/last-result && ( ! -e $CNE_STATE/last-result || -f $CNE_STATE/last-result && -O $CNE_STATE/last-result ) ]]; then
        mv "$CNE_RESULT_FILE" "$CNE_STATE/last-result" || :
    fi
    CNE_RESULT_FILE=''
}
cne_result_show() {
    local file=$CNE_STATE/last-result
    if [[ -f $file && ! -L $file && -O $file ]]; then cat "$file"
    else printf '暂无操作记录。记录只保存操作阶段和错误摘要，不包含密码、配置或二维码。\n'; fi
}
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
    [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 1
    if [[ -n $default ]]; then cne_prompt_print '%s [%s]：' "$label" "$default"; else cne_prompt_print '%s：' "$label"; fi
    IFS= read -r answer || { CNE_INPUT_ENDED=1; cne_prompt_print '\n'; return 1; }
    CNE_ANSWER=${answer:-$default}
}
cne_secret() {
    [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 1
    cne_prompt_print '%s：' "$1"
    IFS= read -r -s CNE_ANSWER || { CNE_INPUT_ENDED=1; cne_prompt_print '\n'; return 1; }
    cne_prompt_print '\n'
}
cne_setup_prompt() {
    cne_prompt "$@" || return 1
    [[ $CNE_ANSWER != 0 ]] || { cne_note '已取消节点设置，配置未保存。'; return 1; }
}
cne_mutation_guard() {
    [[ ! -e $CNE_STATE/active-transaction && ! -L $CNE_STATE/active-transaction ]] || {
        cne_error '存在尚未完成恢复的操作。请先选择“维护与设置 → 重试恢复”，恢复前可以查看状态、日志和诊断。'
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
    if [[ -n ${CNE_RESULT_FILE:-} ]]; then cne_result_finish '运行已结束或中断；未提交的设置没有保存。存在未完成恢复时，请到维护与设置继续。'; fi
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
            cne_port "$user_port" && cne_port "$wss_port" && [[ -z $extra ]] || { cne_error '端口配置格式无效，请重新填写节点。'; return 1; }
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
    if [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then printf '节点设置无效。主菜单 2 重新填写，原文件会保留。\n'
    else printf '节点尚未配置：当前账号没有管理设置，这不表示服务器未安装服务。\n首次使用：主菜单 1 安装；以前安装过：请使用原来的账号运行。\n'; fi
    printf '管理目录：%s\n' "$CNE_STATE"
    cne_manager_account_hint
}
cne_manager_account_hint() {
    local candidate account
    [[ -z ${CNE_HOME:-} && ! -f $CNE_STATE/nodes.tsv ]] || return 0
    if [[ -n ${SUDO_USER:-} && ${SUDO_USER:-} != root ]]; then
        printf '你通过 sudo 切换了账号。若之前由 %s 管理，请退出并用该账号运行；不要因此重新覆盖安装。\n' "$SUDO_USER"
    fi
    [[ $(id -u) == 0 ]] || return 0
    # Inspect existence only: never read another user's settings or credentials.
    for candidate in /home/*/.local/share/cn-egress-shell/nodes.tsv /root/.local/share/cn-egress-shell/nodes.tsv; do
        [[ $candidate != "$CNE_STATE/nodes.tsv" && -f $candidate && ! -L $candidate ]] || continue
        account=${candidate#/home/}; account=${account%%/*}; [[ $candidate != /root/* ]] || account=root
        printf '检测到账号 %s 曾保存管理设置。请先确认原账号；此处不会读取或覆盖它的配置。\n' "$account"
    done
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
cne_setup_address_valid() {
    local role=$1 address=$2 a b c d
    if [[ $role != 2 ]]; then cne_public_ipv4_candidate "$address"; return; fi
    cne_ipv4 "$address" || return 1
    IFS=. read -r a b c d <<< "$address"
    ((a!=0 && a!=127 && a<224 && !(a==169 && b==254))) || return 1
    [[ $address != 192.0.2.* && $address != 198.51.100.* && $address != 203.0.113.* ]]
}
cne_setup() {
    local idx host user port identity connection default candidate local_count=0 user_port wss_port had_ports=0 changed=0 deployment_changed=0 previous='' advanced=0 machine current_user login_description field old new had_settings=0
    local hosts=() users=() ports=() identities=() connections=()
    cne_mutation_guard || return 1
    for identity in nodes.tsv ports; do
        [[ ! -L $CNE_STATE/$identity && ( ! -e $CNE_STATE/$identity || -f $CNE_STATE/$identity && -O $CNE_STATE/$identity ) ]] || { cne_error "原设置文件不安全：${identity}。请检查文件归属或链接。"; return 1; }
    done
    candidate=$(cne_local_ipv4)
    machine=$(hostname 2>/dev/null) || machine=${HOSTNAME:-未知}
    current_user=$(id -un) || return 1
    printf '\n配置安装节点\n当前运行：%s（网卡地址：%s，账号：%s）。\n' "$machine" "${candidate:-未检测到}" "$current_user"
    printf '建议在国内出口机运行；“本机”就是当前这台服务器。大陆中转只填上海或北京中的一台。\n输入 0 取消，回车使用提示中的默认值。\n'
    if [[ -f $CNE_STATE/nodes.tsv && -n ${CNE_HOSTS[0]} ]]; then
        had_settings=1
        printf '推荐设置会保留现有登录方式和端口；需要修改这些项目时选择高级设置。\n'
    else printf '推荐设置使用密码登录，登录端口 22；手机连接端口 51820，大陆中转连接端口 443。\n'; fi
    while :; do
        cne_setup_prompt '设置方式（1 推荐设置 / 2 高级：登录方式与端口）' 1 || return 1
        case $CNE_ANSWER in 1) break;; 2) advanced=1; break;; *) cne_note '请输入 1 或 2。';; esac
    done
    for idx in 0 1 2; do
        printf '\n%s\n' "${CNE_LABELS[$idx]}"
        default=1; [[ ${CNE_CONNECTIONS[$idx]:-ssh} != local ]] || default=2
        while :; do
            cne_setup_prompt '  连接方式（1 远程服务器 SSH / 2 当前这台本机）' "$default" || return 1
            case $CNE_ANSWER in
                1) connection=ssh; break;;
                2) if ((local_count==0)); then connection=local; local_count=1; break; fi; cne_note '  本机已经用于另一个角色，请为此节点选择 SSH。';;
                *) cne_note '  请输入 1 或 2。';;
            esac
        done
        default=${CNE_HOSTS[$idx]}
        if [[ $connection == local ]]; then
            cne_note "  将在当前机器 $machine 执行${CNE_LABELS[$idx]}的管理命令，不会登录你填写的对外地址。请确认当前已登录这台角色对应的服务器。"
            cne_note '  本机直接执行管理命令，不需要填写 SSH 登录信息。'
            if [[ -z $default ]]; then
                if [[ $idx == 2 ]] || cne_public_ipv4_candidate "$candidate"; then default=$candidate
                elif [[ -n $candidate ]]; then cne_note "  检测到本机网卡地址：${candidate}。公网入口请填写云服务器公网地址或路由器映射地址。"; fi
            fi
        fi
        case $idx in
            0) cne_note '  此地址用于手机和电脑连接香港入口；选择本机管理仍需对外连接地址。';;
            1) cne_note '  此地址用于其他节点连接大陆中转，并写入传输证书。';;
            2) [[ $connection != local ]] || cne_note '  此地址记录国内出口的节点身份，可使用本机局域网地址。';;
        esac
        while :; do
            cne_setup_prompt '  IPv4 地址' "$default" || return 1; host=$CNE_ANSWER
            if ! cne_ipv4 "$host"; then cne_note '  地址格式不正确，请填写四段数字，例如 10.200.10.2。'; continue; fi
            if ! cne_setup_address_valid "$idx" "$host"; then
                if [[ $idx == 0 ]]; then cne_note '  这个地址不能作为手机的公网入口。请复制香港服务器控制台中的“公网 IPv4”，不要填内网地址。'
                elif [[ $idx == 1 ]]; then cne_note '  大陆中转需要公网 IPv4，香港和国内出口机才能连接。请复制云服务器控制台中的“公网 IPv4”。'
                else cne_note '  这个地址不能用于连接服务器；请填写国内出口机的局域网 IPv4 或公网 IPv4。'; fi
                continue
            fi
            if ((${#hosts[@]})); then
                for field in "${hosts[@]}"; do [[ $host != "$field" ]] || break; done
                if [[ $host == "$field" ]]; then cne_note '  这个地址已经用于前面的节点。三个角色需要不同机器，请重新填写。'; continue; fi
            fi
            break
        done
        if [[ $connection == local ]]; then
            user=$current_user; port=22; identity=-
            hosts[$idx]=$host; users[$idx]=$user; ports[$idx]=$port; identities[$idx]=$identity; connections[$idx]=local
            cne_note '  使用本机管理，不需要 SSH 登录。'
            continue
        fi
        while :; do cne_setup_prompt '  登录账号（SSH 用户，由服务器提供，通常 root）' "${CNE_USERS[$idx]}" || return 1; user=$CNE_ANSWER; [[ $user =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] && break; cne_note '  用户名格式不正确，请使用服务器提供的登录账号。'; done
        port=${CNE_PORTS[$idx]}; identity=${CNE_IDENTITIES[$idx]}
        if ((advanced)); then
            while :; do cne_setup_prompt '  登录端口（SSH 端口，通常 22）' "$port" || return 1; port=$CNE_ANSWER; cne_port "$port" && break; cne_note '  端口范围为 1–65535。'; done
            while :; do
                cne_setup_prompt '  SSH 私钥绝对路径（- 使用密码）' "$identity" || return 1; identity=$CNE_ANSWER
                [[ $identity != *$'\t'* && $identity != *$'\n'* && ( $identity == - || $identity == /* && -f $identity && -r $identity ) ]] && break
                cne_note '  文件不存在或不可读，请填写完整文件路径；使用密码登录时输入 -。'
            done
        elif [[ $identity != - && ( ! -f $identity || ! -r $identity ) ]]; then
            cne_error "${CNE_LABELS[$idx]}保存的私钥文件不可读。请重新选择“2. 修改节点 → 高级设置”更新登录方式或路径；原设置尚未改动。"; return 1
        fi
        hosts[$idx]=$host; users[$idx]=$user; ports[$idx]=$port; identities[$idx]=$identity; connections[$idx]=ssh
    done
    [[ ${hosts[0]} != "${hosts[1]}" && ${hosts[0]} != "${hosts[2]}" && ${hosts[1]} != "${hosts[2]}" ]] || { cne_error '三个角色需要不同机器，大陆中转只填一台。'; return 1; }
    user_port=$CNE_USER_PORT; wss_port=$CNE_WSS_PORT
    if ((advanced)); then
        while :; do
            cne_setup_prompt '手机连接端口（客户端 UDP 端口）' "$user_port" || return 1
            if cne_port "$CNE_ANSWER"; then break
            else cne_note '端口范围为 1–65535。'; fi
        done
        user_port=$CNE_ANSWER
        while :; do cne_setup_prompt '大陆中转连接端口（TLS 端口）' "$wss_port" || return 1; cne_port "$CNE_ANSWER" && break; cne_note '端口范围为 1–65535。'; done
        wss_port=$CNE_ANSWER
    fi
    printf '\n请核对安装节点\n'
    for idx in 0 1 2; do
        if [[ ${connections[$idx]} == local ]]; then printf '  %s：%s，当前本机 %s（账号 %s）\n' "${CNE_LABELS[$idx]}" "${hosts[$idx]}" "$machine" "${users[$idx]}"
        else
            login_description=密码登录; [[ ${identities[$idx]} == - ]] || login_description="私钥文件 ${identities[$idx]}"
            printf '  %s：%s，远程登录 %s，端口 %s，%s\n' "${CNE_LABELS[$idx]}" "${hosts[$idx]}" "${users[$idx]}" "${ports[$idx]}" "$login_description"
        fi
    done
    printf '  手机连接端口：UDP %s；大陆中转连接端口：TCP %s\n' "$user_port" "$wss_port"
    if ((had_settings)); then
        for idx in 0 1 2; do
            for field in host user port identity connection; do
                case $field in
                    host) old=${CNE_HOSTS[$idx]}; new=${hosts[$idx]}; login_description=地址;;
                    user) old=${CNE_USERS[$idx]}; new=${users[$idx]}; login_description=登录账号;;
                    port) old=${CNE_PORTS[$idx]}; new=${ports[$idx]}; login_description=登录端口;;
                    identity) old=${CNE_IDENTITIES[$idx]}; new=${identities[$idx]}; login_description=登录凭据文件;;
                    connection) old=${CNE_CONNECTIONS[$idx]}; new=${connections[$idx]}; login_description=连接方式; [[ $old != ssh ]] || old=远程服务器; [[ $old != local ]] || old=当前本机; [[ $new != ssh ]] || new=远程服务器; [[ $new != local ]] || new=当前本机;;
                esac
                if [[ $old != "$new" ]]; then
                    changed=1; [[ $field != host ]] || deployment_changed=1
                    printf '  变更 %s%s：%s → %s\n' "${CNE_LABELS[$idx]}" "$login_description" "$old" "$new"
                fi
            done
        done
        [[ $user_port == "$CNE_USER_PORT" ]] || { changed=1; deployment_changed=1; printf '  变更手机连接端口：%s → %s\n' "$CNE_USER_PORT" "$user_port"; }
        [[ $wss_port == "$CNE_WSS_PORT" ]] || { changed=1; deployment_changed=1; printf '  变更大陆中转连接端口：%s → %s\n' "$CNE_WSS_PORT" "$wss_port"; }
        if ((changed)); then
            if ((deployment_changed)); then printf '保存设置不会迁移或停止旧服务器服务。此后菜单操作将使用新地址。\n请通过“1. 一键安装”部署新的整套配置；旧服务器需使用旧设置单独停止或卸载。\n'
            else printf '本次只调整管理登录设置，不会修改服务器上的 VPN 服务或手机配置。\n'; fi
        fi
    fi
    if [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then printf '原节点设置无法加载。确认保存前会先保留原文件。\n'; fi
    cne_prompt '确认保存以上节点设置（y/N）' N || return 1
    [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消，原节点设置保留，未修改服务器。\n'; return 0; }
    if ((changed)) || [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then
        previous=$(mktemp -d "$CNE_STATE/history/node-settings.XXXXXXXX") || return 1
        for identity in nodes.tsv ports; do [[ ! -f $CNE_STATE/$identity ]] || cp -p "$CNE_STATE/$identity" "$previous/$identity" || return 1; done
        printf '旧节点设置已保存：%s\n' "$previous"
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
    local result=0
    cne_send_script "$idx" "$script" || result=$?
    if [[ $result != 0 ]]; then
        CNE_AUTH_READY[$idx]=0; : > "$CNE_TEMP/auth-failed-$idx"
        cne_result_event '节点操作失败' "${CNE_LABELS[$idx]} · $(cne_display_host "$idx") · $action · 返回码 ${result}。请核对这台机器的登录信息和连接诊断。"
    fi
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
    result=0; cne_send_script "$idx" "$script" || result=$?
    rm -f "$script"
    if [[ $result != 0 ]]; then
        CNE_AUTH_READY[$idx]=0; : > "$CNE_TEMP/auth-failed-$idx"
        cne_result_event '节点操作失败' "${CNE_LABELS[$idx]} · $(cne_display_host "$idx") · 安装 · 返回码 ${result}。安装记录和备份保留，请查看恢复结果。"
    fi
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
    result=0; cne_send_script "$idx" "$script" || result=$?
    rm -f "$script"
    if [[ $result != 0 ]]; then
        CNE_AUTH_READY[$idx]=0; : > "$CNE_TEMP/auth-failed-$idx"
        cne_result_event '节点操作失败' "${CNE_LABELS[$idx]} · $(cne_display_host "$idx") · $action · 返回码 ${result}。维护记录和原备份保留。"
    fi
    return "$result"
}
cne_inspect_all() {
    local idx state role
    CNE_INSPECTIONS=()
    cne_result_event '阶段' '登录并检查三台安装节点，尚未替换服务'
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
    printf '\n安装检查\n'; cne_line
    for idx in 0 1 2; do
        if ! CNE_INSPECTIONS[$idx]=$(cne_remote "$idx" inspect); then
            cne_result_event '检查失败' "${CNE_LABELS[$idx]} · $(cne_display_host "$idx")。请核对登录信息或查看连接诊断，再重试安装。"
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
        cne_error "恢复未全部完成；请选择“维护与设置 → 重试恢复”后再进行其他操作。记录：$directory"
        return 1
    fi
    printf 'rolled-back\n' > "$directory/transaction-status" || return 1
    rm -f "$CNE_STATE/active-transaction" || return 1
    cne_note '本次涉及的节点和客户端配置已恢复到操作前状态。'
    cne_note '已补齐的系统依赖、已确认启用的出口转发设置仍保留，不会随 VPN 配置回滚。'
}

cne_recovery_credentials() {
    local idx=$1 user port identity mode
    [[ ${CNE_NONINTERACTIVE:-0} != 1 ]] || { cne_error '恢复需要重新提供登录信息，请运行管理菜单 → 维护与设置 → 重试恢复。'; return 1; }
    if [[ ${CNE_CONNECTIONS[$idx]:-ssh} == local ]]; then
        CNE_AUTH_READY[$idx]=0
        printf '%s保持在当前机器恢复，请重新验证管理员权限。\n' "${CNE_LABELS[$idx]}"
        return 0
    fi
    printf '\n重新提供%s的恢复登录信息 · %s\n服务器地址、角色和原备份保持不变；输入 0 取消。恢复成功后保存登录设置，不保存密码。\n' "${CNE_LABELS[$idx]}" "${CNE_HOSTS[$idx]}"
    while :; do
        cne_prompt '登录用户名' "${CNE_USERS[$idx]}" || return 1; user=$CNE_ANSWER
        [[ $user != 0 ]] || return 1
        [[ $user =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] && break
        cne_note '请填写服务器登录用户名，例如 root。'
    done
    while :; do
        cne_prompt '登录端口' "${CNE_PORTS[$idx]}" || return 1; port=$CNE_ANSWER
        [[ $port != 0 ]] || return 1
        cne_port "$port" && break; cne_note '端口应为 1–65535，通常直接回车使用原端口。'
    done
    while :; do
        cne_prompt '登录方式（1 密码 / 2 私钥文件）' 1 || return 1; mode=$CNE_ANSWER
        case $mode in 0) return 1;; 1) identity=-; break;; 2)
            cne_prompt '当前机器上的私钥完整路径（0 取消）' || return 1; identity=$CNE_ANSWER
            [[ $identity != 0 ]] || return 1
            [[ $identity == /* && $identity != *$'\t'* && $identity != *$'\n'* && -f $identity && -r $identity ]] && break
            cne_note '找不到可读私钥。请重新选择，或选择密码登录。';;
            *) cne_note '请选择 1、2 或 0。';;
        esac
    done
    CNE_USERS[$idx]=$user; CNE_PORTS[$idx]=$port; CNE_IDENTITIES[$idx]=$identity
    CNE_AUTH_READY[$idx]=0; CNE_PASSWORDS[$idx]=''; CNE_SUDOS[$idx]=''
    CNE_RECOVERY_CREDENTIALS_CHANGED=1
    return 0
}
cne_transaction_recover() {
    local journal=$CNE_STATE/active-transaction id role backup idx line current_nodes previous_nodes refresh=${1:-retry}
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
        while IFS= read -r idx <&6; do
            [[ $idx == 0 || $idx == 1 || $idx == 2 ]] && [[ -n ${CNE_TRANSACTION_BACKUPS[$idx]} ]] || return 1
            CNE_TRANSACTION_ATTEMPTED+=("$idx")
            if [[ $refresh == credentials || ( ${CNE_CONNECTIONS[$idx]:-ssh} == ssh && ${CNE_IDENTITIES[$idx]} != - && ( ! -f ${CNE_IDENTITIES[$idx]} || ! -r ${CNE_IDENTITIES[$idx]} ) ) ]]; then
                cne_recovery_credentials "$idx" || return 1
            fi
            cne_authenticate "$idx" || return 1
        done 6< "$CNE_TRANSACTION_DIRECTORY/attempted.txt"
    fi
    CNE_TRANSACTION_ACTIVE=1
    cne_note '发现上次中断的操作，先恢复原有配置。'
    cne_transaction_abort || return 1
    if [[ ${CNE_RECOVERY_CREDENTIALS_CHANGED:-0} == 1 ]]; then
        # Do not modify the recovery identity until every node has recovered.
        [[ ! -L $CNE_STATE/nodes.tsv && -f $CNE_STATE/nodes.tsv && -O $CNE_STATE/nodes.tsv ]] || return 1
        for idx in 0 1 2; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${CNE_ROLES[$idx]}" "${CNE_HOSTS[$idx]}" "${CNE_USERS[$idx]}" "${CNE_PORTS[$idx]}" "${CNE_IDENTITIES[$idx]}" "${CNE_CONNECTIONS[$idx]}"; done > "$CNE_TEMP/recovered-nodes.tsv" || return 1
        chmod 600 "$CNE_TEMP/recovered-nodes.tsv" && mv "$CNE_TEMP/recovered-nodes.tsv" "$CNE_STATE/nodes.tsv" || { cne_error '节点已经恢复，但登录设置保存失败。请用“修改节点”保存当前登录信息。'; return 1; }
        CNE_RECOVERY_CREDENTIALS_CHANGED=0
        printf '恢复完成，已保存新的登录设置；服务器地址未改变，密码未保存。\n'
    fi
    return 0
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

cne_plan_internal_ports() {
    local idx mode data key value line count position seen
    CNE_INTERNAL_PORTS=(51831 51821 51822 51832 5354)
    for idx in 0 1 2; do
        mode=fresh; [[ $(cne_field "${CNE_INSPECTIONS[$idx]}" state) != present ]] || mode=replace
        data=$(cne_remote "$idx" plan-ports "$mode" "$CNE_USER_PORT" "$CNE_WSS_PORT") || { cne_error "${CNE_LABELS[$idx]}无法规划内部端口，未替换现有服务。"; return 1; }
        count=0; seen=' '
        while IFS= read -r line; do
            [[ $line == *=* ]] || { cne_error '内部端口规划结果不完整。'; return 1; }
            key=${line%%=*}; value=${line#*=}
            cne_port "$value" && [[ $seen != *" $key "* ]] || { cne_error '内部端口规划结果无效。'; return 1; }
            case $idx:$key in 0:hk_local) position=0;; 1:sh_hk) position=1;; 1:sh_exit) position=2;; 2:exit_local) position=3;; 2:dns) position=4;; *) cne_error '节点返回了非本角色的端口规划。'; return 1;; esac
            CNE_INTERNAL_PORTS[$position]=$value; seen+="$key "; count=$((count+1))
        done <<< "$data"
        if [[ $idx == 0 ]]; then [[ $count == 1 ]] || return 1; else [[ $count == 2 ]] || return 1; fi
    done
    [[ ${CNE_INTERNAL_PORTS[0]} != "$CNE_USER_PORT" && ${CNE_INTERNAL_PORTS[1]} != "${CNE_INTERNAL_PORTS[2]}" && ${CNE_INTERNAL_PORTS[3]} != "${CNE_INTERNAL_PORTS[4]}" ]] || { cne_error '同一节点的端口发生冲突，未继续安装。'; return 1; }
    return 0
}
cne_public_access_hint() {
    printf '\n服务器准备完成，手机/电脑连接尚未验证。\n云平台需允许以下入站连接（内部端口不需要对公网开放）：\n  香港 %s：UDP %s\n  大陆中转 %s：TCP %s\n' "${CNE_HOSTS[0]}" "$CNE_USER_PORT" "${CNE_HOSTS[1]}" "$CNE_WSS_PORT"
    printf '本次服务器检查不能确认云安全组或澳大利亚网络是否放行；无需关闭整个防火墙。\n'
    cne_result_event '验收' '服务器检查通过；设备公网连接、出口地址和税务应用尚待实际设备验证。'
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
    cne_result_event '阶段' '检查安装条件，尚未替换已有连接服务'
    cne_plan_internal_ports || return 1
    # Complete the installation plan before changing any VPN service.
    for idx in 0 1 2; do
        state=$(cne_field "${CNE_INSPECTIONS[$idx]}" state); mode=fresh; [[ $state != present ]] || mode=replace
        cne_note "检查${CNE_LABELS[$idx]}的安装条件…"
        cne_remote "$idx" preflight "$mode" "$CNE_USER_PORT" "$CNE_WSS_PORT" "${CNE_INTERNAL_PORTS[@]}" || return 1
    done
    if [[ $(cne_field "${CNE_INSPECTIONS[2]}" forwarding) != 1 ]]; then
        printf '\n出口机需要开启 IPv4 转发，才能让手机流量经国内宽带访问网络。\n这是持久的系统设置；不会改变服务器的默认路由。安装失败恢复 VPN 配置时，此设置和新增依赖仍会保留。\n'
        cne_prompt '是否允许在出口机启用（y/N）' N || return 1
        [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消安装。\n'; return 0; }
        CNE_ENABLE_FORWARDING=1
    else CNE_ENABLE_FORWARDING=0; fi
    cne_note '准备节点依赖…'
    for idx in 0 1 2; do
        cne_note "准备${CNE_LABELS[$idx]}的依赖…"
        cne_result_event '阶段' "${CNE_LABELS[$idx]}准备依赖；尚未替换连接服务"
        cne_remote "$idx" prepare awg2 || { cne_error "${CNE_LABELS[$idx]}依赖准备失败，尚未替换连接服务。修复这台机器的依赖错误后，主菜单 1 重试。"; return 1; }
    done
    for idx in 0 1 2; do cne_authenticate "$idx" || return 1; done
    cne_plan_internal_ports || return 1
    # Recheck with all inspection tools available, before rendering or replacement.
    for idx in 0 1 2; do
        state=$(cne_field "${CNE_INSPECTIONS[$idx]}" state); mode=fresh; [[ $state != present ]] || mode=replace
        refreshed=$(cne_remote "$idx" inspect) || return 1
        [[ $(cne_field "$refreshed" state) == "$state" ]] || { cne_error '检查期间节点部署发生变化，请重新执行安装。'; return 1; }
        CNE_INSPECTIONS[$idx]=$refreshed
        cne_remote "$idx" preflight "$mode" "$CNE_USER_PORT" "$CNE_WSS_PORT" "${CNE_INTERNAL_PORTS[@]}" || return 1
    done
    wan=$(cne_field "${CNE_INSPECTIONS[2]}" wan)
    [[ $wan =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { cne_error '无法识别出口机出网网卡。'; return 1; }
    token=$(openssl rand -hex 6) || return 1
    deployment=$(date -u +%Y%m%dT%H%M%SZ)-$token
    directory=$CNE_STATE/history/$deployment
    mkdir -m 700 "$directory" || return 1
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/ports" "$directory/" || return 1
    cne_note '生成安装配置和客户端文件…'
    ( set -Eeuo pipefail; cne_render_bundle "$directory/bundle" "${CNE_HOSTS[0]}" "${CNE_HOSTS[1]}" "$CNE_USER_PORT" "$CNE_WSS_PORT" "$wan" awg2 "${CNE_INTERNAL_PORTS[@]}" ) || return 1
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
        cne_result_event '阶段' "正在安装${CNE_LABELS[$idx]}；失败时自动恢复本次涉及节点"
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
    printf '\n服务器安装和链路检查完成。设备配置已保存：%s\n' "$CNE_STATE/clients"
    cne_public_access_hint
    cne_client_onboarding
    return 0
}
cne_status() {
    local idx result=0
    if ! cne_configured; then cne_unconfigured_status; return 0; fi
    if [[ ${CNE_UI_PAGE:-} != 节点状态 ]]; then printf '\n节点状态\n'; cne_line; fi
    for idx in 0 1 2; do
        printf '\n%s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"
        if ! cne_authenticate "$idx"; then
            [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 1
            cne_note '此节点认证未完成，继续查看其他节点。'; result=1; continue
        fi
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
                if ! cne_authenticate "$idx"; then
                    [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 1
                    cne_note '此节点认证未完成，继续查看其他节点。'; result=1; continue
                fi
                if ! cne_remote "$idx" "$action"; then result=1; CNE_AUTH_READY[$idx]=0; fi
            done
            return "$result";;
        start|stop|restart|uninstall) cne_mutation_guard || return 1;;
        *) cne_error '未知的节点服务操作。'; return 1;;
    esac
    cne_require_config || return 1
    if [[ $action == stop || $action == restart ]]; then
        printf '将%s三台服务器的连接服务，所有正在使用的手机和电脑都会断开。\n' "$([[ $action == stop ]] && printf '停止' || printf '重启')"
        for idx in 0 1 2; do printf '  %s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"; done
        printf '只想关闭自己的连接：请在手机或电脑的连接应用中关闭，不需要停止服务器。\n'
        [[ ${CNE_NONINTERACTIVE:-0} != 1 ]] || { cne_error '停止或重启服务器需要交互确认。'; return 1; }
        cne_prompt '确认影响所有设备（y/N）' N || return 1
        [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || { printf '已取消，服务器服务未改动。\n'; return 0; }
    fi
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
            else cne_note '服务命令已完成，但链路验证失败。请到“状态与服务”查看连接诊断或日志。'; result=1; fi
        fi
    elif [[ $action == stop ]]; then
        if ((result)); then cne_note '部分节点停止失败。请查看节点状态；不要假定所有设备都已断开。'
        else printf '\n三台服务器的连接服务已停止。已有设备配置仍保留，恢复使用请选择“启动服务器服务”。\n'; fi
    fi
    return "$result"
}
cne_clients_list() {
    cne_require_config && cne_authenticate 0 || return 1
    local name address public data
    data=$(cne_remote 0 client-list) || return 1
    printf '\n客户端列表\n'; cne_line
    if [[ -z $data ]]; then printf '暂无已确认客户端。\n'
    else
        while IFS=$'\t' read -r name address public; do
            if [[ $address =~ ^[0-9]+$ ]]; then address=10.77.10.$address; fi
            printf '  %s  %s\n' "$name" "$address"
        done <<< "$data"
    fi
    local pending
    for pending in "$CNE_STATE/clients/"*.conf.pending; do
        [[ -f $pending && ! -L $pending && -O $pending ]] || continue
        name=${pending##*/}; name=${name%.conf.pending}; cne_name "$name" || continue
        printf '  %s  等待确认；再次添加时使用同一名称继续\n' "$name"
    done
}
cne_profile_field() {
    awk -v section="$2" -v field="$3" '
      /^\[/{active=($0=="[" section "]");next}
      active && index($0,"="){key=$0;sub(/[[:space:]]*=.*/,"",key);gsub(/^[[:space:]]*/,"",key);
        if(key==field){sub(/^[^=]*=[[:space:]]*/,"");gsub(/[[:space:]]+$/,"");print;exit}}' "$1"
}
cne_client_add() {
    local name address public private psk server data current index pending user_port existing transport params='' field default_name candidate
    cne_mutation_guard && cne_require_config && cne_bootstrap client && cne_authenticate 0 || return 1
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
    default_name=''
    for candidate in "$CNE_STATE/clients/"*.conf.pending; do
        [[ -f $candidate && ! -L $candidate && -O $candidate ]] || continue
        name=${candidate##*/}; name=${name%.conf.pending}; cne_name "$name" || continue
        if ! cne_client_pending_matches "$candidate" "$server" "${CNE_HOSTS[0]}:$user_port" "$transport" "$params"; then
            printf '原待用配置 %s 与当前入口不同，已保留；不会自动继续使用它。\n' "$name"
            continue
        fi
        printf '上次添加的设备 %s 尚待确认；回车可继续，不会重新生成密钥。\n' "$name"
        default_name=$name; break
    done
    if [[ -z $default_name ]]; then
        index=1
        while :; do
            default_name=device-$index
            if [[ ! -e $CNE_STATE/clients/$default_name.conf && ! -L $CNE_STATE/clients/$default_name.conf && ! -e $CNE_STATE/clients/$default_name.conf.pending && ! -L $CNE_STATE/clients/$default_name.conf.pending ]] && ! awk -F'\t' -v n="$default_name" '$1==n{found=1}END{exit !found}' <<< "$data"; then break; fi
            index=$((index+1))
        done
    fi
    printf '每台设备需要独立配置。直接回车自动命名；也可填 1–32 位英文、数字、下划线或短横线。\n'
    while :; do
        cne_prompt '设备名称（0 取消）' "$default_name" || return 1; name=$CNE_ANSWER
        [[ $name != 0 ]] || { printf '已取消。\n'; return 0; }
        if ! cne_name "$name"; then cne_note '名称格式不正确，请重新输入，或回车使用默认名称。'; continue; fi
        if [[ -e $CNE_STATE/clients/$name.conf || -L $CNE_STATE/clients/$name.conf ]]; then cne_note '该设备已有配置；请换一个名称，或输入 0 返回后显示原配置。'; continue; fi
        if [[ ! -e $CNE_STATE/clients/$name.conf.pending && ! -L $CNE_STATE/clients/$name.conf.pending ]] && awk -F'\t' -v n="$name" '$1==n{found=1}END{exit !found}' <<< "$data"; then cne_note '服务器已登记此名称，请换名；旧设备继续使用原配置。'; continue; fi
        break
    done
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
            cne_client_onboarding "$name"
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
    if ! cne_remote 0 client-add "$name" "$address" "$public" "$server"; then unset CNE_CLIENT_PSK private psk; cne_error "尚未确认添加结果，配置已保留。恢复连接后再次添加，使用同一名称 ${name} 继续；不要先换名重建。文件：$CNE_STATE/clients/$name.conf.pending"; return 1; fi
    unset CNE_CLIENT_PSK private psk
    mv "$pending" "$CNE_STATE/clients/$name.conf" || return 1
    printf '客户端已添加：%s\n配置：%s\n' "$name" "$CNE_STATE/clients/$name.conf"
    cne_client_onboarding "$name"
}
cne_client_pending_matches() {
    local file=$1 server=$2 endpoint=$3 transport=$4 params=$5 field expected
    [[ $(cne_profile_field "$file" Peer PublicKey) == "$server" && $(cne_profile_field "$file" Peer Endpoint) == "$endpoint" ]] || return 1
    if [[ $transport == awg2 ]]; then
        for field in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4; do
            expected=$(sed -nE "s/^$field[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\\1/p" "$params")
            [[ $(cne_profile_field "$file" Interface "$field") == "$expected" ]] || return 1
        done
    else [[ -z $(cne_profile_field "$file" Interface Jc) ]] || return 1; fi
    return 0
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
    CNE_PROFILE_VERDICT=unconfirmed
    cne_require_config && cne_bootstrap client && cne_authenticate 0 || return 1
    current=$(cne_remote 0 inspect) || return 1
    [[ $(cne_field "$current" state) == present && $(cne_field "$current" role) == hk ]] || { cne_client_invalid '当前入口尚未安装或角色不正确。'; return 1; }
    server=$(cne_remote 0 server-public) || return 1
    cne_key "$server" || { cne_error '服务器未返回可核对的入口信息，请查看连接诊断。'; return 1; }
    cne_client_profile_identity "$file" "$server" || { CNE_PROFILE_VERDICT=invalid; return 1; }
    user_port=$(cne_field "$current" user_port)
    cne_port "$user_port" || { cne_error '服务器未返回有效入口端口，请查看连接诊断。'; return 1; }
    [[ $(cne_profile_field "$file" Peer Endpoint) == "${CNE_HOSTS[0]}:$user_port" ]] || { cne_client_invalid '本机配置的入口地址或端口已改变。'; return 1; }
    transport=$(cne_field "$current" user_transport); transport=${transport:-wireguard}
    cne_client_profile_shape "$file" "$transport" || { CNE_PROFILE_VERDICT=invalid; return 1; }
    case $transport in
        wireguard) [[ -z $(cne_profile_field "$file" Interface Jc) ]] || { cne_client_invalid '本机配置与当前入口协议不同。'; return 1; };;
        awg2)
            params=$(cne_remote 0 client-params) || return 1
            for field in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4; do
                actual=$(cne_profile_field "$file" Interface "$field")
                expected=$(awk -F= -v key="$field" '{k=$1;gsub(/^[[:space:]]+|[[:space:]]+$/,"",k);if(k==key){v=$2;gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);print v;count++}} END{if(count!=1)exit 1}' <<< "$params") || { cne_error '当前服务器混淆参数不完整。'; return 1; }
                [[ -n $expected && $actual == "$expected" ]] || { cne_client_invalid '本机配置的混淆参数已经改变。'; return 1; }
            done;;
        *) cne_error '当前入口协议未知。'; return 1;;
    esac
    address=$(cne_profile_field "$file" Interface Address | tr -d '[:space:]')
    [[ $address =~ ^10\.77\.10\.([1-9][0-9]{0,2})/32,fd77:77:10::([1-9][0-9]{0,2})/128$ ]] || { cne_client_invalid '客户端完整地址与当前设备网段不一致。'; return 1; }
    number=${BASH_REMATCH[1]}
    [[ $address == "10.77.10.$number/32,fd77:77:10::$number/128" ]] && ((10#$number>=2 && 10#$number<=249)) || { cne_client_invalid '客户端完整地址无效。'; return 1; }
    [[ $(cne_profile_field "$file" Interface DNS | tr -d '[:space:]') == 10.77.30.2 ]] || { cne_client_invalid '客户端 DNS 已改变，不能按当前配置发放。'; return 1; }
    [[ $(cne_profile_field "$file" Peer AllowedIPs | tr -d '[:space:]') == '0.0.0.0/0,::/0' ]] || { cne_client_invalid '客户端转发范围已改变，不能按当前配置发放。'; return 1; }
    [[ $(cne_profile_field "$file" Interface MTU) == 1380 && $(cne_profile_field "$file" Peer PersistentKeepalive) == 25 ]] || { cne_client_invalid '客户端连接参数已改变，不能按当前配置发放。'; return 1; }
    data=$(cne_remote 0 client-list) || return 1
    if ! awk -F'\t' -v key="$CNE_PROFILE_PUBLIC" -v address="$number" '$3==key && $2==address {found=1} END{exit !found}' <<< "$data"; then
        cne_client_invalid '此设备已撤销或未注册在当前入口，原文件不能作为有效配置发放。'; return 1
    fi
    psk=$(cne_profile_field "$file" Peer PresharedKey)
    cne_key "$psk" || { unset psk; cne_client_invalid '客户端预共享密钥格式无效。'; return 1; }
    digest=$(printf '%s\n' "$psk" | sha256sum) || { unset psk; return 1; }
    digest=${digest%% *}; unset psk
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    cne_remote 0 client-verify "$CNE_PROFILE_PUBLIC" "$server" "$digest" || { cne_error '服务器核对客户端密钥失败，原文件可能已经失效。'; return 1; }
    CNE_PROFILE_VERDICT=valid
    printf '已核对当前入口、协议参数和设备注册信息；公网连接还需在设备上验证。\n'
}

cne_client_invalid() { CNE_PROFILE_VERDICT=invalid; cne_error "$*"; }

cne_client_delivery_hint() {
    local file=$1 kind=${2:-all}
    printf '二维码和文件是此设备的连接凭证，请勿公开或转发截图。\n'
    printf '每台设备使用独立配置；给另一台设备使用时，请新增客户端。\n'
    printf '连接期间，这台设备的网络访问都使用此出口；日常连接/断开在设备应用中操作。退出本菜单不会停止服务器。\n'
    if [[ -n $(cne_profile_field "$file" Interface Jc) ]]; then
        printf '使用支持 AmneziaWG 2 的客户端导入配置，然后开启连接。\n'
        case $kind in all|iphone) printf 'iPhone：https://apps.apple.com/app/amneziawg/id6478942365\n';; esac
        case $kind in all|android) printf 'Android：https://github.com/amnezia-vpn/amneziawg-android/releases（下载适用于手机的安装包）\n';; esac
        case $kind in all|windows) printf 'Windows：https://github.com/amnezia-vpn/amneziawg-windows-client/releases（下载适用于电脑的安装程序）\n';; esac
    else printf '使用 WireGuard 客户端导入配置，然后开启连接。下载：https://www.wireguard.com/install/\n'; fi
}

cne_client_file_hint() {
    local file=$1 kind=${2:-all} name=${1##*/}
    printf '文件保存在当前运行脚本的机器：%s\n' "$file"
    printf '若登录工具有文件下载功能，可打开这个目录并下载配置。文件名应保存为 %s（不要加 .txt）。\n' "$name"
    if [[ $kind == windows ]]; then
        printf '没有下载功能也可这样保存：\n  1. 复制下面从 [Interface] 开始到最后一行的完整内容。\n  2. 在电脑打开记事本，粘贴内容，选择“另存为”。\n  3. 文件名填写 %s，文件类型选择“所有文件”，保存，避免生成 .conf.txt。\n  4. Windows 在应用中选择从文件导入，选刚保存的文件。\n' "$name"
        printf '不要把服务器上的路径当作电脑本地路径。\n'
    else
        printf '同一部手机打开本菜单时，无法直接用相机扫描本手机屏幕。只有登录工具支持下载文件，才能先下载再从文件导入。\n'
        printf '工具没有下载功能或不知道怎样保存：在电脑上登录同一台机器、用同一账号打开菜单，再让手机扫描电脑显示的二维码。不要重新安装服务器。\n'
    fi
}

cne_client_connection_check_hint() {
    printf '\n导入后请在设备上打开连接，再访问 https://www.baidu.com，最后打开税务应用完成实际操作。\n'
    printf '应用开关已打开不等于连接成功；服务器核对也不能证明设备公网连接或税务业务已通过。\n'
    printf '连不上或网页打不开：进入“状态与服务 → 连接诊断”；诊断通过仍连不上，请检查香港入口公网 UDP 端口和设备网络。\n'
    printf '网页能打开但税务应用失败：保留应用提示继续排查，不要先重装服务器。\n'
}

cne_client_choose_delivery() {
    local file=$1 choice default=1 name=${1##*/}
    case $name in Android*) default=2;; Windows*) default=3;; esac
    CNE_DELIVERY_KIND=all; CNE_DELIVERY_METHOD=qr
    cne_ui_interactive || return 0
    printf '\n这份配置要用于哪台设备？\n  1. iPhone\n  2. Android 手机\n  3. Windows 电脑\n  0. 稍后导入\n'
    while :; do
        cne_prompt '请选择' "$default" || return 1; choice=$CNE_ANSWER
        case $choice in 0) return 1;; 1) CNE_DELIVERY_KIND=iphone; break;; 2) CNE_DELIVERY_KIND=android; break;; 3) CNE_DELIVERY_KIND=windows; CNE_DELIVERY_METHOD=file; return 0;; *) cne_note '请输入 0、1、2 或 3。';; esac
    done
    printf '\n  1. 手机扫描另一块屏幕的二维码\n  2. 当前就在这部手机上操作，或需要配置文件\n  0. 稍后导入\n'
    while :; do
        cne_prompt '请选择导入方式' 1 || return 1; choice=$CNE_ANSWER
        case $choice in 0) return 1;; 1) return 0;; 2) CNE_DELIVERY_METHOD=file; return 0;; *) cne_note '请输入 0、1 或 2。';; esac
    done
}

cne_client_onboarding() {
    local name=${1:-} file
    if ! cne_ui_interactive; then
        [[ -z $name ]] || cne_client_delivery_hint "$CNE_STATE/clients/$name.conf"
        printf '设备尚未连接。可进入“客户端管理 → 显示配置与二维码”继续导入。\n'
        return 0
    fi
    printf '\n服务器操作已完成；接下来将配置导入设备，才能使用。\n'
    cne_prompt '现在导入设备配置（回车继续，0 稍后）' 1 || return 0
    [[ $CNE_ANSWER != 0 ]] || { printf '设备尚未导入；稍后进入“客户端管理 → 显示配置与二维码”继续。\n'; return 0; }
    # A failure here does not undo the already committed server operation.
    if ! cne_client_export "$name" onboarding; then
        printf '服务器操作已完成，设备导入尚未完成；稍后可继续显示配置，不需要重新安装。\n'
    fi
    return 0
}

cne_client_export() {
    local name=${1:-} file mode=1 verified=0 client='WireGuard' kind=all method=qr delivery=${2:-manual}
    if [[ -z $name ]]; then cne_client_pick_local || return 1; name=$CNE_CLIENT_SELECTION; fi
    [[ -n $name ]] || { printf '已取消。\n'; return 0; }
    cne_name "$name" || return 1
    file=$CNE_STATE/clients/$name.conf
    [[ -f $file && ! -L $file && -O $file ]] || { cne_error '未找到安全的设备配置文件，请重新选择设备。'; return 1; }
    if [[ $delivery != onboarding ]]; then
        printf '\n  1. 核对当前服务器后显示配置与二维码\n  2. 离线查看原文件（未验证是否仍有效）\n  0. 取消\n'
        while :; do
            cne_prompt '请选择' 1 || return 1; mode=$CNE_ANSWER
            case $mode in 0) printf '已取消。\n'; return 0;; 1|2) break;; *) cne_note '请输入 0、1 或 2。';; esac
        done
    fi
    if [[ $mode == 1 ]]; then
        if cne_client_verify_profile "$file"; then verified=1
        else
            cne_note '当前有效性未通过验证。'
            if [[ ${CNE_PROFILE_VERDICT:-unconfirmed} == invalid ]]; then
                cne_note '已确认原文件不适用于当前部署；它不能恢复连接。请添加新设备配置，或恢复与此文件对应的整套备份。'
                cne_prompt '仅查看历史内容（不能用于当前连接，y/N）' N || return 1
            else
                cne_note '此次无法完成服务器核对，有效性未知。请检查登录、网络或连接诊断后重试；不必先重装或换配置。'
                cne_prompt '是否仍离线查看原文件（y/N）' N || return 1
            fi
            [[ $CNE_ANSWER == y || $CNE_ANSWER == Y ]] || return 1
        fi
    fi
    [[ -z $(cne_profile_field "$file" Interface Jc) ]] || client='AmneziaWG 2 或更新版本'
    printf '\n配置文件：%s\n' "$file"
    if ((verified)); then
        cne_client_choose_delivery "$file" || { printf '已保留设备配置，稍后可继续导入。\n'; return 0; }
        kind=$CNE_DELIVERY_KIND; method=$CNE_DELIVERY_METHOD
        cne_client_delivery_hint "$file" "$kind"
        cne_client_connection_check_hint
        if [[ $method == qr ]] && cne_ensure_qrencode; then
            printf '在%s中选择“扫描二维码”：\n' "$client"
            if qrencode -t ANSIUTF8 < "$file"; then return 0; fi
        fi
        [[ $method != qr ]] || printf '二维码暂不可用，改为保存配置文件。\n'
        cne_client_file_hint "$file" "$kind"
        printf '\n以下配置含私钥，请勿公开：\n\n'
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
    printf '撤销后，使用这份配置的设备会断开，旧文件和二维码不能再连接；重新使用需新增配置。\n'
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
cne_menu_pending() { [[ -e $CNE_STATE/active-transaction || -L $CNE_STATE/active-transaction ]]; }
cne_menu_services() {
    local choice
    while :; do
        [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 0
        cne_ui_header '状态与服务'
        printf '  1. 查看状态\n  2. 连接诊断\n  3. 启动服务器服务\n  4. 停止服务器服务\n  5. 重启服务器服务\n  6. 查看日志\n  7. 上次操作结果\n  0. 返回主菜单\n\n'
        cne_prompt '请选择' || return 0; choice=$CNE_ANSWER
        case $choice in
            0) return 0;;
            1) cne_ui_action '节点状态' '部分节点不可用。' cne_status || return 0;;
            2) cne_ui_action '连接诊断' '部分检查未通过。' cne_action_all doctor || return 0;;
            3) cne_ui_action '启动服务' '部分节点启动失败。' cne_action_all start || return 0;;
            4) cne_ui_action '停止服务' '部分节点停止失败。' cne_action_all stop || return 0;;
            5) cne_ui_action '重启服务' '部分节点重启失败。' cne_action_all restart || return 0;;
            6) cne_ui_action '查看日志' '部分日志读取失败。' cne_action_all logs || return 0;;
            7) cne_ui_header '上次操作结果'; cne_result_show; cne_ui_pause || return 0;;
            *) cne_note '请输入菜单中的编号。'; cne_ui_pause || return 0;;
        esac
    done
}
cne_menu_clients() {
    local choice
    while :; do
        [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 0
        cne_ui_header '客户端管理'
        printf '  1. 客户端列表\n  2. 添加客户端\n  3. 显示配置与二维码\n  4. 撤销客户端\n  0. 返回主菜单\n\n'
        cne_prompt '请选择' || return 0; choice=$CNE_ANSWER
        case $choice in
            0) return 0;;
            1) cne_ui_action '客户端列表' '客户端列表读取失败。' cne_clients_list || return 0;;
            2) cne_ui_action '添加客户端' '客户端添加未完成。' cne_client_add || return 0;;
            3) cne_ui_action '显示配置与二维码' '配置导出未完成。' cne_client_export || return 0;;
            4) cne_ui_action '撤销客户端' '客户端撤销未完成。' cne_client_remove || return 0;;
            *) cne_note '请输入菜单中的编号。'; cne_ui_pause || return 0;;
        esac
    done
}
cne_menu_uninstall() {
    cne_mutation_guard && cne_require_config || return 1
    local idx backup restorable=1 result
    printf '将卸载以下三台服务器的本工具服务，所有设备将无法继续连接。\n卸载前保存包含设备配置的完整备份；备份失败时不会开始卸载。\n'
    for idx in 0 1 2; do printf '  %s · %s\n' "${CNE_LABELS[$idx]}" "$(cne_display_host "$idx")"; done
    cne_prompt '确认卸载请输入 UNINSTALL' || return 1
    [[ $CNE_ANSWER == UNINSTALL ]] || { printf '已取消。\n'; return 0; }
    cne_backup_create || { cne_error '完整备份未完成，未开始卸载。请修复备份错误后重试。'; return 1; }
    backup=$CNE_BACKUP_CREATED
    cne_backup_restorable "$backup" || restorable=0
    if ((restorable==0)); then
        printf '现有服务原本就不完整：已保存状态快照，但不能从它一键恢复完整服务。\n如只是清理残留服务，可以继续；否则请取消并先处理现有部署。\n'
        cne_prompt '仍要清理请输入 UNINSTALL-INCOMPLETE（回车取消）' || return 1
        [[ $CNE_ANSWER == UNINSTALL-INCOMPLETE ]] || { printf '已取消卸载，状态快照保留：%s\n' "$backup"; return 0; }
    fi
    cne_action_all uninstall; result=$?
    if ((restorable)); then printf '\n恢复入口：维护与设置 → 恢复历史备份，选择 %s。\n' "${backup##*/}"
    else printf '\n状态快照：%s。它不是完整服务恢复包。\n' "$backup"; fi
    if ((result)); then cne_error '部分节点卸载未完成，备份保留。请查看节点状态确认哪些服务仍在运行。'; fi
    return "$result"
}
cne_menu_recover() {
    cne_require_config || return 1
    printf '将恢复上次未完成操作涉及的节点；原备份保留，不会开始新安装。\n  1. 使用原登录信息重试\n  2. 重新提供登录信息后恢复\n  0. 返回\n'
    cne_prompt '请选择' 1 || return 1
    case $CNE_ANSWER in 0) printf '已取消恢复，记录保留。\n';; 1) cne_transaction_recover;; 2) cne_transaction_recover credentials;; *) cne_error '请选择 1、2 或 0。';; esac
}
cne_menu_maintenance() {
    local choice
    while :; do
        [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 0
        cne_ui_header '维护与设置'
        printf '  1. 备份配置\n  2. 恢复历史备份\n  3. 证书续期与自动维护\n  4. 配置下载来源\n  5. 组件离线包\n  6. 卸载服务\n'
        if cne_menu_pending; then printf '  7. 重试恢复未完成操作\n'; fi
        printf '  0. 返回主菜单\n\n'
        cne_prompt '请选择' || return 0; choice=$CNE_ANSWER
        case $choice in
            0) return 0;;
            1) cne_ui_action '备份配置' '备份未完成，具体原因见上方。' cne_backup_create || return 0;;
            2) cne_ui_action '恢复历史备份' '恢复未完成，备份和记录已保留。' cne_backup_restore || return 0;;
            3)
                if ! cne_renew_menu; then cne_note '证书维护未完成，具体原因见上方。'; cne_ui_pause || return 0; fi
                continue;;
            4) cne_ui_action '配置下载来源' '下载来源设置未完成。' cne_download_setup || return 0;;
            5)
                if ! cne_download_bundle_menu; then cne_note '组件离线包操作未完成。'; cne_ui_pause || return 0; fi
                continue;;
            6) cne_ui_action '卸载服务' '部分节点卸载未完成。' cne_menu_uninstall || return 0;;
            7)
                if cne_menu_pending; then cne_ui_action '恢复未完成操作' '恢复尚未完成，原备份和记录已保留。' cne_menu_recover || return 0
                else cne_note '当前没有未完成操作。'; cne_ui_pause || return 0; fi;;
            *) cne_note '请输入菜单中的编号。'; cne_ui_pause || return 0;;
        esac
    done
}
cne_menu() {
    local choice
    while :; do
        [[ ${CNE_INPUT_ENDED:-0} == 0 ]] || return 0
        cne_ui_header '一键安装与管理'
        printf '  1. 一键安装\n  2. 修改节点\n  3. 状态与服务\n  4. 客户端管理\n  5. 维护与设置\n  0. 退出\n\n'
        if [[ ${CNE_CONFIG_INVALID:-0} == 1 ]]; then printf '节点设置无效，请选 2 重新填写。\n\n'; fi
        if cne_menu_pending; then printf '有未完成操作，请选 5 → 7 重试恢复。\n\n'; fi
        cne_prompt '请选择' || return 0; choice=$CNE_ANSWER
        case $choice in
            0) return 0;;
            1) cne_ui_action '一键安装' '操作未完成，具体原因见上方。' cne_install || return 0;;
            2) cne_ui_action '修改节点' '节点设置未完成。' cne_setup || return 0;;
            3) cne_menu_services;;
            4) cne_menu_clients;;
            5) cne_menu_maintenance;;
            *) cne_note '请输入菜单中的编号。'; cne_ui_pause || return 0;;
        esac
    done
}
cne_main() {
    local startup_warning=0
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
    [[ ${CNE_CONFIG_INVALID:-0} == 0 ]] || startup_warning=1
    if ! cne_download_load; then
        cne_note '下载设置无效；状态和离线配置仍可查看，请通过“维护与设置 → 配置下载来源”修正。'
        startup_warning=1
    fi
    if [[ ${1:-menu} == menu && $startup_warning == 1 ]]; then cne_ui_pause || return 0; fi
    case ${1:-menu} in menu) cne_menu;; install) cne_install;; status) cne_status;; doctor) cne_action_all doctor;; backup) cne_backup_create;; renew) cne_renew_certificates;; renew-auto) cne_renew_auto || return 1;; esac
}
