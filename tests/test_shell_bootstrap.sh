#!/usr/bin/env bash
# Package-manager calls are mocks; these checks never change host packages.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-bootstrap-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing output: $2"; }
assert_absent() { if grep -Eq -- "$2" "$1"; then fail "unexpected call: $2"; fi; }

mock_setup() {
    source "$ROOT/shell/controller.sh"
    source "$ROOT/shell/bootstrap.sh"
    MOCK_DIR=$WORK/$1
    mkdir -p "$MOCK_DIR"
    MOCK_TRACE=$MOCK_DIR/calls
    : > "$MOCK_TRACE"
    MOCK_UID=0
    MOCK_AUDIT=clean
    MOCK_PLAN=safe
    MOCK_REPOSITORY=ok
    MOCK_INSTALL=ok
    MOCK_MISSING='wg sshpass'
    MOCK_CA=installed
    MOCK_QUERIES=$MOCK_DIR/queries
    : > "$MOCK_QUERIES"
    uname() { printf 'Linux\n'; }
    id() { printf '%s\n' "$MOCK_UID"; }
    dpkg-query() {
        printf '%s\n' "$*" >> "$MOCK_QUERIES"
        [[ $MOCK_CA == installed || -f $MOCK_DIR/installed ]] || return 1
        printf 'install ok installed'
    }
    command() {
        if [[ ${1:-} == -v ]]; then
            case ${2:-} in qrencode|python|python3) return 1 ;; esac
            case " $MOCK_MISSING " in *" ${2:-} "*) [[ -f $MOCK_DIR/installed ]]; return ;; esac
            return 0
        fi
        builtin command "$@"
    }
    dpkg() {
        printf 'dpkg %s\n' "$*" >> "$MOCK_TRACE"
        [[ $* == --audit ]] || fail 'unexpected dpkg operation'
        case $MOCK_AUDIT in
            clean) return 0 ;;
            broken) printf 'unrelated-server: package is unpacked but not configured\n' ;;
            failed) printf 'dpkg: package database is unreadable\n' >&2; return 2 ;;
        esac
    }
    sudo() { printf 'sudo %s\n' "$*" >> "$MOCK_TRACE"; [[ $* == -v ]] || fail 'unexpected sudo operation'; }
    python() { fail 'unexpected Python runtime'; }
    python3() { fail 'unexpected Python runtime'; }
    apt-get() { fail 'package manager bypassed isolated cne_root mock'; }
    cne_root() {
        printf '%s\n' "$*" >> "$MOCK_TRACE"
        case "$*" in
            'apt-get -qq update')
                [[ $MOCK_REPOSITORY == ok ]] || { printf 'APT repository unavailable\n' >&2; return 1; } ;;
            'apt-get -s '*)
                case $MOCK_PLAN in
                    safe)
                        local requested=0 candidate
                        for candidate in "$@"; do
                            if [[ $candidate == install ]]; then requested=1; continue; fi
                            [[ $requested == 0 ]] || printf 'Inst %s (new Debian)\nConf %s (new Debian)\n' "$candidate" "$candidate"
                        done ;;
                    upgrade) printf 'Inst libc6 [old] (new Debian)\n' ;;
                    removal) printf 'Remv unrelated-server [1.0]\n' ;;
                    pending) printf 'Inst sshpass (new Debian)\nConf unrelated-server (1.0 Debian)\n' ;;
                    failed) printf 'APT cannot resolve dependencies\n'; return 1 ;;
                esac ;;
            'apt-get -y '*)
                [[ $MOCK_INSTALL == ok ]] || { printf 'APT installation failed\n' >&2; return 1; }
                touch "$MOCK_DIR/installed" ;;
            *) fail "unexpected privileged operation: $*" ;;
        esac
    }
}

test_install() (
    mock_setup install
    cne_bootstrap > "$MOCK_DIR/output" 2>&1 || fail 'required dependency installation failed'
    assert_contains "$MOCK_TRACE" 'install sshpass wireguard-tools'
    assert_absent "$MOCK_TRACE" 'qrencode|python|--configure|--fix-broken'
    [[ -f $MOCK_DIR/installed ]] || fail 'missing installation'
    printf 'PASS: only required tools install, with no Python or QR dependency\n'
)

