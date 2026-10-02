#!/usr/bin/env bash
# Exercise the real prompts and safe defaults with isolated node/settings files.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-novice-setup.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
fixture() {
    source "$ROOT/shell/controller.sh"
    CNE_STATE=$WORK/$1; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/history"
    OUTPUT=$CNE_STATE/output; TRACE=$CNE_STATE/mutations; : > "$TRACE"
    id() { [[ $* == -un ]] || fail 'setup requested unexpected user metadata'; printf 'fixture\n'; }
    hostname() { printf 'exit-machine\n'; }
    ip() { [[ $* == '-4 route get 1.1.1.1' ]] || fail 'setup requested a network mutation'; printf '1.1.1.1 dev eth0 src 10.200.10.2\n'; }
    ssh() { fail 'setup connected to a node'; }
    curl() { fail 'setup contacted an IP lookup'; }
    apt-get() { fail 'setup installed packages'; }
    sudo() { fail 'setup requested administrator access'; }
    cne_remote() { printf 'rpc\n' >> "$TRACE"; fail 'setup changed a service'; }
}
save_existing() {
    CNE_HOSTS=(8.8.8.10 9.9.9.20 10.200.10.2)
    printf 'hk\t8.8.8.10\troot\t22\t-\tssh\nsh\t9.9.9.20\troot\t22\t-\tssh\nexit\t10.200.10.2\troot\t22\t-\tssh\n' > "$CNE_STATE/nodes.tsv"
    printf '51820 443\n' > "$CNE_STATE/ports"
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/nodes.before"
    cp "$CNE_STATE/ports" "$CNE_STATE/ports.before"
}

(
    fixture recommended
    # Public endpoints must reject private, loopback and multicast entries;
    # the local exit still uses its detected LAN address without SSH questions.
    printf '1\n1\n10.1.2.3\n127.0.0.1\n224.0.0.1\n8.8.8.10\n\n1\n100.64.1.1\n9.9.9.20\n\n2\n\ny\n' > "$CNE_STATE/input"
    cne_setup < "$CNE_STATE/input" > "$OUTPUT" 2>&1 || fail 'recommended setup did not complete'
    cne_configured || fail 'recommended configuration did not publish all three nodes'
    [[ ${CNE_HOSTS[*]} == '8.8.8.10 9.9.9.20 10.200.10.2' && ${CNE_CONNECTIONS[*]} == 'ssh ssh local' ]] || fail 'invalid endpoint or wrong local role was saved'
    [[ ${CNE_PORTS[*]} == '22 22 22' && ${CNE_IDENTITIES[*]} == '- - -' && $CNE_USER_PORT == 51820 && $CNE_WSS_PORT == 443 ]] || fail 'recommended defaults were not used'
    grep -Fq '当前运行：exit-machine（网卡地址：10.200.10.2，账号：fixture）' "$OUTPUT" || fail 'current machine was not identified'
    grep -Fq '不要填内网地址' "$OUTPUT" || fail 'private HK address had no correction instruction'
    grep -Fq '大陆中转需要公网 IPv4' "$OUTPUT" || fail 'relay address had no correction instruction'
    grep -Fq '当前本机 exit-machine' "$OUTPUT" || fail 'confirmation did not identify the machine receiving local commands'
    if grep -Eq '登录端口（SSH 端口|SSH 私钥绝对路径|手机连接端口（客户端|大陆中转连接端口（TLS' "$OUTPUT"; then fail 'recommended setup asked advanced fields'; fi
    [[ ! -s $TRACE ]] || fail 'settings changed server services'
    printf 'PASS: real recommended prompts identify the current machine, reject unusable public endpoints and retain safe defaults\n'
)

(
    fixture duplicate
    printf '1\n1\n8.8.8.10\n\n1\n8.8.8.10\n9.9.9.20\n\n2\n\ny\n' > "$CNE_STATE/input"
    cne_setup < "$CNE_STATE/input" > "$OUTPUT" 2>&1 || fail 'duplicate address could not be corrected in place'
    grep -Fq '这个地址已经用于前面的节点' "$OUTPUT" || fail 'duplicate address had no immediate feedback'
    [[ ${CNE_HOSTS[1]} == 9.9.9.20 ]] || fail 'duplicate address was saved'
    printf 'PASS: duplicate node addresses are corrected at the affected field without losing earlier answers\n'
)

(
    fixture preserve-recommended
    save_existing
    key=$CNE_STATE/existing-key; printf 'do-not-display-key-content\n' > "$key"
    CNE_USERS[0]=operator; CNE_PORTS[0]=2222; CNE_IDENTITIES[0]=$key
    CNE_USER_PORT=60000; CNE_WSS_PORT=8443
    printf 'hk\t8.8.8.10\toperator\t2222\t%s\tssh\nsh\t9.9.9.20\troot\t22\t-\tssh\nexit\t10.200.10.2\troot\t22\t-\tssh\n' "$key" > "$CNE_STATE/nodes.tsv"
    printf '60000 8443\n' > "$CNE_STATE/ports"
    cp "$CNE_STATE/nodes.tsv" "$CNE_STATE/nodes.before"
    printf '1\n1\n\n\n1\n\n\n1\n\n\ny\n' > "$CNE_STATE/input"
    cne_setup < "$CNE_STATE/input" > "$OUTPUT" 2>&1 || fail 'recommended edit did not retain existing advanced settings'
    cmp "$CNE_STATE/nodes.before" "$CNE_STATE/nodes.tsv" || fail 'recommended defaults discarded existing SSH credentials'
    [[ $CNE_USER_PORT == 60000 && $CNE_WSS_PORT == 8443 && ${CNE_IDENTITIES[0]} == "$key" ]] || fail 'recommended edit reset service ports or key path'
    if grep -Fq 'do-not-display-key-content' "$OUTPUT"; then fail 'confirmation read or displayed private-key contents'; fi
    [[ ! -s $TRACE ]] || fail 'recommended edit changed server services'
    printf 'PASS: recommended edits retain existing SSH keys and custom ports without reading private-key contents\n'
)

