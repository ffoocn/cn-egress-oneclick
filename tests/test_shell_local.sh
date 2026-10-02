#!/usr/bin/env bash
# Local-node tests execute harmless fixtures in a private directory only.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-local-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_line() { grep -Fqx -- "$2" "$1" || fail "missing line: $2"; }
assert_absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected call: $2"; fi; }

mock_setup() {
    source "$ROOT/shell/controller.sh"
    CNE_STATE=$WORK/$1
    CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP"
    MOCK_TRACE=$CNE_STATE/trace
    : > "$MOCK_TRACE"
    MOCK_UID=0
    MOCK_SUDO_STATUS=0
    MOCK_SUDO_CACHE=valid
    CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
    CNE_USERS=(root root fixture)
    CNE_CONNECTIONS=(ssh ssh local)
    id() {
        case $* in
            -u) printf '%s\n' "$MOCK_UID" ;;
            -un) printf 'fixture\n' ;;
            *) fail "unexpected identity query: $*" ;;
        esac
    }
    sudo() {
        printf 'sudo %s\n' "$*" >> "$MOCK_TRACE"
        case ${1:-} in
            -v)
                [[ $# == 1 ]] || fail 'local authentication added unexpected sudo options'
                [[ $MOCK_SUDO_STATUS == 0 ]] || return "$MOCK_SUDO_STATUS"
                MOCK_SUDO_CACHE=valid ;;
            -n)
                shift
                if [[ ${1:-} == -v ]]; then
                    [[ $# == 1 ]] || fail 'noninteractive sudo validation added unexpected options'
                    [[ $MOCK_SUDO_CACHE == valid ]]
                    return
                fi
                [[ ${1:-} == /bin/bash ]] || fail 'local execution did not run the Bash fixture'
                [[ $MOCK_SUDO_STATUS == 0 ]] || return "$MOCK_SUDO_STATUS"
                "$@" ;;
            *) fail "unexpected sudo invocation: $*" ;;
        esac
    }
    cne_secret() { printf 'secret-prompt %s\n' "$*" >> "$MOCK_TRACE"; fail 'local node requested an SSH or stored sudo password'; }
    ssh() { printf 'ssh %s\n' "$*" >> "$MOCK_TRACE"; fail 'local node used SSH'; }
    sshpass() { printf 'sshpass %s\n' "$*" >> "$MOCK_TRACE"; fail 'local node used sshpass'; }
    apt-get() { fail 'unexpected host package operation'; }
    curl() { fail 'unexpected download'; }
}

write_nodes() {
    printf 'hk\t203.0.113.10\troot\t22\t-\nsh\t198.51.100.20\troot\t22\t-\nexit\t192.0.2.30\tfixture\t22\t-\n' > "$CNE_STATE/nodes.tsv"
}

test_legacy_config() (
    mock_setup legacy
    write_nodes
    cne_load_config > "$CNE_STATE/output" 2>&1 || fail 'five-column existing configuration was rejected'
    [[ ${CNE_CONNECTIONS[*]} == 'ssh ssh ssh' ]] || fail 'old configuration did not default each node to SSH'
    [[ ${CNE_HOSTS[*]} == '203.0.113.10 198.51.100.20 192.0.2.30' ]] || fail 'old addresses changed'
    printf 'PASS: five-column saved configurations retain SSH connections\n'
)

test_local_config() (
    mock_setup local-config
    printf 'hk\t203.0.113.10\tfixture\t22\t-\tlocal\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\tfixture\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    cne_load_config > "$CNE_STATE/output" 2>&1 || fail 'a single local role was rejected'
    [[ ${CNE_CONNECTIONS[*]} == 'local ssh ssh' ]] || fail 'connection types were not restored'
    [[ ${CNE_HOSTS[0]} == 203.0.113.10 ]] || fail 'local HK replaced its usable client endpoint with localhost'
    printf 'PASS: local roles retain their public endpoint independently of execution method\n'
)

