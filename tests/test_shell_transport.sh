#!/usr/bin/env bash
# Exercise real controller stdin streams with fake SSH and sudo executables.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source shell/controller.sh
cne_bootstrap() { [[ $1 == ssh ]]; }
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export CNE_TEST_DIR=$sandbox
mkdir "$sandbox/bin" "$sandbox/state"
CNE_STATE=$sandbox/state; CNE_TEMP=$sandbox/state
CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
CNE_PASSWORDS=('ssh-password-fixture' '' '')
CNE_SUDOS=('sudo-password-fixture' '' '')
export CNE_TEST_SSH_SECRET=ssh-password-fixture
export CNE_TEST_AUTH_MODE=password
cat > "$sandbox/bin/sshpass" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -d && $2 == 9 ]]
read -r password <&9
[[ $password == "$CNE_TEST_SSH_SECRET" ]]
shift 2
if [[ $CNE_TEST_AUTH_MODE == key ]]; then
    [[ ${1:-} == -P && ${2:-} == passphrase ]]
    printf 'sshpass-mode:passphrase\n' >> "$CNE_TEST_DIR/trace"
    shift 2
else
    [[ ${1:-} != -P ]]
    printf 'sshpass-mode:password\n' >> "$CNE_TEST_DIR/trace"
fi
exec "$@"
STUB
cat > "$sandbox/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
has_arg() { local arg; for arg in "${args[@]}"; do [[ $arg != "$1" ]] || return 0; done; return 1; }
args=("$@")
for arg in "$@"; do
    [[ $arg != *password-fixture* && $arg != *passphrase-fixture* && $arg != *secret-client-marker* ]]
    printf 'ssh-arg:%s\n' "$arg" >> "$CNE_TEST_DIR/trace"
    last=$arg
done
if [[ $CNE_TEST_AUTH_MODE == key ]]; then
    has_arg PreferredAuthentications=publickey
    has_arg PasswordAuthentication=no
    has_arg KbdInteractiveAuthentication=no
    has_arg IdentitiesOnly=yes
    ! has_arg PreferredAuthentications=password,keyboard-interactive
else
    has_arg PubkeyAuthentication=no
    has_arg PreferredAuthentications=password,keyboard-interactive
fi
[[ ${CNE_TEST_SSH_FAIL:-0} != 1 ]] || exit 255
exec /bin/bash -c "$last"
STUB
cat > "$sandbox/bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == *'-v'* ]]; then
    if [[ ${CNE_TEST_NOPASSWD:-0} != 1 ]]; then
        read -r password
        [[ $password == sudo-password-fixture ]]
    fi
    exit 0
fi
[[ $1 == -n ]]; shift
exec "$@"
STUB
chmod +x "$sandbox/bin/"*
PATH=$sandbox/bin:$PATH
export PATH
cne_node_source() {
    cat <<'NODE'
cne_node_main() {
    printf '%s:%s:%s\n' "$1" "$2" "${3:-}"
    if [[ $1 == client-add ]]; then [[ $CNE_CLIENT_PSK == secret-client-marker ]]; fi
}
NODE
}
[[ $(cne_remote 0 status) == status:hk: ]] || fail 'root SSH lost its script input'
printf 'PASS: root SSH sends complete Bash program without password in argv\n'
CNE_USERS[0]=operator
[[ $(cne_remote 0 status) == status:hk: ]] || fail 'password sudo lost its script input'
printf 'PASS: password sudo consumes only its own password\n'
export CNE_TEST_NOPASSWD=1
[[ $(cne_remote 0 status) == status:hk: ]] || fail 'NOPASSWD sudo lost its script input'
printf 'PASS: NOPASSWD sudo does not execute the password as Shell code\n'
CNE_CLIENT_PSK=secret-client-marker
[[ $(cne_remote 0 client-add phone 15 'public-fixture') == client-add:hk:phone ]] || fail 'client secret was not received'
printf 'PASS: client secret is delivered through stdin only\n'
CNE_IDENTITIES[0]=$sandbox/key
printf 'private key fixture\n' > "${CNE_IDENTITIES[0]}"
CNE_PASSWORDS[0]=key-passphrase-fixture
export CNE_TEST_SSH_SECRET=key-passphrase-fixture
export CNE_TEST_AUTH_MODE=key
: > "$sandbox/trace"
[[ $(cne_remote 0 status) == status:hk: ]] || fail 'SSH key mode lost its script input'
for option in PreferredAuthentications=publickey PasswordAuthentication=no KbdInteractiveAuthentication=no IdentitiesOnly=yes; do
    grep -Fqx "ssh-arg:$option" "$sandbox/trace" || fail "key mode omitted $option"
done
grep -Fqx 'sshpass-mode:passphrase' "$sandbox/trace" || fail 'sshpass did not target the passphrase prompt'
printf 'PASS: SSH key mode preserves stdin and excludes password fallback that could hang sshpass\n'

# cne_remote runs in a subshell when its output is captured. The disk marker is
# what invalidates a cached password in the parent shell after that failure.
CNE_USERS[0]=root
CNE_AUTH_READY=(1 1 1)
export CNE_TEST_SSH_FAIL=1
if response=$(cne_remote 0 inspect); then fail 'failed SSH RPC returned success'; fi
[[ ${CNE_AUTH_READY[0]} == 1 && -f $CNE_TEMP/auth-failed-0 && ! -e $CNE_TEMP/auth-failed-1 ]] || fail 'RPC failure did not leave an isolated persistent auth marker'
cne_secret() { printf '%s\n' "$1" >> "$sandbox/prompts"; CNE_ANSWER=replacement-passphrase-fixture; }
cne_authenticate 0 || fail 'authentication did not recover after failed RPC'
[[ ${CNE_PASSWORDS[0]} == replacement-passphrase-fixture && ${CNE_AUTH_READY[0]} == 1 && ! -e $CNE_TEMP/auth-failed-0 ]] || fail 'authentication kept the stale credential or marker'
[[ $(wc -l < "$sandbox/prompts" | tr -d ' ') == 1 ]] || fail 'failed RPC did not prompt exactly once'
cne_authenticate 0
cne_authenticate 1
[[ $(wc -l < "$sandbox/prompts" | tr -d ' ') == 1 ]] || fail 'fresh or unrelated credential was unnecessarily prompted'
export CNE_TEST_SSH_FAIL=0
export CNE_TEST_SSH_SECRET=replacement-passphrase-fixture
[[ $(cne_remote 0 status) == status:hk: ]] || fail 'replacement credential did not recover the RPC'
printf 'PASS: failed captured RPC persists its auth marker and the next authentication reprompts once\n'

# An installation RPC can fail in the same way. The stub fails before executing
# its remote upload program, so no /root files or services are touched.
printf 'local archive fixture\n' > "$sandbox/archive"
export CNE_TEST_SSH_FAIL=1
if response=$(cne_remote_install 0 fresh "$sandbox/archive" 20250101T000000Z-aaaaaaaaaaaa); then fail 'failed installation RPC returned success'; fi
[[ ${CNE_AUTH_READY[0]} == 1 && -f $CNE_TEMP/auth-failed-0 ]] || fail 'captured installation failure lost its auth marker'
cne_authenticate 0 || fail 'authentication did not recover after failed installation RPC'
[[ ! -e $CNE_TEMP/auth-failed-0 && $(wc -l < "$sandbox/prompts" | tr -d ' ') == 2 ]] || fail 'installation failure did not reprompt and clear its marker'
printf 'PASS: failed captured installation RPC also invalidates the cached credential\n'
printf 'Transport checks passed. No network connections or privileged changes occurred.\n'
