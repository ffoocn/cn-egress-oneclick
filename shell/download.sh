#!/usr/bin/env bash
# HTTPS download settings and portable, checksum-verified component caches.
# Configuration is data only; nothing is sourced or evaluated as Shell code.
CNE_DOWNLOAD_GITHUB_PREFIX=''
CNE_DOWNLOAD_GO_BASE=https://go.dev/dl
CNE_DOWNLOAD_GOPROXY=https://proxy.golang.org

cne_download_https() {
    [[ ${#1} -le 512 && $1 =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+:-]*)?$ && $1 != *'/../'* && $1 != */.. ]]
}

cne_download_load() {
    local file=$CNE_STATE/downloads.tsv key value extra seen=' ' github='' go=https://go.dev/dl proxy=https://proxy.golang.org
    CNE_DOWNLOAD_GITHUB_PREFIX=''; CNE_DOWNLOAD_GO_BASE=https://go.dev/dl; CNE_DOWNLOAD_GOPROXY=https://proxy.golang.org
    [[ -e $file || -L $file ]] || return 0
    [[ -f $file && ! -L $file && -O $file ]] || { cne_error '下载设置文件不安全。'; return 1; }
    while IFS=$'\t' read -r key value extra; do
        [[ -z $extra && $seen != *" $key "* ]] || { cne_error '下载设置含重复或无效字段。'; return 1; }
        seen+="$key "
        case $key in
            github_prefix) [[ $value == - ]] || cne_download_https "$value" || return 1; [[ $value != - ]] || value=''; github=$value;;
            go_base) cne_download_https "$value" || return 1; go=${value%/};;
            goproxy) cne_download_https "$value" || return 1; proxy=${value%/};;
            *) cne_error '下载设置含未知字段。'; return 1;;
        esac
    done < "$file"
    [[ $seen == *' github_prefix '* && $seen == *' go_base '* && $seen == *' goproxy '* ]] || { cne_error '下载设置不完整。'; return 1; }
    CNE_DOWNLOAD_GITHUB_PREFIX=$github; CNE_DOWNLOAD_GO_BASE=$go; CNE_DOWNLOAD_GOPROXY=$proxy
}

cne_download_setup() {
    local file=$CNE_STATE/downloads.tsv github go proxy temporary default
    [[ ! -L $file && ( ! -e $file || -f $file && -O $file ) ]] || { cne_error '下载设置文件不安全。'; return 1; }
    cne_download_load || cne_note '原下载设置无效，下面按默认值重新填写。'
    printf '\n下载来源设置\n只接受 HTTPS 地址；所有组件仍核对固定 SHA-256，Go 仍核对 go.sum。输入 0 可取消。\n'
    default=${CNE_DOWNLOAD_GITHUB_PREFIX:--}
    while :; do
        cne_prompt 'GitHub/codeload 镜像前缀（- 使用官方来源）' "$default" || return 1
        github=$CNE_ANSWER
        [[ $github != 0 ]] || { printf '已取消。\n'; return 0; }
        [[ $github == - ]] || cne_download_https "$github" || { cne_note '请填写 HTTPS 镜像前缀或 -；不要包含用户名、密码或查询参数。'; continue; }
        break
    done
    while :; do cne_prompt 'Go 工具链下载目录' "$CNE_DOWNLOAD_GO_BASE" || return 1; go=$CNE_ANSWER; [[ $go != 0 ]] || { printf '已取消。\n'; return 0; }; cne_download_https "$go" && break; cne_note '请填写 HTTPS 下载目录，文件名会自动附加。'; done
    while :; do cne_prompt 'Go 模块 GOPROXY' "$CNE_DOWNLOAD_GOPROXY" || return 1; proxy=$CNE_ANSWER; [[ $proxy != 0 ]] || { printf '已取消。\n'; return 0; }; cne_download_https "$proxy" && break; cne_note '请填写单个 HTTPS Go 模块代理地址。'; done
    temporary=$(mktemp "$CNE_TEMP/download-settings.XXXXXXXX") || return 1
    printf 'github_prefix\t%s\ngo_base\t%s\ngoproxy\t%s\n' "$github" "${go%/}" "${proxy%/}" > "$temporary" && chmod 600 "$temporary" && mv "$temporary" "$file" || return 1
    cne_download_load || return 1
    printf '下载设置已保存。镜像前缀会放在原 GitHub/codeload URL 前；不改变组件校验值。\n'
}

