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
        cne_ui_header '证书续期与自动维护'
        printf '  1. 立即更新证书\n  2. 启用每天自动检查\n  3. 关闭自动检查\n  4. 查看定时维护状态和日志\n  0. 返回\n\n'
        cne_prompt '请选择' || return 0
        case $CNE_ANSWER in
            1) cne_ui_header '立即更新证书'; cne_renew_certificates || cne_note '证书更新未完成。';;
            2) cne_ui_header '启用每天自动检查'; cne_renew_timer_enable || cne_note '自动检查启用未完成。';;
            3) cne_ui_header '关闭自动检查'; cne_renew_timer_disable || cne_note '自动检查关闭未完成。';;
            4) cne_ui_header '定时维护状态和日志'; cne_renew_timer_status || :;;
            0) return 0;;
            *) cne_note '请输入菜单中的编号。';;
        esac
        cne_ui_pause || return 0
    done
}
