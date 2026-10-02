#!/usr/bin/env bash
# Exercise the actual first-run menu without host packages or node connections.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-first-run.XXXXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077
exec 3>&2

fail() {
    printf 'FAIL: %s\n' "$*" >&3
    exit 1
}
contains() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected: $2"; fi; }

setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/download.sh"
    CNE_HOME=$WORK/$1
    CNE_STATE=$CNE_HOME
    CNE_CONFIG_INVALID=0
    CNE_NONINTERACTIVE=0
    TRACE=$WORK/$1.trace
    OUTPUT=$WORK/$1.output
    : > "$TRACE"
    mkdir -p "$CNE_STATE"
    # Locking is tested elsewhere. Keep initialization and the real menu here,
    # while allowing the same test to run on a macOS development machine.
    flock() { [[ $* == '-n 8' ]] || fail 'unexpected lock operation'; }
    chmod() {
        local argument arguments=()
        for argument in "$@"; do [[ $argument == -- ]] || arguments+=("$argument"); done
        command chmod "${arguments[@]}"
    }
    cne_bootstrap() {
        printf 'bootstrap %s\n' "$*" >> "$TRACE"
        [[ $1 == ui ]] || fail 'read-only first run prepared operation dependencies'
    }
    cne_authenticate() { fail 'unconfigured menu requested authentication'; }
    cne_remote() { fail 'unconfigured menu contacted a node'; }
    apt-get() { fail 'first-run read-only menu accessed APT'; }
    dpkg() { fail 'first-run read-only menu inspected package transactions'; }
    sudo() { fail 'first-run read-only menu requested privilege'; }
    ssh() { fail 'first-run read-only menu started SSH'; }
    sshpass() { fail 'first-run read-only menu started SSH'; }
    curl() { fail 'first-run read-only menu downloaded a file'; }
    wg() { fail 'first-run read-only menu required WireGuard tools'; }
    cne_setup() { fail 'read-only management opened the installation wizard'; }
}

assert_no_configuration_writes() {
    local file directory
    for file in nodes.tsv ports current-deployment active-transaction; do
        [[ ! -e $CNE_STATE/$file && ! -L $CNE_STATE/$file ]] || fail "read-only first run wrote $file"
    done
    for directory in clients cache history backups; do
        [[ ! -d $CNE_STATE/$directory || -z $(find "$CNE_STATE/$directory" -mindepth 1 -print -quit) ]] || fail "read-only first run populated $directory"
    done
}

test_empty_menu() (
    setup empty-menu
    cne_main menu <<<'3
4
8
10
0' > "$OUTPUT" 2>&1 || fail 'fresh menu did not remain usable after read-only choices'
    contains "$OUTPUT" "$CNE_STATE"
    [[ $(grep -c '节点尚未配置' "$OUTPUT" || true) -ge 3 ]] || fail 'status, diagnosis and logs did not identify the unconfigured manager'
    absent "$OUTPUT" '配置安装节点|连接方式（|IPv4 地址：|首次准备：|SSH 密码：'
    [[ $(cat "$TRACE") == 'bootstrap ui' ]] || fail 'fresh read-only menu prepared operation dependencies'
    assert_no_configuration_writes
    printf 'PASS: first-run status, diagnosis, logs and client list never open setup or change packages and node configuration\n'
)

test_empty_command() (
    local operation=$1
    setup "empty-$operation"
    cne_main "$operation" > "$OUTPUT" 2>&1 || fail "unconfigured $operation command failed instead of reporting its state"
    contains "$OUTPUT" "$CNE_STATE"
    contains "$OUTPUT" '节点尚未配置'
    absent "$OUTPUT" '配置安装节点|连接方式（|IPv4 地址：|首次准备：'
    [[ $(cat "$TRACE") == 'bootstrap ui' ]] || fail "$operation prepared management dependencies"
    assert_no_configuration_writes
    printf 'PASS: fresh %s command reports unconfigured nodes and returns without starting setup\n' "$operation"
)