cne_download_url() {
    local url=$1
    case $url in
        https://github.com/*|https://codeload.github.com/*)
            [[ -z $CNE_DOWNLOAD_GITHUB_PREFIX ]] || url=${CNE_DOWNLOAD_GITHUB_PREFIX%/}/$url;;
        https://go.dev/dl/*) url=${CNE_DOWNLOAD_GO_BASE%/}/${url#https://go.dev/dl/};;
    esac
    printf '%s\n' "$url"
}

cne_download_verified() {
    local official=$1 expected=$2 archive=$3 label=${4:-组件} actual url temporary
    [[ $expected =~ ^[0-9a-f]{64}$ && ! -L $archive && ( ! -e $archive || -f $archive && -O $archive ) ]] || { cne_error '组件校验参数或缓存文件无效。'; return 1; }
    cne_safe_directory "${archive%/*}" || return 1
    if [[ -f $archive ]]; then
        actual=$(sha256sum "$archive" | awk '{print $1}') || return 1
        [[ $actual != "$expected" ]] || return 0
    fi
    cne_download_load || return 1
    url=$(cne_download_url "$official") || return 1
    temporary=$(mktemp "$CNE_TEMP/component-download.XXXXXXXX") || return 1
    cne_note "下载${label}…"
    if ! curl -fL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$temporary"; then
        rm -f "$temporary"
        cne_error "${label}下载失败：${url}。请在菜单 18 设置下载来源，或在菜单 19 导入已校验缓存后重试。"
        return 1
    fi
    actual=$(sha256sum "$temporary" | awk '{print $1}') || { rm -f "$temporary"; return 1; }
    if [[ $actual != "$expected" ]]; then
        rm -f "$temporary"
        cne_error "${label}的 SHA-256 校验失败，未使用下载结果；请检查下载来源。"
        return 1
    fi
    chmod 600 "$temporary" && mv "$temporary" "$archive"
}

cne_download_component_specs() {
    cat <<'COMPONENTS'
go1.24.4.linux-amd64.tar.gz	77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717	https://go.dev/dl/go1.24.4.linux-amd64.tar.gz
go1.24.4.linux-arm64.tar.gz	d5501ee5aca0f258d5fe9bfaed401958445014495dc115f202d43d5210b45241	https://go.dev/dl/go1.24.4.linux-arm64.tar.gz
amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz	e26d13e5229f0976353008d78d1359bbdb000c9688b17a1d065ba1f61cbd872a	https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/730d6c39d0c4e348a3d080bebe496664215e5c99
amneziawg-tools-5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079.tar.gz	e79a3c7f2def315d052a3648b49058a268c4b63cdb5e082b696d2a4a0a2367f0	https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079
wstunnel_11.0.0_linux_amd64.tar.gz	9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e	https://github.com/erebe/wstunnel/releases/download/v11.0.0/wstunnel_11.0.0_linux_amd64.tar.gz
wstunnel_11.0.0_linux_arm64.tar.gz	b86abf73e340ed0c3ff9a77a5458aa27213784920ec65513132b36def45edc94	https://github.com/erebe/wstunnel/releases/download/v11.0.0/wstunnel_11.0.0_linux_arm64.tar.gz
COMPONENTS
}

cne_download_component_sha() {
    cne_download_component_specs | awk -F'\t' -v name="$1" '$1==name{print $2;found=1}END{exit !found}'
}

cne_download_size() { wc -c < "$1" | tr -d '[:space:]'; }

