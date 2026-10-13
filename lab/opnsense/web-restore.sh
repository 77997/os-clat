#!/bin/sh
# web-restore.sh CONFIG.xml [https://192.168.1.1] - Path B only (PLAN.md decision 4, OPNsense sheet 5.4).
#
# Restores a configuration through the web GUI of an OPNsense box that runs with factory defaults
# (LAN 192.168.1.1, user root, password opnsense), then lets the box reboot.
# Runs in the client namespace of clat-world:
#     bash lab.sh c sh /root/web-restore.sh /root/clat-opn-config.xml https://192.168.1.1
#
# NOT TESTED. Written by reading core's csrf.inc, authgui.inc and diag_backup.php (master); never run.
# What it relies on:
#   - every POST to a legacy page needs the CSRF field of the session; its name is random per session
#     and it is printed as <input type="hidden" name="KEY" value="TOKEN" autocomplete="new-password" />
#   - login fields usernamefld, passwordfld, login=1; a successful login answers with a redirect (302)
#   - restore fields: restore, conffile (the file), rebootafterrestore, flush_history
#   - the box is addressed by IP address (DNS rebind and referer checks)
# The password below is OPNsense's published factory default, not a lab secret.
# Exit status: 0 restored, 1 a step failed (the text says which), 2 usage.
set -eu

CONF=${1:-}
OPN=${2:-https://192.168.1.1}
[ -n "$CONF" ] && [ -r "$CONF" ] || { echo "usage: web-restore.sh CONFIG.xml [https://192.168.1.1]" >&2; exit 2; }

JAR=$(mktemp)
OUT=$(mktemp)
trap 'rm -f "$JAR" "$OUT"' EXIT
CURL="curl -sk --connect-timeout 10 --max-time 120 -c $JAR -b $JAR"

# name=value of the first hidden CSRF field in the page on stdin
tok() {
    sed -n 's/.*<input type="hidden" name="\([^"]*\)" value="\([^"]*\)" autocomplete="new-password" \/>.*/\1=\2/p' | head -n 1
}

T=$($CURL "$OPN/" | tok)
[ -n "$T" ] || { echo "FAILED: no CSRF field on the login page of $OPN (is the GUI reachable from here?)"; exit 1; }

code=$($CURL -o /dev/null -w '%{http_code}' \
    --data-urlencode "${T%%=*}=${T#*=}" --data-urlencode usernamefld=root \
    --data-urlencode passwordfld=opnsense --data-urlencode login=1 "$OPN/")
[ "$code" = 302 ] || { echo "FAILED: login answered HTTP $code, expected 302"; exit 1; }

T=$($CURL "$OPN/diag_backup.php" | tok)
[ -n "$T" ] || { echo "FAILED: no CSRF field on diag_backup.php (login did not hold?)"; exit 1; }

code=$($CURL -o "$OUT" -w '%{http_code}' \
    -F "${T%%=*}=${T#*=}" -F "conffile=@${CONF};type=text/xml" \
    -F rebootafterrestore=on -F flush_history=on -F "restore=Restore configuration" "$OPN/diag_backup.php")
echo "restore answered HTTP $code"
if grep -o 'The configuration has been restored[^<]*' "$OUT"; then
    echo "RESTORED: the box reboots now; wait for 10.99.0.2 with: bash lab.sh opn-wait"
    exit 0
fi
echo "FAILED: the answer does not say that the configuration was restored. Messages found in the page:"
grep -o 'Interfaces do not seem to match[^<]*' "$OUT" || true
grep -o 'CSRF check failed[^<]*' "$OUT" || true
grep -o 'alert-danger[^<]*<[^<]*' "$OUT" | head -n 5 || true
exit 1
