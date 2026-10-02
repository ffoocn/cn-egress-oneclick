#!/usr/bin/env bash
# Build a plain Shell release. No archives, Python or generated runtime sources.
set -euo pipefail
cd -- "$(dirname -- "$0")"
output=${1:-cn-egress-oneclick.sh}
temporary=$(mktemp "${output}.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT
emit_source() {
    local name=$1 path=$2 marker
    marker=CNE_EMBEDDED_${name}_V2
    printf '\n%s() {\ncat <<'\''%s'\''\n' "$name" "$marker"
    cat "$path"
    printf '\n%s\n}\n' "$marker"
}
{
    printf '#!/usr/bin/env bash\n# 一键安装与管理 — standalone Bash release\nset -uo pipefail\n'
    emit_source cne_node_source shell/node.sh
    emit_source cne_net_source shell/assets/cn-egress-net.sh
    emit_source cne_obfs_source shell/assets/cn-egress-obfs.sh
    emit_source cne_users_source shell/assets/cn-egress-users.sh
    emit_source cne_probe_source shell/assets/cn-egress-probe.sh
    emit_source cne_restrictions_source shell/assets/restrictions.yaml
    cat shell/bootstrap.sh shell/awg.sh shell/render.sh shell/controller.sh
    printf '\nif [[ ${BASH_SOURCE[0]} == "$0" ]]; then cne_main "$@"; fi\n'
} > "$temporary"
bash -n "$temporary"
chmod 755 "$temporary"
mv -- "$temporary" "$output"
printf 'Built %s\n' "$output"
