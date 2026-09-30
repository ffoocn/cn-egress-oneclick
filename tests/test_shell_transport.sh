#!/usr/bin/env bash
# Exercise the real controller stdin stream with fake SSH and sudo executables.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source shell/controller.sh
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export CNE_TEST_DIR=$sandbox
mkdir "$sandbox/bin" "$sandbox/state"
CNE_STATE=$sandbox/state; CNE_TEMP=$sandbox/state
CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
CNE_PASSWORDS=('ssh-password-fixture' '' '')
CNE_SUDOS=('sudo-password-fixture' '' '')
cat > "$sandbox/bin/sshpass" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
read -r password <&9
[[ $password == ssh-password-fixture ]]
shift 2
[[ ${1:-} != -P ]] || shift 2
exec "$@"
STUB
cat > "$sandbox/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  [[ $arg != *password-fixture* && $arg != *secret-client-marker* ]]
  last=$arg
done
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
[[ $(cne_remote 0 status) == status:hk: ]]
printf 'PASS: root SSH sends complete Bash program without password in argv\n'
CNE_USERS[0]=operator
[[ $(cne_remote 0 status) == status:hk: ]]
printf 'PASS: password sudo consumes only its own password\n'
export CNE_TEST_NOPASSWD=1
[[ $(cne_remote 0 status) == status:hk: ]]
printf 'PASS: NOPASSWD sudo does not execute the password as Shell code\n'
CNE_CLIENT_PSK=secret-client-marker
[[ $(cne_remote 0 client-add phone 15 'public-fixture') == client-add:hk:phone ]]
printf 'PASS: client secret is delivered through stdin only\n'
CNE_IDENTITIES[0]=$sandbox/key
[[ $(cne_remote 0 status) == status:hk: ]]
printf 'PASS: SSH key passphrase mode preserves the remote input stream\n'