test_existing() (
    mock_setup existing
    touch "$MOCK_DIR/installed"
    MOCK_AUDIT=broken
    MOCK_UID=1000
    cne_bootstrap > "$MOCK_DIR/output" 2>&1 || fail 'missing optional QR tool blocked startup'
    [[ ! -s $MOCK_TRACE ]] || fail 'existing dependencies accessed the package manager'
    printf 'PASS: existing dependencies skip APT and broken dpkg despite missing QR\n'
)

test_lazy_ui() (
    mock_setup lazy-ui
    MOCK_MISSING='ssh sshpass openssl curl wg tar base64 sha256sum gzip'
    MOCK_CA=missing
    MOCK_AUDIT=broken
    MOCK_UID=1000
    cne_bootstrap ui > "$MOCK_DIR/output" 2>&1 || fail 'offline UI was blocked by unrelated tools or broken dpkg'
    [[ ! -s $MOCK_TRACE && ! -s $MOCK_QUERIES ]] || fail 'UI startup inspected packages or requested privilege escalation'
    printf 'PASS: UI opens with missing VPN/SSH tools, missing CA package and broken dpkg\n'
)

test_lazy_ssh_existing() (
    mock_setup lazy-ssh-existing
    MOCK_MISSING='openssl curl wg tar base64 sha256sum gzip'
    MOCK_CA=missing
    MOCK_AUDIT=broken
    MOCK_UID=1000
    cne_bootstrap ssh > "$MOCK_DIR/output" 2>&1 || fail 'SSH management required VPN build/download tools'
    [[ ! -s $MOCK_TRACE && ! -s $MOCK_QUERIES ]] || fail 'existing SSH prerequisites inspected unrelated packages'
    printf 'PASS: SSH management ignores absent VPN/download tools and CA certificates\n'
)

test_lazy_ssh_install() (
    mock_setup lazy-ssh-install
    MOCK_MISSING='ssh sshpass openssl curl wg tar base64 sha256sum gzip'
    MOCK_CA=missing
    cne_bootstrap ssh > "$MOCK_DIR/output" 2>&1 || fail 'SSH-only dependencies did not install automatically'
    assert_contains "$MOCK_TRACE" 'install openssh-client sshpass'
    assert_absent "$MOCK_TRACE" 'wireguard|openssl|curl|ca-certificates|qrencode|coreutils|gzip|tar'
    [[ ! -s $MOCK_QUERIES ]] || fail 'SSH preparation queried a TLS CA package'
    printf 'PASS: missing SSH transport tools install without VPN or TLS dependencies\n'
)

test_lazy_client_existing() (
    mock_setup lazy-client-existing
    MOCK_MISSING='openssl curl tar base64 gzip'
    MOCK_CA=missing
    MOCK_AUDIT=broken
    MOCK_UID=1000
    cne_bootstrap client > "$MOCK_DIR/output" 2>&1 || fail 'client management required unrelated install/download tools'
    [[ ! -s $MOCK_TRACE && ! -s $MOCK_QUERIES ]] || fail 'client management inspected unrelated packages or requested sudo'
    printf 'PASS: client management ignores missing build/download dependencies and broken dpkg\n'
)

test_lazy_client_install() (
    mock_setup lazy-client-install
    MOCK_MISSING='wg sshpass openssl curl tar base64 sha256sum gzip'
    MOCK_CA=missing
    cne_bootstrap client > "$MOCK_DIR/output" 2>&1 || fail 'client management prerequisites did not install automatically'
    assert_contains "$MOCK_TRACE" 'install wireguard-tools sshpass coreutils'
    assert_absent "$MOCK_TRACE" 'openssl|curl|ca-certificates|qrencode|gzip|tar'
    [[ ! -s $MOCK_QUERIES ]] || fail 'client management queried a TLS CA package'
    printf 'PASS: client management installs only missing key and SSH tools\n'
)