test_missing_configuration_guard() (
    local operation
    setup missing-guard
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/clients"
    for operation in cne_require_config cne_clients_list cne_client_add cne_client_remove; do
        if "$operation" > "$OUTPUT" 2>&1; then fail "$operation accepted an unconfigured manager"; fi
        [[ ! -s $TRACE ]] || fail "$operation prepared dependencies before checking configuration"
    done
    if cne_client_verify_profile "$CNE_STATE/clients/missing.conf" > "$OUTPUT" 2>&1; then fail 'verified export accepted an unconfigured manager'; fi
    [[ ! -s $TRACE ]] || fail 'verified export prepared dependencies before checking configuration'
    contains "$OUTPUT" '节点'
    [[ ! -e $CNE_STATE/nodes.tsv && ! -e $CNE_STATE/ports ]] || fail 'configuration guard wrote new settings'
    printf 'PASS: missing configuration blocks remote client management before dependencies, credentials or setup\n'
)

test_install_configuration_entry() (
    local mode=$1 expected
    setup "install-entry-$mode"
    ENTRY_MODE=$mode
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP"
    if [[ $mode == configured ]]; then
        CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    elif [[ $mode == noninteractive ]]; then CNE_NONINTERACTIVE=1; fi
    cne_setup() {
        [[ $ENTRY_MODE == fresh ]] || fail 'installation requested unnecessary or noninteractive setup'
        printf 'setup\n' >> "$TRACE"
        CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    }
    cne_inspect_all() {
        printf 'inspect\n' >> "$TRACE"
        # Deliberately stop before the actual installation plan or SSH. The
        # setup/guard/transaction entry path above remains the real controller.
        return 1
    }
    if cne_install > "$OUTPUT" 2>&1; then fail 'installation passed the deliberately failed inspection boundary'; fi
    case $mode in
        fresh) expected=$'setup\ninspect' ;;
        configured) expected=inspect ;;
        noninteractive) expected='' ;;
        *) fail 'unknown installation-entry fixture' ;;
    esac
    [[ $(cat "$TRACE") == "$expected" ]] || fail "$mode installation crossed the wrong setup or dependency boundary"
    [[ ! -e $CNE_STATE/nodes.tsv && ! -e $CNE_STATE/ports ]] || fail 'mock installation entry wrote configuration files'
    printf 'PASS: %s installation enters setup only when explicitly needed and never prompts in unattended mode\n' "$mode"
)

runtime_configuration() {
    declare -p CNE_HOSTS CNE_USERS CNE_PORTS CNE_IDENTITIES CNE_CONNECTIONS CNE_USER_PORT CNE_WSS_PORT
}

test_atomic_config_parser() (
    local kind=$1 before
    setup "atomic-$kind"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_USERS=(old-hk old-relay old-exit)
    CNE_PORTS=(2201 2202 2203)
    CNE_IDENTITIES=(/missing/key-hk /missing/key-relay /missing/key-exit)
    CNE_CONNECTIONS=(ssh local ssh)
    CNE_USER_PORT=51825; CNE_WSS_PORT=8443
    before=$(runtime_configuration)
    printf 'hk\t203.0.113.11\tnew-hk\t22\t-\tssh\nsh\t198.51.100.21\tnew-relay\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    case $kind in
        partial) ;;
        invalid-role) printf 'unknown\t192.0.2.31\tnew-exit\t22\t-\tssh\n' >> "$CNE_STATE/nodes.tsv" ;;
        duplicate-host) printf 'exit\t203.0.113.11\tnew-exit\t22\t-\tssh\n' >> "$CNE_STATE/nodes.tsv" ;;
        invalid-ports)
            printf 'exit\t192.0.2.31\tnew-exit\t22\t-\tssh\n' >> "$CNE_STATE/nodes.tsv"
            printf '51820 not-a-port\n' > "$CNE_STATE/ports" ;;
        *) fail 'unknown parser fixture' ;;
    esac
    cp "$CNE_STATE/nodes.tsv" "$WORK/$kind.nodes.before"
    if cne_load_config > "$OUTPUT" 2>&1; then fail "$kind node configuration was accepted"; fi
    [[ $(runtime_configuration) == "$before" ]] || fail "$kind parse changed runtime configuration before complete validation"
    cmp "$WORK/$kind.nodes.before" "$CNE_STATE/nodes.tsv" || fail 'parser rewrote malformed node settings'
    [[ ! -s $TRACE ]] || fail 'configuration parsing prepared dependencies'
    printf 'PASS: %s configuration parsing is atomic and preserves previous runtime settings\n' "$kind"
)

