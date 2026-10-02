#!/usr/bin/env bash
# Missing or invalid node settings must fail before maintenance prerequisites.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-missing-config.XXXXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test_missing_config() (
    local scenario=$1 action=$2 result=0
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/backup.sh"
    source "$ROOT/shell/renew.sh"
    CNE_STATE=$WORK/$scenario-$action
    CNE_TEMP=$CNE_STATE/session
    mkdir -m 700 "$CNE_STATE" "$CNE_TEMP"
    TRACE=$WORK/$scenario-$action.trace
    : > "$TRACE"
    CNE_NONINTERACTIVE=0
    case $scenario in
        absent) : ;;
        truncated)
            printf 'hk\t203.0.113.10\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
            ;;
        invalid-address)
            printf 'hk\tinvalid\troot\t22\t-\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
            ;;
        invalid-connection)
            printf 'hk\t203.0.113.10\troot\t22\t-\tssh\nsh\t198.51.100.20\troot\t22\t-\tunknown\nexit\t192.0.2.30\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
            ;;
        extra-node)
            printf 'hk\t203.0.113.10\troot\t22\t-\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tssh\nexit\t192.0.2.40\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
            ;;
        *) fail "unknown fixture $scenario" ;;
    esac
    # Exercise the real loader too: a failed parse must never leave a usable
    # prefix of otherwise valid nodes for later menu operations.
    if [[ $scenario != absent ]]; then
        if cne_load_config > "$WORK/$scenario-$action.load" 2>&1; then fail "$scenario configuration was accepted"; fi
    fi
    cp -R "$CNE_STATE" "$WORK/$scenario-$action.before"
    forbidden() { printf '%s\n' "$*" >> "$TRACE"; return 99; }
    cne_bootstrap() { forbidden "bootstrap $*"; }
    cne_setup() { forbidden 'setup wizard'; }
    cne_prompt() { forbidden "prompt $*"; }
    cne_secret() { forbidden "secret $*"; }
    cne_authenticate() { forbidden "authenticate $*"; }
    cne_remote() { forbidden "remote $*"; }
    cne_remote_payload() { forbidden "payload $*"; }
    cne_transaction_recover() { forbidden 'transaction recovery'; }
    cne_backup_pick() { forbidden 'history picker'; }
    cne_safe_directory() { forbidden "prepare directory $*"; }
    cne_renew_timer_id() { forbidden 'prepare timer'; }
    cne_renew_timer_call() { forbidden "timer mutation $*"; }
    cne_root() { forbidden "root $*"; }
    sudo() { forbidden "sudo $*"; }
    apt-get() { forbidden "APT $*"; }
    dpkg() { forbidden "dpkg $*"; }
    ssh() { forbidden "SSH $*"; }
    sshpass() { forbidden "SSH password helper $*"; }
    "$action" > "$WORK/$scenario-$action.output" 2>&1 || result=$?
    ((result!=0)) || fail "$action succeeded with $scenario settings"
    [[ ! -s $TRACE ]] || { cat "$TRACE" >&2; fail "$action acted before rejecting $scenario settings"; }
    diff -r "$WORK/$scenario-$action.before" "$CNE_STATE" >/dev/null || fail "$action changed manager files with $scenario settings"
    grep -q '错误：' "$WORK/$scenario-$action.output" || fail "$action omitted a clear settings error"
    ! grep -q '配置安装节点' "$WORK/$scenario-$action.output" || fail "$action opened the installation wizard"
)

for action in cne_backup_create cne_backup_restore cne_renew_certificates cne_renew_auto cne_renew_timer_enable; do
    for scenario in absent truncated invalid-address invalid-connection extra-node; do
        test_missing_config "$scenario" "$action"
    done
    printf 'PASS: %s rejects absent and invalid settings before dependencies, prompts, connections or manager writes\n' "$action"
done
printf 'Missing configuration checks passed. No packages, timers or node services changed.\n'
