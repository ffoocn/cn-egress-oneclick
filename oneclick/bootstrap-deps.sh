#!/usr/bin/env bash
# Shared by the downloadable launcher and the extracted-directory launcher.
# Only management-machine prerequisites are installed here.

cne_dependency_error() {
  printf '依赖准备失败：%s\n' "$*" >&2
  return 1
}

cne_find_python() {
  local name candidate
  CNE_PYTHON=''
  for name in python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9; do
    candidate=$(command -v "$name" 2>/dev/null) || continue
    [[ $candidate == /* && -x $candidate ]] || continue
    if "$candidate" -I -c 'import sys; sys.exit(1) if sys.version_info < (3, 9) else None; import base64,fcntl,hashlib,json,pathlib,ssl,subprocess,tarfile,tempfile,zipfile,zlib' >/dev/null 2>&1; then
      CNE_PYTHON="$candidate"
      return 0
    fi
  done
  return 1
}

cne_package_installed() {
  case "$CNE_PACKAGE_MANAGER" in
    apt-get) [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]] ;;
    dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

cne_require_privileges() {
  CNE_USE_SUDO=0
  if [[ $(id -u) != 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { cne_dependency_error '自动安装需要 root 或 sudo 权限。'; return 1; }
    printf '缺少依赖，正在申请 sudo 权限。\n' >&2
    sudo -v </dev/null || { cne_dependency_error '无法取得 sudo 权限。'; return 1; }
    CNE_USE_SUDO=1
  fi
}

cne_root_command() {
  # Package managers must never consume the caller's menu input.
  if [[ ${CNE_USE_SUDO:-0} == 1 ]]; then
    sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@" </dev/null
  else
    env LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@" </dev/null
  fi
}

cne_pick_apt_python() {
  local package policy version major minor
  CNE_PYTHON_PACKAGE=''
  for package in python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9; do
    # A side-by-side runtime avoids replacing an older system interpreter.
    if cne_package_installed "$package"; then continue; fi
    policy=$(LC_ALL=C apt-cache policy "$package" 2>/dev/null) || continue
    if [[ $policy =~ Candidate:[[:space:]]*([^[:space:]]+) ]]; then
      version=${BASH_REMATCH[1]}
      version=${version#*:}
      if [[ $version =~ ^([0-9]+)\.([0-9]+) ]]; then
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        if (( major > 3 || (major == 3 && minor >= 9) )); then
          CNE_PYTHON_PACKAGE="$package"
          return 0
        fi
      fi
    fi
  done
  cne_dependency_error '当前软件源没有可新增的 Python 3.9+；请使用新版 Debian/Ubuntu 或已有的独立 Python 运行时。'
}

cne_install_apt() {
  local audit plan line
  local packages=()
  audit=$(cne_root_command dpkg --audit) || { cne_dependency_error 'dpkg 状态检查失败。'; return 1; }
  [[ -z $audit ]] || { printf '%s\n' "$audit" >&2; cne_dependency_error '已有未完成的软件包操作，请先处理该状态。'; return 1; }
  printf '正在更新软件索引并准备缺少的依赖…\n' >&2
  cne_root_command apt-get update || { cne_dependency_error 'APT 软件索引更新失败，请检查网络和软件源。'; return 1; }
  if [[ $CNE_NEED_PYTHON == 1 ]]; then
    cne_pick_apt_python || return 1
    packages+=("$CNE_PYTHON_PACKAGE")
  fi
  [[ $CNE_NEED_SSH == 0 ]] || packages+=(openssh-client)
  [[ $CNE_NEED_OPENSSL == 0 ]] || packages+=(openssl)
  [[ $CNE_NEED_CA == 0 ]] || packages+=(ca-certificates)
  plan=$(cne_root_command apt-get -s --no-install-recommends --no-upgrade --no-remove install "${packages[@]}") || { cne_dependency_error 'APT 无法生成依赖安装方案。'; return 1; }
  while IFS= read -r line; do
    if [[ $line == Remv\ * || $line =~ ^Inst[[:space:]]+[^[:space:]]+[[:space:]]+\[ ]]; then
      printf '%s\n' "$line" >&2
      cne_dependency_error '安装依赖需要替换、升级或删除现有软件，已停止。'
      return 1
    fi
  done <<< "$plan"
  printf '正在安装缺少的依赖：%s\n' "${packages[*]}" >&2
  cne_root_command apt-get -y --no-install-recommends --no-upgrade --no-remove install "${packages[@]}" || { cne_dependency_error 'APT 依赖安装失败。'; return 1; }
}

cne_install_rpm() {
  local package plan line
  local packages=()
  if [[ $CNE_NEED_PYTHON == 1 ]]; then
    CNE_PYTHON_PACKAGE=''
    for package in python3.12 python3.11 python3.10 python39 python3.9 python3; do
      if ! cne_package_installed "$package" && cne_root_command "$CNE_PACKAGE_MANAGER" -q list --available "$package" >/dev/null 2>&1; then
        CNE_PYTHON_PACKAGE="$package"
        break
      fi
    done
    [[ -n $CNE_PYTHON_PACKAGE ]] || { cne_dependency_error '当前软件源没有可新增的 Python 3.9+。'; return 1; }
    packages+=("$CNE_PYTHON_PACKAGE")
  fi
  [[ $CNE_NEED_SSH == 0 ]] || packages+=(openssh-clients)
  [[ $CNE_NEED_OPENSSL == 0 ]] || packages+=(openssl)
  [[ $CNE_NEED_CA == 0 ]] || packages+=(ca-certificates)
  # --assumeno is expected to return nonzero after showing the transaction.
  plan=$(cne_root_command "$CNE_PACKAGE_MANAGER" --assumeno --setopt=install_weak_deps=False --setopt=obsoletes=False install "${packages[@]}" 2>&1) || :
  [[ $plan == *'Transaction Summary'* && $plan == *'Install'* ]] || { printf '%s\n' "$plan" >&2; cne_dependency_error '无法确认 RPM 依赖安装方案。'; return 1; }
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*(Upgrading|Updating|Downgrading|Removing|Erasing|Obsoleting|Reinstalling|Replacing|replacing)([[:space:]][^:]*)?: ||
          $line =~ ^[[:space:]]*(Upgrade|Update|Downgrade|Remove|Erase|Obsolete|Reinstall)[[:space:]]+[0-9] ||
          $line =~ ^[[:space:]]*(Replacing|replacing)[[:space:]] ]]; then
      cne_dependency_error '安装依赖需要替换、升级或删除现有软件，已停止。'
      return 1
    fi
  done <<< "$plan"
  printf '正在安装缺少的依赖：%s\n' "${packages[*]}" >&2
  cne_root_command "$CNE_PACKAGE_MANAGER" -y --setopt=install_weak_deps=False --setopt=obsoletes=False install "${packages[@]}" || { cne_dependency_error 'RPM 依赖安装失败。'; return 1; }
}

cne_install_apk() {
  local plan
  local packages=()
  if [[ $CNE_NEED_PYTHON == 1 ]]; then
    if cne_package_installed python3; then
      cne_dependency_error '现有 Python 不满足要求，请先提供 Python 3.9+ 的独立运行时。'
      return 1
    fi
    packages+=(python3)
  fi
  [[ $CNE_NEED_SSH == 0 ]] || packages+=(openssh-client)
  [[ $CNE_NEED_OPENSSL == 0 ]] || packages+=(openssl)
  [[ $CNE_NEED_CA == 0 ]] || packages+=(ca-certificates)
  plan=$(cne_root_command apk add --simulate --no-cache "${packages[@]}" 2>&1) || { cne_dependency_error 'APK 无法生成依赖安装方案。'; return 1; }
  [[ $plan == *'Installing '* ]] || { printf '%s\n' "$plan" >&2; cne_dependency_error '无法确认 APK 依赖安装方案。'; return 1; }
  if [[ $plan =~ Upgrading|Downgrading|Purging|Replacing|Reinstalling|Updating[[:space:]]pinning ]]; then
    cne_dependency_error '安装依赖需要替换、升级或删除现有软件，已停止。'
    return 1
  fi
  cne_root_command apk add --no-cache "${packages[@]}" || { cne_dependency_error 'APK 依赖安装失败。'; return 1; }
}

cne_ensure_dependencies() {
  local platform manager
  local packages=()
  CNE_NEED_PYTHON=0 CNE_NEED_SSH=0 CNE_NEED_OPENSSL=0 CNE_NEED_CA=0
  CNE_PACKAGE_MANAGER=''
  cne_find_python || CNE_NEED_PYTHON=1
  command -v ssh >/dev/null 2>&1 || CNE_NEED_SSH=1
  command -v openssl >/dev/null 2>&1 || CNE_NEED_OPENSSL=1
  platform=$(uname -s)
  if [[ $platform == Linux ]]; then
    for manager in apt-get dnf yum apk; do
      if command -v "$manager" >/dev/null 2>&1; then CNE_PACKAGE_MANAGER="$manager"; break; fi
    done
    if [[ -n $CNE_PACKAGE_MANAGER ]] && ! cne_package_installed ca-certificates; then CNE_NEED_CA=1; fi
  fi
  if [[ $CNE_NEED_PYTHON == 0 && $CNE_NEED_SSH == 0 && $CNE_NEED_OPENSSL == 0 && $CNE_NEED_CA == 0 ]]; then
    return 0
  fi
  if [[ $platform == Darwin ]]; then
    command -v brew >/dev/null 2>&1 || { cne_dependency_error 'macOS 缺少所需工具，且未安装 Homebrew。'; return 1; }
    [[ $(id -u) != 0 ]] || { cne_dependency_error 'Homebrew 不能以 root 安装，请使用普通用户运行。'; return 1; }
    [[ $CNE_NEED_PYTHON == 0 ]] || packages+=(python)
    [[ $CNE_NEED_SSH == 0 ]] || packages+=(openssh)
    [[ $CNE_NEED_OPENSSL == 0 ]] || packages+=(openssl@3)
    env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "${packages[@]}" </dev/null || { cne_dependency_error 'Homebrew 依赖安装失败。'; return 1; }
    if [[ $CNE_NEED_OPENSSL == 1 ]] && ! command -v openssl >/dev/null 2>&1; then
      local openssl_prefix
      openssl_prefix=$(brew --prefix openssl@3) || return 1
      PATH="$openssl_prefix/bin:$PATH"
      export PATH
    fi
  else
    [[ $platform == Linux && -n $CNE_PACKAGE_MANAGER ]] || { cne_dependency_error '缺少依赖，且未发现支持的 apt-get、dnf、yum 或 apk。'; return 1; }
    cne_require_privileges || return 1
    case "$CNE_PACKAGE_MANAGER" in
      apt-get) cne_install_apt || return 1 ;;
      dnf|yum) cne_install_rpm || return 1 ;;
      apk) cne_install_apk || return 1 ;;
    esac
  fi
  cne_find_python || { cne_dependency_error '安装后仍没有可用的 Python 3.9+（含完整标准库），无法继续。'; return 1; }
  command -v ssh >/dev/null 2>&1 || { cne_dependency_error '安装后仍找不到 SSH 客户端。'; return 1; }
  command -v openssl >/dev/null 2>&1 || { cne_dependency_error '安装后仍找不到 OpenSSL。'; return 1; }
  if [[ -n $CNE_PACKAGE_MANAGER ]] && ! cne_package_installed ca-certificates; then
    cne_dependency_error '安装后仍缺少 CA 证书包。'
    return 1
  fi
  printf '依赖已准备好，正在打开管理程序。\n' >&2
}
