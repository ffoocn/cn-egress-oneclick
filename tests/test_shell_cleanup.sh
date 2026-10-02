#!/usr/bin/env bash
# Exercise real read-only Go cache directories, with no host-service operations.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-cleanup-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'find "$WORK" -type d -exec chmod u+rwx {} + 2>/dev/null || :; rm -rf "$WORK"' EXIT
umask 077
source "$ROOT/shell/controller.sh"
source "$ROOT/shell/awg.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mode() {
    case $(uname -s) in
        Darwin) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

make_fixture() {
    CNE_STATE=$WORK/$1
    CNE_TEMP=$CNE_STATE/.session.fixture
    OUTSIDE=$CNE_STATE/outside-readonly
    mkdir -p "$CNE_TEMP" "$OUTSIDE/nested"
    printf 'outside fixture must remain untouched\n' > "$OUTSIDE/nested/untouched"
    chmod 444 "$OUTSIDE/nested/untouched"
    chmod 555 "$OUTSIDE/nested" "$OUTSIDE"
    OUTSIDE_MODE=$(mode "$OUTSIDE")
    OUTSIDE_NESTED_MODE=$(mode "$OUTSIDE/nested")
    OUTSIDE_FILE_MODE=$(mode "$OUTSIDE/nested/untouched")
    CNE_TRANSACTION_ACTIVE=0
}

assert_outside_unchanged() {
    [[ $(mode "$OUTSIDE") == "$OUTSIDE_MODE" && $(mode "$OUTSIDE/nested") == "$OUTSIDE_NESTED_MODE" && $(mode "$OUTSIDE/nested/untouched") == "$OUTSIDE_FILE_MODE" ]] || fail 'cleanup changed permissions outside its own work/session'
    [[ $(cat "$OUTSIDE/nested/untouched") == 'outside fixture must remain untouched' ]] || fail 'cleanup removed or changed a sibling through a symlink'
}

make_readonly_module_cache() {
    local work=$1
    mkdir -p "$work/gomodcache/example.test/dependency@v1.0.0/nested"
    printf 'readonly module fixture\n' > "$work/gomodcache/example.test/dependency@v1.0.0/nested/module.go"
    chmod 444 "$work/gomodcache/example.test/dependency@v1.0.0/nested/module.go"
    ln -s "$OUTSIDE" "$work/gomodcache/outside-link"
    chmod 555 "$work/gomodcache/example.test/dependency@v1.0.0/nested" "$work/gomodcache/example.test/dependency@v1.0.0"
}

test_nonroot_reproduction() (
    [[ $(id -u) != 0 ]] || { printf 'SKIP: root bypasses read-only directory permissions; cleanup scope checks still run\n'; return 0; }
    make_fixture reproduction
    make_readonly_module_cache "$CNE_TEMP/awg-build.fixture"
    if rm -rf -- "$CNE_TEMP/awg-build.fixture" 2> "$CNE_STATE/expected-rm-error"; then fail 'read-only fixture did not reproduce the original nonroot cleanup failure'; fi
    [[ -f $CNE_TEMP/awg-build.fixture/gomodcache/example.test/dependency@v1.0.0/nested/module.go ]] || fail 'permission-denied reproduction unexpectedly removed the module file'
    [[ -s $CNE_STATE/expected-rm-error ]] || fail 'permission-denied reproduction did not produce an error'
    assert_outside_unchanged
    printf 'PASS: real nonroot read-only Go module cache reproduces the original rm failure\n'
)

test_awg_cleanup() (
    make_fixture awg
    local work=$CNE_TEMP/awg-build.fixture
    make_readonly_module_cache "$work"
    mkdir "$work/source" "$work/gocache"
    printf 'private compiler fixture\n' > "$work/source/private-file"
    cne_awg_cleanup "$work" || fail 'AWG work cleanup failed on a read-only module cache'
    [[ ! -e $work ]] || fail 'AWG cleanup left its read-only build directory behind'
    [[ -d $CNE_TEMP ]] || fail 'AWG cleanup removed the whole controller session'
    assert_outside_unchanged
    printf 'PASS: AWG cleanup removes read-only module directories without changing a linked sibling\n'
)

test_controller_cleanup() (
    make_fixture controller
    make_readonly_module_cache "$CNE_TEMP/awg-build.fixture"
    printf 'private client fixture\n' > "$CNE_TEMP/client.conf"
    chmod 400 "$CNE_TEMP/client.conf"
    mkdir -p "$CNE_TEMP/readonly-parent/readonly-child"
    printf 'private interrupted fixture\n' > "$CNE_TEMP/readonly-parent/readonly-child/private-file"
    chmod 555 "$CNE_TEMP/readonly-parent/readonly-child" "$CNE_TEMP/readonly-parent"
    ln -s "$OUTSIDE" "$CNE_TEMP/outside-link"
    CNE_PASSWORDS=(first-secret-fixture second-secret-fixture third-secret-fixture)
    CNE_SUDOS=(first-sudo-fixture second-sudo-fixture third-sudo-fixture)
    CNE_ANSWER=private-answer-fixture
    cne_cleanup || fail 'controller cleanup failed on an interrupted read-only build'
    [[ ! -e $CNE_TEMP ]] || fail 'controller cleanup left private session files behind'
    [[ ${#CNE_PASSWORDS[@]} == 0 && ${#CNE_SUDOS[@]} == 0 && ! ${CNE_ANSWER+x} ]] || fail 'controller cleanup retained secrets in memory'
    assert_outside_unchanged
    printf 'PASS: controller cleanup removes private read-only session files and clears secrets within its scope\n'
)

test_awg_scope_guard() (
    make_fixture awg-scope
    if cne_awg_cleanup "$OUTSIDE" > "$CNE_STATE/output" 2>&1; then fail 'AWG cleanup accepted a directory outside its build-work prefix'; fi
    ln -s "$OUTSIDE" "$CNE_TEMP/awg-build.link"
    if cne_awg_cleanup "$CNE_TEMP/awg-build.link" >> "$CNE_STATE/output" 2>&1; then fail 'AWG cleanup accepted a symlink as its work root'; fi
    [[ -L $CNE_TEMP/awg-build.link ]] || fail 'AWG scope guard removed a rejected symlink'
    assert_outside_unchanged
    printf 'PASS: AWG cleanup rejects outside paths and symlink work roots before changing permissions\n'
)

test_controller_scope_guard() (
    make_fixture controller-scope
    rmdir "$CNE_TEMP"
    ln -s "$OUTSIDE" "$CNE_TEMP"
    cne_cleanup || fail 'controller cleanup failed while skipping a symlink session'
    [[ -L $CNE_TEMP ]] || fail 'controller cleanup removed a rejected symlink session'
    assert_outside_unchanged
    printf 'PASS: controller cleanup leaves a symlink session root and its external target untouched\n'
)

test_nonroot_reproduction
test_awg_cleanup
test_controller_cleanup
test_awg_scope_guard
test_controller_scope_guard
printf 'Cleanup checks passed. Only private test directories were changed.\n'