test_canonical_config() (
    mock_setup canonical
    write_nodes
    local before after
    before=$(cne_nodes_canonical "$CNE_STATE/nodes.tsv") || fail 'old transaction nodes could not be normalized'
    awk -F'\t' '{print $0 "\tssh"}' "$CNE_STATE/nodes.tsv" > "$CNE_STATE/new-nodes.tsv"
    after=$(cne_nodes_canonical "$CNE_STATE/new-nodes.tsv") || fail 'new SSH nodes could not be normalized'
    [[ $before == "$after" ]] || fail 'format-only upgrade prevented recovery of the same SSH nodes'
    awk -F'\t' 'BEGIN{OFS="\t"} NR==1{$6="local"} {print}' "$CNE_STATE/new-nodes.tsv" > "$CNE_STATE/changed-nodes.tsv"
    after=$(cne_nodes_canonical "$CNE_STATE/changed-nodes.tsv") || fail 'new local nodes could not be normalized'
    [[ $before != "$after" ]] || fail 'changing execution from SSH to local was ignored by transaction comparison'
    printf 'PASS: transaction comparisons accept format upgrades and distinguish a changed execution method\n'
)

test_saved_unavailable_key() (
    local kind=$1
    mock_setup "saved-key-$kind"
    local identity=$CNE_STATE/unavailable-key
    [[ $kind != directory ]] || mkdir "$identity"
    printf 'hk\t203.0.113.10\troot\t22\t%s\tssh\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\tfixture\t22\t-\tssh\n' "$identity" > "$CNE_STATE/nodes.tsv"
    cne_load_config > "$CNE_STATE/output" 2>&1 || fail "saved $kind SSH key blocked loading node settings"
    [[ ${CNE_IDENTITIES[0]} == "$identity" ]] || fail 'saved SSH key path was discarded instead of being available for repair'
    CNE_AUTH_READY[0]=1
    cne_bootstrap() { fail 'unavailable SSH key prepared packages'; }
    if cne_authenticate 0 >> "$CNE_STATE/output" 2>&1; then fail 'unavailable SSH key bypassed validation using cached authentication'; fi
    [[ ${CNE_AUTH_READY[0]} == 0 && ! -s $MOCK_TRACE ]] || fail 'unavailable SSH key prompted credentials or started connections'
    grep -Fq '2. 修改节点' "$CNE_STATE/output" || fail 'unavailable SSH key did not explain how to update the path'
    printf 'PASS: saved %s SSH key permits configuration loading and stops SSH before dependency or password prompts\n' "$kind"
)

test_saved_symlink_key() (
    mock_setup saved-symlink-key
    printf 'private-key-fixture\n' > "$CNE_STATE/key-target"
    ln -s "$CNE_STATE/key-target" "$CNE_STATE/key-link"
    CNE_IDENTITIES[0]=$CNE_STATE/key-link
    CNE_CONNECTIONS[0]=ssh
    CNE_AUTH_READY[0]=1
    cne_bootstrap() { [[ $* == ssh ]] || fail 'SSH authentication prepared unrelated tools'; }
    cne_authenticate 0 > "$CNE_STATE/output" 2>&1 || fail 'readable key symlink was rejected'
    [[ ${CNE_AUTH_READY[0]} == 1 && ! -s $MOCK_TRACE ]] || fail 'valid cached key unnecessarily prompted for credentials'
    printf 'PASS: an existing readable SSH key reached through a symlink remains supported\n'
)

