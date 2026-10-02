#!/usr/bin/env bash
# Download and portable-cache boundary tests use local fixtures only.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-download-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
chmod() { local arg args=(); for arg in "$@"; do [[ $arg == -- ]] || args+=("$arg"); done; command chmod "${args[@]}"; }
source "$ROOT/shell/download.sh"
REAL_SPECS=$(cne_download_component_specs)
SOURCE_NAME=amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz

setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/download.sh"
    CNE_STATE=$WORK/$1; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_STATE/cache" "$CNE_TEMP"
    TRACE=$CNE_STATE/calls; : > "$TRACE"
    FIXTURE=verified-component; CURL_RESULT=0
    curl() {
        printf '%s\n' "$*" >> "$TRACE"
        [[ $CURL_RESULT == 0 ]] || return 7
        local previous='' argument
        for argument in "$@"; do [[ $previous != -o ]] || { printf '%s' "$FIXTURE" > "$argument"; return 0; }; previous=$argument; done
        return 1
    }
    ssh() { fail 'unexpected SSH'; }; sudo() { fail 'unexpected sudo'; }; apt-get() { fail 'unexpected package operation'; }
}

test_download() (
    setup download
    printf '%s' "$FIXTURE" > "$CNE_TEMP/fixture"
    local expected before
    expected=$(sha256sum "$CNE_TEMP/fixture" | awk '{print $1}')
    printf 'github_prefix\thttps://mirror.invalid/\ngo_base\thttps://go.invalid/files\ngoproxy\thttps://modules.invalid\n' > "$CNE_STATE/downloads.tsv"
    cne_download_verified https://github.com/project/file "$expected" "$CNE_STATE/cache/file" fixture
    contains "$TRACE" 'https://mirror.invalid/https://github.com/project/file'
    contains "$TRACE" '--proto =https --proto-redir =https'
    before=$(wc -l < "$TRACE")
    CURL_RESULT=7
    cne_download_verified https://github.com/project/file "$expected" "$CNE_STATE/cache/file" fixture
    [[ $(wc -l < "$TRACE") == "$before" ]] || fail 'verified cache used the network'
    [[ $(cne_download_url https://go.dev/dl/go1.24.4.linux-arm64.tar.gz) == https://go.invalid/files/go1.24.4.linux-arm64.tar.gz ]]
    CURL_RESULT=0; FIXTURE=corrupted-component
    if cne_download_verified https://github.com/project/file "${expected%?}0" "$CNE_STATE/cache/file" fixture 2>/dev/null; then fail 'corruption accepted'; fi
    cmp "$CNE_TEMP/fixture" "$CNE_STATE/cache/file" || fail 'bad download replaced verified cache'
    [[ -z $(find "$CNE_TEMP" -name 'component-download.*' -print) ]] || fail 'partial download remained'
    printf 'PASS: HTTPS mirrors preserve pinned checksums, cache reuse and atomic failure\n'
)

test_settings() (
    setup settings
    local value
    for value in 'http://mirror.invalid' 'https://user:password@mirror.invalid' 'https://mirror.invalid/?token=secret' '$(touch /tmp/unsafe)' 'https://mirror.invalid/../path'; do
        printf 'github_prefix\t%s\ngo_base\thttps://go.dev/dl\ngoproxy\thttps://proxy.golang.org\n' "$value" > "$CNE_STATE/downloads.tsv"
        if cne_download_load >/dev/null 2>&1; then fail 'invalid setting accepted'; fi
    done
    rm "$CNE_STATE/downloads.tsv"
    printf '%s\n' https://mirror.invalid 0 | cne_download_setup > "$CNE_STATE/output"
    [[ ! -e $CNE_STATE/downloads.tsv ]] || fail 'cancel saved partial settings'
    ln -s "$TRACE" "$CNE_STATE/downloads.tsv"
    if cne_download_load >/dev/null 2>&1; then fail 'symlink configuration accepted'; fi
    printf 'PASS: settings remain validated data and cancelled changes are not saved\n'
)

make_cache_fixture() {
    local name expected url hash directory file
    SPEC_FIXTURE=$CNE_STATE/specs
    directory=$CNE_TEMP/source/amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99
    mkdir -p "$directory"
    printf 'example.org/lib v1.2.3 h1:fixture\nexample.org/lib v1.2.3/go.mod h1:fixture\n' > "$directory/go.sum"
    : > "$SPEC_FIXTURE"
    while IFS=$'\t' read -r name expected url; do
        file=$CNE_STATE/cache/$name
        if [[ $name == "$SOURCE_NAME" ]]; then (cd "$CNE_TEMP/source" && tar -czf "$file" "${directory##*/}/go.sum"); else printf 'fixture:%s' "$name" > "$file"; fi
        hash=$(sha256sum "$file" | awk '{print $1}')
        printf '%s\t%s\t%s\n' "$name" "$hash" "$url" >> "$SPEC_FIXTURE"
    done <<< "$REAL_SPECS"
    cne_download_component_specs() { cat "$SPEC_FIXTURE"; }
    mkdir -p "$CNE_STATE/cache/gomod-download/example.org/lib/@v"
    for name in mod info zip; do printf 'module-%s' "$name" > "$CNE_STATE/cache/gomod-download/example.org/lib/@v/v1.2.3.$name"; done
    for name in amd64 arm64; do printf '%s %s\n' 730d6c39d0c4e348a3d080bebe496664215e5c99 "$name" > "$CNE_STATE/cache/gomod-download/.ready.$name"; done
}

test_bundle_roundtrip() (
    setup roundtrip; make_cache_fixture
    local original=$CNE_STATE bundle=$CNE_STATE/bundle.tar.gz build
    cne_download_bundle_export "$bundle" > "$original/output"
    contains "$original/output" '6/6'
    CNE_STATE=$original/receiver; CNE_TEMP=$CNE_STATE/session
    mkdir -p "$CNE_TEMP" "$CNE_STATE/cache"
    cne_download_bundle_import "$bundle" > "$CNE_STATE/output"
    cmp "$original/cache/$SOURCE_NAME" "$CNE_STATE/cache/$SOURCE_NAME"
    [[ ! -e $CNE_STATE/cache/amneziawg-go-0.2.16-linux-amd64 ]]
    build=$CNE_TEMP/seed; mkdir -p "$build/gomodcache"
    cne_download_modules_seed "$build" amd64 "$CNE_STATE/cache/$SOURCE_NAME"
    [[ $CNE_GO_PROXY == file://* ]] || fail 'completed module cache did not select offline proxy'
    [[ -z $(find "$build/gomodcache" -name '*.ziphash' -print) ]] || fail 'portable ziphash was trusted'
    printf 'PASS: portable cache transfers only pinned archives and download-only module artifacts\n'
)

test_bundle_reject() (
    setup "reject-$1"; make_cache_fixture
    local bundle=$CNE_STATE/bundle.tar.gz unpack=$CNE_TEMP/unpack name hash size file relative
    cne_download_bundle_export "$bundle" >/dev/null
    mkdir "$unpack"; tar -xzf "$bundle" -C "$unpack"
    case $1 in
        executable) printf 'untrusted engine' > "$unpack/amneziawg-go-0.2.16-linux-amd64";;
        ziphash) printf 'h1:forged' > "$unpack/modules/example.org/lib/@v/v1.2.3.ziphash";;
        link) rm "$unpack/archives/$SOURCE_NAME"; ln -s /etc/passwd "$unpack/archives/$SOURCE_NAME";;
        component) printf 'wrong pinned component' > "$unpack/archives/go1.24.4.linux-amd64.tar.gz";;
        module) mkdir -p "$unpack/modules/unknown.invalid/module/@v"; printf unknown > "$unpack/modules/unknown.invalid/module/@v/v1.0.0.zip";;
        oversize) sed 's/\t[0-9][0-9]*$/\t268435457/' "$unpack/manifest.tsv" > "$unpack/new-manifest"; mv "$unpack/new-manifest" "$unpack/manifest.tsv";;
    esac
    if [[ $1 == component || $1 == module ]]; then
        : > "$unpack/manifest.tsv"
        while IFS= read -r file; do
            relative=${file#"$unpack"/}; hash=$(sha256sum "$file" | awk '{print $1}'); size=$(cne_download_size "$file")
            printf '%s\t%s\t%s\n' "$relative" "$hash" "$size" >> "$unpack/manifest.tsv"
        done < <(find "$unpack/archives" "$unpack/modules" -type f -print | sort)
    fi
    (cd "$unpack" && find . \( -type f -o -type l \) -print | sed 's#^./##' > "$CNE_TEMP/members" && tar -czf "$CNE_TEMP/bad.tar.gz" -T "$CNE_TEMP/members")
    hash=$(sha256sum "$CNE_STATE/cache/$SOURCE_NAME")
    if cne_download_bundle_import "$CNE_TEMP/bad.tar.gz" > "$CNE_STATE/output" 2>&1; then fail 'unsafe portable bundle accepted'; fi
    [[ $(sha256sum "$CNE_STATE/cache/$SOURCE_NAME") == "$hash" ]] || fail 'rejected import changed cache'
    printf 'PASS: %s cache bundle is rejected before cache publication\n' "$1"
)

