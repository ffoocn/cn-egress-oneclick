#!/usr/bin/env bash
# Pinned, userspace-only AmneziaWG 2.0 build. Sourcing has no side effects.
# The upstream Go repository publishes source tags, not Linux release binaries.
CNE_AWG_GO_COMMIT=730d6c39d0c4e348a3d080bebe496664215e5c99
CNE_AWG_GO_SHA256=e26d13e5229f0976353008d78d1359bbdb000c9688b17a1d065ba1f61cbd872a
CNE_AWG_TOOLS_COMMIT=5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079
CNE_AWG_TOOLS_SHA256=e79a3c7f2def315d052a3648b49058a268c4b63cdb5e082b696d2a4a0a2367f0

cne_awg_arch() {
    case $1 in x86_64|amd64) printf 'amd64\n';; aarch64|arm64) printf 'arm64\n';; *) return 1;; esac
}

# URL SHA256 CACHE_FILE; publish only a completely verified download.
cne_awg_download() {
    local url=$1 checksum=$2 archive=$3 temporary actual
    [[ ! -L $archive ]] || return 1
    if [[ -f $archive ]]; then
        actual=$(sha256sum "$archive" | awk '{print $1}') || return 1
        [[ $actual != "$checksum" ]] || return 0
    fi
    temporary=$(mktemp "$CNE_TEMP/awg-download.XXXXXXXX") || return 1
    if ! curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$temporary"; then rm -f "$temporary"; cne_error "组件下载失败：$url。配置尚未替换；请检查网络或 HTTPS_PROXY 后重试。"; return 1; fi
    actual=$(sha256sum "$temporary" | awk '{print $1}') || { rm -f "$temporary"; return 1; }
    if [[ $actual != "$checksum" ]]; then
        rm -f "$temporary"
        cne_error 'AmneziaWG 组件校验失败，已停止。'
        return 1
    fi
    chmod 600 "$temporary" && mv "$temporary" "$archive"
}

# TARGET_ARCH -> CNE_AWG_ENGINE and CNE_AWG_TOOLS_SOURCE. Build on the manager;
# no host Go installation, C compiler, kernel module or system upgrade is used.
cne_fetch_awg() {
    local target manager checksum go_archive engine_archive tools_archive work engine digest existing
    target=$(cne_awg_arch "$1") || { cne_error "不支持的 AmneziaWG 架构：$1"; return 1; }
    [[ $(uname -s) == Linux ]] || { cne_error 'AmneziaWG 编译需要 Linux 管理机。'; return 1; }
    manager=$(cne_awg_arch "$(uname -m)") || { cne_error '管理机须使用 amd64 或 arm64 架构。'; return 1; }
    case $manager in
        amd64) checksum=77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717;;
        arm64) checksum=d5501ee5aca0f258d5fe9bfaed401958445014495dc115f202d43d5210b45241;;
    esac
    go_archive=$CNE_STATE/cache/go1.24.4.linux-$manager.tar.gz
    engine_archive=$CNE_STATE/cache/amneziawg-go-$CNE_AWG_GO_COMMIT.tar.gz
    tools_archive=$CNE_STATE/cache/amneziawg-tools-$CNE_AWG_TOOLS_COMMIT.tar.gz
    cne_note '准备 AmneziaWG 2.0 用户态组件（首次会下载 Go 并编译）…'
    cne_awg_download "https://go.dev/dl/go1.24.4.linux-$manager.tar.gz" "$checksum" "$go_archive" || return 1
    cne_awg_download "https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/$CNE_AWG_GO_COMMIT" "$CNE_AWG_GO_SHA256" "$engine_archive" || return 1
    cne_awg_download "https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/$CNE_AWG_TOOLS_COMMIT" "$CNE_AWG_TOOLS_SHA256" "$tools_archive" || return 1
    engine=$CNE_STATE/cache/amneziawg-go-0.2.16-linux-$target
    digest=$engine.sha256
    [[ ! -L $engine && ! -L $digest ]] || return 1
    if [[ -x $engine && -f $digest ]]; then
        IFS= read -r existing < "$digest" || return 1
        if [[ $existing =~ ^[0-9a-f]{64}$ && $(sha256sum "$engine" | awk '{print $1}') == "$existing" ]]; then
            CNE_AWG_ENGINE=$engine; CNE_AWG_TOOLS_SOURCE=$tools_archive
            return 0
        fi
    fi
    work=$(mktemp -d "$CNE_TEMP/awg-build.XXXXXXXX") || return 1
    mkdir "$work/source" "$work/gocache" "$work/gomodcache" || return 1
    tar -xzf "$go_archive" -C "$work" || return 1
    tar -xzf "$engine_archive" --strip-components=1 -C "$work/source" || return 1
    # GOTOOLCHAIN=local prevents a source directive from fetching another Go.
    # Go verifies dependencies against the source's go.sum and checksum database.
    (cd "$work/source" && timeout --signal=TERM --kill-after=10s 600s env CGO_ENABLED=0 GOOS=linux GOARCH="$target" \
        GOENV=off GOTOOLCHAIN=local GOWORK=off GOFLAGS= GOAMD64=v1 GOARM64=v8.0 \
        GOPRIVATE= GONOSUMDB= GONOPROXY= GOINSECURE= GOCACHE="$work/gocache" \
        GOMODCACHE="$work/gomodcache" GOPROXY=https://proxy.golang.org \
        GOSUMDB=sum.golang.org "$work/go/bin/go" build -mod=readonly -trimpath \
        -buildvcs=false -o "$work/amneziawg-go" .) || { cne_error 'AmneziaWG 编译或 Go 依赖下载失败（最长等待 10 分钟）。配置尚未替换；请检查上述错误和网络后重试。'; return 1; }
    chmod 755 "$work/amneziawg-go" || return 1
    existing=$(sha256sum "$work/amneziawg-go" | awk '{print $1}') || return 1
    printf '%s\n' "$existing" > "$work/engine.sha256" || return 1
    mv "$work/amneziawg-go" "$engine" && mv "$work/engine.sha256" "$digest" || return 1
    CNE_AWG_ENGINE=$engine; CNE_AWG_TOOLS_SOURCE=$tools_archive
    rm -rf -- "$work"
}