test_invalid_config() (
    local kind=$1
    mock_setup "invalid-$kind"
    case $kind in
        two-local)
            printf 'hk\t203.0.113.10\tfixture\t22\t-\tlocal\nsh\t198.51.100.20\tfixture\t22\t-\tlocal\nexit\t192.0.2.30\tfixture\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv" ;;
        unknown-type)
            printf 'hk\t203.0.113.10\troot\t22\t-\tcommand\nsh\t198.51.100.20\troot\t22\t-\tssh\nexit\t192.0.2.30\tfixture\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv" ;;
    esac
    if cne_load_config > "$CNE_STATE/output" 2>&1; then fail "invalid connection configuration accepted: $kind"; fi
    [[ ! -s $MOCK_TRACE ]] || fail 'invalid configuration initiated connections or authentication'
    printf 'PASS: %s configuration is rejected without connecting\n' "$kind"
)

test_local_authentication() (
    local uid=$1
    mock_setup "authentication-$uid"
    MOCK_UID=$uid
    CNE_PASSWORDS[2]=obsolete-ssh-fixture
    CNE_SUDOS[2]=obsolete-sudo-fixture
    cne_authenticate 2 > "$CNE_STATE/output" 2>&1 || fail 'local authentication failed'
    cne_authenticate 2 >> "$CNE_STATE/output" 2>&1 || fail 'cached local authentication failed'
    [[ ${CNE_AUTH_READY[2]} == 1 && -z ${CNE_PASSWORDS[2]} && -z ${CNE_SUDOS[2]} ]] || fail 'local authentication stored a password'
    if [[ $uid == 0 ]]; then
        [[ ! -s $MOCK_TRACE ]] || fail 'root local authentication invoked sudo or requested secrets'
    else
        [[ $(cat "$MOCK_TRACE") == $'sudo -v\nsudo -v' ]] || fail 'nonroot local authentication did not refresh sudo for each operation'
    fi
    printf 'PASS: local UID %s authenticates without SSH credentials\n' "$uid"
)

test_sudo_refusal() (
    mock_setup sudo-refusal
    MOCK_UID=1000
    MOCK_SUDO_STATUS=1
    if cne_authenticate 2 > "$CNE_STATE/output" 2>&1; then fail 'sudo refusal was ignored'; fi
    [[ ${CNE_AUTH_READY[2]} == 0 ]] || fail 'failed sudo validation was cached as authenticated'
    assert_line "$MOCK_TRACE" 'sudo -v'
    assert_absent "$MOCK_TRACE" 'ssh|secret-prompt'
    printf 'PASS: refused local sudo validation stops without an SSH fallback\n'
)

test_local_script() (
    local uid=$1
    mock_setup "script-$uid"
    MOCK_UID=$uid
    local script=$CNE_TEMP/fixture.sh
    printf 'printf "fixture-executed\\n"\nexit 17\n' > "$script"
    local result=0
    cne_send_script 2 "$script" > "$CNE_STATE/output" 2>&1 || result=$?
    [[ $result == 17 ]] || fail "local script exit status was changed: $result"
    assert_line "$CNE_STATE/output" fixture-executed
    if [[ $uid == 0 ]]; then [[ ! -s $MOCK_TRACE ]] || fail 'root local execution invoked sudo';
    else
        [[ $(cat "$MOCK_TRACE") == "sudo -n -v"$'\n'"sudo -n /bin/bash $script" ]] || fail 'local execution did not refresh and use noninteractive sudo'
    fi
    printf 'PASS: local UID %s executes the same script and preserves its exit status\n' "$uid"
)