test_publish_failure() (
    setup atomic-publication; make_cache_fixture
    local bundle=$CNE_STATE/bundle.tar.gz old_hash
    cne_download_bundle_export "$bundle" >/dev/null
    printf 'locally built engine fixture\n' > "$CNE_STATE/cache/local-engine"
    old_hash=$(sha256sum "$CNE_STATE/cache/$SOURCE_NAME")
    mv() {
        if [[ ${1:-} == "$CNE_STATE"/.cache-new.* && ${2:-} == "$CNE_STATE/cache" ]]; then return 71; fi
        command mv "$@"
    }
    if cne_download_bundle_import "$bundle" > "$CNE_STATE/output" 2>&1; then fail 'failed cache publication reported success'; fi
    [[ -f $CNE_STATE/cache/local-engine && $(sha256sum "$CNE_STATE/cache/$SOURCE_NAME") == "$old_hash" ]] || fail 'cache publication failure did not restore original cache'
    [[ -z $(find "$CNE_STATE" -maxdepth 1 -name '.cache-before-import.*' -print) ]] || fail 'original cache remained stranded'
    printf 'PASS: failed directory publication restores the whole original cache\n'
)

test_module_refresh() (
    setup refresh; make_cache_fixture
    local build=$CNE_TEMP/refresh-build
    mkdir -p "$build/gomodcache"
    CNE_AWG_REFRESH_MODULE_CACHE=1
    cne_download_modules_seed "$build" amd64 "$CNE_STATE/cache/$SOURCE_NAME"
    [[ $CNE_GO_PROXY == https://proxy.golang.org && -z $(find "$build/gomodcache" -type f -print) ]] || fail 'repair mode reused a potentially corrupt module cache'
    printf 'PASS: explicit complete-cache preparation can refresh corrupt Go dependencies\n'
)

test_download
test_settings
test_bundle_roundtrip
for kind in executable ziphash link component module oversize; do test_bundle_reject "$kind"; done
test_publish_failure
test_module_refresh
printf 'Download checks passed. No network, SSH or package changes occurred.\n'