test_lazy_ui_install() (
    mock_setup lazy-ui-install
    MOCK_MISSING='flock ssh sshpass openssl curl wg tar base64 sha256sum gzip'
    MOCK_CA=missing
    cne_bootstrap ui > "$MOCK_DIR/output" 2>&1 || fail 'UI lock prerequisite did not install automatically'
    assert_contains "$MOCK_TRACE" 'install util-linux'
    assert_absent "$MOCK_TRACE" 'openssh|sshpass|wireguard|openssl|curl|ca-certificates|qrencode|coreutils|gzip|tar'
    [[ ! -s $MOCK_QUERIES ]] || fail 'UI preparation queried a TLS CA package'
    printf 'PASS: a missing UI lock tool installs only util-linux\n'
)

test_default_complete_install() (
    mock_setup default-complete
    MOCK_MISSING='ssh sshpass openssl curl wg flock tar base64 sha256sum gzip'
    MOCK_CA=missing
    cne_bootstrap > "$MOCK_DIR/output" 2>&1 || fail 'first installation did not prepare the complete tool set'
    assert_contains "$MOCK_TRACE" 'install openssh-client sshpass openssl curl wireguard-tools util-linux tar coreutils gzip ca-certificates'
    [[ $(grep -c '^.*install .*coreutils' "$MOCK_TRACE") == 2 ]] || fail 'shared coreutils package was duplicated or omitted in APT calls'
    assert_contains "$MOCK_QUERIES" 'ca-certificates'
    assert_absent "$MOCK_TRACE" 'qrencode|python|--configure|--fix-broken'
    printf 'PASS: default installation automatically prepares all prerequisites and deduplicates packages\n'
)

test_audit() (
    mock_setup "audit-$1"
    MOCK_AUDIT=$1
    MOCK_UID=1000
    if cne_bootstrap > "$MOCK_DIR/output" 2>&1; then fail 'unhealthy dpkg accepted'; fi
    assert_contains "$MOCK_TRACE" 'dpkg --audit'
    assert_absent "$MOCK_TRACE" 'apt-get|sudo|--configure|--fix-broken'
    case $1 in
        broken) assert_contains "$MOCK_DIR/output" 'unrelated-server: package is unpacked but not configured' ;;
        failed) assert_contains "$MOCK_DIR/output" 'dpkg: package database is unreadable' ;;
    esac
    printf 'PASS: dpkg %s stops dependency installation with diagnostics and no repair\n' "$1"
)

test_plan() (
    mock_setup "plan-$1"
    MOCK_PLAN=$1
    if cne_bootstrap > "$MOCK_DIR/output" 2>&1; then fail "unsafe/failed plan accepted: $1"; fi
    assert_absent "$MOCK_TRACE" '^apt-get -y |--configure|--fix-broken'
    [[ ! -f $MOCK_DIR/installed ]] || fail 'unsafe/failed plan was installed'
    case $1 in
        upgrade) assert_contains "$MOCK_DIR/output" 'Inst libc6 [old]' ;;
        removal) assert_contains "$MOCK_DIR/output" 'Remv unrelated-server' ;;
        pending) assert_contains "$MOCK_DIR/output" 'Conf unrelated-server' ;;
        failed) assert_contains "$MOCK_DIR/output" 'APT cannot resolve dependencies' ;;
    esac
    printf 'PASS: %s plan does not mutate unrelated packages\n' "$1"
)

test_failure() (
    mock_setup "failure-$1"
    case $1 in repository) MOCK_REPOSITORY=failed ;; install) MOCK_INSTALL=failed ;; esac
    if cne_bootstrap > "$MOCK_DIR/output" 2>&1; then fail "$1 failure ignored"; fi
    [[ ! -f $MOCK_DIR/installed ]] || fail 'failed dependency setup was published'
    if [[ $1 == repository ]]; then assert_absent "$MOCK_TRACE" '^apt-get -[sy] '; fi
    printf 'PASS: required dependency %s failure stops startup\n' "$1"
)

test_install
test_existing
test_lazy_ui
test_lazy_ssh_existing
test_lazy_ssh_install
test_lazy_client_existing
test_lazy_client_install
test_lazy_ui_install
test_default_complete_install
test_audit broken
test_audit failed
for plan in upgrade removal pending failed; do test_plan "$plan"; done
test_failure repository
test_failure install
printf 'Bootstrap checks passed. No host package changes occurred.\n'