test_expired_sudo() (
    local result_expected=$1
    mock_setup "sudo-expired-$result_expected"
    MOCK_UID=1000
    MOCK_SUDO_CACHE=expired
    local script=$CNE_TEMP/fixture.sh
    printf 'printf "fixture-executed\\n"\n' > "$script"
    local result=0
    [[ $result_expected == success ]] || MOCK_SUDO_STATUS=1
    cne_send_script 2 "$script" > "$CNE_STATE/output" 2>&1 || result=$?
    assert_line "$MOCK_TRACE" 'sudo -n -v'
    assert_line "$MOCK_TRACE" 'sudo -v'
    grep -Fq '本机管理员授权已过期' "$CNE_STATE/output" || fail 'expired sudo authorization did not explain the request'
    if [[ $result_expected == success ]]; then
        [[ $result == 0 ]] || fail 'renewed sudo validation did not permit local execution'
        [[ $(cat "$MOCK_TRACE") == "sudo -n -v"$'\n'"sudo -v"$'\n'"sudo -n /bin/bash $script" ]] || fail 'expired sudo execution order is incorrect'
        assert_line "$CNE_STATE/output" fixture-executed
    else
        [[ $result == 1 ]] || fail 'refused sudo renewal was ignored'
        assert_absent "$MOCK_TRACE" 'sudo -n /bin/bash'
        assert_absent "$CNE_STATE/output" '^fixture-executed$'
    fi
    assert_absent "$MOCK_TRACE" 'ssh|secret-prompt'
    printf 'PASS: expired sudo cache %s is handled before any local RPC executes\n' "$result_expected"
)

test_local_rpc() (
    mock_setup rpc
    cne_node_source() {
        printf 'cne_node_main() { printf "role=%%s action=%%s argument=%%s\\n" "$2" "$1" "$3"; }\n'
    }
    cne_remote 2 inspect 'literal argument; exit 91' > "$CNE_STATE/output" 2>&1 || fail 'local RPC failed'
    assert_line "$CNE_STATE/output" 'role=exit action=inspect argument=literal argument; exit 91'
    [[ -z $(find "$CNE_TEMP" -name 'rpc.*' -print -quit) ]] || fail 'local RPC left its generated script behind'
    [[ ! -s $MOCK_TRACE ]] || fail 'local RPC invoked SSH, sudo or password prompts as root'
    printf 'PASS: local execution uses the shared, safely quoted node RPC\n'
)

test_local_install_payload() (
    mock_setup payload
    printf 'fixture archive content\n' > "$CNE_TEMP/archive.tar.gz"
    cne_node_source() {
        # Redirect the install RPC upload into the private test directory.
        printf 'mktemp() { command mktemp %q; }\n' "$CNE_TEMP/upload.XXXXXX"
        printf 'cne_node_main() { [[ "$1 $2 $3 $5" == "install exit fresh fixture-deployment" ]] || exit 98; cat "$4"; }\n'
    }
    cne_remote_install 2 fresh "$CNE_TEMP/archive.tar.gz" fixture-deployment > "$CNE_STATE/output" 2>&1 || fail 'shared local install RPC failed'
    cmp "$CNE_TEMP/archive.tar.gz" "$CNE_STATE/output" || fail 'local install payload changed'
    [[ -z $(find "$CNE_TEMP" \( -name 'upload.*' -o -name 'install.*' \) -print -quit) ]] || fail 'local installation RPC retained temporary uploads'
    [[ ! -s $MOCK_TRACE ]] || fail 'local install used SSH credentials or privilege escalation as root'
    printf 'PASS: local installation uses the same embedded payload and cleans its upload\n'
)

test_local_failure_reauthentication() (
    mock_setup reauthentication
    MOCK_UID=1000
    CNE_AUTH_READY[2]=1
    cne_node_source() { printf 'cne_node_main() { return 42; }\n'; }
    local output result=0
    output=$(cne_remote 2 inspect 2> "$CNE_STATE/output") || result=$?
    [[ $result == 42 && -f $CNE_TEMP/auth-failed-2 ]] || fail 'failed subshell RPC did not record an authentication retry'
    cne_authenticate 2 >> "$CNE_STATE/output" 2>&1 || fail 'local authentication retry failed'
    [[ ! -e $CNE_TEMP/auth-failed-2 && ${CNE_AUTH_READY[2]} == 1 ]] || fail 'local authentication retry did not clear the failure marker'
    assert_line "$MOCK_TRACE" 'sudo -v'
    assert_absent "$MOCK_TRACE" 'ssh|secret-prompt'
    printf 'PASS: failed local RPC in a subshell requests sudo validation on the next attempt\n'
)

