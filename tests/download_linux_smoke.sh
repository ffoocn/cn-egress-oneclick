#!/usr/bin/env bash
# Run inside the isolated Download.Dockerfile image; no node services or SSH.
set -Eeuo pipefail
umask 077
source /source/controller.sh
source /source/download.sh
source /source/awg.sh
cne_bootstrap() { return 0; } # Dependencies are preinstalled in this test image.
prepare_state() {
    CNE_STATE=/work/$1
    mkdir -p "$CNE_STATE/cache" "$CNE_STATE/session"
    CNE_TEMP=$CNE_STATE/session
}
case ${1:-} in
    prepare)
        prepare_state prepared
        cne_download_prepare_cache
        cne_download_bundle_export /work/components.tar.gz
        printf 'REAL DOWNLOAD PREPARATION PASSED\n';;
    offline)
        prepare_state "imported-${2:-default}"
        cne_download_bundle_import /work/components.tar.gz
        curl() { printf 'ERROR: offline build attempted a download\n' >&2; return 91; }
        CNE_AWG_FORCE_MODULE_CACHE=1
        cne_fetch_awg arm64
        [[ -x $CNE_AWG_ENGINE ]]
        printf 'REAL NETWORK-DISABLED BUILD PASSED\n'
        archive=$(find "$CNE_STATE/cache/gomod-download/golang.org/x/crypto/@v" -name '*.zip' -print -quit)
        [[ -n $archive ]]
        member=$(unzip -Z1 "$archive" | awk '/\.go$/&&!found {print;found=1}')
        mkdir -p /work/tamper
        unzip -oq "$archive" "$member" -d /work/tamper
        printf '\n// Corrupted portable-cache test fixture.\n' >> "/work/tamper/$member"
        (cd /work/tamper && zip -q "$archive" "$member")
        if cne_fetch_awg arm64 > /work/tamper-result.log 2>&1; then
            printf 'ERROR: modified cached Go ZIP was accepted\n' >&2; exit 1
        fi
        grep -Eq 'checksum mismatch|SECURITY ERROR' /work/tamper-result.log
        printf 'REAL TAMPERED MODULE CHECKSUM REJECTION PASSED\n';;
    *) printf 'Use prepare or offline inside the isolated test container.\n' >&2; exit 2;;
esac