(
    fixture cancelled
    printf '1\n1\n8.8.8.10\n\n1\n9.9.9.20\n\n2\n\n\n' > "$CNE_STATE/input"
    cne_setup < "$CNE_STATE/input" > "$OUTPUT" 2>&1 || fail 'declining first-run confirmation did not return safely'
    [[ ! -e $CNE_STATE/nodes.tsv && ! -e $CNE_STATE/ports && -z ${CNE_HOSTS[0]} ]] || fail 'default refusal saved a partial configuration'
    grep -Fq '未修改服务器' "$OUTPUT" || fail 'cancellation did not explain the safe outcome'
    printf 'PASS: first-run confirmation defaults to refusal and does not publish any settings or contact servers\n'
)

for confirmation in n y; do (
    fixture "metadata-$confirmation"
    save_existing
    key=$CNE_STATE/private-key; printf 'fixture-key-file\n' > "$key"
    # All addresses and service ports stay unchanged: only connection method,
    # account, SSH port and credential path change.
    printf '2\n2\n8.8.8.10\n1\n9.9.9.20\noperator\n2222\n%s\n1\n10.200.10.2\nroot\n22\n-\n51820\n443\n%s\n' "$key" "$confirmation" > "$CNE_STATE/input"
    cne_setup < "$CNE_STATE/input" > "$OUTPUT" 2>&1 || fail 'metadata-only edit failed'
    for expected in '变更 香港入口连接方式：远程服务器 → 当前本机' '变更 大陆中转登录账号：root → operator' '变更 大陆中转登录端口：22 → 2222' '变更 大陆中转登录凭据文件：- →' '本次只调整管理登录设置'; do
        grep -Fq "$expected" "$OUTPUT" || fail "metadata change was not explained: $expected"
    done
    if [[ $confirmation == n ]]; then
        cmp "$CNE_STATE/nodes.before" "$CNE_STATE/nodes.tsv" || fail 'declined metadata change altered saved nodes'
        [[ ${CNE_CONNECTIONS[0]} == ssh && ${CNE_PORTS[1]} == 22 ]] || fail 'declined metadata change altered runtime settings'
        [[ -z $(find "$CNE_STATE/history" -mindepth 1 -print -quit) ]] || fail 'declined edit archived unnecessarily'
    else
        [[ ${CNE_CONNECTIONS[0]} == local && ${CNE_USERS[1]} == operator && ${CNE_PORTS[1]} == 2222 && ${CNE_IDENTITIES[1]} == "$key" ]] || fail 'confirmed metadata change was not saved'
        history=$(find "$CNE_STATE/history" -mindepth 1 -maxdepth 1 -type d -name 'node-settings.*')
        [[ -n $history ]] || fail 'metadata-only changes did not retain the prior settings'
        cmp "$CNE_STATE/nodes.before" "$history/nodes.tsv" || fail 'metadata history lost the old settings'
    fi
    [[ ! -s $TRACE ]] || fail 'metadata edit changed a server'
    printf 'PASS: metadata-only changes (%s) require complete confirmation and preserve prior settings\n' "$confirmation"
); done

(
    fixture advanced-invalid-port
    printf '2\n1\n8.8.8.10\nroot\n22\n-\n1\n9.9.9.20\nroot\n22\n-\n2\n\n51820\nwrong\n8443\ny\n' > "$CNE_STATE/input"
    cne_setup < "$CNE_STATE/input" > "$OUTPUT" 2>&1 || fail 'invalid advanced TLS port could not be corrected'
    [[ $CNE_WSS_PORT == 8443 ]] || fail 'corrected TLS port was not saved'
    grep -Fq '端口范围为 1–65535' "$OUTPUT" || fail 'invalid TLS port had no explanation'
    printf 'PASS: advanced port validation explains allowed values and accepts correction without restarting setup\n'
)

for role in hk sh exit; do
    output=$WORK/dependency-$role.output
    cat > "$WORK/dependency-$role.sh" <<EOF
set -Eeuo pipefail
source '$ROOT/shell/node.sh'
cne_n_os_check() { return 0; }
cne_n_has() { case \$1 in apt-get|dpkg) return 0;; *) return 1;; esac; }
dpkg-query() { return 1; }
dpkg() { printf 'fixture-package is unpacked but not configured\n'; }
apt-get() { printf 'MUTATION\n'; exit 99; }
cne_n_prepare '$role' wireguard
printf 'UNEXPECTED SUCCESS\n'
EOF
    if bash "$WORK/dependency-$role.sh" > "$output" 2>&1; then fail 'pending package state was accepted'; fi
    case $role in hk) label=香港入口;; sh) label=大陆中转;; exit) label=国内出口;; esac
    grep -Fq "${label}：现有软件包状态未完成" "$output" || fail 'dependency failure did not identify its node'
    grep -Fq 'fixture-package is unpacked but not configured' "$output" || fail 'dpkg details disappeared under real errexit behavior'
    grep -Fq 'sudo dpkg --audit' "$output" || fail 'dependency error omitted the safe follow-up check'
    grep -Fq '主菜单选择“一键安装”重试' "$output" || fail 'dependency error omitted the retry path'
    if grep -Eq 'MUTATION|UNEXPECTED SUCCESS' "$output"; then fail 'pending package state permitted mutations'; fi
    printf 'PASS: %s dependency failure preserves dpkg details and gives a node-specific read-only check and retry path\n' "$role"
done
