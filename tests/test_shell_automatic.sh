#!/usr/bin/env bash
# Scheduler transport exercises real Shell stdin with private executable stubs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-automatic.XXXXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
umask 077
source "$ROOT/shell/controller.sh"
CNE_STATE=$WORK/state; CNE_TEMP=$CNE_STATE/session
mkdir -p "$CNE_TEMP" "$WORK/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cne_bootstrap() { [[ $1 == ssh ]]; }
cne_secret() { fail 'automatic operation asked for a password'; }
cne_prompt() { fail 'automatic operation asked an interactive question'; }
CNE_NONINTERACTIVE=1
CNE_HOSTS=(203.0.113.10 198.51.100.20 192.0.2.30)
CNE_USERS=(root operator operator)
CNE_IDENTITIES=("$WORK/key" - -)
CNE_CONNECTIONS=(ssh ssh local)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
cne_authenticate 0
[[ ${CNE_AUTH_READY[0]} == 1 && -z ${CNE_PASSWORDS[0]} && -z ${CNE_SUDOS[0]} ]] || fail 'automatic key login retained secrets'
if cne_authenticate 1 > "$WORK/no-key" 2>&1; then fail 'automatic password-only SSH succeeded'; fi
ssh-keygen -q -t ed25519 -N fixture-passphrase -f "$WORK/encrypted-key"
CNE_IDENTITIES[1]=$WORK/encrypted-key
if cne_authenticate 1 > "$WORK/encrypted" 2>&1; then fail 'automatic encrypted key asked or succeeded'; fi
printf 'PASS: scheduled SSH permits only actual unencrypted private keys and never prompts for secrets\n'
export CNE_AUTO_WORK=$WORK
cat > "$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do printf '%s\n' "$argument" >> "$CNE_AUTO_WORK/ssh-args"; last=$argument; done
exec /bin/bash -c "$last"
STUB
cat > "$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CNE_AUTO_WORK/sudo-args"
[[ $1 == -n && $2 == -k && $3 == /bin/bash ]]
[[ ${CNE_AUTO_SUDO_DENY:-0} == 0 ]] || exit 1
shift 2
exec "$@"
STUB
cat > "$WORK/bin/sshpass" <<'STUB'
#!/usr/bin/env bash
exit 99
STUB
chmod +x "$WORK/bin/"*
PATH=$WORK/bin:$PATH
cne_node_source() { printf 'cne_node_main() { printf "automatic:%%s:%%s\\n" "$1" "$2"; }\n'; }
[[ $(cne_remote 0 maintenance-info) == automatic:maintenance-info:hk ]] || fail 'automatic root script lost stdin'
for argument in BatchMode=yes IdentitiesOnly=yes PasswordAuthentication=no KbdInteractiveAuthentication=no; do grep -Fxq "$argument" "$WORK/ssh-args" || fail "missing $argument"; done
CNE_IDENTITIES[1]=$WORK/key
cne_authenticate 1
[[ $(cne_remote 1 maintenance-info) == automatic:maintenance-info:sh ]] || fail 'automatic remote sudo lost stdin'
grep -Fxq 'sudo -n -k /bin/bash -s' "$WORK/ssh-args" || fail 'remote sudo reused a password timestamp'
printf 'PASS: scheduled SSH uses BatchMode, no password fallback or sshpass, and ignores sudo timestamps\n'
id() { [[ $* == -u ]] && printf '1000\n'; }
cne_authenticate 2
[[ $(cne_remote 2 maintenance-info) == automatic:maintenance-info:exit ]] || fail 'automatic local sudo lost script'
export CNE_AUTO_SUDO_DENY=1
if cne_remote 2 maintenance-info > "$WORK/local-denied" 2>&1; then fail 'password sudo accepted through cache'; fi
grep -Eq -- '^-n -k /bin/bash /' "$WORK/sudo-args" || fail 'local sudo did not ignore cached authorization'
[[ -z ${CNE_PASSWORDS[2]} && -z ${CNE_SUDOS[2]} ]] || fail 'local scheduler retained passwords'
printf 'PASS: scheduled local management tests actual password-free sudo and fails without prompting\n'
CNE_HOSTS=('' '' '')
if cne_require_config > "$WORK/no-config" 2>&1; then fail 'empty automatic configuration was accepted'; fi
printf 'PASS: missing scheduled configuration fails without opening the setup wizard\n'
cne_safe_directory() { return 0; }
flock() { return 1; }
CNE_HOME=$CNE_STATE
result=0
cne_initialize > "$WORK/busy" 2>&1 || result=$?
[[ $result == 75 ]] || fail 'busy management lock lost the scheduler retry status'
grep -Fq '15 分钟' "$WORK/busy" || fail 'lock contention did not explain deferral'
printf 'PASS: a busy management lock returns the dedicated timer retry status without changing files or prompting\n'
