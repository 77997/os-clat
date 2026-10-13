#!/bin/sh
# provision.sh - milestone M6 on clat-opn (OPNsense 26.7, FreeBSD /bin/sh).
#
# Written from PLAN.md M6, decision 18 and section 7 row 14, and the OPNsense sheet 7.2 and 7.3.
# Ran once on OPNsense 26.7.6, 2026-10-11 (.work/results/provision-<UTC>.log).
#
# Started by "lab.sh opn-provision" on the box as
#     nohup sh /root/provision.sh > /root/provision.log 2>&1 &
# and polled for the last line "PROVISION DONE rc=<n>" (package upgrades restart sshd).
#
# What the caller has set up before, and takes away afterwards (this script touches neither):
#   - the runtime route "route add -inet default 10.99.0.1" and "ispctl provision on" on clat-world;
#   - working DNS (the local Unbound, else /etc/resolv.conf pointing at 10.99.0.1);
#   - clat-world's PPPoE server stopped, so that no IPv6 default route leads to an ISP without Internet.
#
# Environment:
#   UPDATE=yes|no       yes (default): packages and base to the current 26.7.x. no: only tayga.
#   KERNEL=auto|hold|current
#                       auto (default): hold kernel HOLD_KERNEL and lock it while BAD_KERNEL is the newest
#                       kernel set on the mirror; take the current kernel, unlocked, when a newer one exists.
#   HOLD_KERNEL=26.7.4  BAD_KERNEL=26.7.6
#   SETS_URL=https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/sets/
#
# Result files: /root/lab-kernel.policy ("hold <version>", "current <version>" or "image") is read by
# the guard of run-tests.sh. Exit status and the DONE line: 0 = every step succeeded.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
ASSUME_ALWAYS_YES=yes
export ASSUME_ALWAYS_YES

UPDATE=${UPDATE:-yes}
KERNEL=${KERNEL:-auto}
HOLD_KERNEL=${HOLD_KERNEL:-26.7.4}
BAD_KERNEL=${BAD_KERNEL:-26.7.6}
SETS_URL=${SETS_URL:-https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/sets/}
POLICY=/root/lab-kernel.policy

finish() {
    echo "== state at the end"
    opnsense-version 2>&1
    uname -v
    echo "kernel set version: $(kernel_version)"
    opnsense-update -T -k >/dev/null 2>&1
    echo "kernel lock test (1 = locked): $?"
    echo "kernel policy: $(cat "$POLICY" 2>/dev/null || echo none)"
    echo "tayga: $(pkg query %v tayga 2>/dev/null || echo 'not installed')"
    df -h / | tail -n 1
    echo "PROVISION DONE rc=$1"
    exit "$1"
}
trap 'echo "interrupted"; echo "PROVISION DONE rc=130"; exit 130' INT TERM

step() {        # step <rc on failure> <description> <command...>: run, log, stop the script on failure
    s_rc=$1; s_what=$2; shift 2
    echo "== $s_what"
    echo "+ $*"
    "$@"
    s_r=$?
    if [ "$s_r" -ne 0 ]; then
        echo "FAILED (exit $s_r): $s_what"
        finish "$s_rc"
    fi
}

kernel_version() {      # version of the installed kernel set, as OPNsense records it
    opnsense-version -v kernel 2>/dev/null || cat /usr/local/opnsense/version/kernel 2>/dev/null || echo unknown
}

case "$UPDATE" in yes|no) ;; *) echo "UPDATE must be yes or no"; finish 2 ;; esac
case "$KERNEL" in auto|hold|current) ;; *) echo "KERNEL must be auto, hold or current"; finish 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "must run as root"; finish 2; }

echo "== state at the start ($(date -u '+%Y-%m-%dT%H:%M:%SZ')) UPDATE=$UPDATE KERNEL=$KERNEL"
opnsense-version 2>&1
uname -v
echo "kernel set version: $(kernel_version)"
echo "IPv4 default route(s):"; netstat -rn -f inet | grep '^default' || echo "  none"
echo "IPv6 default route(s):"; netstat -rn -f inet6 | grep '^default' || echo "  none"
cat /etc/resolv.conf
df -h / | tail -n 1

if ! netstat -rn -f inet | grep -q '^default'; then
    echo "there is no IPv4 default route: the caller has to add the temporary route first"
    finish 10
fi
if netstat -rn -f inet6 | grep -q '^default'; then
    # an IPv6 default route to an ISP without Internet: make the resolver try IPv4 first.
    # Core switches back at its next resolver configuration; the reboot after M6 does that too.
    echo "an IPv6 default route exists: preferring IPv4 for the downloads"
    /etc/rc.d/ip6addrctl prefer_ipv4 || true
