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