test_local_setup() (
    local reserved=${1:-no}
    mock_setup "setup-$reserved"
    local connection_questions=0 ssh_questions=0 udp_questions=0
    CNE_CONNECTIONS=(ssh ssh ssh)
    cne_prompt() {
        printf 'prompt %s %s\n' "$idx" "$1" >> "$MOCK_TRACE"
        case $1 in
            *连接方式*)
                connection_questions=$((connection_questions+1))
                if [[ $idx == 2 ]]; then CNE_ANSWER=2; else CNE_ANSWER=1; fi ;;
            *IPv4*) CNE_ANSWER=${CNE_HOSTS[$idx]} ;;
            *SSH*用户*) [[ $idx != 2 ]] || fail 'local setup requested an SSH username'; ssh_questions=$((ssh_questions+1)); CNE_ANSWER=root ;;
            *SSH*端口*) [[ $idx != 2 ]] || fail 'local setup requested an SSH port'; ssh_questions=$((ssh_questions+1)); CNE_ANSWER=22 ;;
            *SSH*私钥*) [[ $idx != 2 ]] || fail 'local setup requested an SSH identity'; ssh_questions=$((ssh_questions+1)); CNE_ANSWER=- ;;
            *客户端*端口*)
                udp_questions=$((udp_questions+1))
                if [[ $reserved == yes && $udp_questions == 1 ]]; then CNE_ANSWER=51831; else CNE_ANSWER=51820; fi ;;
            *TLS*端口*) CNE_ANSWER=443 ;;
            *) fail "unexpected setup question: $1" ;;
        esac
    }
    cne_setup > "$CNE_STATE/output" 2>&1 || fail 'local setup failed'
    [[ $connection_questions == 3 && $ssh_questions == 6 ]] || fail 'setup asked unexpected connection or SSH questions'
    assert_line "$CNE_STATE/nodes.tsv" $'exit\t192.0.2.30\tfixture\t22\t-\tlocal'
    [[ ${CNE_CONNECTIONS[*]} == 'ssh ssh local' ]] || fail 'setup did not retain the local selection'
    [[ ${CNE_USERS[2]} == fixture && ${CNE_PORTS[2]} == 22 && ${CNE_IDENTITIES[2]} == - ]] || fail 'local node inherited obsolete SSH identity settings'
    if [[ $reserved == yes ]]; then
        [[ $udp_questions == 2 && $CNE_USER_PORT == 51820 ]] || fail 'reserved client port was saved instead of asking for another port'
        grep -Fq '51831 用于内部隧道' "$CNE_STATE/output" || fail 'reserved client port was not explained'
        assert_absent "$MOCK_TRACE" '^ssh|secret-prompt'
        printf 'PASS: reserved client port is rejected during setup before SSH authentication\n'
    else
        [[ $udp_questions == 1 ]] || fail 'valid client port was unexpectedly asked again'
        printf 'PASS: selecting this machine skips irrelevant SSH questions and saves the local role\n'
    fi
)

