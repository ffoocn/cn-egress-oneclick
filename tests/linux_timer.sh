#!/usr/bin/env bash
# Isolated real systemd timer installation, interruption recovery and ownership.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cne-linux-timer.XXXXXXXX")
WORK=$(cd "$WORK" && pwd -P)
NAME=cne-timer-test-$$
cleanup() {
    local result=$?
    if ((result)); then
        docker exec "$NAME" systemctl --no-pager status 'cn-egress-renew-abcdef012345.service' 'cn-egress-renew-abcdef012345.timer' >&2 || :
        docker exec "$NAME" journalctl --no-pager -n 20 >&2 || :
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || :
    rm -rf "$WORK"
}
trap cleanup EXIT
umask 077
source "$ROOT/shell/controller.sh"
source "$ROOT/shell/renew.sh"
CNE_STATE='/root/manager % "quoted" state'; HOME=/root
CNE_RENEW_TIMER_ID=abcdef012345
id() { printf '0\n'; }
cne_renew_timer_files "$WORK"
cp "$ROOT/cn-egress-oneclick.sh" "$WORK/manager.sh"
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'; declare -f cne_renew_timer_root; printf '\ncne_renew_timer_root "$@"\n'; } > "$WORK/helper"
cat > "$WORK/run" <<'LINUX'
#!/usr/bin/env bash
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
id=abcdef012345; unit=cn-egress-renew-$id; directory=/usr/local/lib/$unit
mkdir -p "$directory" /root/testbin
chmod 755 /usr /usr/local /usr/local/lib /etc /etc/systemd /etc/systemd/system "$directory"
# Simulate a failed copy on the second published file, using the real first file.
cat > /root/testbin/mv <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${2:-} == /etc/systemd/system/cn-egress-renew-abcdef012345.service && ! -f /root/injected ]]; then
    touch /root/injected
    exit 1
fi
exec /bin/mv "$@"
STUB
chmod 755 /root/testbin/mv
if PATH=/root/testbin:$PATH /bin/bash /root/input/helper enable "$id" /root/input; then fail 'injected publication failure succeeded'; fi
[[ -f $directory/ownership.pending && -f $directory/manager.sh && ! -f /etc/systemd/system/$unit.service ]] || fail 'interruption did not leave safe recovery evidence'
/bin/bash /root/input/helper enable "$id" /root/input
[[ -f $directory/ownership && ! -e $directory/candidate && ! -e $directory/ownership.pending ]] || fail 'retry did not complete prior publication'
systemctl is-enabled --quiet "$unit.timer" && systemctl is-active --quiet "$unit.timer" || fail 'timer not running'
systemd-analyze verify "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"
printf 'PASS: real systemd timer retries an interrupted first installation from a proven pending receipt\n'
# Running the copied standalone command must use exactly the quoted state path.
# Missing configuration/dependencies fail safely; no keys or nodes are supplied.
systemctl start "$unit.service" >/dev/null 2>&1 && fail 'empty configuration unexpectedly succeeded'
[[ -d '/root/manager % "quoted" state' && ! -e /root/manager ]] || fail 'systemd environment quoting changed the state path'
journalctl --no-pager -u "$unit.service" -n 30 | grep -Eq '自动维护缺少(依赖|三个节点)' || fail 'scheduled command did not report its safe failure'
printf 'PASS: the scheduled standalone command preserves spaces, percent and quotes and fails without interaction\n'
# A held menu lock must schedule a retry rather than lose today's check.
flock '/root/manager % "quoted" state/lock' sleep 60 & locker=$!
sleep 0.2
systemctl start "$unit.service" >/dev/null 2>&1 && fail 'busy state unexpectedly succeeded'
[[ $(systemctl show "$unit.service" -p ExecMainStatus --value) == 75 && $(systemctl show "$unit.service" -p SubState --value) == auto-restart ]] || fail 'busy manager did not schedule its dedicated retry'
/bin/bash /root/input/helper disable "$id"
[[ $(systemctl show "$unit.service" -p SubState --value) != auto-restart ]] || fail 'disabling left a pending automatic retry'
kill "$locker"; wait "$locker" || :
/bin/bash /root/input/helper enable "$id" /root/input
printf 'PASS: busy menu locks defer maintenance and timer disable cancels the pending retry\n'
# A failed update then a different new program must finish the first candidate.
printf '\n# second program version\n' >> /root/input/manager.sh
rm -f /root/injected
if PATH=/root/testbin:$PATH /bin/bash /root/input/helper enable "$id" /root/input; then fail 'update fault was ignored'; fi
printf '\n# third program version\n' >> /root/input/manager.sh
/bin/bash /root/input/helper enable "$id" /root/input
cmp /root/input/manager.sh "$directory/manager.sh" || fail 'retry with newer input did not publish safely'
printf 'PASS: interrupted owned updates can recover before publishing a newer program\n'
/bin/bash /root/input/helper disable "$id"
! systemctl is-active --quiet "$unit.timer" || fail 'disable left timer running'
printf 'PASS: timer disable stops scheduling without stopping unrelated services\n'
# An external modification must fail before service changes.
printf '\n# external change\n' >> /etc/systemd/system/$unit.service
if /bin/bash /root/input/helper enable "$id" /root/input; then fail 'modified owned service was overwritten'; fi
! systemctl is-active --quiet "$unit.timer" || fail 'foreign-modified unit reenabled timer'
printf 'PASS: root receipts reject externally modified units before overwrite or execution\n'
# Prefix drop-ins that will attach only after creation must also block a new ID.
mkdir -p /etc/systemd/system/cn-egress-renew-.service.d
printf '[Service]\nEnvironment=FOREIGN=1\n' > /etc/systemd/system/cn-egress-renew-.service.d/foreign.conf
if /bin/bash /root/input/helper enable 012345abcdef /root/input; then fail 'new unit ignored prefix drop-in'; fi
[[ ! -e /usr/local/lib/cn-egress-renew-012345abcdef ]] || fail 'drop-in rejection created service files'
printf 'PASS: dashed-prefix drop-ins block first-time unit creation before mutations\n'
LINUX
# Network disabled; only this task-owned privileged test container is affected.
docker run -d --privileged --network none --tmpfs /run --tmpfs /run/lock --name "$NAME" "${CNE_TEST_IMAGE:-cne-maintenance-test:local}" /lib/systemd/systemd >/dev/null
docker cp "$WORK/." "$NAME:/root/input" >/dev/null
for attempt in 1 2 3 4 5; do
    state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null) || :
    [[ $state == running || $state == degraded ]] && break
    sleep 1
done
docker exec "$NAME" /bin/bash /root/input/run