# Only artifacts for modules listed in the pinned upstream go.sum can travel.
# Existing .ziphash files are deliberately excluded: Go must recompute hashes
# of portable ZIP files before comparing them with the pinned source go.sum.
cne_download_module_allowlist() {
    local archive=$1 expected actual member
    member=amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99/go.sum
    expected=$(cne_download_component_sha "${archive##*/}") || return 1
    actual=$(sha256sum "$archive" | awk '{print $1}') || return 1
    [[ $actual == "$expected" ]] || { cne_error 'Go 模块名单的固定源码校验失败。'; return 1; }
    tar -xOzf "$archive" "$member" | awk '
      function escape(v, out,i,c){out="";for(i=1;i<=length(v);i++){c=substr(v,i,1);out=out (c~/[A-Z]/?"!" tolower(c):c)}return out}
      NF==3&&$3~/^h1:/ {v=$2;sub(/\/go.mod$/,"",v);p=escape($1) "/@v/" escape(v);if(p!~/^[A-Za-z0-9.!_+\/-]+\/@v\/[A-Za-z0-9.!_+-]+$/){bad=1;next};if(!seen[p]++){print p ".mod";print p ".info";print p ".zip"}}
      END{exit bad?1:0}' | LC_ALL=C sort
}

cne_download_module_name_ok() {
    [[ $1 =~ ^[A-Za-z0-9.!_+/-]+/@v/[A-Za-z0-9.!_+-]+\.(mod|info|zip)$ && $1 != /* && $1 != *'../'* && $1 != *'/..'* ]] && grep -Fqx -- "$1" "$2"
}

cne_download_file_url() {
    printf 'file://'
    printf '%s\n' "$1" | sed 's/%/%25/g;s/ /%20/g;s/#/%23/g;s/?/%3F/g'
}

cne_download_modules_seed() {
    local work=$1 target=$2 source=$3 cache=$CNE_STATE/cache/gomod-download file relative allowlist ready
    cne_download_load || return 1
    CNE_GO_PROXY=$CNE_DOWNLOAD_GOPROXY
    [[ ${CNE_AWG_REFRESH_MODULE_CACHE:-0} != 1 ]] || return 0
    [[ -e $cache || -L $cache ]] || return 0
    cne_safe_directory "$cache" || return 1
    [[ -z $(find "$cache" -type l -print -quit) ]] || { cne_error 'Go 依赖缓存不能含符号链接。'; return 1; }
    allowlist=$work/module-allowlist
    cne_download_module_allowlist "$source" > "$allowlist" || return 1
    mkdir -p "$work/gomodcache/cache/download" || return 1
    while IFS= read -r file; do
        relative=${file#"$cache"/}
        [[ $relative != .ready.* ]] || continue
        cne_download_module_name_ok "$relative" "$allowlist" || { cne_error 'Go 缓存包含来源名单之外的文件。'; return 1; }
        mkdir -p "$work/gomodcache/cache/download/${relative%/*}" && cp "$file" "$work/gomodcache/cache/download/$relative" || return 1
    done < <(find "$cache" -type f -print | LC_ALL=C sort)
    ready=$cache/.ready.$target
    if [[ -f $ready && ! -L $ready ]] && [[ $(cat "$ready") == "730d6c39d0c4e348a3d080bebe496664215e5c99 $target" ]]; then
        CNE_GO_PROXY=$(cne_download_file_url "$work/gomodcache/cache/download") || return 1
        cne_note '使用已完成编译的 Go 依赖缓存；本次编译不从模块代理下载。'
    fi
}

cne_download_modules_publish() {
    local work=$1 target=$2 source=$3 from=$1/gomodcache/cache/download stage cache=$CNE_STATE/cache/gomod-download file relative allowlist previous=''
    allowlist=$work/module-allowlist
    [[ -f $allowlist ]] || cne_download_module_allowlist "$source" > "$allowlist" || return 1
    [[ -d $from ]] || return 0
    [[ -z $(find "$from" -type l -print -quit) ]] || return 1
    stage=$(mktemp -d "$CNE_STATE/cache/.gomod-publish.XXXXXXXX") || return 1
    while IFS= read -r file; do
        relative=${file#"$from"/}
        case $relative in *.mod|*.info|*.zip) ;; *) continue;; esac
        cne_download_module_name_ok "$relative" "$allowlist" || continue
        mkdir -p "$stage/${relative%/*}" && cp "$file" "$stage/$relative" || { rm -rf "$stage"; return 1; }
    done < <(find "$from" -type f -print | LC_ALL=C sort)
    if [[ ${CNE_AWG_REFRESH_MODULE_CACHE:-0} != 1 && -d $cache && ! -L $cache ]]; then
        for relative in .ready.amd64 .ready.arm64; do
            if [[ -f $cache/$relative && ! -L $cache/$relative ]] && [[ $(cat "$cache/$relative") == "730d6c39d0c4e348a3d080bebe496664215e5c99 ${relative#.ready.}" ]]; then
                cp "$cache/$relative" "$stage/$relative" || { rm -rf "$stage"; return 1; }
            fi
        done
    fi
    printf '%s %s\n' 730d6c39d0c4e348a3d080bebe496664215e5c99 "$target" > "$stage/.ready.$target" || { rm -rf "$stage"; return 1; }
    chmod -R go-rwx "$stage" || { rm -rf "$stage"; return 1; }
    if [[ -e $cache || -L $cache ]]; then
        cne_safe_directory "$cache" || { rm -rf "$stage"; return 1; }
        previous=$(mktemp -d "$CNE_STATE/cache/.gomod-previous.XXXXXXXX") && rmdir "$previous" && mv "$cache" "$previous" || { rm -rf "$stage"; return 1; }
    fi
    if ! mv "$stage" "$cache"; then [[ -z $previous ]] || mv "$previous" "$cache"; rm -rf "$stage"; return 1; fi
    [[ -z $previous ]] || rm -rf "$previous"
}

cne_download_bundle_tools() {
    local tool
    for tool in tar gzip sha256sum find wc head awk sort uniq; do command -v "$tool" >/dev/null 2>&1 || { cne_error "缓存管理缺少 ${tool}；请先在可联网环境准备依赖。"; return 1; }; done
    cne_safe_directory "$CNE_STATE/cache"
}

cne_download_tar() {
    # Linux coreutils provides timeout. Tests on other hosts use small archives.
    if command -v timeout >/dev/null 2>&1; then timeout --signal=TERM --kill-after=5s 60s tar "$@"; else tar "$@"; fi
}

cne_download_bundle_name_ok() {
    local name=$1 component
    case $name in
        manifest.tsv) return 0;;
        archives/*) component=${name#archives/}; cne_download_component_sha "$component" >/dev/null;;
        modules/.ready.amd64|modules/.ready.arm64) return 0;;
        modules/*) [[ ${name#modules/} =~ ^[A-Za-z0-9.!_+/-]+/@v/[A-Za-z0-9.!_+-]+\.(mod|info|zip)$ && $name != *'../'* && $name != *'/..'* ]];;
        *) return 1;;
    esac
}

cne_download_bundle_extract() {
    local bundle=$1 member=$2 destination=$3 maximum=$4 size
    # Stream one allowlisted regular member; never extract an archive tree.
    cne_download_tar -xOzf "$bundle" "$member" | head -c "$((maximum+1))" > "$destination" || return 1
    size=$(cne_download_size "$destination") || return 1
    ((size<=maximum))
}

cne_download_cache_publish() {
    local stage=$1 replacement previous file cache=$CNE_STATE/cache
    cne_safe_directory "$cache" || return 1
    [[ -z $(find "$cache" -type l -print -quit) ]] || { cne_error '现有组件缓存含符号链接，未导入。'; return 1; }
    replacement=$(mktemp -d "$CNE_STATE/.cache-new.XXXXXXXX") || return 1
    # Preserve locally built engines, but never accept engines from a bundle.
    cp -a "$cache/." "$replacement/" || { rm -rf "$replacement"; return 1; }
    if [[ -d $stage/archives ]]; then
        while IFS= read -r file; do chmod 600 "$file" && mv "$file" "$replacement/${file##*/}" || { rm -rf "$replacement"; return 1; }; done < <(find "$stage/archives" -type f -print)
    fi
    if [[ -d $stage/modules ]]; then
        chmod -R go-rwx "$stage/modules" || { rm -rf "$replacement"; return 1; }
        if [[ -d $replacement/gomod-download ]]; then chmod -R u+w "$replacement/gomod-download" && rm -rf "$replacement/gomod-download" || { rm -rf "$replacement"; return 1; }; fi
        mv "$stage/modules" "$replacement/gomod-download" || { rm -rf "$replacement"; return 1; }
    fi
    previous=$(mktemp -d "$CNE_STATE/.cache-before-import.XXXXXXXX") && rmdir "$previous" || { rm -rf "$replacement"; return 1; }
    mv "$cache" "$previous" || { rm -rf "$replacement"; return 1; }
    if ! mv "$replacement" "$cache"; then
        if ! mv "$previous" "$cache"; then cne_error "缓存发布和恢复均未完成，原缓存保留在 ${previous}。"; fi
        rm -rf "$replacement"; return 1
    fi
    chmod -R u+w "$previous" && rm -rf "$previous" || cne_note "缓存已导入，但旧临时目录尚未清理：$previous"
}

cne_download_bundle_export() {
    local output=$1 stage name expected url source=$CNE_STATE/cache/amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz file relative size hash count=0 module_count=0 allowlist list temporary
    cne_download_bundle_tools || return 1
    [[ $output == /* && ! -e $output && ! -L $output && -d ${output%/*} && ! -L ${output%/*} ]] || { cne_error '请填写尚不存在的绝对输出文件路径。'; return 1; }
    stage=$(mktemp -d "$CNE_TEMP/cache-export.XXXXXXXX") || return 1
    mkdir "$stage/archives" "$stage/modules" || return 1
    while IFS=$'\t' read -r name expected url; do
        file=$CNE_STATE/cache/$name
        [[ -e $file || -L $file ]] || continue
        [[ -f $file && ! -L $file && -O $file ]] && [[ $(sha256sum "$file" | awk '{print $1}') == "$expected" ]] || { cne_error "缓存组件未通过校验：$name"; return 1; }
        cp "$file" "$stage/archives/$name" || return 1
        count=$((count+1))
    done < <(cne_download_component_specs)
    ((count)) || { cne_error '还没有已校验组件缓存，请先选择“准备完整缓存”。'; return 1; }
    if [[ -d $CNE_STATE/cache/gomod-download ]]; then
        cne_safe_directory "$CNE_STATE/cache/gomod-download" || return 1
        [[ -z $(find "$CNE_STATE/cache/gomod-download" -type l -print -quit) ]] || { cne_error 'Go 缓存不能含符号链接。'; return 1; }
        allowlist=$stage/module-allowlist
        cne_download_module_allowlist "$source" > "$allowlist" || return 1
        while IFS= read -r file; do
            relative=${file#"$CNE_STATE/cache/gomod-download"/}
            case $relative in
                .ready.amd64|.ready.arm64)
                    [[ $(cat "$file") == "730d6c39d0c4e348a3d080bebe496664215e5c99 ${relative#.ready.}" ]] || { cne_error 'Go 缓存完成记录无效。'; return 1; };;
                *) cne_download_module_name_ok "$relative" "$allowlist" || { cne_error 'Go 缓存含非固定源码所需的文件。'; return 1; }; module_count=$((module_count+1));;
            esac
            if [[ $relative == */* ]]; then mkdir -p "$stage/modules/${relative%/*}" || return 1; fi
            cp "$file" "$stage/modules/$relative" || return 1
        done < <(find "$CNE_STATE/cache/gomod-download" -type f -print | LC_ALL=C sort)
    fi
    : > "$stage/manifest.tsv"
    list=$stage/files
    printf 'manifest.tsv\n' > "$list"
    while IFS= read -r file; do
        relative=${file#"$stage"/}
        size=$(cne_download_size "$file") || return 1
        [[ $size =~ ^[0-9]{1,10}$ ]] && ((size<=268435456)) || { cne_error '缓存文件超过允许大小。'; return 1; }
        hash=$(sha256sum "$file" | awk '{print $1}') || return 1
        printf '%s\t%s\t%s\n' "$relative" "$hash" "$size" >> "$stage/manifest.tsv" && printf '%s\n' "$relative" >> "$list" || return 1
    done < <(find "$stage/archives" "$stage/modules" -type f -print | LC_ALL=C sort)
    temporary=$(mktemp "${output%/*}/.cn-egress-cache.XXXXXXXX") || return 1
    if ! (cd "$stage" && tar -czf "$temporary" -T files); then rm -f "$temporary"; return 1; fi
    [[ ! -e $output && ! -L $output ]] && chmod 600 "$temporary" && mv "$temporary" "$output" || { rm -f "$temporary"; return 1; }
    printf '缓存已导出：%s\n包含 %s/6 个固定组件、%s 个 Go 依赖文件；不包含私钥、节点设置或编译后的程序。\n' "$output" "$count" "$module_count"
    if ((count<6 || module_count==0)) || [[ ! -f $stage/modules/.ready.amd64 || ! -f $stage/modules/.ready.arm64 ]]; then
        printf '这是部分缓存。导入后缺少的组件或 Go 依赖仍需联网；可先选择“准备完整缓存”再导出。\n'
    else printf '包含两个目标架构的已完成编译依赖缓存；导入后仍会用固定源码重新编译并核对 go.sum。系统软件包需另行准备。\n'; fi
}

cne_download_bundle_import() {
    local bundle=$1 stage list manifest name hash size extra actual expected total=0 count=0 source allowlist file relative cache previous=''
    cne_download_bundle_tools || return 1
    [[ $bundle == /* && -f $bundle && ! -L $bundle ]] || { cne_error '请填写缓存包的绝对文件路径，不能使用符号链接。'; return 1; }
    size=$(cne_download_size "$bundle") || return 1
    [[ $size =~ ^[0-9]{1,10}$ ]] && ((size<=1073741824)) || { cne_error '缓存包超过允许大小。'; return 1; }
    stage=$(mktemp -d "$CNE_TEMP/cache-import.XXXXXXXX") || return 1
    list=$stage/list
    cne_download_tar -P -tzf "$bundle" > "$list" || { cne_error '无法读取缓存包。'; return 1; }
    [[ -z $(LC_ALL=C sort "$list" | uniq -d) ]] && [[ $(wc -l < "$list") -le 4096 ]] || { cne_error '缓存包含重复文件或文件数过多。'; return 1; }
    while IFS= read -r name; do cne_download_bundle_name_ok "$name" || { cne_error '缓存包含不允许的文件名。'; return 1; }; done < "$list"
    cne_download_tar -P -tvzf "$bundle" | awk 'substr($0,1,1)!="-"{bad=1}END{exit bad?1:0}' || { cne_error '缓存包仅允许普通文件，不能含目录、链接或设备文件。'; return 1; }
    grep -Fqx manifest.tsv "$list" || { cne_error '缓存包缺少清单。'; return 1; }
    manifest=$stage/manifest.tsv
    cne_download_bundle_extract "$bundle" manifest.tsv "$manifest" 262144 || { cne_error '缓存清单无效或过大。'; return 1; }
    : > "$stage/expected-list"
    printf 'manifest.tsv\n' >> "$stage/expected-list"
    while IFS=$'\t' read -r name hash size extra; do
        [[ -z $extra && $name != manifest.tsv && $hash =~ ^[0-9a-f]{64}$ && $size =~ ^[0-9]{1,10}$ ]] && ((10#$size<=268435456)) && cne_download_bundle_name_ok "$name" || { cne_error '缓存清单格式无效。'; return 1; }
        count=$((count+1)); total=$((total+10#$size))
        ((count<=4095 && total<=1073741824)) || { cne_error '缓存展开大小超过限制。'; return 1; }
        printf '%s\n' "$name" >> "$stage/expected-list"
        mkdir -p "$stage/${name%/*}" || return 1
        cne_download_bundle_extract "$bundle" "$name" "$stage/$name" "$((10#$size))" || { cne_error '缓存文件大小不符。'; return 1; }
        actual=$(sha256sum "$stage/$name" | awk '{print $1}') || return 1
        [[ $actual == "$hash" && $(cne_download_size "$stage/$name") == "$size" ]] || { cne_error '缓存文件校验失败。'; return 1; }
        case $name in
            archives/*) expected=$(cne_download_component_sha "${name#archives/}") || return 1; [[ $actual == "$expected" ]] || { cne_error '缓存组件不符合脚本固定 SHA-256。'; return 1; };;
            modules/.ready.*) [[ $(cat "$stage/$name") == "730d6c39d0c4e348a3d080bebe496664215e5c99 ${name#modules/.ready.}" ]] || { cne_error 'Go 缓存完成记录无效。'; return 1; };;
        esac
    done < "$manifest"
    ((count)) && [[ -z $(LC_ALL=C sort "$stage/expected-list" | uniq -d) ]] || { cne_error '缓存清单为空或含重复项目。'; return 1; }
    LC_ALL=C sort "$list" > "$stage/sorted-list"; LC_ALL=C sort "$stage/expected-list" > "$stage/sorted-expected"
    cmp -s "$stage/sorted-list" "$stage/sorted-expected" || { cne_error '缓存文件与清单不一致。'; return 1; }
    if [[ -d $stage/modules ]]; then
        source=$stage/archives/amneziawg-go-730d6c39d0c4e348a3d080bebe496664215e5c99.tar.gz
        [[ -f $source ]] || { cne_error 'Go 依赖缓存必须同时包含固定源码包。'; return 1; }
        allowlist=$stage/module-allowlist
        cne_download_module_allowlist "$source" > "$allowlist" || return 1
        while IFS= read -r file; do
            relative=${file#"$stage/modules"/}
            [[ $relative == .ready.amd64 || $relative == .ready.arm64 ]] || cne_download_module_name_ok "$relative" "$allowlist" || { cne_error '缓存模块不属于固定源码的 go.sum。'; return 1; }
        done < <(find "$stage/modules" -type f -print)
    fi
    # Every member and existing destination passes validation before replacing
    # the cache directory. A failed publication restores the whole old cache.
    if [[ -d $stage/archives ]]; then
        while IFS= read -r file; do
            relative=$CNE_STATE/cache/${file##*/}
            [[ ! -L $relative && ( ! -e $relative || -f $relative && -O $relative ) ]] || { cne_error '现有组件缓存路径不安全，未导入。'; return 1; }
        done < <(find "$stage/archives" -type f -print)
    fi
    cne_download_cache_publish "$stage" || return 1
    printf '缓存已导入。固定组件已核对脚本内的 SHA-256；Go 依赖会在重新编译时按固定源码 go.sum 再校验。\n未导入编译后的程序、私钥或节点配置；缓存不足时仍需联网。\n'
}

cne_download_prepare_cache() (
    local name expected url target
    cne_bootstrap install && cne_download_bundle_tools && cne_download_load || return 1
    while IFS=$'\t' read -r name expected url; do cne_download_verified "$url" "$expected" "$CNE_STATE/cache/$name" "$name" || return 1; done < <(cne_download_component_specs)
    CNE_AWG_FORCE_MODULE_CACHE=1
    CNE_AWG_REFRESH_MODULE_CACHE=1
    for target in amd64 arm64; do cne_fetch_awg "$target" || return 1; CNE_AWG_REFRESH_MODULE_CACHE=0; done
    printf '固定组件和两个目标架构的 Go 编译依赖缓存已准备，可导出。APT 系统依赖需在目标管理机和节点另行准备。\n'
)

cne_download_bundle_menu() {
    local choice file
    printf '\n组件缓存\n  1. 导出当前缓存\n  2. 导入缓存包\n  3. 准备完整缓存（需联网下载并编译）\n  0. 取消\n'
    cne_prompt '请选择' 0 || return 1; choice=$CNE_ANSWER
    case $choice in
        0) return 0;;
        1) cne_prompt '输出绝对路径' "$CNE_STATE/component-cache-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" || return 1; file=$CNE_ANSWER; cne_download_bundle_export "$file";;
        2) cne_prompt '缓存包绝对路径' || return 1; file=$CNE_ANSWER; cne_download_bundle_import "$file";;
        3) cne_download_prepare_cache;;
        *) cne_error '请输入 0、1、2 或 3。'; return 1;;
    esac
}