test_configuration_final_lines() (
    local kind=$1 before
    setup "final-line-$kind"
    CNE_HOSTS=(203.0.113.90 198.51.100.90 192.0.2.90)
    CNE_USERS=(old-hk old-relay old-exit)
    CNE_PORTS=(2201 2202 2203)
    CNE_IDENTITIES=(/missing/key-hk /missing/key-relay /missing/key-exit)
    CNE_CONNECTIONS=(ssh local ssh)
    CNE_USER_PORT=51825; CNE_WSS_PORT=8443
    before=$(runtime_configuration)
    printf 'hk\t203.0.113.10\troot\t22\t-\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\troot\t22\t-\tssh' > "$CNE_STATE/nodes.tsv"
    printf '51820 443' > "$CNE_STATE/ports"
    case $kind in
        nodes-garbage)
            printf '\ngarbage-without-a-final-newline' >> "$CNE_STATE/nodes.tsv"
            printf '\n' >> "$CNE_STATE/ports" ;;
        nodes-tabs)
            printf '\n\t\t\t' >> "$CNE_STATE/nodes.tsv"
            printf '\n' >> "$CNE_STATE/ports" ;;
        ports-garbage)
            printf '\n' >> "$CNE_STATE/nodes.tsv"
            printf '\ngarbage-without-a-final-newline' >> "$CNE_STATE/ports" ;;
        valid-no-newline) ;;
        *) fail 'unknown final-line fixture' ;;
    esac
    cp "$CNE_STATE/nodes.tsv" "$WORK/$kind.nodes.before"
    cp "$CNE_STATE/ports" "$WORK/$kind.ports.before"
    if [[ $kind == valid-no-newline ]]; then
        cne_load_config > "$OUTPUT" 2>&1 || fail 'valid node and port files without final newlines were rejected'
        cne_configured || fail 'valid unterminated final lines did not publish complete nodes'
        [[ ${CNE_HOSTS[*]} == '203.0.113.10 198.51.100.20 192.0.2.30' && ${CNE_USERS[*]} == 'root root root' && ${CNE_CONNECTIONS[*]} == 'ssh ssh ssh' ]] || fail 'valid unterminated final lines were not fully loaded'
        [[ $CNE_USER_PORT == 51820 && $CNE_WSS_PORT == 443 ]] || fail 'valid unterminated port line was not loaded'
    else
        if cne_load_config > "$OUTPUT" 2>&1; then fail "$kind trailing unterminated content was ignored"; fi
        [[ $(runtime_configuration) == "$before" ]] || fail "$kind parse partially published runtime configuration"
    fi
    cmp "$WORK/$kind.nodes.before" "$CNE_STATE/nodes.tsv" || fail 'final-line parsing changed saved node bytes'
    cmp "$WORK/$kind.ports.before" "$CNE_STATE/ports" || fail 'final-line parsing changed saved port bytes'
    [[ ! -s $TRACE ]] || fail 'final-line parsing prepared dependencies'
    printf 'PASS: %s final-line parsing consumes all bytes and preserves saved settings\n' "$kind"
)