fi

echo "== mirror reachable, list of sets"
SETS=$(fetch -T 30 -qo - "$SETS_URL" 2>&1)
if [ $? -ne 0 ] || [ -z "$SETS" ]; then
    echo "cannot fetch $SETS_URL: $SETS"
    echo "check: route, DNS (drill pkg.opnsense.org), 'ispctl provision on' on clat-world"
    finish 10
fi
KERNELS=$(printf '%s\n' "$SETS" | grep -o 'kernel-[0-9][0-9._]*-amd64\.txz' | sed -e 's/^kernel-//' -e 's/-amd64\.txz$//' | sort -u -V)
NEWEST=$(printf '%s\n' "$KERNELS" | tail -n 1)
echo "kernel sets on the mirror: $(echo $KERNELS)"
echo "newest: ${NEWEST:-unknown}"

step 11 "package repository catalogue" pkg update -f

if [ "$UPDATE" = yes ]; then
    # what the GUI runs for the package part (core scripts/firmware/update.sh)
    step 12 "package upgrade to the current 26.7.x" opnsense-update -pt opnsense
fi

step 13 "tayga package" pkg install -y tayga
if [ ! -x /usr/local/sbin/tayga ]; then
    echo "FAILED: /usr/local/sbin/tayga does not exist after the installation"
    finish 13
fi
echo "tayga $(pkg query %v tayga)"

if [ "$UPDATE" = no ]; then
    echo "image" > "$POLICY"
    echo "UPDATE=no: base and kernel stay as in the image"
    finish 0
fi

echo "== base set"
if opnsense-update -b -c; then
    step 14 "base set to the current 26.7.x" opnsense-update -b
else
    echo "no newer base set (opnsense-update -b -c): skipped"
fi

echo "== kernel set"
MODE=$KERNEL
if [ "$MODE" = auto ]; then
    if [ -z "$NEWEST" ]; then
        echo "could not read the kernel versions from the mirror listing: holding $HOLD_KERNEL"
        MODE=hold
    elif [ "$NEWEST" = "$BAD_KERNEL" ] || [ "$NEWEST" = "$HOLD_KERNEL" ]; then
        echo "newest kernel set is $NEWEST: holding $HOLD_KERNEL (PLAN decision 18)"
        MODE=hold
    else
        # NEWEST is above BAD_KERNEL when BAD_KERNEL sorts before it
        if [ "$(printf '%s\n%s\n' "$BAD_KERNEL" "$NEWEST" | sort -V | tail -n 1)" = "$NEWEST" ]; then
            echo "a kernel set newer than $BAD_KERNEL exists ($NEWEST): taking it, no lock (PLAN section 7 row 14)"
            MODE=current
        else
            echo "newest kernel set $NEWEST is older than $BAD_KERNEL: holding $HOLD_KERNEL"
            MODE=hold
        fi
    fi
fi

if [ "$MODE" = hold ]; then
    opnsense-update -T -k >/dev/null 2>&1
    LOCKED=$?
    if [ "$(kernel_version)" = "$HOLD_KERNEL" ] && [ "$LOCKED" -eq 1 ]; then
        echo "kernel set $HOLD_KERNEL is installed and locked already: nothing to do"
    else
        if [ "$LOCKED" -eq 1 ]; then
            step 15 "unlock the kernel set to replace it" opnsense-update -U -k
        fi
        step 15 "kernel set $HOLD_KERNEL" opnsense-update -kr "$HOLD_KERNEL"
        step 16 "lock the kernel set" opnsense-update -L -k
    fi
    opnsense-update -T -k >/dev/null 2>&1
    if [ $? -ne 1 ]; then
        echo "FAILED: the kernel set is not locked (opnsense-update -T -k did not exit 1)"
        finish 16
    fi
    echo "hold $HOLD_KERNEL" > "$POLICY"
else
    opnsense-update -T -k >/dev/null 2>&1
    if [ $? -eq 1 ]; then
        step 15 "unlock the kernel set" opnsense-update -U -k
    fi
    if opnsense-update -k -c; then
        step 15 "kernel set to the current 26.7.x" opnsense-update -k
    else
        echo "no newer kernel set (opnsense-update -k -c): skipped"
    fi
    echo "current ${NEWEST:-unknown}" > "$POLICY"
fi

echo "== done; the caller removes the route and reboots (opnsense-update never reboots by itself)"
finish 0
