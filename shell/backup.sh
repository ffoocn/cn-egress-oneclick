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
    ((${#entries[@]})) || { cne_error '没有完整且通过校验的历史备份，请先进入“维护与设置 → 备份配置”。'; return 1; }
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