test_invalid_configuration_offline_menu() (
    local kind=$1 original
    setup "invalid-offline-$kind"
    mkdir -p "$CNE_STATE/clients"
    printf '[Interface]\nPrivateKey = offline-first-run-fixture\nAddress = 10.77.10.2/32\n\n[Peer]\nPublicKey = offline-server-fixture\nEndpoint = 203.0.113.10:51820\n' > "$CNE_STATE/clients/phone.conf"
    original=$WORK/$kind.nodes.original
    printf 'hk\t203.0.113.10\troot\t22\t-\tssh\n' > "$original"
    if [[ $kind == symlink ]]; then ln -s "$original" "$CNE_STATE/nodes.tsv"
    else cp "$original" "$CNE_STATE/nodes.tsv"; fi
    cne_main menu <<<'3
12
phone
2
0' > "$OUTPUT" 2>&1 || fail 'invalid saved settings blocked the management and offline file menus'
    [[ $CNE_CONFIG_INVALID == 1 ]] || fail 'invalid saved settings were not explicitly flagged'
    [[ -z ${CNE_HOSTS[0]} && -z ${CNE_HOSTS[1]} && -z ${CNE_HOSTS[2]} ]] || fail 'failed initialization retained a partially configured node'
    contains "$OUTPUT" 'PrivateKey = offline-first-run-fixture'
    contains "$OUTPUT" '离线查看不连接服务器，也不安装依赖'
    absent "$OUTPUT" '配置导出未完成|配置安装节点|连接方式（|首次准备：'
    cmp "$original" "$CNE_STATE/nodes.tsv" || fail 'read-only invalid-configuration menu changed the saved settings'
    [[ $kind != symlink || -L $CNE_STATE/nodes.tsv ]] || fail 'read-only menu replaced a node-configuration symlink'
    [[ $(cat "$TRACE") == 'bootstrap ui' ]] || fail 'invalid-configuration menu prepared remote dependencies'
    [[ -z $(find "$CNE_STATE/history" -mindepth 1 -print -quit) ]] || fail 'read-only invalid-configuration menu wrote repair history'
    printf 'PASS: %s saved node settings preserve offline file access and clear unusable runtime nodes\n' "$kind"
)

