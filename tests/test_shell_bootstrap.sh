#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source shell/controller.sh
source shell/bootstrap.sh
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
uname() { printf 'Linux\n'; }
id() { printf '0\n'; }
dpkg-query() { printf 'install ok installed'; }
command() {
    if [[ ${1:-} == -v ]]; then
        case ${2:-} in wg|sshpass|qrencode)
            [[ -f $sandbox/installed ]]; return;;
        esac
        return 0
    fi
    builtin command "$@"
}
cne_root() {
    printf '%s\n' "$*" >> "$sandbox/calls"
    case "$*" in
        'dpkg --audit') return 0;;
        'apt-get -qq update') return 0;;
        'apt-get -s '*)
            if [[ -f $sandbox/upgrade ]]; then printf 'Inst libc6 [old] (new Debian)\n'; else printf 'Inst wireguard-tools (new Debian)\n'; fi;;
        'apt-get -y '*) [[ ! -f $sandbox/failure ]] || return 1; touch "$sandbox/installed";;
        *) return 1;;
    esac
}
cne_bootstrap > "$sandbox/output"
grep -q 'install sshpass wireguard-tools qrencode' "$sandbox/calls"
[[ -f $sandbox/installed ]]
printf 'PASS: missing tools are installed without Python\n'
: > "$sandbox/calls"
cne_bootstrap
[[ ! -s $sandbox/calls ]]
printf 'PASS: existing dependencies skip package manager\n'
rm "$sandbox/installed"
touch "$sandbox/upgrade"
if cne_bootstrap > "$sandbox/output" 2>&1; then printf 'FAIL: unsafe dependency upgrade accepted\n' >&2; exit 1; fi
[[ ! -f $sandbox/installed ]]
printf 'PASS: unrelated upgrade is not performed\n'
rm "$sandbox/upgrade"
touch "$sandbox/failure"
if cne_bootstrap > "$sandbox/output" 2>&1; then printf 'FAIL: failed dependency install accepted\n' >&2; exit 1; fi
printf 'PASS: install failure stops startup\n'
