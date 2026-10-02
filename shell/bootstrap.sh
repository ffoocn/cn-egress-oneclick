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
        command -v "$tool" >/dev/null 2>&1 || { cne_error "安装后仍缺少 $tool。"; return 1; }
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