test_invalid_configuration_repair() (
    local choice=$1 history
    setup "repair-$choice"
    # Restore the real setup implementation; none of its operations may invoke
    # the package or SSH side-effect stubs installed by setup().
    source "$ROOT/shell/controller.sh"
    printf 'hk\t203.0.113.10\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    printf 'bad-port 443\n' > "$CNE_STATE/ports"
    cp "$CNE_STATE/nodes.tsv" "$WORK/repair-$choice.nodes.before"
    cp "$CNE_STATE/ports" "$WORK/repair-$choice.ports.before"
    cne_initialize > "$OUTPUT" 2>&1 || fail 'malformed configuration blocked initialization for repair'
    [[ $CNE_CONFIG_INVALID == 1 ]] || fail 'repair fixture was not flagged invalid'
    ANSWERS=(1 203.0.113.10 root 22 - 1 198.51.100.20 root 22 - 1 192.0.2.30 root 22 - 51820 443 "$choice")
    ANSWER_INDEX=0
    cne_prompt() {
        [[ $ANSWER_INDEX -lt ${#ANSWERS[@]} ]] || fail 'repair requested unexpected additional input'
        CNE_ANSWER=${ANSWERS[$ANSWER_INDEX]}
        ANSWER_INDEX=$((ANSWER_INDEX+1))
    }
    cne_setup >> "$OUTPUT" 2>&1 || fail 'owned malformed configuration could not be repaired or safely declined'
    if [[ $choice == y ]]; then
        cne_configured || fail 'confirmed repair did not publish valid runtime nodes'
        [[ $CNE_CONFIG_INVALID == 0 ]] || fail 'successful repair kept the invalid configuration flag'
        cne_load_config >> "$OUTPUT" 2>&1 || fail 'repaired saved settings could not be loaded'
        history=$(find "$CNE_STATE/history" -mindepth 1 -maxdepth 1 -type d -name 'node-settings.*')
        [[ -n $history && -d $history ]] || fail 'repair did not retain the original malformed files'
        cmp "$WORK/repair-$choice.nodes.before" "$history/nodes.tsv" || fail 'repair lost the original malformed node file'
        cmp "$WORK/repair-$choice.ports.before" "$history/ports" || fail 'repair lost the original malformed port file'
        [[ $CNE_USER_PORT == 51820 && $CNE_WSS_PORT == 443 ]] || fail 'repaired port settings were not published'
    else
        [[ $CNE_CONFIG_INVALID == 1 && -z ${CNE_HOSTS[0]} && -z ${CNE_HOSTS[1]} && -z ${CNE_HOSTS[2]} ]] || fail 'declining repair published runtime nodes'
        cmp "$WORK/repair-$choice.nodes.before" "$CNE_STATE/nodes.tsv" || fail 'declining repair changed original node settings'
        cmp "$WORK/repair-$choice.ports.before" "$CNE_STATE/ports" || fail 'declining repair changed original port settings'
        [[ -z $(find "$CNE_STATE/history" -mindepth 1 -print -quit) ]] || fail 'declining repair created unnecessary history'
    fi
    [[ ! -s $TRACE ]] || fail 'configuration repair prepared dependencies or connected to a node'
    printf 'PASS: malformed configuration repair (%s) preserves originals and publishes only after confirmation\n' "$choice"
)

test_symlink_configuration_repair_refused() (
    setup repair-symlink
    source "$ROOT/shell/controller.sh"
    printf 'original-settings-fixture\n' > "$WORK/symlink-repair-target"
    ln -s "$WORK/symlink-repair-target" "$CNE_STATE/nodes.tsv"
    cne_initialize > "$OUTPUT" 2>&1 || fail 'unsafe settings blocked access to the management menu'
    cne_prompt() { fail 'unsafe settings requested replacement details before rejecting the symlink'; }
    if cne_setup >> "$OUTPUT" 2>&1; then fail 'setup accepted a node-settings symlink for repair'; fi
    [[ -L $CNE_STATE/nodes.tsv && $(cat "$WORK/symlink-repair-target") == original-settings-fixture ]] || fail 'refused symlink repair changed the original target'
    [[ ! -s $TRACE ]] || fail 'refused symlink repair prepared dependencies'
    printf 'PASS: unsafe node-settings symlinks are refused before setup prompts and are never replaced\n'
)

test_readonly_failure_continues() (
    local operation=$1 failure=$2
    setup "continue-$operation-$failure"
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    cne_authenticate() {
        printf 'authenticate %s\n' "$1" >> "$TRACE"
        [[ $failure != authenticate || $1 != 1 ]]
    }
    cne_remote() {
        printf 'rpc %s %s\n' "$1" "$2" >> "$TRACE"
        printf 'fixture %s\n' "$1"
        [[ $failure != remote || $1 != 1 ]]
    }
    if [[ $operation == status ]]; then
        if cne_status > "$OUTPUT" 2>&1; then fail 'failed status was reported entirely successful'; fi
    else
        if cne_action_all "$operation" > "$OUTPUT" 2>&1; then fail "failed $operation was reported entirely successful"; fi
    fi
    contains "$TRACE" 'authenticate 0'
    contains "$TRACE" 'authenticate 1'
    contains "$TRACE" 'authenticate 2'
    contains "$TRACE" "rpc 0 $operation"
    contains "$TRACE" "rpc 2 $operation"
    contains "$OUTPUT" '香港入口'
    contains "$OUTPUT" '大陆中转'
    contains "$OUTPUT" '国内出口'
    absent "$TRACE" '^bootstrap '
    if [[ $failure == authenticate ]]; then absent "$TRACE" '^rpc 1 '; fi
    printf 'PASS: %s continues to inspect remaining nodes after one %s failure\n' "$operation" "$failure"
)

test_mutations_pre_authenticate() (
    local operation=$1
    setup "mutation-$operation"
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP"
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    cne_authenticate() { printf 'authenticate %s\n' "$1" >> "$TRACE"; [[ $1 != 1 ]]; }
    cne_remote() { fail 'service mutation ran before all node authentication succeeded'; }
    if cne_action_all "$operation" > "$OUTPUT" 2>&1; then fail "$operation ignored an authentication failure"; fi
    absent "$TRACE" '^rpc |^bootstrap '
    printf 'PASS: %s still authenticates all nodes before changing any service\n' "$operation"
)

test_empty_menu
test_empty_command status
test_empty_command doctor
test_missing_configuration_guard
for fixture in fresh configured noninteractive; do test_install_configuration_entry "$fixture"; done
for fixture in partial invalid-role duplicate-host invalid-ports; do test_atomic_config_parser "$fixture"; done
for fixture in nodes-garbage nodes-tabs ports-garbage valid-no-newline; do test_configuration_final_lines "$fixture"; done
for fixture in partial symlink; do test_invalid_configuration_offline_menu "$fixture"; done
test_invalid_configuration_repair n
test_invalid_configuration_repair y
test_symlink_configuration_repair_refused
for operation in status doctor logs; do
    for failure in authenticate remote; do test_readonly_failure_continues "$operation" "$failure"; done
done
for operation in start stop restart uninstall; do test_mutations_pre_authenticate "$operation"; done
printf 'First-run management checks passed. No packages, host services or SSH connections changed.\n'