test_setup_cancel() (
    local position=$1
    mock_setup "setup-cancel-$position"
    write_nodes
    printf '51820 443\n' > "$CNE_STATE/ports"
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/nodes.before"
    cp "$CNE_STATE/ports" "$CNE_STATE/ports.before"
    CNE_AUTH_READY=(1 1 1)
    CNE_PASSWORDS=(first-fixture second-fixture third-fixture)
    local globals_before globals_after
    globals_before=$(declare -p CNE_HOSTS CNE_USERS CNE_PORTS CNE_IDENTITIES CNE_CONNECTIONS CNE_USER_PORT CNE_WSS_PORT CNE_AUTH_READY CNE_PASSWORDS)
    cne_prompt() {
        printf 'prompt %s %s\n' "$idx" "$1" >> "$MOCK_TRACE"
        case $1 in
            *连接方式*) if [[ $position == early ]]; then CNE_ANSWER=0; elif [[ $idx == 2 ]]; then CNE_ANSWER=2; else CNE_ANSWER=1; fi ;;
            *IPv4*) CNE_ANSWER=203.0.113.$((idx+100)) ;;
            *SSH*用户*) CNE_ANSWER=root ;;
            *SSH*端口*) CNE_ANSWER=2222 ;;
            *SSH*私钥*) CNE_ANSWER=- ;;
            *客户端*端口*) CNE_ANSWER=51821 ;;
            *TLS*端口*) CNE_ANSWER=0 ;;
            *) fail "unexpected cancellation question: $1" ;;
        esac
    }
    if cne_setup > "$CNE_STATE/output" 2>&1; then fail 'cancelled setup reported saved configuration'; fi
    cmp "$CNE_STATE/nodes.before" "$CNE_STATE/nodes.tsv" || fail 'cancelled setup changed saved nodes'
    cmp "$CNE_STATE/ports.before" "$CNE_STATE/ports" || fail 'cancelled setup changed saved ports'
    globals_after=$(declare -p CNE_HOSTS CNE_USERS CNE_PORTS CNE_IDENTITIES CNE_CONNECTIONS CNE_USER_PORT CNE_WSS_PORT CNE_AUTH_READY CNE_PASSWORDS)
    [[ $globals_before == "$globals_after" ]] || fail 'cancelled setup published staged settings or cleared current authentication'
    [[ ! -e $CNE_TEMP/nodes.tsv && ! -e $CNE_TEMP/ports ]] || fail 'cancelled setup left publishable partial settings'
    grep -Fq '已取消节点设置，配置未保存' "$CNE_STATE/output" || fail 'cancelled setup did not explain that current settings are retained'
    assert_absent "$MOCK_TRACE" '^ssh|sudo|secret-prompt'
    printf 'PASS: %s setup cancellation retains node files, ports, credentials and runtime settings\n' "$position"
)

test_setup_pending_journal() (
    local kind=$1
    mock_setup "setup-pending-$kind"
    write_nodes
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/nodes.before"
    case $kind in
        file) printf 'unfinished-fixture\n' > "$CNE_STATE/active-transaction" ;;
        dangling-link) ln -s "$CNE_STATE/missing-journal" "$CNE_STATE/active-transaction" ;;
    esac
    cne_prompt() { fail 'pending recovery allowed settings prompts'; }
    if cne_setup > "$CNE_STATE/output" 2>&1; then fail 'pending recovery allowed node changes'; fi
    cmp "$CNE_STATE/nodes.before" "$CNE_STATE/nodes.tsv" || fail 'pending recovery changed saved nodes'
    [[ -e $CNE_STATE/active-transaction || -L $CNE_STATE/active-transaction ]] || fail 'pending recovery marker was removed'
    grep -Fq '维护与设置 → 重试恢复' "$CNE_STATE/output" || fail 'pending recovery did not provide an actionable menu instruction'
    [[ ! -s $MOCK_TRACE ]] || fail 'blocked setup requested connections or authentication'
    printf 'PASS: pending %s recovery marker prevents settings changes before asking questions\n' "$kind"
)

test_legacy_config
test_local_config
test_canonical_config
test_saved_unavailable_key missing
test_saved_unavailable_key directory
test_saved_symlink_key
test_invalid_config two-local
test_invalid_config unknown-type
test_local_authentication 0
test_local_authentication 1000
test_sudo_refusal
test_local_script 0
test_local_script 1000
test_expired_sudo success
test_expired_sudo refused
test_local_rpc
test_local_install_payload
test_local_failure_reauthentication
test_local_setup
test_local_setup yes
test_setup_cancel early
test_setup_cancel late
test_setup_pending_journal file
test_setup_pending_journal dangling-link
printf 'Local-node checks passed. No host services or SSH connections were changed.\n'
