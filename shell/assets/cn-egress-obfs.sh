#!/usr/bin/env bash
# Run the authenticated transport without modifying host routes or trust stores.
set -euo pipefail
config=/etc/cn-egress-wss
IFS= read -r role < "$config/role"
IFS= read -r host < "$config/sh-host"
IFS= read -r port < "$config/port"
[[ $role == hk || $role == sh || $role == exit ]] || { printf 'Invalid transport role\n' >&2; exit 1; }
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && ${#host} -le 253 ]] || { printf 'Invalid transport host\n' >&2; exit 1; }
[[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { printf 'Invalid transport port\n' >&2; exit 1; }
internal=(51831 51821 51822 51832 5354)
if [[ -e $config/internal-ports || -L $config/internal-ports ]]; then
    [[ -f $config/internal-ports && ! -L $config/internal-ports && $(awk 'END{print NR}' "$config/internal-ports") == 1 ]] || { printf 'Invalid internal port settings\n' >&2; exit 1; }
    IFS=' ' read -r -a internal < "$config/internal-ports"
    ((${#internal[@]}==5)) || { printf 'Invalid internal port settings\n' >&2; exit 1; }
    for value in "${internal[@]}"; do [[ $value =~ ^[1-9][0-9]{0,4}$ ]] && ((value<=65535)) || { printf 'Invalid internal port\n' >&2; exit 1; }; done
    [[ ${internal[1]} != "${internal[2]}" && ${internal[3]} != "${internal[4]}" ]] || { printf 'Conflicting internal ports\n' >&2; exit 1; }
fi
binary=/opt/cn-egress/wstunnel-11.0.0/wstunnel
mode=client
[[ $role != sh ]] || mode=server
args=("$binary" "$mode" --no-color --log-lvl INFO --nb-worker-threads 2
    --tls-certificate "$config/node.crt" --tls-private-key "$config/node.key")
if [[ $role == sh ]]; then
    args+=(--tls-client-ca-certs "$config/ca.crt" --restrict-config "$config/restrictions.yaml" "wss://0.0.0.0:$port")
else
    export SSL_CERT_FILE="$config/ca.crt" SSL_CERT_DIR="$config/empty-ca"
    if [[ $role == hk ]]; then local_port=${internal[0]}; remote_port=${internal[1]}; else local_port=${internal[3]}; remote_port=${internal[2]}; fi
    args+=(--tls-verify-certificate --http-upgrade-path-prefix "cn-egress-$role" -L
        "udp://127.0.0.1:$local_port:127.0.0.1:$remote_port?timeout_sec=0" "wss://$host:$port")
fi
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
exec "${args[@]}"
