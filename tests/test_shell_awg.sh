#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source shell/controller.sh
source shell/download.sh
source shell/awg.sh
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
CNE_TEMP=$work
CNE_STATE=$work/state
mkdir "$CNE_STATE"
cne_error() { printf '%s\n' "$*" >&2; return 1; }
# BSD chmod treats -- as a filename; production GNU chmod accepts it.
chmod() { local arg args=(); for arg in "$@"; do [[ $arg == -- ]] || args+=("$arg"); done; command chmod "${args[@]}"; }
calls=0
curl() {
    calls=$((calls+1))
    local previous='' arg
    for arg in "$@"; do
        [[ $previous != -o ]] || { printf '%s' "$fixture" > "$arg"; return; }
        previous=$arg
    done
    return 1
}
sha256sum() {
    if command -v /usr/bin/sha256sum >/dev/null 2>&1; then /usr/bin/sha256sum "$@"
    else shasum -a 256 "$@"; fi
}
fixture=verified-source
printf '%s' "$fixture" > "$work/fixture"
checksum=$(sha256sum "$work/fixture" | awk '{print $1}')
cne_awg_download https://example.invalid/source "$checksum" "$work/source.tar.gz"
cmp "$work/source.tar.gz" "$work/fixture"
[[ $calls == 1 ]]
cne_awg_download https://example.invalid/source "$checksum" "$work/source.tar.gz"
[[ $calls == 1 ]]
fixture=unverified-source
if cne_awg_download https://example.invalid/source "${checksum%?}0" "$work/source.tar.gz" 2>/dev/null; then exit 1; fi
cmp "$work/source.tar.gz" "$work/fixture"
[[ $(find "$work" -name 'component-download.*' | wc -l | tr -d ' ') == 0 ]]
[[ $(cne_awg_arch x86_64) == amd64 && $(cne_awg_arch aarch64) == arm64 ]]
if cne_awg_arch mips >/dev/null; then exit 1; fi
printf 'PASS: verified AWG download cache, rejected corruption, atomic publication and architecture checks\n'
