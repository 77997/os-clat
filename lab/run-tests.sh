#!/usr/bin/env bash
# run-tests.sh - the test runner of the os-clat Hyper-V lab (PLAN.md section 8).
#
# In use on the lab since 2026-10-11: every test except T25 has run, with in-guest resets only
# (README.md section 10). T25 has run as "bash lab.sh t25" (screens/t25.mjs: a browser presses the buttons);
# the T25 of this file waits for clicks by hand. The reset modes "hyperv" and "manual" have not run: no
# checkpoint exists yet; they restore one checkpoint, which holds the configuration of one profile only.
#
# One file, two parts:
#   outer part (this bash code; Git Bash on the Windows host): H resets, copies the current plugin tree
#       and this file to clat-world, starts the inner part once per test, fetches the results.
#   inner part (the Python 3 text at the end; runs on clat-world, started by "--inside"): the guard T00,
#       the soft reset, the sampler and one function per test id.
#
# usage, from Git Bash in the lab/ folder of this repository:
#   bash run-tests.sh all                       the set of the profile (below): the production set by default, with --profile p0 the full run in the order of PLAN.md section 8
#   bash run-tests.sh T04 T11                   single tests; a test that continues from another one
#                                               (T08 from T07, T19 from T18, T20 from T19) pulls that one in
#   bash run-tests.sh T00                       the guard alone, on the lab as it is: no reset, nothing changed
#                                               (every other test runs the same guard before and after its body)
#   bash run-tests.sh --reset guest T16         choose how an H reset is done:
#        hyperv  restore checkpoint clat-base with hyperv\reset-lab.ps1 (default with Hyper-V rights)
#        guest   in-guest reset: remove the plugin and its leftovers, put the configuration of the profile back,
#                reboot clat-opn, the ISP's defaults (default without Hyper-V rights; weaker than a checkpoint)
#        manual  print WAITING FOR RESTORE and wait until reset-lab.ps1 has been run elevated by hand
#   bash run-tests.sh list                      the test ids, their reset and title
#   bash run-tests.sh T25                       the one hand test (waits for clicks in the GUI by hand)
#   bash run-tests.sh --profile p0 T04          choose the profile the tests run in:
#        prod    (default) the production profile: the ISP as "ispctl defaults" sets it (WAN /64 by SLAAC, /56 PD, no PREF64,
#                PPP-Max-Payload echoed) and clat-opn configured by the customer page (/root/config.lab-prod.xml:
#                WAN MTU 1508, DNS servers by hand, Unbound forwarding). "all" is then the production set:
#                T01 T26 T14 T13 T11 T15 T27 T28 T29 T12; the other tests are not adapted to it and are skipped
#        p0      the first profile: "ispctl defaults p0" (PREF64 and RDNSS in the RA, PPP MTU 1492) and the lab's base
#                configuration (/root/config.lab-base.xml); every test T01 to T24 (T25 only when it is named)
#        An S test needs the box in the profile of the run; an H test (T01 first) puts it there.
#
# Needs: .work/disks/build/ssh_config from "bash lab.sh addr" (hosts clat-world and clat-opn), milestones
# M0 to M7 done, and for single S tests the plugin installed (T01 or "bash lab.sh plugin install").
#
# Results: .work/results/<UTC run id>/ with env.txt, summary.tsv, console.log and one folder per test:
# result.tsv, checks.txt, commands.log (every command with its output), sampler-*.jsonl, ping-*.log,
# *.pcap with a text summary, st-*.json, pfctl and route listings.
# summary.tsv: id, pass | fail | blocked (reason) | invalid | skipped (reason), seconds, note.
# Exit status: 0 every test passed; 1 at least one fail, blocked or invalid; 2 usage or set-up error.
set -u

if [ "${1:-}" = "--inside" ]; then
    # clat-world: cut the Python part out of this file (line numbers are kept) and run it
    shift
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    py="$(dirname "$self")/.run-tests-inner.py"
    awk '/^: <<.__INNER_PYTHON__.$/ { on = 1; print ""; next }
         /^__INNER_PYTHON__$/ { on = 0 }
         { print (on ? $0 : "") }' "$self" > "$py" || exit 97
    exec python3 -B "$py" "$@"
fi

LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$LAB/.work
RESULTS=$WORK/results
BUILD=$WORK/disks/build
SSHCFG=$BUILD/ssh_config
PLUGIN=$(cd "$LAB/.." && pwd)/net/clat
REMOTE=/root/clat-tests

FULL_ORDER="T01 T02 T03 T03b T04 T22 T05 T06 T07 T08 T09 T10 T11 T13 T14 T15 T24 T12 T16 T17 T18 T19 T20 T23 T21"
PROD_ORDER="T01 T26 T14 T13 T11 T15 T27 T28 T29 T12"

say() { printf '%s\n' "$*"; }
die() { printf 'run-tests: %s\n' "$*" >&2; exit 2; }

reset_of() {    # H = hard reset before the test, S = soft reset, from = continues from the test before it, none = no reset
    case "$1" in
    T00) echo none ;;
    T01|T16|T17|T18|T23|T21) echo H ;;
    T08|T19|T20) echo from ;;
    *) echo S ;;
    esac
}
pred_of() { case "$1" in T08) echo T07 ;; T19) echo T18 ;; T20) echo T19 ;; esac; }
title_of() {
    case "$1" in
    T00) echo "the guard alone, on the lab as it is (no reset)" ;;
    T01) echo "install on a clean box, activation by PREF64 only" ;;
    T02) echo "pf rules, NAT and states while a client flow runs" ;;
    T03) echo "gateway, default route, datapath TCP/UDP/ICMP, strict-prefix refusal, bypass" ;;
    T03b) echo "interface-bound states" ;;
    T04) echo "MSS and DF at PPP MTU 1492" ;;
    T22) echo "WAN without a SLAAC address" ;;
    T05) echo "dormant interface is inert (15 minutes)" ;;
    T06) echo "PREF64 lifetime, withdrawal, solicited RA" ;;
    T07) echo "DNS discovery on a default box finds nothing" ;;
    T08) echo "DNS discovery with forwarding and with DNS64 in Unbound" ;;
    T09) echo "static prefix" ;;
    T10) echo "forged RA from the LAN" ;;
    T11) echo "PPPoE session loss: reset, silent drop, suspend" ;;
    T13) echo "tayga crash, supervisor crash" ;;
    T14) echo "API: status, test, settings, disable and enable, validation" ;;
    T15) echo "reboot, also in the DNS-only configuration" ;;
    T24) echo "throughput (informational)" ;;
    T12) echo "renumbering: new /56, single /64" ;;
    T16) echo "native IPv4 through IPCP" ;;
    T17) echo "static IPv4 gateway on MGMT, suspend with fail-over" ;;
    T18) echo "jumbo: WAN MTU field 1508 against an echoing BNG" ;;
    T19) echo "jumbo: field 1508 against a BNG that does not echo" ;;
    T20) echo "jumbo: fields 1518 and 1528" ;;
    T23) echo "outbound NAT mode manual" ;;
    T21) echo "plugin removal and second install" ;;
    T25) echo "record drift after an Assignments edit (by hand)" ;;
    T26) echo "production profile: activation by DNS, addresses, rules, MSS, DF, client by name, the firewall itself" ;;
    T27) echo "production profile: DNS64 resolver unreachable for 10 minutes and back, Unbound restart" ;;
    T28) echo "production profile: 15 minutes idle, Router Solicitations and DNS queries counted" ;;
    T29) echo "production profile: PREF64 and option 108 on the LAN (Devices translate) together with the plugin" ;;
    esac
}

RESET_MODE=
PROFILE=prod
WANT=
ALL=no
while [ $# -gt 0 ]; do
    case "$1" in
    --reset) RESET_MODE=${2:-}; shift ;;
    --reset=*) RESET_MODE=${1#--reset=} ;;
    --profile) PROFILE=${2:-}; shift ;;
    --profile=*) PROFILE=${1#--profile=} ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    list) for t in T00 $FULL_ORDER T25 T26 T27 T28 T29; do printf '%-5s %-5s %s\n' "$t" "$(reset_of "$t")" "$(title_of "$t")"; done; exit 0 ;;
    all) ALL=yes ;;
    selftest) WANT="$WANT selftest" ;;
    T[0-9]*) [ -n "$(title_of "$1")" ] || die "unknown test id $1 (see: run-tests.sh list)"; WANT="$WANT $1" ;;
    *) die "unknown argument $1 (see: run-tests.sh --help)" ;;
    esac
    shift
done
case "$PROFILE" in prod|p0) ;; *) die "--profile takes prod or p0" ;; esac
if [ "$PROFILE" = prod ]; then ORDER=$PROD_ORDER; else ORDER=$FULL_ORDER; fi
[ "$ALL" = yes ] && WANT="$WANT $ORDER"
[ -n "$WANT" ] || die "nothing to run; give test ids or 'all' (see: run-tests.sh --help)"

hyperv_rights() {       # member of Hyper-V Administrators (S-1-5-32-578) or an elevated shell (high integrity)
    local groups whoami
    # Windows' whoami by its path: Git Bash has a whoami.exe of its own that knows no /groups
    whoami="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32/whoami.exe"
    groups=$(MSYS_NO_PATHCONV=1 "$whoami" /groups 2>/dev/null) || return 1
    case "$groups" in *S-1-5-32-578*|*S-1-16-12288*|*S-1-16-16384*) return 0 ;; esac
    return 1
}
if [ -z "$RESET_MODE" ]; then
    if hyperv_rights; then RESET_MODE=hyperv; else RESET_MODE=guest; fi
fi
case "$RESET_MODE" in hyperv|guest|manual) ;; *) die "--reset takes hyperv, guest or manual" ;; esac

# the tests to run: predecessors added, in the order of the full run of the profile; T00 (only when asked for)
# first, then the tests of the other profile's order that were asked for by id, T25 last
REST=
for t in $FULL_ORDER $PROD_ORDER; do
    case " $ORDER $REST " in *" $t "*) ;; *) REST="$REST $t" ;; esac
done
LIST=
for t in T00 $ORDER $REST T25; do
    need=no
    for w in $WANT; do
        [ "$w" = "$t" ] && need=yes
        p=$(pred_of "$w"); [ "$p" = "$t" ] && need=yes
        [ -n "$p" ] && [ "$(pred_of "$p")" = "$t" ] && need=yes
    done
    [ "$need" = yes ] && LIST="$LIST $t"
done
case " $WANT " in *" selftest "*) LIST="selftest" ;; esac

wssh() { ssh -F "$SSHCFG" -o ServerAliveInterval=15 -o ServerAliveCountMax=8 clat-world "$@"; }
wssh_quick() { ssh -F "$SSHCFG" -o ConnectTimeout=8 clat-world "$@" 2>/dev/null; }
wscp() { scp -q -F "$SSHCFG" "$@"; }

find_world() {  # wait until clat-world answers; its address on the Default Switch can change
    local i
    for i in $(seq 1 40); do
        if [ -f "$SSHCFG" ] && [ "$(wssh_quick hostname)" = clat-world ]; then return 0; fi
        bash "$LAB/lab.sh" addr >/dev/null 2>&1 || true
        if [ -f "$SSHCFG" ] && [ "$(wssh_quick hostname)" = clat-world ]; then return 0; fi
        sleep 15
    done
    return 1
}

build_bundle() {        # the plugin tree as it is now: files only, modes are set on the box
    mkdir -p "$BUILD" || return 1
    [ -d "$PLUGIN/src" ] || { say "no plugin source at $PLUGIN/src"; return 1; }
    ( cd "$PLUGIN/src" && find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' | sed 's|^\./||' | LC_ALL=C sort ) > "$BUILD/os-clat.files" || return 1
    [ -s "$BUILD/os-clat.files" ] || { say "the plugin source tree is empty"; return 1; }
    if ( cd "$PLUGIN/src" && grep -l $'\r' $(cat "$BUILD/os-clat.files") ) 2>/dev/null | grep -q .; then
        say "WARNING: files with CR line ends in $PLUGIN/src"
    fi
    ( cd "$PLUGIN/src" && tar -cf "$BUILD/os-clat.tar" --owner=0 --group=0 --numeric-owner -T "$BUILD/os-clat.files" ) || return 1
    TAR_SHA=$(sha256sum "$BUILD/os-clat.tar" | cut -d' ' -f1)
}

push_runner() {         # everything the inner part needs; repeated after a restore, which reverts clat-world
    wssh "mkdir -p $REMOTE/results/$RUN" || return 1
    wscp "$LAB/run-tests.sh" "$LAB/opnsense/install-plugin.sh" "clat-world:$REMOTE/" || return 1
    wscp "$BUILD/os-clat.tar" "$BUILD/os-clat.files" clat-world:/root/ || return 1
    wscp "$PLUGIN/+POST_INSTALL.post" clat-world:/root/os-clat.post-install || return 1
    wscp "$PLUGIN/+PRE_DEINSTALL.pre" clat-world:/root/os-clat.pre-deinstall || return 1
    wscp "$PLUGIN/+POST_DEINSTALL.post" clat-world:/root/os-clat.post-deinstall || return 1
    wscp "$RESULTS/$RUN/env.txt" "clat-world:$REMOTE/results/$RUN/env.txt" || return 1
}

fetch_results() {
    wssh "tar -C $REMOTE/results -cf - $RUN" 2>/dev/null | tar -C "$RESULTS" -xf - 2>/dev/null
}

hard_reset() {          # hyperv and manual: both VMs back to checkpoint clat-base. guest: done by the inner part
    case "$RESET_MODE" in
    hyperv)
        say "== H reset: restoring checkpoint clat-base on both VMs"
        MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File "$(cygpath -w "$LAB/hyperv/reset-lab.ps1")" -Action Restore -Name clat-base \
            > "$RESULTS/$RUN/restore-before-$1.log" 2>&1
        rc=$?
        tail -n 12 "$RESULTS/$RUN/restore-before-$1.log"
        [ "$rc" -eq 0 ] || { say "reset-lab.ps1 exited $rc (log: $RESULTS/$RUN/restore-before-$1.log)"; return 1; }
        ;;
    manual)
        say "WAITING FOR RESTORE"
        say "  run in an elevated PowerShell:"
        say "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(cygpath -w "$LAB/hyperv/reset-lab.ps1") -Action Restore -Name clat-base"
        while [ "$(wssh_quick hostname)" = clat-world ]; do sleep 5; done
        say "  clat-world stopped answering; waiting for it to come back"
        ;;
    guest)
        return 0
        ;;
    esac
    find_world || { say "clat-world does not answer after the restore"; return 1; }
    push_runner || { say "cannot copy the runner to clat-world after the restore"; return 1; }
}

summarise() {
    : > "$RESULTS/$RUN/summary.tsv"
    for t in $DONE; do
        if [ -s "$RESULTS/$RUN/$t/result.tsv" ]; then
            cat "$RESULTS/$RUN/$t/result.tsv" >> "$RESULTS/$RUN/summary.tsv"
        else
            printf '%s\tinvalid\t0\tno result came back from clat-world (connection lost or the runner died)\n' "$t" >> "$RESULTS/$RUN/summary.tsv"
        fi
    done
}

# ---- main -----------------------------------------------------------------------------------------------

RUN=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RESULTS/$RUN" || die "cannot create $RESULTS/$RUN"
find_world || die "clat-world does not answer over ssh (bash lab.sh addr; is the VM running?)"

if [ "$LIST" = selftest ]; then
    wssh "mkdir -p $REMOTE" && wscp "$LAB/run-tests.sh" "clat-world:$REMOTE/" || die "cannot copy the runner"
    wssh "bash $REMOTE/run-tests.sh --inside selftest"
    exit $?
fi

build_bundle || die "cannot pack the plugin tree"
{
    echo "RUN=$RUN"
    echo "RESET_MODE=$RESET_MODE"
    echo "PROFILE=$PROFILE"
    echo "TESTS=$(echo $LIST)"
    echo "PLUGIN_TAR_SHA256=$TAR_SHA"
    echo "PLUGIN_FILES=$(wc -l < "$BUILD/os-clat.files" | tr -d ' ')"
    echo "HOST_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RESULTS/$RUN/env.txt"
push_runner || die "cannot copy the runner and the plugin tree to clat-world"

say "run $RUN: profile $PROFILE, reset mode $RESET_MODE, tests:$LIST"
say "results: $RESULTS/$RUN"
DONE=
for t in $LIST; do
    kind=$(reset_of "$t")
    [ "$t" = T25 ] && kind=S
    if [ "$kind" = H ]; then
        if ! hard_reset "$t"; then
            mkdir -p "$RESULTS/$RUN/$t"
            printf '%s\tinvalid\t0\tthe H reset (%s) failed\n' "$t" "$RESET_MODE" > "$RESULTS/$RUN/$t/result.tsv"
            DONE="$DONE $t"
            say "RESULT $t invalid: the H reset failed"
            continue
        fi
        [ "$RESET_MODE" = guest ] && kind=guestH
    fi
    wssh "bash $REMOTE/run-tests.sh --inside $RUN $t $kind $RESET_MODE $PROFILE" 2>&1 | tee -a "$RESULTS/$RUN/console.log"
    DONE="$DONE $t"
    fetch_results || say "could not fetch the results of $t (clat-world unreachable?)"
    summarise
done

summarise
say
say "== summary of run $RUN ($RESULTS/$RUN/summary.tsv)"
cat "$RESULTS/$RUN/summary.tsv"
if awk -F '\t' '$2 != "pass" && $2 !~ /^skipped/ { bad = 1 } END { exit bad ? 0 : 1 }' "$RESULTS/$RUN/summary.tsv"; then
    exit 1
fi
exit 0

: <<'__INNER_PYTHON__'
# ======================================================================================================
# Inner part: Python 3 (standard library only), runs on clat-world as root.
#   run-tests.sh --inside <run id> <test id> <S|H|guestH|from|none> [reset mode]
#   run-tests.sh --inside selftest          checks the parsers of this file against built-in samples
# Prefixes in commands.log: "W:" command on clat-world, "C:" in the client namespace, "O:" /bin/sh on
# clat-opn, "API" web API of clat-opn. "st" is the JSON of "configctl clat details" (once per step);
# everything sampled per second reads /var/run/clat/status.json.
# ======================================================================================================
import base64
import ipaddress
import json
import os
import re
import signal
import ssl
import struct
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request

OPN = '10.99.0.2'
TARGET = '192.88.99.1'                  # IPv4 test target on clat-world
TARGET6 = '64:ff9b::c058:6301'          # the same through the NAT64 prefix
NEG_DST = '10.255.255.1'                # private: the CLAT's tayga must refuse it under the well-known prefix
RESOLVER6 = '2001:db8:64::53'
GOOGLE_DNS64 = ('2001:4860:4860::6464', '2001:4860:4860::64')   # clat-world's resolver answers on them too
NAME4 = 'v4only.clat.lab'               # A record TARGET only; the ISP's DNS64 answers AAAA with TARGET6
WKP = '64:ff9b::/96'

# What differs between the two profiles (run-tests.sh --profile). 'defaults' puts the ISP into the profile,
# 'config' is the configuration the in-guest reset puts back, 'pd' the delegated prefix and 'clat64' its
# highest /64, 'source' where the NAT64 prefix comes from, 'mtu' the PPP MTU, the translated IPv4 MTU and
# the TCP MSS, 'forwarding' Unbound's "Use System Nameservers", 'wan_mtu' the MTU field of the WAN.
PROFILES = {
    'p0': {'defaults': 'ispctl defaults p0', 'config': '/root/config.lab-base.xml', 'pd': '2001:db8:5600::/56',
           'clat64': '2001:db8:5600:ff::/64', 'wan64': '2001:db8:a::/64', 'source': 'ra', 'mtu': (1492, 1472, 1432),
           'forwarding': '0', 'wan_mtu': None},
    'prod': {'defaults': 'ispctl defaults', 'config': '/root/config.lab-prod.xml', 'pd': '2001:db8:4800:100::/56',
             'clat64': '2001:db8:4800:1ff::/64', 'wan64': '2001:db8:4800::/64', 'source': 'dns', 'mtu': (1500, 1480, 1440),
             'forwarding': '1', 'wan_mtu': '1508'},
}
PROD_TESTS = ('T00', 'T01', 'T11', 'T12', 'T13', 'T14', 'T15', 'T26', 'T27', 'T28', 'T29')    # adapted to 'prod'
PROFILE = 'p0'
P = PROFILES[PROFILE]
PD_DEFAULT = P['pd']
PROFILE_MARK = '/root/lab-profile'      # on clat-opn: the profile its configuration was last reset to


def use_profile(name):
    global PROFILE, P, PD_DEFAULT
    PROFILE, P = name, PROFILES[name]
    PD_DEFAULT = P['pd']
CLAT_IPV4 = '192.0.0.1'
TAYGA_IPV4 = '192.0.0.2'
LAN_NET = ipaddress.ip_network('192.168.1.0/24')
MGMT_NET = ipaddress.ip_network('10.99.0.0/24')
ROOT = '/root/clat-tests'
INSTALLER = ROOT + '/install-plugin.sh'
SEND_RA = '/usr/local/lib/isp/send-ra-pref64.py'
TOL = 2.0       # seconds of tolerance on criteria read from the one-per-second sampler

SSH = ['ssh', '-i', '/root/.ssh/id_ed25519', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
       '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
       '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3']
OPN_LOGIN = 'root@' + OPN
OPN_PATH = 'PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin; export PATH\n'

CUR = None      # the Test that is running; commands are logged to its folder


class Invalid(Exception):
    """ The lab is not in the state the test needs, or the runner failed: result 'invalid'. """


class Skipped(Exception):
    """ A precondition that is an open point of PLAN section 7 does not hold: result 'skipped'. """


# ---- running commands ---------------------------------------------------------------------------------

class Res:
    def __init__(self, rc, out):
        self.rc = rc
        self.out = out

    @property
    def ok(self):
        return self.rc == 0

    def lines(self):
        return [line for line in self.out.splitlines() if line.strip()]

    def last(self):
        lines = self.lines()
        return lines[-1].strip() if lines else ''


def stamp(moment=None):
    return time.strftime('%H:%M:%S', time.gmtime(moment if moment is not None else time.time()))


def clip(text, limit=60000):
    return text if len(text) <= limit else text[:limit] + '\n[... %d more characters not logged]\n' % (len(text) - limit)


def log(text):
    if CUR is not None:
        CUR.cmdlog.write(text)
        CUR.cmdlog.flush()


def run(argv, stdin_text=None, timeout=60, shown=None, quiet=False):
    started = time.time()
    kwargs = dict(stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, text=True, errors='replace')
    if stdin_text is None:
        kwargs['stdin'] = subprocess.DEVNULL
    else:
        kwargs['input'] = stdin_text
    try:
        proc = subprocess.run(argv, **kwargs)
        rc, out = proc.returncode, proc.stdout or ''
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ''
        if isinstance(out, bytes):
            out = out.decode('utf-8', 'replace')
        rc, out = 124, out + '\n[runner: no end after %d s, killed]\n' % timeout
    except OSError as exc:
        rc, out = 127, '[runner: cannot start %s: %s]\n' % (argv[0], exc)
    if not quiet:
        log('\n### %s  %s\n%s\n[exit %d, %.1f s]\n' % (stamp(started), shown or ' '.join(argv), clip(out).rstrip('\n'),
                                                     rc, time.time() - started))
    return Res(rc, out)


def W(cmd, timeout=60, quiet=False):
    """ A command line on clat-world (bash). """
    return run(['bash', '-c', cmd], timeout=timeout, shown='W: ' + cmd, quiet=quiet)


def C(cmd, timeout=60, quiet=False):
    """ A command line in the IPv4-only client namespace. """
    return run(['bash', '-c', 'ip netns exec client ' + cmd], timeout=timeout, shown='C: ' + cmd, quiet=quiet)


def opn_wrap(script):
    """ root's shell on OPNsense hands a remote command line to csh. The script therefore travels on the
        standard input of /bin/sh; it is stored first and run with stdin closed, so that no command in it
        can swallow the lines that follow it.
    """
    return (OPN_PATH + 'f=$(mktemp /tmp/lab-run.XXXXXX) || exit 97\n'
            "cat > \"$f\" <<'__LAB_SCRIPT_END__'\n" + OPN_PATH + script.strip('\n') + '\n__LAB_SCRIPT_END__\n'
            '/bin/sh "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc\n')


def O(script, timeout=60, quiet=False):
    """ A /bin/sh script on clat-opn. Exit 255 means that ssh itself failed. """
    argv = SSH + [OPN_LOGIN, '/bin/sh', '-s']
    return run(argv, stdin_text=opn_wrap(script), timeout=timeout, shown='O: ' + script.strip('\n'), quiet=quiet)


def port_open(port=22, wait=2):
    return subprocess.run(['nc', '-z', '-w', str(wait), OPN, str(port)], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, check=False).returncode == 0


def wait_port(want_open, timeout):
    """ Probe TCP 22 without logging in (five failed logins lock clat-world out of the box). """
    start = time.time()
    while time.time() - start < timeout:
        if port_open() == want_open:
            return time.time()
        time.sleep(2)
    return None


def wait_login(timeout=900):
    """ Time of the first possible key login; None when there is none within the timeout. """
    start = time.time()
    while time.time() - start < timeout:
        if port_open():
            if O('true', timeout=20, quiet=True).rc == 0:
                return time.time()
            time.sleep(5)
        else:
            time.sleep(2)
    return None


def reboot_opn():
    """ Reboot clat-opn and return (time of the command, time ssh closed, time of the first login). """
    t_cmd = time.time()
    O('configctl -d system reboot', timeout=30)
    t_down = wait_port(False, 240)
    if t_down is None:
        raise Invalid('clat-opn did not go down within 240 s of "configctl -d system reboot"')
    t_login = wait_login(900)
    if t_login is None:
        raise Invalid('clat-opn did not accept a login within 15 minutes of the reboot')
    return t_cmd, t_down, t_login


# ---- web API -----------------------------------------------------------------------------------------

def lab_env(path='/root/lab.env'):
    env = {}
    try:
        with open(path) as handle:
            for line in handle:
                m = re.match(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line.rstrip('\r\n'))
                if m:
                    value = m.group(2).strip()
                    if len(value) >= 2 and value[0] == value[-1] and value[0] in '\'"':
                        value = value[1:-1]
                    env[m.group(1)] = value
    except OSError:
        pass
    return env


def api_creds(env=None):
    env = lab_env() if env is None else env
    key = secret = None
    for name, value in env.items():
        upper = name.upper()
        if 'CRYPT' in upper or 'HASH' in upper:
            continue
        if re.search(r'API_?KEY$', upper):
            key = value
        elif re.search(r'API_?SECRET$', upper):
            secret = value
    if not key or not secret:
        raise Invalid('/root/lab.env has no API key and secret (names ending in API_KEY and API_SECRET)')
    return key, secret


def api(method, path, body=None, timeout=90):
    """ (HTTP code, parsed JSON or text) of a call to the web API of clat-opn; code 0 = no HTTP answer. """
    key, secret = api_creds()
    headers = {'Authorization': 'Basic ' + base64.b64encode(('%s:%s' % (key, secret)).encode()).decode()}
    data = None
    if method == 'POST':
        data = json.dumps({} if body is None else body).encode()
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request('https://%s%s' % (OPN, path), data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    started = time.time()
    try:
        with opener.open(request, timeout=timeout) as response:
            code, text = response.status, response.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as exc:
        code, text = exc.code, exc.read().decode('utf-8', 'replace')
    except Exception as exc:        # no answer at all: recorded, the caller's check fails on code 0
        code, text = 0, 'runner: %s: %s' % (type(exc).__name__, exc)
    log('\n### %s  API %s %s %s\n%s\n[HTTP %d, %.1f s]\n' % (stamp(started), method, path,
                                                           json.dumps(body) if body is not None else '', clip(text), code,
                                                           time.time() - started))
    try:
        return code, json.loads(text)
    except ValueError:
        return code, text


def api_set(model_path, body):
    """ POST a settings/set and say whether the answer is {"result": "saved"}. """
    code, answer = api('POST', model_path, body)
    return code == 200 and isinstance(answer, dict) and answer.get('result') == 'saved', code, answer


def clat_set(fields, reconfigure=True):
    ok, code, answer = api_set('/api/clat/settings/set', {'clat': {'general': fields}})
    if ok and reconfigure:
        code2, answer2 = api('POST', '/api/clat/service/reconfigure')
        ok = code2 == 200
    return ok, code, answer


def unbound_set(section, fields):
    ok, code, answer = api_set('/api/unbound/settings/set', {'unbound': {section: fields}})
    code2, answer2 = api('POST', '/api/unbound/service/reconfigure', timeout=180)
    return ok and code2 == 200, (code, answer, code2, answer2)


CLAT_DEFAULTS = {
    'enabled': '1', 'uplink': '', 'prefix': '', 'discover_dns': '1', 'keep_with_native': '0', 'prefix_id': '',
    'address': '', 'mss_clamp': '1', 'mss_offset': '', 'firewall_rule': '1', 'manual_nat': '0',
    'ipv4_clat': CLAT_IPV4, 'ipv4_tayga': TAYGA_IPV4, 'ipv4_mtu': '1500', 'ipv6_mtu': '', 'udp_cksum': 'calc',
    'test_target': TARGET, 'log_state': '1',
}


# ---- config.xml settings that have no API (PLAN 3.3 "opn-cfg"; UNCONFIRMED until its first use) -------------

PHP_CFG = r'''<?php
require_once 'config.inc';
require_once 'util.inc';
$op = $argv[1];
$path = explode('.', $argv[2]);
$value = $argv[3] ?? '';
$last = array_pop($path);
$ref = &$config;
foreach ($path as $key) {
    if (!isset($ref[$key]) || !is_array($ref[$key])) {
        if ($op != 'set') {
            echo "CFG absent\n";
            exit(0);
        }
        $ref[$key] = [];
    }
    $ref = &$ref[$key];
}
if ($op == 'get') {
    echo 'CFG ', (array_key_exists($last, $ref) ? 'value ' . json_encode($ref[$last]) : 'absent'), "\n";
    exit(0);
}
if ($op == 'set') {
    $ref[$last] = $value;
} else {
    unset($ref[$last]);
}
write_config('lab: ' . $op . ' ' . $argv[2]);
echo "CFG written\n";
'''


def opn_cfg(op, path, value=''):
    """ get | set | unset one node of config.xml on the box, by its dotted path. Returns the 'CFG ...' line. """
    script = ("cat > /tmp/lab-cfg.php <<'__LAB_PHP_END__'\n" + PHP_CFG + "__LAB_PHP_END__\n"
              "/usr/local/bin/php /tmp/lab-cfg.php '%s' '%s' '%s'; rc=$?; rm -f /tmp/lab-cfg.php; exit $rc\n"
              % (op, path, value))
    res = O(script, timeout=60)
    for line in res.out.splitlines():
        if line.startswith('CFG '):
            return line[4:].strip()
    raise Invalid('opn-cfg %s %s failed (PLAN section 7 row 16): %s' % (op, path, res.out.strip()[-300:]))


# ---- the plugin's status ------------------------------------------------------------------------------

def jget(data, path, default=None):
    for key in path.split('.'):
        if not isinstance(data, dict) or key not in data:
            return default
        data = data[key]
    return data


def first_json(text):
    """ The first JSON object in a command's output; {} when there is none. """
    start = text.find('{')
    while start != -1:
        try:
            value, _end = json.JSONDecoder().raw_decode(text[start:])
            if isinstance(value, dict):
                return value
        except ValueError:
            pass
        start = text.find('{', start + 1)
    return {}


def status_json(quiet=True):
    """ What the supervisor last wrote; None while the file does not exist. """
    res = O('cat /var/run/clat/status.json 2>/dev/null', timeout=20, quiet=quiet)
    data = first_json(res.out)
    return data or None


def st(t, label):
    """ 'configctl clat details', once per step: runs facts.php twice, pkg and pfctl on the box. """
    res = O('configctl clat details', timeout=90)
    t.save('st-%s.json' % label, res.out)
    return first_json(res.out)


def sdesc(status):
    if not status:
        return 'no status file'
    pref = status.get('pref64') or {}
    return 'state %s%s, pref64 %s%s' % (
        status.get('state'), ' (%s)' % status['reason'] if status.get('reason') else '',
        pref.get('prefix'), ' by %s' % pref['source'] if pref.get('source') else '')


def state_is(state, reason=None, source=None):
    def pred(status):
        if not status or status.get('state') != state:
            return False
        if reason is not None and status.get('reason') != reason:
            return False
        if source is not None and jget(status, 'pref64.source') != source:
            return False
        return True
    return pred


def wait_status(pred, timeout, interval=1.0):
    """ Poll status.json until pred(status) holds: (reached, seconds, last status). """
    start = time.time()
    while True:
        last = status_json()
        try:
            hit = bool(pred(last))
        except Exception:
            hit = False
        elapsed = time.time() - start
        if hit or elapsed >= timeout:
            return hit, elapsed, last
        time.sleep(interval)


def wait_active(timeout=120):
    return wait_status(state_is('active'), timeout)


# ---- facts of the box ---------------------------------------------------------------------------------

def o_int(script, default=-1):
    res = O(script, quiet=True)
    m = re.search(r'-?\d+', res.last())
    return int(m.group(0)) if m else default


def o_default4():
    """ [(gateway, device)] of the IPv4 default routes. """
    res = O("netstat -rn -f inet | awk '$1==\"default\"{print $2, $4}'")
    return [tuple(line.split()[:2]) for line in res.lines() if len(line.split()) >= 2]


def o_default6():
    res = O("netstat -rn -f inet6 | awk '$1==\"default\"{print $2, $4}'")
    return [tuple(line.split()[:2]) for line in res.lines() if len(line.split()) >= 2]


def is_ipv4(text):
    try:
        ipaddress.IPv4Address(text)
        return True
    except ValueError:
        return False


def parse_gateways(status_text, list_text):
    """ IPv4 gateways core knows: [(name, address)]; None when neither output can be read.
        status: {"NAME": {"name": .., "address": ..}} of 'configctl interface gateways status';
        list:   {"NAME": "NAME - <address or inet|inet6>"} of core's scripts/routes/gateways.php (what
                'configctl interface gateways list' runs, without configd's 20 s cache).
        The list always holds core's two built-in loopback gateways for null routes ("Null4 - 127.0.0.1",
        "Null6 - ::1"); a gateway on a loopback address is left out.
    """
    found, readable = {}, False
    for text, kind in ((status_text, 'status'), (list_text, 'list')):
        try:
            data = json.loads(text.strip() or 'null')
        except ValueError:
            continue
        if isinstance(data, dict):
            items = list(data.items())
        elif isinstance(data, list):
            items = [(item.get('name', '?'), item) for item in data if isinstance(item, dict)]
        else:
            continue
        readable = True
        for name, item in items:
            if kind == 'status' and isinstance(item, dict):
                address = str(item.get('address', ''))
                if is_ipv4(address):
                    found[name] = address
            elif kind == 'list' and isinstance(item, str):
                tail = item.split(' - ')[-1].strip()
                if is_ipv4(tail) and ipaddress.IPv4Address(tail).is_loopback:
                    continue
                if is_ipv4(tail) or tail == 'inet':
                    found.setdefault(name, tail)
    return sorted(found.items()) if readable else None


def o_ipv4_gateways():
    # the list comes from core's script itself: the configd action "interface gateways list" answers from a
    # cache for 20 s (cache_ttl in actions_interface.conf), and core's own pages fill that cache, so it named
    # CLAT_GW for up to 20 s after the gateway was gone (seen 2026-10-12 in T09)
    res = O('configctl interface gateways status; echo; echo ---LIST---; /usr/local/opnsense/scripts/routes/gateways.php')
    status_text, _sep, list_text = res.out.partition('---LIST---')
    return parse_gateways(status_text, list_text)


def o_tayga_pids():
    return O('pgrep -x tayga', quiet=True).out.split()


def o_backups():
    return o_int('ls /conf/backup 2>/dev/null | wc -l')


def o_prefix_mtime():
    return o_int('stat -f %m /tmp/pppoe0_prefixv6 2>/dev/null || echo 0', 0)


def o_prefix_file():
    return O('head -n 1 /tmp/pppoe0_prefixv6 2>/dev/null', quiet=True).out.strip()


def same_net(text, network):
    """ True when text (as netstat prints a destination) is the given network. """
    try:
        return ipaddress.ip_network(text.split('%')[0], strict=False) == ipaddress.ip_network(network, strict=False)
    except ValueError:
        return False


def world_session():
    """ (interface, peer link-local) of the PPP session on clat-world; ('', '') without one. """
    iface = W('ispctl iface', quiet=True).out.strip()
    peer = W('. /run/isp/session 2>/dev/null; echo "$PEER_LL"', quiet=True).out.strip() if iface else ''
    peer = peer.split('%')[0]
    try:        # pppd writes the groups zero-padded (fe80::00c1:...); the captures give the short form
        peer = str(ipaddress.IPv6Address(peer))
    except ValueError:
        pass
    return iface, peer


def wait_m5(newer_than=None, timeout=300, prefix=None):
    """ The state of milestone M5: a session on ppp0, the prefix file written (after 'newer_than' when given)
        with the delegated prefix, and an IPv6 default route on pppoe0. Returns (reached, seconds, text).
    """
    prefix = prefix or PD_DEFAULT
    start = time.time()
    text = ''
    while True:
        iface = W('ispctl iface', quiet=True).out.strip()
        res = O("echo PFX=$(head -n 1 /tmp/pppoe0_prefixv6 2>/dev/null) MT=$(stat -f %m /tmp/pppoe0_prefixv6 2>/dev/null || echo 0) "
                "D6=$(netstat -rn -f inet6 | awk '$1==\"default\"{print $4}' | head -n 1)", quiet=True, timeout=20)
        m = re.search(r'PFX=(\S*) MT=(\d+) D6=(\S*)', res.out)
        pfx, mtime, dev6 = (m.group(1), int(m.group(2)), m.group(3)) if m else ('', 0, '')
        text = 'session %s, prefix file %s (mtime %d), IPv6 default on %s' % (iface or 'none', pfx or 'none', mtime, dev6 or 'none')
        elapsed = time.time() - start
        if iface == 'ppp0' and pfx == prefix and dev6 == 'pppoe0' and (newer_than is None or mtime > newer_than):
            return True, elapsed, text
        if elapsed >= timeout:
            return False, elapsed, text
        time.sleep(3)


def ps_seconds(text):
    """ CPU time of ps -o time= ('0:01.23', '1:02:03.45') in seconds; None when unreadable. """
    text = text.strip().replace(',', '.')
    if not re.match(r'^[\d:.]+$', text):
        return None
    total = 0.0
    for part in text.split(':'):
        total = total * 60 + float(part or 0)
    return total


def parse_drill(text):
    """ (rcode, [AAAA addresses]) of drill or dig output; rcode 'NOANSWER' when no header was printed. """
    m = re.search(r'(?:rcode|status): (\w+)', text)
    addrs = [a for a in re.findall(r'^[^;\s]\S*\s+\d+\s+IN\s+AAAA\s+(\S+)', text, re.M)]
    return (m.group(1) if m else 'NOANSWER'), addrs


def icmp6_ra_input(text):
    """ The 'router advertisement' counter of the input histogram of 'netstat -s -p icmp6'; None if absent. """
    inside, indent = False, 0
    for line in text.splitlines():
        stripped = line.strip()
        depth = len(line) - len(line.lstrip())
        if stripped.lower().startswith('input histogram'):
            inside, indent = True, depth
            continue
        if inside:
            if depth <= indent:
                inside = False
                continue
            m = re.match(r'router advertisement: (\d+)', stripped)
            if m:
                return int(m.group(1))
    return None


# ---- client-side measurements --------------------------------------------------------------------------

def ping_counts(text):
    """ (transmitted, received) of a ping summary, Linux or FreeBSD wording. """
    m = re.search(r'(\d+) packets transmitted, (\d+) (?:packets )?received', text)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def c_ping(count=3, dst=TARGET, opts='', wait=2):
    res = C('ping -n -c%d -W%d %s %s' % (count, wait, opts, dst), timeout=30 + count * (wait + 1))
    return ping_counts(res.out)[1], res


def frag_error(text):
    """ (sender, mtu) of 'From X icmp_seq=N Frag needed and DF set (mtu = M)'; (None, None) without one. """
    m = re.search(r'From (\S+) icmp_seq=\d+ Frag needed and DF set \(mtu = (\d+)\)', text)
    return (m.group(1), int(m.group(2))) if m else (None, None)


def flush_cache():
    C('ip route flush cache', quiet=True)


def c_download():
    res = C("curl -sS -o /dev/null -m 900 -w '%{http_code} %{size_download}' http://" + TARGET + "/100M.bin", timeout=960)
    return res.last()


def c_iperf(args, timeout=60):
    """ iperf3 from the client with JSON output: the parsed result, {} when unreadable. """
    res = C('iperf3 -c %s -J %s' % (TARGET, args), timeout=timeout)
    return first_json(res.out)


def udp_loss(result):
    """ (lost percent, packets) of an iperf3 UDP result; (None, 0) when the run failed. """
    summary = jget(result, 'end.sum') or {}
    if 'lost_percent' not in summary:
        return None, 0
    return float(summary['lost_percent']), int(summary.get('packets', 0))


def fragment_pair(t):
    """ PLAN section 8 'FRAG_RETURN': a 1260-byte echo comes back whole, a 1261-byte one as two IPv6
        fragments. 'ok' both answered, 'lost' only the second unanswered, 'unknown' the first unanswered.
        'lost' is about ICMP only (seen 2026-10-11): the two fragments reach tun464 and tayga 0.9.6 writes
        nothing back, because no tayga translates a fragmented ICMP message; a UDP reply that the PLAT
        returned as two IPv6 fragments passed. Every check that depends on this value is an echo.
    """
    small, _res = c_ping(3, opts='-s 1232')
    large, _res = c_ping(3, opts='-s 1233')
    value = 'ok' if small and large else ('lost' if small else 'unknown')
    env_set(t.run_dir, 'FRAG_RETURN', value)
    t.info('fragment pair', 'ping -s 1232: %d of 3, -s 1233: %d of 3, FRAG_RETURN=%s' % (small, large, value))
    if value == 'lost':
        t.info('FINDING', 'echo replies above 1260 bytes are lost: the PLAT returns them as IPv6 fragments and tayga does not '
                          'translate fragmented ICMP (echo checks on packet sizes above 1260 bytes need replies '
                          'with DF, "ispctl echodf on", or are blocked)')
    return value


def frag_return(t):
    value = env_get(t.run_dir, 'FRAG_RETURN')
    return value if value else fragment_pair(t)


def echo_df(t):
    """ Where FRAG_RETURN is 'lost', make the test target answer echo with DF set ("ispctl echodf on"): the
        PLAT then returns replies above 1260 bytes whole, and the checks on a reply size and on the plugin's
        DF probe run instead of being reported blocked. "ispctl defaults" of the next soft reset ends it.
    """
    if frag_return(t) != 'lost':
        return
    res = W('ispctl echodf on')
    got, _res = c_ping(3, opts='-s 1233')
    t.echo_df = res.ok and got == 3
    t.info('echo replies of the test target now carry DF (ispctl echodf on), so the size checks run',
           'ping -s 1233: %d of 3%s' % (got, '' if t.echo_df else '; the size checks stay blocked'))


# ---- run-wide notes (env.txt) ---------------------------------------------------------------------------

def env_path(run_dir):
    return os.path.join(run_dir, 'env.txt')


def env_get(run_dir, key):
    try:
        with open(env_path(run_dir)) as handle:
            value = None
            for line in handle:
                if line.startswith(key + '='):
                    value = line[len(key) + 1:].strip()
            return value
    except OSError:
        return None


def env_set(run_dir, key, value):
    with open(env_path(run_dir), 'a') as handle:
        handle.write('%s=%s\n' % (key, str(value).replace('\n', ' ')))


# ---- background helpers: sampler, client ping, packet capture --------------------------------------------

SAMPLER_SH = r'''
end=$(( $(date +%s) + __DURATION__ ))
while [ "$(date +%s)" -lt "$end" ]; do
  t=$(date +%s)
  s=$(cat /var/run/clat/status.json 2>/dev/null)
  case "$s" in "{"*"}") ;; *) s=null ;; esac
  d4=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{printf "%s%s %s", sep, $2, $4; sep=";"}')
  d6=$(netstat -rn -f inet6 2>/dev/null | awk '$1=="default"{printf "%s%s %s", sep, $2, $4; sep=";"}')
  nat=$(pfctl -sn 2>/dev/null | grep -c "^nat on tun464 ")
  tp=$(pgrep -x tayga | tr "\n" " ")
  cp=$(pgrep -f clatd.py | tr "\n" " ")
  if [ -s /tmp/tun464_router ]; then rtr=1; else rtr=0; fi
  pfx=$(stat -f %m /tmp/pppoe0_prefixv6 2>/dev/null || echo 0)
  if ifconfig pppoe0 2>/dev/null | head -n 1 | grep -q "<UP[,>]"; then up=1; else up=0; fi
  if ifconfig tun464 >/dev/null 2>&1; then
    tun=$(ifconfig tun464 | awk '$1=="inet"{print $2; exit}')
    [ -n "$tun" ] || tun=noaddr
  else
    tun=absent
  fi
  printf '{"t":%s,"st":%s,"d4":"%s","d6":"%s","nat":%s,"tayga":"%s","clatd":"%s","rtr":%s,"pfx":%s,"tun":"%s","up":%s}\n' \
    "$t" "$s" "$d4" "$d6" "${nat:-0}" "${tp% }" "${cp% }" "$rtr" "${pfx:-0}" "$tun" "$up"
  sleep __INTERVAL__
done
'''


def clock_offset():
    """ clat-opn's clock minus clat-world's, in seconds (both follow the host; measured, not assumed). """
    before = time.time()
    res = O("/usr/local/bin/python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s", quiet=True)
    after = time.time()
    try:
        return float(res.last()) - (before + after) / 2
    except ValueError:
        return 0.0


class Sampler:
    """ One line per interval from clat-opn (PLAN section 8 'Sampler'): time, status.json ('st', None while
        the file does not exist), IPv4 and IPv6 default routes as "gateway device" ('d4', 'd6'), number of
        NAT lines on tun464, tayga and clatd pids, router file, mtime of the prefix file, tun464 ('absent',
        'noaddr' or its IPv4 address), whether pppoe0 has the flag UP ('up'). 'tl' is the sample time on
        clat-world's clock.
    """

    def __init__(self, t, name, duration, interval=1):
        self.path = t.path('sampler-%s.jsonl' % name)
        self.duration, self.interval = int(duration), interval
        self.proc = self.handle = None
        self.offset = 0.0

    def start(self):
        self.offset = clock_offset()
        script = SAMPLER_SH.replace('__DURATION__', str(self.duration)).replace('__INTERVAL__', str(self.interval))
        self.handle = open(self.path, 'w')
        self.proc = subprocess.Popen(SSH + [OPN_LOGIN, '/bin/sh', '-s'], stdin=subprocess.PIPE, stdout=self.handle,
                                     stderr=subprocess.DEVNULL)
        self.proc.stdin.write(opn_wrap(script).encode())
        self.proc.stdin.close()
        log('\n### %s  sampler started -> %s (clock offset %.2f s)\n' % (stamp(), os.path.basename(self.path), self.offset))
        return self

    def peek(self):
        return parse_samples(self.path, self.offset)

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.handle.close()
            self.proc = None
        samples = parse_samples(self.path, self.offset)
        log('### %s  sampler stopped, %d samples in %s\n' % (stamp(), len(samples), os.path.basename(self.path)))
        return samples


def parse_samples(path, offset=0.0):
    samples = []
    try:
        with open(path) as handle:
            for line in handle:
                try:
                    sample = json.loads(line)
                except ValueError:
                    continue
                if isinstance(sample, dict) and 't' in sample:
                    sample['tl'] = sample['t'] - offset
                    samples.append(sample)
    except OSError:
        pass
    return samples


def s_state(sample):
    return sample['st'].get('state') if isinstance(sample.get('st'), dict) else None


def s_down(sample):
    """ The uplink has no usable IPv6 in this sample: pppoe0 is not up, or there is no IPv6 default route.
        OPNsense keeps the route while the PPP session is gone (first run, PLAN section 7 row 30): mpd5 only
        takes the device down, so the route alone never shows a session loss.
    """
    return not sample.get('d6') or not sample.get('up', 1)


def s_get(sample, path, default=None):
    return jget(sample.get('st'), path, default) if isinstance(sample.get('st'), dict) else default


def s_routes(text):
    """ 'gw dev;gw dev' of a sample -> [(gateway, device)] """
    return [tuple(part.split()) for part in text.split(';') if len(part.split()) == 2]


def s_d4_devs(sample):
    return sorted({dev for _gw, dev in s_routes(sample.get('d4', ''))})


def first_sample(samples, pred, after=None):
    for sample in samples:
        if (after is None or sample['tl'] >= after) and pred(sample):
            return sample
    return None


def collapse(values):
    """ Consecutive duplicates removed. """
    out = []
    for value in values:
        if not out or out[-1] != value:
            out.append(value)
    return out


def collapse_times(values):
    """ As collapse(), and a time within TOL seconds of the one before it is the same time. The plugin writes
        tayga.started as wall-clock seconds, computed from its monotonic clock each time it writes the status
        file. When the system clock is set (ntpd, minutes after a reboot) the number moves with it, without a
        restart of tayga.
    """
    out = []
    for value in values:
        near = bool(out) and isinstance(out[-1], (int, float)) and isinstance(value, (int, float)) and abs(value - out[-1]) <= TOL
        if not out or (out[-1] != value and not near):
            out.append(value)
    return out


def tayga_view(samples):
    pids = collapse([s['tayga'] for s in samples if s.get('tayga')])
    started = collapse_times([s_get(s, 'tayga.started') for s in samples if isinstance(s.get('st'), dict)])
    restarts = sorted({s_get(s, 'tayga.restarts') for s in samples if isinstance(s.get('st'), dict)} - {None})
    without = sum(1 for s in samples if not s.get('tayga'))
    return {'pids': pids, 'started': started, 'restarts': restarts, 'without': without, 'n': len(samples)}


def tayga_text(view):
    return 'tayga pids %s, tayga.started %s, %d of %d samples without tayga, tayga.restarts %s' % (
        view['pids'], view['started'], view['without'], view['n'], view['restarts'])


def tayga_not_restarted(samples):
    """ PLAN section 8: the same pid in every sample of the step and an unchanged tayga.started. """
    view = tayga_view(samples)
    good = (view['n'] > 0 and view['without'] == 0 and len(view['pids']) == 1 and len(view['started']) == 1
            and view['started'][0] is not None)
    return good, tayga_text(view)


def tayga_restarted_once(samples, uptime, step_seconds):
    """ PLAN section 8: the pid changed exactly once, tayga.started moved once, uptime shorter than the step. """
    view = tayga_view(samples)
    moved = collapse([value for value in view['started'] if value is not None])
    good = (len(view['pids']) == 2 and len(moved) == 2 and isinstance(uptime, (int, float)) and uptime < step_seconds)
    return good, '%s, st.tayga.uptime %s s, step %.0f s' % (tayga_text(view), uptime, step_seconds)


class PingLog:
    """ 'ping -D -i 0.5' from the client namespace to the test target; replies carry clat-world's time. """

    def __init__(self, t, name, interval='0.5'):
        self.path = t.path('ping-%s.log' % name)
        self.interval = interval
        self.proc = self.handle = None
        self.replies = []

    def start(self):
        self.handle = open(self.path, 'w')
        self.proc = subprocess.Popen(['ip', 'netns', 'exec', 'client', 'ping', '-D', '-n', '-i', self.interval, TARGET],
                                     stdin=subprocess.DEVNULL, stdout=self.handle, stderr=subprocess.STDOUT)
        log('\n### %s  client ping started -> %s\n' % (stamp(), os.path.basename(self.path)))
        return self

    def read(self):
        self.replies = parse_ping_log(self.path)
        return self.replies

    def stop(self):
        if self.proc is not None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.handle.close()
            self.proc = None
        return self.read()

    def first_after(self, moment):
        for stamp_ in self.replies:
            if stamp_ >= moment:
                return stamp_
        return None

    def count_between(self, start, end):
        return sum(1 for stamp_ in self.replies if start <= stamp_ <= end)


def parse_ping_log(path):
    replies = []
    try:
        with open(path, errors='replace') as handle:
            for line in handle:
                m = re.match(r'\[(\d+\.\d+)\] \d+ bytes from ', line)
                if m:
                    replies.append(float(m.group(1)))
    except OSError:
        pass
    return replies


class Capture:
    """ tcpdump on clat-world (or in the client namespace) into a pcap file, read back by this script.
        Not promiscuous (-p): radvd answers every change of the promiscuous flag of ppp0 with a new burst of
        unsolicited advertisements (seen 2026-10-11: one at the start and one at the end of a capture, then
        two more 16 s apart), which would hand the box a PREF64 the test did not send.
    """

    def __init__(self, t, name, iface, bpf, netns=False):
        self.t, self.name, self.iface, self.bpf, self.netns = t, name, iface, bpf, netns
        self.path = t.path('%s.pcap' % name)
        self.proc = None

    def start(self):
        argv = (['ip', 'netns', 'exec', 'client'] if self.netns else []) + [
            'tcpdump', '-Z', 'root', '-p', '-n', '-U', '-i', self.iface, '-w', self.path, self.bpf]
        self.err = open(self.path + '.err', 'w')
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=self.err, stderr=subprocess.STDOUT)
        time.sleep(1.5)
        if self.proc.poll() is not None:
            self.err.close()
            with open(self.path + '.err') as handle:
                raise Invalid('tcpdump on %s did not start: %s' % (self.iface, handle.read().strip()[-200:]))
        log('\n### %s  capture started on %s%s: %s -> %s\n' % (stamp(), self.iface, ' (client)' if self.netns else '',
                                                           self.bpf, os.path.basename(self.path)))
        return self

    def peek(self):
        return read_pcap(self.path)

    def stop(self, settle=1.0):
        if self.proc is not None:
            time.sleep(settle)
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.err.close()
            self.proc = None
            summary = run(['tcpdump', '-Z', 'root', '-nn', '-tt', '-v', '-r', self.path], timeout=60, quiet=True)
            self.t.save('%s.pcap.txt' % self.name, '\n'.join(summary.out.splitlines()[:400]) + '\n')
        return read_pcap(self.path)


# ---- reading captures (classic pcap) ---------------------------------------------------------------------

def read_pcap(path):
    """ [(time, link type, frame bytes)] of a classic pcap file; a cut-off last record is ignored. """
    packets = []
    try:
        with open(path, 'rb') as handle:
            data = handle.read()
    except OSError:
        return packets
    if len(data) < 24:
        return packets
    magic = data[:4]
    if magic == b'\xd4\xc3\xb2\xa1':
        order, frac = '<', 1e6
    elif magic == b'\xa1\xb2\xc3\xd4':
        order, frac = '>', 1e6
    elif magic == b'\x4d\x3c\xb2\xa1':
        order, frac = '<', 1e9
    elif magic == b'\xa1\xb2\x3c\x4d':
        order, frac = '>', 1e9
    else:
        raise Invalid('%s is not a classic pcap file' % path)
    linktype = struct.unpack(order + 'I', data[20:24])[0] & 0x0fffffff
    pos = 24
    while pos + 16 <= len(data):
        sec, sub, incl, _orig = struct.unpack(order + 'IIII', data[pos:pos + 16])
        pos += 16
        if pos + incl > len(data):
            break
        packets.append((sec + sub / frac, linktype, data[pos:pos + incl]))
        pos += incl
    return packets


def l3(linktype, frame):
    """ (ethertype, payload) of a captured frame; (None, b'') for a link type or frame this does not know. """
    if linktype == 1 and len(frame) >= 14:                      # Ethernet
        ethertype, off = int.from_bytes(frame[12:14], 'big'), 14
        while ethertype in (0x8100, 0x88a8) and len(frame) >= off + 4:
            ethertype, off = int.from_bytes(frame[off + 2:off + 4], 'big'), off + 4
        return ethertype, frame[off:]
    if linktype == 113 and len(frame) >= 16:                    # Linux cooked v1 (ppp0)
        return int.from_bytes(frame[14:16], 'big'), frame[16:]
    if linktype == 276 and len(frame) >= 20:                    # Linux cooked v2
        return int.from_bytes(frame[0:2], 'big'), frame[20:]
    if linktype == 9 and len(frame) >= 4:                       # PPP
        body = frame[2:] if frame[:2] == b'\xff\x03' else frame
        proto, body = int.from_bytes(body[:2], 'big'), body[2:]
        return {0x0021: 0x0800, 0x0057: 0x86dd}.get(proto), body
    if linktype in (0, 108) and len(frame) >= 5:                # BSD loopback
        frame = frame[4:]
        linktype = 101
    if linktype in (12, 14, 101, 228, 229) and frame:           # raw IP
        return {4: 0x0800, 6: 0x86dd}.get(frame[0] >> 4), frame
    return None, b''


def parse_ip(ethertype, payload):
    """ The IP header of a packet as a dict, 'l4' being the transport header and data; None if it is not IP. """
    if ethertype == 0x0800 and len(payload) >= 20 and payload[0] >> 4 == 4:
        ihl = (payload[0] & 15) * 4
        flags = int.from_bytes(payload[6:8], 'big')
        return {'v': 4, 'src': str(ipaddress.IPv4Address(payload[12:16])), 'dst': str(ipaddress.IPv4Address(payload[16:20])),
                'proto': payload[9], 'len': int.from_bytes(payload[2:4], 'big'), 'df': bool(flags & 0x4000),
                'frag': bool(flags & 0x3fff), 'first': not flags & 0x1fff, 'l4': payload[ihl:]}
    if ethertype == 0x86dd and len(payload) >= 40 and payload[0] >> 4 == 6:
        nxt, off, frag, first = payload[6], 40, False, True
        while nxt in (0, 43, 44, 60) and len(payload) >= off + 8:
            if nxt == 44:
                frag = True
                first = not int.from_bytes(payload[off + 2:off + 4], 'big') & 0xfff8
                nxt, off = payload[off], off + 8
            else:
                nxt, off = payload[off], off + (payload[off + 1] + 1) * 8
        return {'v': 6, 'src': str(ipaddress.IPv6Address(payload[8:24])), 'dst': str(ipaddress.IPv6Address(payload[24:40])),
                'proto': nxt, 'len': int.from_bytes(payload[4:6], 'big') + 40, 'hlim': payload[7], 'frag': frag,
                'first': first, 'l4': payload[off:]}
    return None


def ip_packets(packets):
    """ [(time, parsed IP header)] of the IP packets in a capture. """
    out = []
    for moment, linktype, frame in packets:
        parsed = parse_ip(*l3(linktype, frame))
        if parsed:
            out.append((moment, parsed))
    return out


def tcp_info(l4):
    """ Ports, SYN and ACK flags and the MSS option of a TCP header; None when it is too short. """
    if len(l4) < 20:
        return None
    sport, dport = struct.unpack('!HH', l4[:4])
    header, flags = (l4[12] >> 4) * 4, l4[13]
    mss, pos = None, 20
    while pos < min(header, len(l4)):
        kind = l4[pos]
        if kind == 0:
            break
        if kind == 1:
            pos += 1
            continue
        if pos + 1 >= len(l4) or l4[pos + 1] < 2:
            break
        if kind == 2 and l4[pos + 1] == 4:
            mss = int.from_bytes(l4[pos + 2:pos + 4], 'big')
        pos += l4[pos + 1]
    return {'sport': sport, 'dport': dport, 'syn': bool(flags & 2), 'ack': bool(flags & 16), 'mss': mss}


def syn_mss(packets, version, synack=False, src=None, dst=None):
    """ MSS values of the SYN (or SYN-ACK) segments of a capture, filtered by address. """
    values = []
    for _moment, ip in ip_packets(packets):
        if ip['v'] != version or ip['proto'] != 6 or not ip['first']:
            continue
        tcp = tcp_info(ip['l4'])
        if not tcp or not tcp['syn'] or tcp['ack'] != synack:
            continue
        if src is not None and not src(ip['src']):
            continue
        if dst is not None and ip['dst'] != dst:
            continue
        values.append(tcp['mss'])
    return values


PLC_LENGTH = {0: 96, 1: 64, 2: 56, 3: 48, 4: 40, 5: 32}


def nd_router(ip):
    """ A Router Solicitation (133) or Advertisement (134): type, options and the PREF64 options
        (RFC 8781, option 38) as [(lifetime in seconds, 'prefix/length')]. None for any other packet.
    """
    if not ip or ip['v'] != 6 or ip['proto'] != 58 or len(ip['l4']) < 8 or ip['l4'][0] not in (133, 134):
        return None
    l4 = ip['l4']
    pos = 8 if l4[0] == 133 else 16
    options, pref64 = [], []
    while pos + 2 <= len(l4):
        length = l4[pos + 1] * 8
        if length == 0 or pos + length > len(l4):
            break
        body = l4[pos + 2:pos + length]
        options.append(l4[pos])
        if l4[pos] == 38 and len(body) >= 14:
            word = int.from_bytes(body[0:2], 'big')
            prefix = ipaddress.IPv6Address(body[2:14] + b'\0\0\0\0')
            pref64.append(((word >> 3) * 8, '%s/%s' % (prefix, PLC_LENGTH.get(word & 7, '?'))))
        pos += length
    return {'type': l4[0], 'options': options, 'pref64': pref64, 'src': ip['src'], 'dst': ip['dst'], 'hlim': ip.get('hlim')}


def router_messages(packets):
    """ [(time, nd_router dict)] of the RS and RA messages in a capture. """
    out = []
    for moment, ip in ip_packets(packets):
        message = nd_router(ip)
        if message:
            out.append((moment, message))
    return out


PPPOE_CODES = {0x09: 'PADI', 0x07: 'PADO', 0x19: 'PADR', 0x65: 'PADS', 0xa7: 'PADT'}


def pppoe_discovery(packets):
    """ [(time, code name, PPP-Max-Payload value or None, source MAC)] of the PPPoE discovery frames. """
    out = []
    for moment, linktype, frame in packets:
        ethertype, body = l3(linktype, frame)
        if ethertype != 0x8863 or len(body) < 6:
            continue
        end = min(len(body), 6 + int.from_bytes(body[4:6], 'big'))
        pos, payload = 6, None
        while pos + 4 <= end:
            tag, length = int.from_bytes(body[pos:pos + 2], 'big'), int.from_bytes(body[pos + 2:pos + 4], 'big')
            if tag == 0x0120 and length >= 2:
                payload = int.from_bytes(body[pos + 4:pos + 6], 'big')
            pos += 4 + length
        mac = ':'.join('%02x' % byte for byte in frame[6:12]) if linktype == 1 else ''
        out.append((moment, PPPOE_CODES.get(body[1], hex(body[1])), payload, mac))
    return out


def discovery_text(frames):
    return ', '.join('%s %s' % (code, 'max-payload %d' % payload if payload is not None else 'no tag')
                     for _moment, code, payload, _mac in frames) or 'no discovery frame captured'


def last_exchange(frames):
    """ The last PADI, PADO, PADR and PADS of a capture: {code: PPP-Max-Payload or None}; absent codes missing. """
    out = {}
    for _moment, code, payload, _mac in frames:
        out[code] = payload
    return out


# ---- pf listings -------------------------------------------------------------------------------------

def parse_states(text):
    """ 'pfctl -ss -vv' -> [{'if', 'line', 'detail', 'origif'}]: a state is a line that starts in column 0,
        its detail lines are indented. Floating states are listed under 'all'; -vv adds 'origif:'.
    """
    states = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0] in ' \t':
            if states:
                states[-1]['detail'] += line.strip() + ' '
            continue
        if line.startswith('No ALTQ') or line.startswith('ALTQ'):
            continue
        states.append({'if': line.split()[0], 'line': line.strip(), 'detail': ''})
    for state in states:
        m = re.search(r'origif: (\S+)', state['detail'])
        state['origif'] = m.group(1) if m else None
    return states


def state_iface(state):
    """ The interface of a state: its first column, or 'origif' when the state floats. """
    return state['if'] if state['if'] != 'all' else (state['origif'] or 'all')


def line_ipv6(line):
    out = set()
    for token in re.findall(r'[0-9a-fA-F:]{3,39}', line):
        if token.count(':') >= 2:
            try:
                out.add(ipaddress.IPv6Address(token))
            except ValueError:
                pass
    return out


def clat_states(states, clat6):
    """ The three kinds of states a client flow to the test target makes (PLAN T02 criterion 5), and the
        untranslated ones that must not exist.
    """
    target6, clat6 = ipaddress.IPv6Address(TARGET6), ipaddress.IPv6Address(clat6) if clat6 else None
    nat44 = re.compile(r'%s:\d+ \(192\.168\.1\.\d+:\d+\) -> %s:\d+' % (re.escape(CLAT_IPV4), re.escape(TARGET)))
    plain = re.compile(r'^\S+ \S+ (192\.168\.1\.\d+)(?::\d+)? -> (\d+\.\d+\.\d+\.\d+)')
    found = {'nat44': [], 'v6': [], 'untranslated': []}
    for state in states:
        if nat44.search(state['line']):
            found['nat44'].append(state)
            continue
        addrs = line_ipv6(state['line'])
        if clat6 is not None and clat6 in addrs and target6 in addrs:
            found['v6'].append(state)
            continue
        m = plain.match(state['line'])
        if m:
            iface, dst = state_iface(state), ipaddress.ip_address(m.group(2))
            if iface == 'tun464' or (iface == 'all' and dst not in LAN_NET and dst not in MGMT_NET):
                found['untranslated'].append(state)
    return found


def rule_labels(rules_debug):
    """ {description: label} of the rules in /tmp/rules.debug that end in: label "<id>" # <description> """
    out = {}
    for line in rules_debug.splitlines():
        m = re.search(r'label "([^"]+)"\s+# (.*)$', line)
        if m and not line.lstrip().startswith('#'):
            out.setdefault(m.group(2).strip(), m.group(1))
    return out


CLAT_RULE = re.compile(r'^pass in (log )?quick on tun464 inet6 .*keep state.* label "')
CLAT_RULE_DESCR = 'CLAT: translated IPv6 from tayga'
USER_RULES = ('Default allow LAN to any rule', 'Default allow LAN IPv6 to any rule', 'lab: MGMT to this firewall')


def scrub_mss(rules_text, family='inet6'):
    """ max-mss values of the normalisation rules on tun464 for one family (old 'scrub on' and new
        'match on ... scrub (max-mss N)' wording).
    """
    values = []
    for line in rules_text.splitlines():
        if ' on tun464 %s ' % family in line + ' ' and 'scrub' in line:
            m = re.search(r'max-mss (\d+)', line)
            if m:
                values.append(int(m.group(1)))
    return values


# ---- one test ----------------------------------------------------------------------------------------

class Test:
    def __init__(self, tid, run_dir):
        self.id, self.run_dir = tid, run_dir
        self.dir = os.path.join(run_dir, tid)
        os.makedirs(self.dir, exist_ok=True)
        self.cmdlog = open(os.path.join(self.dir, 'commands.log'), 'a')
        self.checks = open(os.path.join(self.dir, 'checks.txt'), 'a')
        self.rows = []
        self.forced = None
        self.echo_df = False        # echo_df() made replies above 1260 bytes return whole
        self.started = time.time()

    def path(self, name):
        return os.path.join(self.dir, name)

    def save(self, name, text):
        with open(self.path(name), 'w') as handle:
            handle.write(text)
        return self.path(name)

    def _row(self, kind, cid, text, observed):
        observed = observed if isinstance(observed, str) else repr(observed)
        line = '%-7s %-9s %s%s' % (kind, cid, text, ' :: ' + observed if observed != '' else '')
        print(line, flush=True)
        self.checks.write(line + '\n')
        self.checks.flush()
        log('\n>>> %s\n' % line)
        self.rows.append((kind, cid, observed))

    def check(self, cid, ok, text, observed=''):
        self._row('PASS' if ok else 'FAIL', '%s.%s' % (self.id, cid), text, observed)
        return bool(ok)

    def info(self, text, observed=''):
        self._row('INFO', self.id, text, observed)

    def skip(self, cid, text, reason):
        self._row('SKIP', '%s.%s' % (self.id, cid), text, reason)

    def blocked(self, cid, text, reason, observed=''):
        self._row('BLOCKED', '%s.%s' % (self.id, cid), text, 'blocked by %s; observed: %s' % (reason, observed))

    def frag_check(self, cid, ok, text, observed=''):
        """ A criterion on a reply above 1260 bytes: 'blocked by FRAG_RETURN' instead of 'fail' when the
            lab's PLAT loses returned IPv6 fragments (PLAN section 8) and echo_df() has not ended that.
        """
        if ok or self.echo_df or frag_return(self) != 'lost':
            return self.check(cid, ok, text, observed)
        self.blocked(cid, text, 'FRAG_RETURN', observed)
        return False

    def outcome(self):
        """ (status for summary.tsv, note) """
        failed = [cid for kind, cid, _seen in self.rows if kind == 'FAIL']
        blocked = [cid for kind, cid, _seen in self.rows if kind == 'BLOCKED']
        skipped = [(cid, reason) for kind, cid, reason in self.rows if kind == 'SKIP']
        passed = [cid for kind, cid, _seen in self.rows if kind == 'PASS']
        if self.forced:
            return self.forced
        if failed:
            return 'fail', '%d of %d checks failed: %s' % (len(failed), len(failed) + len(passed), ' '.join(failed))
        if blocked:
            return 'blocked (FRAG_RETURN)', '%d checks passed; blocked: %s' % (len(passed), ' '.join(blocked))
        if passed:
            note = '%d checks passed' % len(passed)
            if skipped:
                note += '; skipped: ' + ' '.join(cid for cid, _text in skipped)
            return 'pass', note
        if skipped:
            return 'skipped (%s)' % skipped[0][1], 'no check ran'
        return 'invalid', 'the test made no check'


# ---- guard T00, resets --------------------------------------------------------------------------------

def guard(t, when):
    """ PLAN section 8, guard T00. Returns the list of violations; any makes the test 'invalid'. """
    problems = []
    res = O('echo VERSION=$(opnsense-version 2>&1)\n'
            'echo UNAME=$(uname -v)\n'
            'echo SIGNALS=$(dmesg | grep -c "exited on signal")\n'
            'opnsense-update -T -k >/dev/null 2>&1; echo KLOCK=$?\n'
            'echo POLICY=$(cat /root/lab-kernel.policy 2>/dev/null)\n'
            'echo TAYGA=$(pkg query %v tayga 2>/dev/null)\n'
            'echo "D4=$(netstat -rn -f inet | awk \'$1=="default"{printf "%s/%s ", $2, $4}\')"\n', timeout=60)
    if res.rc == 255 or 'VERSION=' not in res.out:
        return ['clat-opn does not answer over ssh from clat-world']
    facts = dict(re.findall(r'^([A-Z0-9]+)=(.*)$', res.out, re.M))
    if when == 'before' and not env_get(t.run_dir, 'OPNSENSE_VERSION'):
        env_set(t.run_dir, 'OPNSENSE_VERSION', facts.get('VERSION', ''))
        env_set(t.run_dir, 'OPNSENSE_UNAME', facts.get('UNAME', ''))
        env_set(t.run_dir, 'OPNSENSE_TAYGA', facts.get('TAYGA', ''))
        env_set(t.run_dir, 'KERNEL_POLICY', facts.get('POLICY', '') or 'none recorded')
        env_set(t.run_dir, 'WORLD_KERNEL', W('uname -r', quiet=True).out.strip())
    if facts.get('SIGNALS', '').strip() != '0':
        problems.append('dmesg has %s "exited on signal" lines (wrong kernel on Hyper-V? PLAN decision 18)' % facts.get('SIGNALS'))
    for route in facts.get('D4', '').split():
        if not route.endswith('/tun464'):
            problems.append('IPv4 default route %s is not through tun464' % route)
    gateways = o_ipv4_gateways()
    if gateways is None:
        problems.append('the gateway list of core cannot be read')
    else:
        for name, address in gateways:
            if name != 'CLAT_GW' and address != TAYGA_IPV4:
                problems.append('IPv4 gateway %s (%s) exists besides CLAT_GW' % (name, address))
    policy = facts.get('POLICY', '').split()
    if not policy or policy[0] == 'hold':
        if facts.get('KLOCK', '').strip() != '1':
            problems.append('the kernel set is not locked (opnsense-update -T -k exits %s)' % facts.get('KLOCK'))
        if 'n284150-0a7d52ef8757' in facts.get('UNAME', ''):
            problems.append('the 26.7.6 kernel is running')
    provision = W('nft list set inet isp provision4', quiet=True)
    if not provision.ok or re.search(r'elements\s*=', provision.out):
        problems.append('the provisioning NAT set on clat-world is not empty or cannot be read')
    iface = W('ispctl iface', quiet=True).out.strip()
    if iface not in ('ppp0', ''):
        problems.append('the PPP session is on %s, not ppp0 (PLAN section 7 row 23)' % iface)
    log('\n>>> guard %s: %s\n' % (when, '; '.join(problems) or 'ok'))
    t.info('guard T00 %s' % when, '; '.join(problems) if problems else
           'ok (%s; kernel %s)' % (facts.get('VERSION', '?'), facts.get('UNAME', '?')[:60]))
    return problems


def tidy(*steps):
    """ Clean-up at the end of a test: every step runs, also when an earlier one fails; failures are logged. """
    for step in steps:
        try:
            step()
        except Exception:
            log('\n>>> a clean-up step failed:\n%s\n' % traceback.format_exc())


def base_config():
    """ Nodes of config.xml that tests change, with their value in the configuration of the profile. """
    return (
        ('interfaces.wan.ipaddr', None, 'wan'),
        ('interfaces.wan.mtu', P['wan_mtu'], 'wan'),
        ('interfaces.wan.dhcp6-ia-pd-len', '8', 'wan'),
        ('nat.outbound.mode', 'automatic', 'filter'),
        ('system.state-policy', None, 'filter'),
    )


def restore_base_config():
    """ Put back what an earlier test may have left in config.xml; returns the paths that were restored. """
    restored, apply = [], set()
    for path, value, area in base_config():
        current = opn_cfg('get', path)
        wanted = 'absent' if value is None else 'value %s' % json.dumps(value)
        if current != wanted:
            if value is None:
                opn_cfg('unset', path)
            else:
                opn_cfg('set', path, value)
            restored.append('%s (was %s)' % (path, current))
            apply.add(area)
    if 'wan' in apply:
        O('configctl interface reconfigure wan', timeout=180)
    if 'filter' in apply:
        O('configctl filter reload', timeout=120)
    return restored


def no_pref64():
    """ PLAN section 8 'no-PREF64': withdraw (one RA with lifetime 0), wait until the state left 'active',
        then announce no option at all.
    """
    was = (status_json() or {}).get('state')
    W('ispctl pref64 withdraw')
    if was == 'active':
        wait_status(lambda status: status and status.get('state') != 'active', 20)
    else:
        time.sleep(5)
    W('ispctl pref64 off')


def soft_reset(t):
    """ PLAN 3.3 'soft-reset': ISP defaults, plugin and Unbound settings back, a new supervisor, an empty
        route cache on the client, then wait for 'active'.
    """
    if not O('test -x /usr/local/etc/rc.d/clat', quiet=True).ok:
        raise Invalid('the plugin is not installed on clat-opn (run T01, or: bash lab.sh plugin install)')
    mark = O('cat %s 2>/dev/null || echo p0' % PROFILE_MARK, quiet=True).last()
    if mark != PROFILE:
        raise Invalid('clat-opn is configured for profile %s and this run is --profile %s: run T01 of this profile first '
                      '(its reset puts %s back)' % (mark, PROFILE, P['config']))
    restored = restore_base_config()
    if restored:
        t.info('soft reset: config.xml nodes left by an earlier test were put back', restored)
    before = o_prefix_mtime()
    res = W(P['defaults'], timeout=180)
    if not res.ok:
        raise Invalid('soft reset: "%s" failed: %s' % (P['defaults'], res.last()))
    reached, seconds, text = wait_m5(newer_than=before, timeout=300)
    if not reached:
        raise Invalid('soft reset: no new session with prefix %s within %.0f s (%s)' % (PD_DEFAULT, seconds, text))
    ok, code, answer = clat_set(dict(CLAT_DEFAULTS))
    if not ok:
        raise Invalid('soft reset: the plugin settings could not be stored through the API (HTTP %s: %s)' % (code, str(answer)[:200]))
    code, current = api('GET', '/api/unbound/settings/get')
    forwarding = str(jget(current, 'unbound.forwarding.enabled', '0'))
    dns64 = str(jget(current, 'unbound.general.dns64', '0'))
    if code != 200 or forwarding != P['forwarding'] or dns64 != '0':
        api_set('/api/unbound/settings/set', {'unbound': {'forwarding': {'enabled': P['forwarding']}, 'general': {'dns64': '0'}}})
        api('POST', '/api/unbound/service/reconfigure', timeout=180)
    O('configctl clat restart', timeout=120)
    flush_cache()
    reached, seconds, last = wait_active(120)
    if not reached:
        raise Invalid('soft reset: not active within 120 s of "configctl clat restart" (%s)' % sdesc(last))
    log('\n>>> soft reset done in %.0f s, active\n' % (time.time() - t.started))


def guest_reset(t):
    """ PLAN section 10, in-guest reset for a run without Hyper-V rights. Goes beyond what a package
        removal does and is weaker than a checkpoint.
    """
    if wait_login(120) is None:
        raise Invalid('guest reset: clat-opn does not accept a login')
    if not O('test -s %s' % P['config'], quiet=True).ok:
        raise Invalid('guest reset: %s is missing on clat-opn (the base one is saved at milestone M7, the production '
                      'one after the steps of the customer page: lab README section 13)' % P['config'])
    if O('test -s /root/os-clat.files || pkg query %n os-clat >/dev/null 2>&1', quiet=True).ok:
        W('sh %s remove' % INSTALLER, timeout=300)      # the copied files, or the package from the lab repository
    O('rm -rf /usr/local/etc/clat /var/run/clat /var/run/clat.pid /var/log/clat /etc/rc.conf.d/clat /tmp/tun464_router\n'
      'rm -rf /usr/local/etc/pkg/repos/os-clat.conf /usr/local/etc/pkg/fingerprints/os-clat\n'
      'cp %s /conf/config.xml\n'
      'rm -f /tmp/config.cache\n'
      'echo %s > %s\n' % (P['config'], PROFILE, PROFILE_MARK), timeout=60)
    W(P['defaults'], timeout=180)
    reboot_opn()
    log('\n>>> guest reset done\n')


def hard_post(t, install):
    """ After an H reset: wait for the box and for the state of M5, then install the current plugin tree. """
    if wait_login(900) is None:
        raise Invalid('H reset: clat-opn does not accept a login within 15 minutes')
    reached, seconds, text = wait_m5(timeout=420)
    if not reached:
        raise Invalid('H reset: the state of M5 was not reached within %.0f s (%s)' % (seconds, text))
    if O('test -e /usr/local/etc/rc.d/clat || ifconfig tun464 >/dev/null 2>&1', quiet=True).ok:
        raise Invalid('H reset: the plugin is on the box although the base state has none')
    if install:
        res = W('sh %s install' % INSTALLER, timeout=600)
        t.save('install.log', res.out)
        if not res.ok:
            raise Invalid('H reset: install-plugin.sh install failed: %s' % res.last())
        reached, seconds, last = wait_active(120)
        if not reached:
            raise Invalid('H reset: not active within 120 s of the install (%s)' % sdesc(last))


def evidence(t, label):
    """ What every test leaves behind: pf, routes, interfaces, the status file, the plugin's log. """
    res = O('echo "== date"; date -u\n'
            'echo "== status.json"; cat /var/run/clat/status.json 2>/dev/null || echo nofile\n'
            'echo "== netstat -rn -f inet"; netstat -rn -f inet\n'
            'echo "== netstat -rn -f inet6"; netstat -rn -f inet6\n'
            'echo "== ifconfig tun464"; ifconfig tun464 2>&1\n'
            'echo "== ifconfig pppoe0"; ifconfig pppoe0 2>&1\n'
            'echo "== pfctl -sn"; pfctl -sn 2>&1\n'
            'echo "== pfctl -sr"; pfctl -sr 2>&1\n'
            'echo "== pfctl -ss"; pfctl -ss 2>&1 | head -n 200\n'
            'echo "== router file"; cat /tmp/tun464_router 2>&1\n'
            'echo "== processes"; ps -axo pid,user,etime,time,command | grep -E "tayga|clatd|mpd5|dhcp6c" | grep -v grep\n'
            'echo "== tayga.conf"; cat /usr/local/etc/clat/tayga.conf 2>&1\n'
            'echo "== clat log (last 150 lines)"; cat /var/log/clat/clat_*.log 2>/dev/null | tail -n 150\n'
            'echo "== dmesg, exited on signal"; dmesg | grep "exited on signal"\n', timeout=90, quiet=True)
    t.save('evidence-%s-opn.txt' % label, res.out)
    res = W('ispctl status 2>&1; echo "== pppd.log"; tail -n 60 /var/log/isp/pppd.log 2>&1', timeout=60, quiet=True)
    t.save('evidence-%s-world.txt' % label, res.out)


# ---- shared test steps --------------------------------------------------------------------------------

def client_checks(t, prefix):
    """ The client-side datapath checks of T03: 100 MB over TCP, UDP at 5 Mbit/s, ICMP. """
    got = c_download()
    t.check(prefix + 'tcp', got == '200 104857600', 'client: HTTP 200 and 104857600 bytes from the test target', got)
    result = c_iperf('-u -b 5M -t 5')
    loss, packets = udp_loss(result)
    t.check(prefix + 'udp', loss is not None and packets > 0 and loss <= 1.0, 'client: UDP 5 Mbit/s for 5 s, loss at most 1 %',
            'lost %s %% of %d datagrams, datagram size %s%s' % (loss, packets, jget(result, 'start.test_start.blksize'),
                                                              ', error: %s' % result['error'] if result.get('error') else ''))
    got, _res = c_ping(3)
    t.check(prefix + 'icmp', got == 3, 'client: ping to the test target, 3 of 3', '%d of 3' % got)


def read_rules(t, label):
    res = O('echo "@@SR"; pfctl -sr 2>&1; echo "@@SN"; pfctl -sn 2>&1; echo "@@SS"; pfctl -ss -vv 2>&1; '
            'echo "@@DEBUG"; cat /tmp/rules.debug 2>&1', timeout=90, quiet=True)
    parts = re.split(r'^@@(SR|SN|SS|DEBUG)\n', res.out, flags=re.M)
    data = {parts[i]: parts[i + 1] for i in range(1, len(parts) - 1, 2)}
    for key, name in (('SR', 'pfctl-sr'), ('SN', 'pfctl-sn'), ('SS', 'pfctl-ss-vv'), ('DEBUG', 'rules.debug')):
        t.save('%s-%s.txt' % (name, label), data.get(key, ''))
    return data.get('SR', ''), data.get('SN', ''), data.get('SS', ''), data.get('DEBUG', '')


def start_flow():
    """ A rate-limited download from the client, so that states exist while pf is listed. """
    return subprocess.Popen(['ip', 'netns', 'exec', 'client', 'curl', '-s', '--limit-rate', '2M', '-o', '/dev/null',
                             '-m', '120', 'http://%s/100M.bin' % TARGET], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_proc(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


def plugin_test(t, label):
    """ 'configctl clat test': the parsed result and its tests by id. """
    res = O('configctl clat test', timeout=180)
    t.save('clat-test-%s.json' % label, res.out)
    result = first_json(res.out)
    return result, {item.get('id'): item for item in result.get('tests', []) if isinstance(item, dict)}


def syn_capture(t, label):
    """ SYN and SYN-ACK of one small download, on the client's LAN and on the ISP's side of the PPP link. """
    flush_cache()
    lan = Capture(t, 'syn-lan-%s' % label, 'lan0', 'tcp[tcpflags] & tcp-syn != 0 and host %s' % TARGET, netns=True).start()
    ppp = Capture(t, 'syn-ppp-%s' % label, 'ppp0', 'ip6 and tcp and host %s' % TARGET6).start()
    C('curl -sS -o /dev/null -m 20 http://%s/' % TARGET, timeout=40)
    lan_packets, ppp_packets = lan.stop(), ppp.stop()
    return (syn_mss(lan_packets, 4, src=lambda a: a.startswith('192.168.1.')),
            syn_mss(ppp_packets, 6, dst=TARGET6),
            syn_mss(lan_packets, 4, synack=True, src=lambda a: a == TARGET))


def wait_session(prefix=None, newer_than=None, timeout=300):
    """ A PPP session on ppp0 and a rewritten prefix file; for tests that change the delegated prefix. """
    start = time.time()
    while time.time() - start < timeout:
        iface = W('ispctl iface', quiet=True).out.strip()
        mtime, content = o_prefix_mtime(), o_prefix_file()
        if iface == 'ppp0' and (newer_than is None or mtime > newer_than) and (prefix is None or content == prefix):
            return True, time.time() - start, content
        time.sleep(3)
    return False, time.time() - start, o_prefix_file()


def link_local_of_opn():
    res = O("ifconfig pppoe0 2>/dev/null | awk '$1==\"inet6\" && $2 ~ /^fe80/ {sub(/%.*/, \"\", $2); print $2; exit}'", quiet=True)
    return res.last()


def analyse_reconnect(samples, t_action):
    """ Times of a session loss and recovery, read from the sampler: when the prefix file was rewritten,
        the first 'active' sample after that, the longest time the uplink was down (s_down).
    """
    out = {'t_pfx': None, 's_active': None, 'gap6': 0.0, 't_lost6': None}
    if not samples:
        return out
    base = samples[0]['pfx']
    rewritten = first_sample(samples, lambda s: s['pfx'] != base and s['pfx'] != 0, after=t_action)
    if rewritten:
        out['t_pfx'] = rewritten['tl']
        out['s_active'] = first_sample(samples, lambda s: s_state(s) == 'active', after=rewritten['tl'])
    run_start = None
    for sample in samples:
        if sample['tl'] < t_action:
            continue
        if s_down(sample):
            if run_start is None:
                run_start = sample['tl']
                if out['t_lost6'] is None:
                    out['t_lost6'] = sample['tl']
            out['gap6'] = max(out['gap6'], sample['tl'] - run_start)
        else:
            run_start = None
    return out


def untranslated_after(t, label, cid):
    _sr, _sn, ss, _debug = read_rules(t, label)
    clat6 = jget(status_json(), 'plan.clat6')
    found = clat_states(parse_states(ss), clat6)
    t.check(cid, not found['untranslated'], 'afterwards no untranslated 192.168.1.x state on tun464',
            '; '.join(s['line'] for s in found['untranslated'][:3]) or 'none')


# ======================================================================================================
# The tests of PLAN.md section 8, one function per id.
# ======================================================================================================

def T00(t):
    """ none. The guard alone, on the lab as it is. """
    # main() ran the guard before this body and runs it again after it; a violation makes the result 'invalid'
    t.check('guard', True, 'the guard found no violation before the test body')


def T01(t):
    """ H (no plugin). Install on a clean box; activation by PREF64 only (production profile: by DNS only). """
    if O('test -e /usr/local/etc/rc.d/clat || ifconfig tun464 >/dev/null 2>&1', quiet=True).ok:
        raise Invalid('the plugin is already on the box; T01 needs the H reset')
    if P['source'] == 'ra':
        W('ispctl dns64 off')
    php_before = o_int('wc -l < /var/lib/php/tmp/PHP_errors.log 2>/dev/null || echo 0', 0)
    capture = Capture(t, 'ra', 'ppp0', 'icmp6 and (ip6[40] == 133 or ip6[40] == 134)').start()
    sampler = Sampler(t, 'install', 600).start()
    t_start = time.time()
    res = W('sh %s install' % INSTALLER, timeout=600)
    t_installed = time.time()
    t.save('install.log', res.out)
    backups_installed = o_backups()
    reached, seconds, last = wait_active(60)
    if not reached:
        wait_active(120)        # for the record; criterion 2 has failed already
    time.sleep(60)
    backups_later = o_backups()
    details = st(t, 'active')
    # one -o per keyword: FreeBSD's ps takes everything after "=" as the header, commas included
    processes = O('ps -ax -o user= -o pid= -o comm= | awk \'$3=="tayga"\'').lines()
    php = O('tail -n +%d /var/lib/php/tmp/PHP_errors.log 2>/dev/null | grep -i clat' % (php_before + 1)).lines()
    packets = capture.stop()
    samples = sampler.stop()

    lines = {tpl: [line for line in res.out.splitlines() if line.startswith('Reloading template %s:' % tpl)]
             for tpl in ('OPNsense/Clat', 'OPNsense/Syslog')}
    both = all(found and found[-1].strip().endswith(': OK') for found in lines.values())
    t.check('1', res.ok and both and not php, 'both template lines end in OK, install exits 0, no PHP error names clat',
            'exit %d; %s; PHP errors: %s' % (res.rc, '; '.join(found[-1] if found else 'line missing' for found in lines.values()),
                                           php[:2] or 'none'))
    t.check('2', reached, 'state active within 60 s of the end of the install, no setting changed',
            '%.0f s, %s' % (seconds, sdesc(last)))
    pref = details.get('pref64') or {}
    lifetime = pref.get('lifetime')
    if P['source'] == 'ra':
        t.check('3', pref.get('prefix') == WKP and pref.get('source') == 'ra' and isinstance(lifetime, int) and 1 <= lifetime <= 1800,
                'st.pref64 is 64:ff9b::/96 by RA with a lifetime of 1 to 1800 s', json.dumps(pref))
    else:
        t.check('3', pref.get('prefix') == WKP and pref.get('source') == 'dns' and lifetime is None,
                'st.pref64 is 64:ff9b::/96 by DNS, without a lifetime', json.dumps(pref))
        active = first_sample(samples, lambda s: s_state(s) == 'active')
        t.info('time from the start of the install to active (a configured box: DNS servers set, Unbound forwarding)',
               '%.0f s; the install itself took %.0f s' % (active['tl'] - t_start, t_installed - t_start) if active else 'never active')
    clat6 = jget(details, 'address.clat6', '')
    try:
        placed = ipaddress.IPv6Address(clat6) in ipaddress.ip_network(P['clat64']) and int(ipaddress.IPv6Address(clat6)) % 2 == 0
    except ValueError:
        placed = False
    t.check('4', placed and jget(details, 'gateway.default') is True and details.get('nat_rule') is True,
            'clat6 even and inside %s (the highest /64 of the /56); gateway.default and nat_rule true' % P['clat64'],
            'clat6 %s, gateway %s, nat_rule %s' % (clat6, json.dumps(details.get('gateway')), details.get('nat_rule')))
    peer = world_session()[1] or link_local_of_opn()
    messages = [(moment, m) for moment, m in router_messages(packets) if moment >= t_start]
    solicits = [moment for moment, m in messages if m['type'] == 133]
    answers = [(moment, m) for moment, m in messages
               if m['type'] == 134 and solicits and moment >= solicits[0] and m['dst'] == peer and m['pref64']]
    if P['source'] == 'ra':
        t.check('5', 1 <= len(solicits) <= 3 and bool(answers),
                'capture on ppp0: 1 to 3 RS from OPNsense, then an RA to its link-local address with option 38',
                '%d RS; %d unicast RA to %s with PREF64 %s; all RA destinations: %s' % (
                    len(solicits), len(answers), peer, answers[0][1]['pref64'] if answers else '-',
                    sorted({m['dst'] for _moment, m in messages if m['type'] == 134})))
    else:
        with_option = [m for _moment, m in messages if m['type'] == 134 and m['pref64']]
        t.check('5', 1 <= len(solicits) <= 3 and not with_option,
                'capture on ppp0: 1 to 3 RS from OPNsense, and no RA of this ISP carries option 38',
                '%d RS; %d RA, %d of them with PREF64' % (len(solicits), sum(1 for _moment, m in messages if m['type'] == 134),
                                                       len(with_option)))
    t.check('6', len(processes) == 1 and processes[0].split()[0] == 'nobody', 'one tayga process, user nobody', processes)
    t.check('7', backups_later == backups_installed, 'no file added to /conf/backup after the install finished',
            '%d at the end of the install, %d 60 s after active' % (backups_installed, backups_later))
    crashes = tayga_view(samples)['restarts']
    t.info('sampler', tayga_text(tayga_view(samples)) + '; crash counter %s' % crashes)

    frag = fragment_pair(t)
    t.check('frag', frag != 'unknown', 'fragment pair: a 1260-byte echo is answered through the CLAT', 'FRAG_RETURN=%s' % frag)
    echo_df(t)
    result, _tests = plugin_test(t, 'no-target')
    t.check('8a', result.get('error') == 'No test target is set.', '"configctl clat test" answers "No test target is set."',
            result.get('error') or result.get('text') or 'no JSON')
    ok, code, answer = clat_set({'test_target': TARGET})
    time.sleep(5)
    result, tests = plugin_test(t, 'target')
    t.check('8b', ok and jget(tests, 'plat.ok') is True and jget(tests, 'path.ok') is True,
            'with test_target set through the API the first two tests are ok',
            'API saved %s; %s' % (ok, result.get('text') or result.get('error') or 'no JSON'))
    t.frag_check('8c', jget(tests, 'mtu.ok') is True and jget(tests, 'mtu.size') == P['mtu'][1], 'the size test is ok with %d' % P['mtu'][1],
                 jget(tests, 'mtu.detail') or 'no result')


def T02(t):
    """ S. pf while a client flow runs. """
    clat6 = jget(status_json(), 'plan.clat6')
    flow = start_flow()
    time.sleep(5)
    sr, sn, ss, debug = read_rules(t, 'flow')
    alive = flow.poll() is None
    stop_proc(flow)
    rules = sr.splitlines()
    ours = [line for line in rules if CLAT_RULE.match(line)]
    t.check('1', len(ours) == 1, 'exactly one rule "pass in [log] quick on tun464 inet6 ... keep state label ..."',
            ours or 'none in pfctl -sr')
    on_tun = [line for line in rules if ' on tun464 ' in line + ' ']
    bad = [line for line in on_tun if 'reply-to' in line or 'route-to' in line]
    ipv4_pass = [line for line in on_tun if line.startswith('pass ') and ' inet ' in line + ' ']
    t.check('2', not bad and not ipv4_pass, 'no rule on tun464 has reply-to or route-to, and none passes IPv4 there',
            'reply-to/route-to: %s; IPv4 pass rules: %s' % (bad or 'none', ipv4_pass or 'none'))
    labels = rule_labels(debug)
    own = labels.get(CLAT_RULE_DESCR)
    users = {descr: labels[descr] for descr in USER_RULES if descr in labels}

    def position(label):
        return next((i for i, line in enumerate(rules) if 'label "%s"' % label in line), None)
    own_pos = position(own) if own else None
    user_pos = {descr: position(label) for descr, label in users.items()}
    known = [pos for pos in user_pos.values() if pos is not None]
    t.check('3', own_pos is not None and bool(known) and own_pos < min(known),
            'the rule stands before every user rule in pfctl -sr',
            'plugin rule at line %s; user rules at %s' % (own_pos, user_pos or 'not found in rules.debug'))
    nat = [line for line in sn.splitlines() if re.match(r'^nat on tun464 inet from \(hn0:network\) to any .*-> \(tun464:0\)', line)]
    t.check('4', bool(nat), 'at least one line "nat on tun464 inet from (hn0:network) to any ... -> (tun464:0)"',
            nat[:2] or [line for line in sn.splitlines() if 'tun464' in line][:3] or 'no NAT line names tun464')
    found = clat_states(parse_states(ss), clat6)
    nat44_if = sorted({state_iface(s) for s in found['nat44']})
    v6_if = sorted({state_iface(s) for s in found['v6']})
    shown = 'all' not in nat44_if + v6_if
    good = bool(found['nat44']) and bool(found['v6']) and not found['untranslated'] and alive
    if shown:
        good = good and nat44_if == ['tun464'] and 'tun464' in v6_if and 'pppoe0' in v6_if
    t.check('5', good, 'states of the flow: 192.0.0.1:port (192.168.1.x:port) -> target on tun464, clat6 <-> 64:ff9b::c058:6301 '
            'on tun464 and pppoe0, nothing untranslated',
            'flow running %s; NAT44 states %d on %s; IPv6 states %d on %s; untranslated %s%s' % (
                alive, len(found['nat44']), nat44_if, len(found['v6']), v6_if,
                [s['line'] for s in found['untranslated'][:2]] or 'none',
                '' if shown else ' (floating states: pfctl does not name the interface)'))
    mss = scrub_mss(sr) or scrub_mss(debug)
    t.check('6', 1432 in mss, 'normalisation on tun464 inet6 with max-mss 1432', mss or 'no max-mss rule on tun464 inet6')


def T03(t):
    """ S. Gateway, default route, datapath, the firewall's own IPv4, strict-prefix refusal, bypass. """
    details = st(t, 'start')
    clat6, tayga6 = jget(details, 'address.clat6', ''), jget(details, 'address.tayga6', '')
    routes = o_default4()
    t.check('route', routes == [(TAYGA_IPV4, 'tun464')], 'exactly one IPv4 default route: 192.0.0.2 on tun464', routes)
    gateways = o_ipv4_gateways()
    t.check('gateway', gateways is not None and [name for name, _a in gateways] == ['CLAT_GW'], 'exactly one IPv4 gateway, CLAT_GW', gateways)
    router = O('cat /tmp/tun464_router').out.strip()
    t.check('router', router == TAYGA_IPV4, 'router file holds 192.0.0.2', router or 'no file')
    tun = O('ifconfig tun464').out
    pids = o_tayga_pids()
    opened = re.search(r'Opened by PID (\d+)', tun)
    t.check('tun', bool(re.search(r'inet 192\.0\.0\.1 --> 192\.0\.0\.2 netmask 0xffffffff', tun)) and bool(opened)
            and pids == [opened.group(1)],
            'tun464 has "inet 192.0.0.1 --> 192.0.0.2 netmask 0xffffffff" and is opened by tayga',
            '%s; opened by %s, tayga pid %s' % (re.findall(r'inet .*', tun)[:1], opened.group(1) if opened else '-', pids))
    table6 = O('netstat -rn -f inet6').out
    pair = [line.split() for line in table6.splitlines() if '/127' in line and 'tun464' in line]
    t.check('pair', len(pair) == 1 and bool(clat6) and same_net(pair[0][0], clat6 + '/127'), 'one /127 route for the CLAT pair on tun464',
            pair or 'none')
    addresses = set()
    for token in re.findall(r'inet6 (\S+)', O('ifconfig -a').out):
        try:
            addresses.add(ipaddress.IPv6Address(token.split('%')[0]))
        except ValueError:
            pass
    own = [a for a in (clat6, tayga6) if a and ipaddress.IPv6Address(a) in addresses]
    t.check('unconfigured', bool(clat6) and not own, 'neither address of the pair is configured on any interface', own or 'none configured')
    res = O('ping -n -c3 -t 10 %s' % TARGET, timeout=40)
    t.check('own', ping_counts(res.out) == (3, 3), "OPNsense's own ping to the test target, 3 of 3", '%d of %d' % ping_counts(res.out)[::-1])
    client_checks(t, 'client-')
    got, res = c_ping(2, dst=NEG_DST)
    refused = re.search(r'From (\S+) icmp_seq=\d+ Destination Host Unreachable', res.out)
    t.check('strict', got == 0 and bool(refused) and refused.group(1) == TAYGA_IPV4,
            'ping to 10.255.255.1 is answered "Destination Host Unreachable" from 192.0.0.2',
            'replies %d; %s' % (got, refused.group(0) if refused else (res.lines()[-2:] or 'no output')))

    def drops():
        text = W('nft list chain inet isp input', quiet=True).out
        m = re.search(r'iifname "mgmt0".*counter packets (\d+)', text)
        return int(m.group(1)) if m else None
    before = drops()
    got, _res = c_ping(2, dst='10.99.0.1')
    time.sleep(1)
    after = drops()
    t.check('bypass', got == 0 and before is not None and after is not None and after - before == 2,
            'ping to 10.99.0.1 gets no reply and the mgmt0 drop counter on clat-world grows by 2 (it left by hn2, not by the CLAT)',
            'replies %d; drop counter %s -> %s' % (got, before, after))


def T03b(t):
    """ S. Interface-bound states. """
    try:
        opn_cfg('set', 'system.state-policy', '1')
        O('configctl filter reload', timeout=120)
        line = O("grep -c 'set state-policy if-bound' /tmp/rules.debug").last()
        t.check('policy', line == '1', '/tmp/rules.debug has "set state-policy if-bound"', '%s line(s)' % line)
        O('configctl clat restart', timeout=120)
        reached, seconds, last = wait_active(120)
        t.check('active', reached, 'active again after "configctl clat restart" under the new policy', '%.0f s, %s' % (seconds, sdesc(last)))
        clat6 = jget(status_json(), 'plan.clat6')
        flow = start_flow()
        time.sleep(5)
        sr, _sn, ss, _debug = read_rules(t, 'if-bound')
        alive = flow.poll() is None
        stop_proc(flow)
        found = clat_states(parse_states(ss), clat6)
        nat44_if = sorted({s['if'] for s in found['nat44']})
        v6_if = sorted({s['if'] for s in found['v6']})
        t.check('states', alive and nat44_if == ['tun464'] and v6_if == ['pppoe0', 'tun464'] and not found['untranslated'],
                'the states of T02(5) exist and name tun464 or pppoe0 as their interface, none of them "all"',
                'flow running %s; NAT44 on %s (%d); IPv6 on %s (%d); untranslated %d' % (
                    alive, nat44_if, len(found['nat44']), v6_if, len(found['v6']), len(found['untranslated'])))
        ours = [line for line in sr.splitlines() if CLAT_RULE.match(line)]
        t.check('rule', len(ours) == 1 and 'reply-to' not in ours[0], "no reply-to on the plugin's rule", ours or 'rule not found')
        client_checks(t, 'client-')
    finally:
        tidy(lambda: opn_cfg('unset', 'system.state-policy'), lambda: O('configctl filter reload', timeout=120))
    line = O("grep -c 'set state-policy if-bound' /tmp/rules.debug").last()
    got, _res = c_ping(3)
    t.check('unset', line == '0' and got == 3, 'after the unset the line is gone and ping is 3 of 3', '%s line(s), ping %d of 3' % (line, got))


def T04(t):
    """ S. MSS and DF at PPP MTU 1492, in the order of the plan. """
    client_syn, ppp_syn, client_synack = syn_capture(t, '1492')
    t.check('1a', bool(client_syn) and set(client_syn) == {1460}, 'the client SYN leaves with MSS 1460', client_syn or 'no SYN captured on lan0')
    t.check('1b', bool(ppp_syn) and set(ppp_syn) == {1432}, 'the SYN on ppp0 (IPv6) has MSS 1432', ppp_syn or 'no SYN captured on ppp0')
    t.check('1c', bool(client_synack) and set(client_synack) == {1432}, 'the SYN-ACK reaching the client has MSS 1432',
            client_synack or 'no SYN-ACK captured on lan0')
    frag = fragment_pair(t)
    t.check('2', frag != 'unknown', 'fragment pair: the 1260-byte echo is answered (the 1261-byte one decides FRAG_RETURN)', 'FRAG_RETURN=%s' % frag)
    if frag == 'lost':
        result, tests = plugin_test(t, 'fragments')
        t.check('2b', jget(tests, 'mtu.ok', False) is None and jget(tests, 'mtu.size') == 1260,
                "with those replies lost the plugin's size test says inconclusive and names 1260 bytes",
                jget(tests, 'mtu.detail') or result.get('error') or 'no result')
    echo_df(t)

    flush_cache()
    got, res = c_ping(1, opts='-M probe -s 1444')
    t.frag_check('3a', got == 1, 'DF probe of 1472 bytes (-s 1444) is answered', res.lines()[-2:] or 'no output')

    def sweep(flush):
        hits = []
        for size in range(1445, 1465):
            if flush:
                flush_cache()
            _got, res = c_ping(1, opts='-M probe -s %d' % size)
            hits.append((size + 28,) + frag_error(res.out))
        return hits
    hits = sweep(False)
    good = [hit for hit in hits if hit[2] == 1472]
    note = ''
    if len(good) < 20:
        note = ' (first pass without a cache flush: %d of 20; PLAN section 7 row 24 fallback used)' % len(good)
        hits = sweep(True)
        good = [hit for hit in hits if hit[2] == 1472]
    t.check('3b', len(good) == 20, 'each of the 20 sizes from 1473 to 1492 bytes gets its own "Frag needed and DF set (mtu = 1472)"',
            '%d of 20; senders %s; sizes without the error: %s%s' % (
                len(good), sorted({hit[1] for hit in hits if hit[1]}), [hit[0] for hit in hits if hit[2] != 1472] or 'none', note))
    senders = sorted({hit[1] for hit in good})
    t.info('sender of the errors (expected 192.0.0.2)', senders)

    flush_cache()
    res = C('tracepath -4 -n %s' % TARGET, timeout=90)
    m = re.search(r'Resume: pmtu (\d+)', res.out)
    t.check('4', bool(m) and m.group(1) == '1472', 'tracepath reports pmtu 1472', m.group(0) if m else res.lines()[-2:])

    if W('iperf3 --help 2>&1 | grep -c -- --dont-fragment', quiet=True).last() == '0':
        t.skip('5', 'UDP with DF at 1472 and 1473 bytes', 'PLAN section 7 row 25: this iperf3 has no --dont-fragment')
    else:
        counts = {}
        for payload in (1444, 1445):
            flush_cache()
            capture = Capture(t, 'udp-%d' % payload, 'ppp0', 'ip6 and udp and dst port 5201').start()
            result = c_iperf('-u --dont-fragment -b 5M -l %d -t 5' % payload)
            packets = capture.stop()
            arrived = sum(1 for _moment, ip in ip_packets(packets)
                          if ip['proto'] == 17 and ip['first'] and len(ip['l4']) >= 6
                          and int.from_bytes(ip['l4'][4:6], 'big') == payload + 8)
            counts[payload] = (arrived, udp_loss(result), result.get('error'))
        arrived, (loss, packets), error = counts[1444]
        t.check('5a', loss is not None and packets > 0 and loss <= 1.0 and arrived > 0,
                'UDP with DF, 1472-byte packets: at most 1 % loss', 'lost %s %% of %d; %d datagrams seen on ppp0%s' % (
                    loss, packets, arrived, '; error %s' % error if error else ''))
        arrived, (loss, packets), error = counts[1445]
        t.check('5b', arrived == 0, 'UDP with DF, 1473-byte packets: no datagram reaches the ISP side',
                '%d datagrams of that size seen on ppp0; iperf3: lost %s %% of %d%s' % (arrived, loss, packets, '; error %s' % error if error else ''))

    result, tests = plugin_test(t, 'df')
    t.frag_check('6', jget(tests, 'mtu.ok') is True and jget(tests, 'mtu.size') == 1472, "the plugin's DF probe reports 1472",
                 jget(tests, 'mtu.detail') or result.get('error') or 'no result')


def T22(t):
    """ S. WAN without a SLAAC address. """
    before = o_prefix_mtime()
    W('ispctl slaac off')
    W('ispctl session reset')
    reached, seconds, content = wait_session(prefix=PD_DEFAULT, newer_than=before)
    if not reached:
        raise Invalid('no new session within %.0f s of the reset (prefix file: %s)' % (seconds, content or 'none'))
    reached, seconds, last = wait_active(120)
    time.sleep(5)
    text = O('ifconfig pppoe0').out
    addresses = [token.split('%')[0] for token in re.findall(r'inet6 (\S+)', text)]
    globals_ = [a for a in addresses if not a.lower().startswith('fe80')]
    t.check('wan', bool(addresses) and not globals_, 'pppoe0 has only a link-local IPv6 address', addresses or 'no IPv6 address')
    details = st(t, 'noslaac')
    clat6 = jget(details, 'address.clat6', '')
    try:
        inside = ipaddress.IPv6Address(clat6) in ipaddress.ip_network(PD_DEFAULT)
    except ValueError:
        inside = False
    t.check('active', reached and details.get('state') == 'active', 'active after the new session', '%.0f s, %s' % (seconds, details.get('message')))
    t.check('clat6', inside, 'clat6 lies in the delegated prefix', clat6 or 'none')
    got, _res = c_ping(3)
    t.check('icmp', got == 3, 'client ping 3 of 3', '%d of 3' % got)
    got = c_download()
    t.check('tcp', got == '200 104857600', '100 MB download complete', got)


def T05(t):
    """ S. Dormant interface is inert for 15 minutes. """
    duration = int(os.environ.get('CLAT_T05_SECONDS', '900'))
    W('ispctl dns64 off')
    no_pref64()
    reached, seconds, last = wait_status(state_is('listening', 'no_nat64_prefix'), 60)
    if not reached:
        t.check('dormant', False, 'the CLAT goes dormant without PREF64 and without DNS64', sdesc(last))
        return
    time.sleep(15)      # the state change itself may log and reload once

    measure = ('echo BACKUPS=$(ls /conf/backup 2>/dev/null | wc -l)\n'
               'echo RULES=$(stat -f %m /tmp/rules.debug)\n'
               'echo CLATLOG=$(cat /var/log/clat/clat_*.log 2>/dev/null | wc -l)\n'
               'echo CONFIGD=$(opnsense-log configd 2>/dev/null | grep -Ec "clat|Reloading filter|New IPv[46] on")\n'
               'pid=$(cat /var/run/clat.pid 2>/dev/null)\n'
               'echo CPU=$(ps -o time= -p "$pid" 2>/dev/null)\n')

    def measured():
        return {key: value.strip() for key, value in re.findall(r'^([A-Z]+)=(.*)$', O(measure).out, re.M)}
    first = measured()
    sampler = Sampler(t, 'dormant', duration + 60, interval=10).start()
    time.sleep(duration)
    samples = sampler.stop()
    second = measured()
    new_lines = O('opnsense-log configd 2>/dev/null | grep -E "clat|Reloading filter|New IPv[46] on" | tail -n 5').out.strip()

    states = sorted({'%s/%s' % (s_state(s), s_get(s, 'reason')) for s in samples})
    t.check('state', len(samples) >= duration // 20 and states == ['listening/no_nat64_prefix'],
            'whole window: state listening, reason no_nat64_prefix', '%d samples, states %s' % (len(samples), states))
    t.check('route', all(not s['d4'] for s in samples) and all(s['nat'] == 0 for s in samples) and all(s['rtr'] == 0 for s in samples),
            'whole window: no IPv4 default route, no NAT line on tun464, no router file',
            'samples with a default route %d, with a NAT line %d, with a router file %d' % (
                sum(1 for s in samples if s['d4']), sum(1 for s in samples if s['nat']), sum(1 for s in samples if s['rtr'])))
    t.check('tun', all(s['tun'] == 'noaddr' for s in samples) and all(not s['tayga'] for s in samples),
            'whole window: tun464 exists without an inet address, no tayga',
            'tun464: %s; samples with tayga %d' % (sorted({s['tun'] for s in samples}), sum(1 for s in samples if s['tayga'])))
    t.check('config', first.get('BACKUPS') == second.get('BACKUPS') and first.get('RULES') == second.get('RULES'),
            '/conf/backup count unchanged, /tmp/rules.debug not rewritten',
            'backups %s -> %s, rules.debug mtime %s -> %s' % (first.get('BACKUPS'), second.get('BACKUPS'), first.get('RULES'), second.get('RULES')))
    t.check('log', first.get('CLATLOG') == second.get('CLATLOG'), '0 new clat log lines after the state change',
            '%s -> %s lines' % (first.get('CLATLOG'), second.get('CLATLOG')))
    t.check('configd', first.get('CONFIGD') == second.get('CONFIGD'), '0 configd actions naming clat, a filter reload or a new address',
            '%s -> %s matching lines; last: %s' % (first.get('CONFIGD'), second.get('CONFIGD'), new_lines[-200:] or 'none'))
    cpu0, cpu1 = ps_seconds(first.get('CPU', '')), ps_seconds(second.get('CPU', ''))
    t.check('cpu', cpu0 is not None and cpu1 is not None and cpu1 - cpu0 < 2.0, 'clatd CPU time grows by less than 2 s',
            '%s -> %s' % (first.get('CPU'), second.get('CPU')))
    gateways = o_ipv4_gateways()
    t.check('gateway', gateways is not None and 'CLAT_GW' not in [name for name, _a in gateways], 'no CLAT_GW', gateways)
    code, overview = api('GET', '/api/interfaces/overview/interfaces_info')
    rows = [row for row in (overview.get('rows', []) if isinstance(overview, dict) else []) if row.get('device') == 'tun464']
    ipv4 = [str(row.get(key)) for row in rows for key in ('addr4', 'ipv4') if row.get(key)]
    t.check('overview', code == 200 and len(rows) == 1 and not ipv4, 'the interface list shows CLAT without an IPv4 address',
            'HTTP %s, %d row(s) for tun464, IPv4: %s' % (code, len(rows), ipv4 or 'none'))
    res = O('ping -6 -n -c2 %s' % RESOLVER6, timeout=30)
    t.check('ipv6', ping_counts(res.out)[1] == 2, 'ping6 from OPNsense to the ISP resolver still works', '%d of 2' % ping_counts(res.out)[1])


def T06(t):
    """ S, DNS64 off. PREF64 lifetime. """
    W('ispctl dns64 off')
    restarts = jget(status_json(), 'tayga.restarts')
    seen_restarts = set()
    capture = Capture(t, 'ra', 'ppp0', 'icmp6 and (ip6[40] == 133 or ip6[40] == 134)').start()
    try:
        # (a) withdrawal while active
        sampler = Sampler(t, 'a', 180).start()
        time.sleep(3)
        t_cmd = time.time()
        W('ispctl pref64 withdraw')
        reached, seconds, last = wait_status(state_is('listening', 'no_nat64_prefix'), 25)
        time.sleep(4)
        samples = sampler.stop()
        seen_restarts.update(tayga_view(samples)['restarts'])
        zero = [moment for moment, m in router_messages(capture.peek())
                if m['type'] == 134 and moment >= t_cmd - 1 and any(life == 0 for life, _p in m['pref64'])]
        dormant = first_sample(samples, lambda s: s_state(s) == 'listening', after=t_cmd)
        delta = dormant['tl'] - zero[0] if dormant and zero else None
        t.check('a1', reached and delta is not None and delta <= 10 + TOL, 'listening / no_nat64_prefix within 10 s of the RA with lifetime 0',
                '%s; RA with lifetime 0 seen: %s; %s s after it' % (sdesc(last), bool(zero), '%.1f' % delta if delta is not None else '-'))
        tail = samples[-1] if samples else {'d4': '?', 'nat': '?'}
        left = o_int("pfctl -ss | grep -c '192\\.0\\.0\\.1'")
        t.check('a2', tail['d4'] == '' and tail['nat'] == 0 and left == 0, 'default route and NAT line gone, no state for 192.0.0.1',
                'default route "%s", NAT lines %s, states naming 192.0.0.1: %d' % (tail['d4'], tail['nat'], left))

        # (b) lifetime 64, then RAs without the option
        W('ispctl pref64 on %s 64' % WKP)
        reached, seconds, last = wait_active(90)
        if t.check('b0', reached, 'active again by an RA with lifetime 64', '%.0f s, %s' % (seconds, sdesc(last))):
            sampler = Sampler(t, 'b', 240).start()
            time.sleep(3)
            t_off = time.time()
            W('ispctl pref64 off')
            time.sleep(32)
            wait_status(lambda status: status and status.get('state') != 'active', 70)
            time.sleep(4)
            samples = sampler.stop()
            seen_restarts.update(tayga_view(samples)['restarts'])
            window = [s for s in samples if t_off <= s['tl'] <= t_off + 30]
            t.check('b1', bool(window) and all(s_state(s) == 'active' for s in window),
                    'still active 30 s after "pref64 off" (an RA without the option does not withdraw)',
                    sorted({str(s_state(s)) for s in window}))
            carried = [moment for moment, m in router_messages(capture.peek())
                       if m['type'] == 134 and any(life > 0 for life, _p in m['pref64'])]
            gone = first_sample(samples, lambda s: s_state(s) != 'active', after=t_off)
            delta = gone['tl'] - carried[-1] if gone and carried else None
            t.check('b2', delta is not None and 64 - TOL <= delta <= 80 + TOL,
                    'deactivation between 64 and 80 s after the last RA that carried the option',
                    '%s s after it; state then %s' % ('%.1f' % delta if delta is not None else '-', s_state(gone) if gone else 'still active'))

        # (c) a second prefix while the first is valid
        W('ispctl pref64 on %s 1800' % WKP)
        reached, seconds, last = wait_active(90)
        if t.check('c0', reached, 'active by an RA with lifetime 1800', '%.0f s, %s' % (seconds, sdesc(last))):
            sampler = Sampler(t, 'c', 150).start()
            time.sleep(3)
            W('ispctl pref64 on 2001:db8:64:ff9b::/96 1800')
            time.sleep(60)
            samples = sampler.stop()
            seen_restarts.update(tayga_view(samples)['restarts'])
            details = st(t, 'c')
            same, text = tayga_not_restarted(samples)
            t.check('c1', jget(details, 'pref64.prefix') == WKP and same,
                    'after 60 s st.pref64.prefix is still 64:ff9b::/96 and tayga was not restarted',
                    'prefix %s; %s' % (jget(details, 'pref64.prefix'), text))
        W('ispctl pref64 withdraw')       # takes the second prefix back
        time.sleep(3)
        W('ispctl pref64 on %s 1800' % WKP)
        wait_active(60)

        # (d) no unsolicited RAs: the plugin has to solicit
        kea = 'systemctl show -p ActiveEnterTimestampMonotonic --value kea-dhcp6-server'
        kea_before = W(kea).out.strip()
        W('ispctl set RA_UNSOLICITED off && ispctl apply')
        kea_after = W(kea).out.strip()
        time.sleep(3)
        t_restart = time.time()
        O('configctl clat restart', timeout=120)
        reached, seconds, last = wait_active(35)
        time.sleep(3)
        messages = [(moment, m) for moment, m in router_messages(capture.peek()) if moment >= t_restart]
        solicits = [m for _moment, m in messages if m['type'] == 133]
        unicast = [m for _moment, m in messages if m['type'] == 134 and not m['dst'].startswith('ff02') and m['pref64']]
        multicast = [m for _moment, m in messages if m['type'] == 134 and m['dst'].startswith('ff02')]
        t.check('d1', reached and seconds <= 30 + TOL, 'active within 30 s of the restart, by a solicited RA', '%.0f s, %s' % (seconds, sdesc(last)))
        t.check('d2', bool(solicits) and bool(unicast) and not multicast,
                'capture: an RS, a unicast RA with option 38, no multicast RA',
                '%d RS, %d unicast RA with PREF64, %d multicast RA' % (len(solicits), len(unicast), len(multicast)))
        t.check('d3', kea_before == kea_after and kea_before not in ('', '0'), "Kea's start time did not change with \"ispctl apply\"",
                '%s -> %s' % (kea_before, kea_after))

        # (e) short lifetime, refreshed in time
        W('ispctl set RA_UNSOLICITED on && ispctl set RA_INTERVAL 20 && ispctl pref64 on %s 64' % WKP)
        wait_active(60)
        time.sleep(25)
        sampler = Sampler(t, 'e', 240).start()
        time.sleep(180)
        samples = sampler.stop()
        seen_restarts.update(tayga_view(samples)['restarts'])
        late = [s for s in samples if not (isinstance(s_get(s, 'pref64.expires'), (int, float)) and s_get(s, 'pref64.expires') > s['t'])]
        states = sorted({str(s_state(s)) for s in samples})
        same, text = tayga_not_restarted(samples)
        t.check('e1', len(samples) >= 90 and not late and states == ['active'] and same,
                'for 3 minutes pref64.expires is always in the future, the state stays active, tayga is not restarted',
                '%d samples, %d with an expiry not in the future, states %s; %s' % (len(samples), len(late), states, text))
    finally:
        capture.stop()
    t.check('restarts', seen_restarts <= {restarts}, 'tayga.restarts unchanged in all steps (no crash)',
            'before %s, seen %s' % (restarts, sorted(seen_restarts)))


def T07(t):
    """ S. DNS discovery on a default box: recursive Unbound, the ISP's DNS64 on, no PREF64. """
    duration = int(os.environ.get('CLAT_T07_SECONDS', '300'))
    no_pref64()
    reached, seconds, last = wait_status(state_is('listening', 'no_nat64_prefix'), 60)
    sampler = Sampler(t, 'a', duration + 60, interval=2).start()
    time.sleep(duration)
    samples = sampler.stop()
    states = sorted({'%s/%s' % (s_state(s), s_get(s, 'reason')) for s in samples})
    t.check('a1', reached and len(samples) >= duration // 4 and states == ['listening/no_nat64_prefix'],
            'listening / no_nat64_prefix for the whole 5 minutes', '%d samples, states %s' % (len(samples), states))
    gateways = o_ipv4_gateways()
    t.check('a2', gateways is not None and 'CLAT_GW' not in [name for name, _a in gateways], 'no CLAT_GW', gateways)
    # drill without a server takes the name servers of resolv.conf in random order, and the second one there is
    # the ISP's DNS64 resolver learned from the RA (seen 2026-10-12: one run answered by 127.0.0.1 without AAAA,
    # the next by 2001:db8:64::53 with both). The plugin asks the first one only (DESIGN 5.2), so that one is asked.
    first = O("awk '$1==\"nameserver\"{print $2; exit}' /etc/resolv.conf").last()
    rcode, addrs = parse_drill(O('drill AAAA ipv4only.arpa @%s' % (first or '127.0.0.1'), timeout=60).out)
    t.check('a3', first == '127.0.0.1' and not addrs,
            'the first name server of the box is its own Unbound, and the lookup there returns no AAAA record',
            'first name server %s; rcode %s (recorded; without IPv6 Internet SERVFAIL, from the cache NOERROR), AAAA %s' % (
                first or 'none', rcode, addrs or 'none'))

    # (b) only if OPNsense's Unbound can recurse through the CLAT (PLAN section 7 row 19)
    W('ispctl pref64 on %s 64' % WKP)
    reached, seconds, last = wait_active(120)
    if not reached:
        t.check('b0', False, 'active by an RA with lifetime 64, as the start of step (b)', sdesc(last))
    else:
        time.sleep(5)
        rcode, addrs = parse_drill(O('drill AAAA ipv4only.arpa @127.0.0.1', timeout=90).out)
        if rcode != 'NOERROR':
            t.skip('b1', 'while active the lookup returns NOERROR without AAAA',
                   "PLAN section 7 row 19: OPNsense's Unbound cannot recurse through the CLAT (rcode %s)" % rcode)
        else:
            t.check('b1', not addrs, 'while active the lookup returns NOERROR without AAAA', 'rcode %s, AAAA %s' % (rcode, addrs or 'none'))
    sampler = Sampler(t, 'b', 420, interval=2).start()
    W('ispctl pref64 off')
    reached, seconds, last = wait_status(state_is('listening'), 110)
    time.sleep(180)
    samples = sampler.stop()
    after = [s for s in samples if s['tl'] >= time.time() - 178]
    states = sorted({str(s_state(s)) for s in after})
    t.check('b2', reached and bool(after) and states == ['listening'], 'after the expiry the state is listening and stays so for 3 minutes',
            'listening after %.0f s; states in the last 3 minutes %s' % (seconds, states))


def T08(t):
    """ From T07 (PREF64 off, ISP DNS64 on, the plugin's DNS retry backed off). DNS discovery, four steps. """
    status = status_json()
    world = W("grep -E '^(PREF64|DNS64)=' /etc/isp/isp.env", quiet=True).out.split()
    if not (status and status.get('state') == 'listening' and 'PREF64=off' in world and 'DNS64=on' in world):
        t.info('start state established by T08 itself (T07 did not leave it); the DNS retry is then not backed off',
               '%s; %s' % (sdesc(status), world))
        W('ispctl dns64 on')
        no_pref64()
        wait_status(state_is('listening'), 120)
    restarts = jget(status_json(), 'tayga.restarts')
    seen_restarts = set()
    added_dns = False
    try:
        resolv = O('cat /etc/resolv.conf; ls -l /tmp/*nameserver* 2>/dev/null; cat /tmp/*nameserver* 2>/dev/null').out
        if RESOLVER6 not in resolv:
            t.info('pre-check: the resolver of the RA is not among the system name servers; entered as system DNS server', resolv.split())
            opn_cfg('set', 'system.dnsserver.0', RESOLVER6)
            O('configctl dns reload', timeout=120)
            added_dns = True
        else:
            t.info('pre-check: %s learned from the RA is a system name server' % RESOLVER6)

        # (a) "Use System Nameservers" (query forwarding)
        sampler = Sampler(t, 'a', 420).start()
        ok, detail = unbound_set('forwarding', {'enabled': '1'})
        t_reconf = time.time()
        reached, seconds, last = wait_status(state_is('active'), 330)
        samples = sampler.stop()
        seen_restarts.update(tayga_view(samples)['restarts'])
        t.check('a0', ok, 'Unbound forwarding switched on through the API', detail)
        rcode, addrs = parse_drill(O('drill AAAA ipv4only.arpa @127.0.0.1', timeout=60).out)
        t.check('a1', sorted(addrs) == ['64:ff9b::c000:aa', '64:ff9b::c000:ab'], 'the lookup returns 64:ff9b::c000:aa and 64:ff9b::c000:ab',
                'rcode %s, %s' % (rcode, addrs))
        t.check('a2', reached, 'active within 330 s of the reconfigure with nothing else done', '%.0f s, %s' % (time.time() - t_reconf if not reached else seconds, sdesc(last)))
        t.info('latency a customer waits after ticking "Use System Nameservers"', '%.0f s' % seconds if reached else 'not reached')
        details = st(t, 'a')
        pref = details.get('pref64') or {}
        t.check('a3', pref.get('prefix') == WKP and pref.get('source') == 'dns' and pref.get('lifetime') is None,
                'st.pref64 is 64:ff9b::/96, source dns, lifetime null', json.dumps(pref))
        got, _res = c_ping(3)
        t.check('a4', got == 3, 'client ping 3 of 3', '%d of 3' % got)

        # (c) the resolver stops synthesising
        sampler = Sampler(t, 'c', 200).start()
        t_off = time.time()
        W('ispctl dns64 off')
        reached, seconds, last = wait_status(lambda s: state_is('listening', 'no_nat64_prefix')(s) and not s.get('pref64'), 130 + TOL)
        time.sleep(4)
        samples = sampler.stop()
        seen_restarts.update(tayga_view(samples)['restarts'])
        tail = samples[-1] if samples else {'d4': '?', 'nat': '?'}
        t.check('c1', reached and tail['d4'] == '' and tail['nat'] == 0,
                'within 130 s of "dns64 off": pref64 null, listening / no_nat64_prefix, default route and NAT line gone',
                '%.0f s, %s; default route "%s", NAT lines %s' % (seconds, sdesc(last), tail['d4'], tail['nat']))
        t.info('time from "dns64 off" to dormant (TTL 60 + refresh)', '%.0f s' % seconds if reached else 'not reached')

        # (d) DNS64 in OPNsense's own Unbound, with forwarding; the ISP's DNS64 stays off
        ok, detail = unbound_set('general', {'dns64': '1'})
        t_reconf = time.time()
        reached, seconds, last = wait_status(state_is('active', source='dns'), 130 + TOL)
        t.check('d0', ok, 'DNS64 in Unbound switched on through the API', detail)
        rcode, addrs = parse_drill(O('drill AAAA ipv4only.arpa @127.0.0.1', timeout=60).out)
        t.check('d1', sorted(addrs) == ['64:ff9b::c000:aa', '64:ff9b::c000:ab'],
                "the lookup returns the two addresses, synthesised by OPNsense's own Unbound", 'rcode %s, %s' % (rcode, addrs))
        t.check('d2', reached, 'active within 130 s of the reconfigure, source dns', '%.0f s, %s' % (seconds, sdesc(last)))
        got, _res = c_ping(3)
        t.check('d3', got == 3, 'client ping 3 of 3', '%d of 3' % got)
        unbound_set('general', {'dns64': '0'})
        W('ispctl dns64 on')
        time.sleep(5)
        reached, seconds, last = wait_status(state_is('active', source='dns'), 400)
        t.check('d4', reached, "back on the ISP's DNS64: active with source dns", '%.0f s, %s' % (seconds, sdesc(last)))

        # (b) PREF64 appears: the RA takes over, same prefix, no restart
        if reached:
            sampler = Sampler(t, 'b', 120).start()
            time.sleep(3)
            W('ispctl pref64 on')
            reached, seconds, last = wait_status(lambda s: jget(s, 'pref64.source') == 'ra', 30 + TOL)
            time.sleep(5)
            samples = sampler.stop()
            seen_restarts.update(tayga_view(samples)['restarts'])
            same, text = tayga_not_restarted(samples)
            t.check('b1', reached and same, 'within 30 s the source becomes ra; tayga is not restarted (same prefix)',
                    '%.0f s, %s; %s' % (seconds, sdesc(last), text))
        else:
            t.skip('b1', 'the RA takes over from DNS without a restart', 'step (d) did not end in active by DNS')
    finally:
        tidy(lambda: unbound_set('forwarding', {'enabled': '0'}), lambda: unbound_set('general', {'dns64': '0'}),
             lambda: added_dns and opn_cfg('unset', 'system.dnsserver'),
             lambda: added_dns and O('configctl dns reload', timeout=120))
    t.check('restarts', seen_restarts <= {restarts}, 'tayga.restarts unchanged throughout (no crash)',
            'before %s, seen %s' % (restarts, sorted(seen_restarts)))


def T09(t):
    """ S. Static prefix. """
    W('ispctl dns64 off')
    no_pref64()
    reached, seconds, last = wait_status(state_is('listening'), 60)
    if not t.check('0', reached, 'dormant without PREF64 and DNS64', sdesc(last)):
        return
    try:
        ok, code, answer = clat_set({'prefix': WKP})
        reached, seconds, last = wait_active(30 + TOL)
        details = st(t, 'a')
        pref = details.get('pref64') or {}
        t.check('a1', ok and reached and pref.get('source') == 'static' and pref.get('lifetime') is None,
                'active within 30 s of the reconfigure; source static, lifetime null', '%.0f s, %s, %s' % (seconds, sdesc(last), json.dumps(pref)))
        got, _res = c_ping(3)
        t.check('a2', got == 3, 'client ping 3 of 3', '%d of 3' % got)

        W('ispctl pref64 on 2001:db8:64:ff9b::/96')
        time.sleep(60)
        pref = st(t, 'b').get('pref64') or {}
        t.check('b', pref.get('prefix') == WKP and pref.get('source') == 'static',
                'another prefix in the RA: after 60 s the prefix is still 64:ff9b::/96, source static', json.dumps(pref))

        # inside the delegated 2001:db8:5600::/56. The plan's 2001:db8:5600:ff00::/96 is not (its fourth group
        # is ff00, the /56 ends at 00ff), and the plugin rightly went active with it (seen 2026-10-12)
        overlap = '2001:db8:5600:ff::/96'
        ok, code, answer = clat_set({'prefix': overlap})
        reached, seconds, last = wait_status(state_is('blocked', 'pref64_overlap'), 40)
        details = st(t, 'c')
        gateways = o_ipv4_gateways()
        t.check('c', ok and reached and overlap in str(details.get('message')) and gateways is not None
                and 'CLAT_GW' not in [name for name, _a in gateways],
                'a prefix inside the delegation: blocked, reason pref64_overlap, the message names the prefix, no CLAT_GW',
                '%s; message "%s"; IPv4 gateways %s' % (sdesc(last), details.get('message'), gateways))

        no_pref64()
        ok, code, answer = clat_set({'prefix': ''})
        reached, seconds, last = wait_status(state_is('listening', 'no_nat64_prefix'), 30 + TOL)
        t.check('d', ok and reached, 'prefix emptied and no PREF64: listening / no_nat64_prefix within 30 s of the reconfigure',
                '%.0f s, %s' % (seconds, sdesc(last)))
    finally:
        tidy(lambda: clat_set({'prefix': ''}))


def T10(t):
    """ S. Forged RA from the LAN, sent with the BNG's own link-local address as source. """
    route = O('route -6 -n get default').out
    m = re.search(r'gateway: (\S+)', route)
    router = m.group(1).split('%')[0] if m else ''
    if not router.lower().startswith('fe80'):
        raise Invalid('no link-local IPv6 default gateway on clat-opn: %s' % route.strip()[-200:])
    t.info('R, the gateway of the IPv6 default route (expected fe80::1)', router)
    restarts = jget(status_json(), 'tayga.restarts')
    seen_restarts = set()
    client_mac = C('cat /sys/class/net/lan0/address', quiet=True).last().lower()
    if not re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', client_mac):
        raise Invalid('cannot read the MAC address of lan0 in the client namespace: %s' % client_mac)
    genuine = Capture(t, 'genuine-ra', 'ppp0', 'icmp6 and ip6[40] == 134').start()

    def counter():
        return icmp6_ra_input(O('netstat -s -p icmp6', quiet=True).out)

    def send(label, args, count=3):
        """ Send forged RAs; True when they reached hn0 and were delivered to OPNsense's ICMPv6 input.
            The capture on hn0 takes frames from the client's MAC only: OPNsense sends RAs of its own there.
        """
        before = counter()
        seen = subprocess.Popen(SSH + [OPN_LOGIN, '/bin/sh', '-s'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        seen.stdin.write(opn_wrap("timeout 20 tcpdump -ni hn0 -c 1 'icmp6 and ip6[40] == 134 and ether src %s' 2>&1"
                                  % client_mac).encode())
        seen.stdin.close()
        seen.stdin = None       # communicate() below would flush the closed pipe and raise ValueError
        time.sleep(4)
        C('python3 %s --iface lan0 --count %d %s' % (SEND_RA, count, args), timeout=60)
        try:
            output = seen.communicate(timeout=30)[0].decode('utf-8', 'replace')
        except subprocess.TimeoutExpired:
            seen.kill()
            output = ''
        t.save('forged-%s-hn0.txt' % label, output)
        time.sleep(1)
        after = counter()
        on_wire = 'router advertisement' in output or bool(re.search(r'\b1 packets? captured', output))
        if before is None or after is None:
            t.info('%s: FreeBSD input counter not readable (PLAN section 7 row 26); seen by the NIC: %s' % (label, on_wire))
            return on_wire, 'seen by the NIC %s; delivery to the ICMPv6 input not shown' % on_wire
        delivered = after - before >= count
        return on_wire and delivered, 'seen on hn0 %s; "router advertisement" input counter +%d for %d sent' % (on_wire, after - before, count)

    def window_clean(start):
        return not [moment for moment, m in router_messages(genuine.peek()) if moment >= start]

    def route_ok():
        routes = o_default6()
        return [(gw.split('%')[0], dev) for gw, dev in routes] == [(router, 'pppoe0')], routes

    def active_case(cid, label, sends, what):
        """ While active: nothing may change and no client ping is lost. The pings (two per second) run
            from before the first forged RA until 30 s after the last one.
        """
        for attempt in (1, 2):
            start = time.time()
            before = status_json()
            sampler = Sampler(t, '%s-%d' % (label, attempt), 180).start()
            sent = 2 * (len(sends) * 12 + 30)
            pinger = subprocess.Popen(['ip', 'netns', 'exec', 'client', 'ping', '-n', '-c', str(sent), '-i', '0.5', '-W', '2', TARGET],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            valid, notes = True, []
            for index, args in enumerate(sends):
                arrived, note = send('%s-%d-%d' % (label, attempt, index), args)
                valid = valid and arrived
                notes.append(note)
            try:
                summary = pinger.communicate(timeout=sent)[0].decode('utf-8', 'replace')
            except subprocess.TimeoutExpired:
                pinger.kill()
                summary = ''
            t.save('ping-%s-%d.log' % (label, attempt), summary)
            lost = sent - ping_counts(summary)[1]
            samples = sampler.stop()
            after = status_json()
            seen_restarts.update(tayga_view(samples)['restarts'])
            if window_clean(start) or attempt == 2:
                break
            t.info('%s: a genuine RA from the BNG arrived in the window, the case is repeated once' % label)
        if not valid:
            t.skip(cid, what, 'void: the forged RA did not reach OPNsense (RouterGuard on the adapter?): %s' % '; '.join(notes))
            return
        same, text = tayga_not_restarted(samples)
        unchanged = (jget(before, 'pref64.prefix') == jget(after, 'pref64.prefix') == WKP
                     and jget(before, 'pref64.source') == jget(after, 'pref64.source') == 'ra'
                     and jget(before, 'pref64.expires') == jget(after, 'pref64.expires') and jget(after, 'state') == 'active')
        still, routes = route_ok()
        t.check(cid, unchanged and same and lost == 0 and still, what,
                'pref64 before %s, after %s; state %s; %s; pings lost %d of %d; IPv6 default %s; %s' % (
                    json.dumps(jget(before, 'pref64')), json.dumps(jget(after, 'pref64')), jget(after, 'state'), text, lost, sent,
                    routes, '; '.join(notes)))

    def dormant_case(cid, label, args, what):
        before = status_json()
        arrived, note = send(label, args)
        time.sleep(30)
        after = status_json()
        if not arrived:
            t.skip(cid, what, 'void: the forged RA did not reach OPNsense: %s' % note)
            return
        still, routes = route_ok()
        pids = o_tayga_pids()
        t.check(cid, jget(after, 'state') == 'listening' and not jget(after, 'pref64') and not pids and still, what,
                'before %s, after %s; tayga pids %s; IPv6 default %s; %s' % (sdesc(before), sdesc(after), pids or 'none', routes, note))

    try:
        src = '--src %s' % router
        active_case('b', 'b', ['%s --prefix 2001:db8:bad:64::/96' % src],
                    '(b) active, forged other prefix: prefix and source unchanged, tayga not restarted, no client ping lost')
        active_case('c', 'c', ['%s --prefix %s --lifetime 0' % (src, WKP), '%s --prefix %s --lifetime 65528' % (src, WKP)],
                    '(c) active, forged withdrawal and forged long lifetime: prefix kept, pref64.expires unchanged, tayga not restarted, no ping lost')
        active_case('d-c', 'dc', ['--prefix %s --lifetime 0' % WKP, '--prefix %s --lifetime 65528' % WKP],
                    '(d) the same from the foreign source fe80::bad:64 (rejected by the source test alone)')
        W('ispctl dns64 off')
        no_pref64()
        reached, seconds, last = wait_status(state_is('listening'), 60)
        if not reached:
            t.check('a0', False, 'dormant without PREF64 and DNS64, as the start of step (a)', sdesc(last))
        else:
            dormant_case('a', 'a', '%s --prefix %s' % (src, WKP), '(a) dormant, forged PREF64 from the LAN: still listening, pref64 null, no tayga')
            dormant_case('d-a', 'da', '--prefix %s' % WKP, '(d) the same from the foreign source fe80::bad:64')
    finally:
        genuine.stop()
    t.check('restarts', seen_restarts <= {restarts}, 'tayga.restarts unchanged in every case (no crash)',
            'before %s, seen %s' % (restarts, sorted(seen_restarts)))


def session_step(t, name, action, settle=20, max_wait=300):
    """ Run one session-loss action under the sampler and the client ping; returns what the checks need. """
    before = status_json()
    world_before = W('stat -c %Y /run/isp/session 2>/dev/null || echo 0', quiet=True).last()
    sampler = Sampler(t, name, max_wait + 200).start()
    ping = PingLog(t, name).start()
    time.sleep(6)
    t_action = time.time()
    t_done = action()
    deadline = t_action + max_wait
    base = None
    while time.time() < deadline:
        samples = sampler.peek()
        if samples:
            base = samples[0]['pfx'] if base is None else base
            if any(s['pfx'] != base and s['pfx'] != 0 and s['tl'] >= t_action for s in samples):
                break
        time.sleep(3)
    wait_active(45)
    time.sleep(settle)
    samples = sampler.stop()
    ping.stop()
    world_after = W('stat -c %Y /run/isp/session 2>/dev/null || echo 0', quiet=True).last()
    info = analyse_reconnect(samples, t_action)
    info.update({'samples': samples, 'ping': ping, 't_action': t_action, 't_done': t_done or t_action, 'before': before,
                 'after': status_json(),
                 'new_session': (int(world_after) - t_action) if world_after.isdigit() and world_after != world_before else None})
    return info


def recovery_checks(t, cid, info, with_ping=True):
    """ 'active within 30 s of the prefix file being rewritten', and the pings come back. """
    active = info['s_active']
    delta = active['tl'] - info['t_pfx'] if active and info['t_pfx'] else None
    t.check(cid + '-active', delta is not None and delta <= 30 + TOL,
            'active no later than 30 s after /tmp/pppoe0_prefixv6 was rewritten by the new session',
            'prefix file rewritten %s; active %s s after it' % (
                '%.0f s after the action' % (info['t_pfx'] - info['t_action']) if info['t_pfx'] else 'never',
                '%.0f' % delta if delta is not None else '-'))
    if with_ping:
        back = info['ping'].first_after(active['tl']) if active else None
        t.check(cid + '-ping', back is not None and back - active['tl'] <= 10 + TOL, 'pings answered again within 10 s of active',
                '%.1f s' % (back - active['tl']) if back is not None else 'no reply after active')


def T11(t):
    """ S. PPPoE session loss: graceful reset, silent drop, suspend. """
    restarts = jget(status_json(), 'tayga.restarts')
    seen_restarts = set()

    # (a) graceful reset by the BNG
    def reset():
        W('ispctl session reset')
    info = session_step(t, 'a', reset)
    seen_restarts.update(tayga_view(info['samples'])['restarts'])
    recovery_checks(t, 'a', info)
    t.check('a-clat6', jget(info['before'], 'plan.clat6') and jget(info['before'], 'plan.clat6') == jget(info['after'], 'plan.clat6'),
            'clat6 unchanged', '%s -> %s' % (jget(info['before'], 'plan.clat6'), jget(info['after'], 'plan.clat6')))
    same, text = tayga_not_restarted(info['samples'])
    t.check('a-tayga', same, 'tayga not restarted', text)
    bare = [s for s in info['samples'] if s['d4'] and s['nat'] == 0]
    t.check('a-nat', not bare, 'no sample with an IPv4 default route present and the NAT line absent', '%d of %d samples' % (len(bare), len(info['samples'])))
    untranslated_after(t, 'a', 'a-states')
    t.info('time from the reset to the new session on clat-world (more than 30 s decides for PLAN section 7 row 23 fallback)',
           '%.0f s' % info['new_session'] if info['new_session'] is not None else 'no new session seen')

    # (b) silent loss: no PADT, no terminate
    wait_active(120)

    def drop():
        W('ispctl session drop')
    info = session_step(t, 'b', drop)
    seen_restarts.update(tayga_view(info['samples'])['restarts'])
    noticed = first_sample(info['samples'], lambda s: s_down(s) or s_state(s) != 'active', after=info['t_action'])
    t.info('(b) time until OPNsense noticed the silent loss (keep-alive 10 60: up to 60 s)',
           '%.0f s' % (noticed['tl'] - info['t_action']) if noticed else 'never left active and pppoe0 never went down')
    suspended = [s for s in info['samples'] if s_state(s) == 'suspended']
    if info['gap6'] > 15 + TOL:
        t.check('b-suspended', bool(suspended), 'suspended, because the uplink was down for more than 15 s',
                'pppoe0 down for %.0f s; suspended samples %d' % (info['gap6'], len(suspended)))
    else:
        t.info('(b) suspended not expected: the uplink was down for %.0f s' % info['gap6'], 'suspended samples %d' % len(suspended))
    recovery_checks(t, 'b', info, with_ping=False)
    same, text = tayga_not_restarted(info['samples'])
    t.check('b-tayga', same, 'tayga not restarted', text)

    # (c) the standard customer: the BNG is away for 45 s
    wait_active(120)
    marks = {}

    def suspend():
        W('systemctl stop isp-pppoe', timeout=60)
        time.sleep(45)
        marks['start'] = time.time()
        W('systemctl start isp-pppoe', timeout=60)
        return marks['start']
    info = session_step(t, 'c', suspend)
    seen_restarts.update(tayga_view(info['samples'])['restarts'])
    lost = first_sample(info['samples'], s_down, after=info['t_action'])
    if lost is None or lost['tl'] > info['t_done']:
        t.check('c-down', False, 'with the PPPoE server stopped the uplink of OPNsense goes down (pppoe0 loses UP, or the IPv6 default route goes)',
                'pppoe0 stayed up with its IPv6 default route for the 45 s: "suspended" cannot be reached')
    else:
        t.info('(c) what showed the loss (PLAN section 7 row 30: OPNsense keeps the IPv6 default route)',
               'pppoe0 up %s, IPv6 default route "%s", %.0f s after the stop' % (lost.get('up'), lost.get('d6'), lost['tl'] - info['t_action']))
        first = first_sample(info['samples'], lambda s: s_state(s) == 'suspended', after=lost['tl'])
        delta = first['tl'] - lost['tl'] if first else None
        t.check('c-suspended', delta is not None and 15 - TOL <= delta <= 30 + TOL and s_get(first, 'withdrawn') is False,
                'suspended between 15 and 30 s after the uplink went down (pppoe0 lost UP), withdrawn false',
                '%s s after it; withdrawn %s' % ('%.0f' % delta if delta is not None else '-', s_get(first, 'withdrawn') if first else '-'))
        if first:
            held = [s for s in info['samples'] if first['tl'] <= s['tl'] <= info['t_done']]
            bad = [s for s in held if not (s['rtr'] == 1 and s['tun'] == CLAT_IPV4 and s_d4_devs(s) == ['tun464'] and s['nat'] >= 1
                                           and s['tayga'] == held[0]['tayga'] and s['tayga'])]
            t.check('c-kept', bool(held) and not bad,
                    'from then until the start, in every sample: router file, 192.0.0.1 on tun464, IPv4 default route on tun464, NAT line, same tayga pid',
                    '%d of %d samples differ%s' % (len(bad), len(held), ': %s' % json.dumps({k: bad[0][k] for k in ('rtr', 'tun', 'd4', 'nat', 'tayga')}) if bad else ''))
    recovery_checks(t, 'c', info)
    same, text = tayga_not_restarted(info['samples'])
    t.check('c-tayga', same, 'tayga not restarted', text)
    t.check('restarts', seen_restarts <= {restarts}, 'tayga.restarts unchanged in all three (no crash)',
            'before %s, seen %s' % (restarts, sorted(seen_restarts)))


def T13(t):
    """ S. tayga crash three times; then the supervisor is killed. """
    base = jget(status_json(), 'tayga.restarts', 0)
    sampler = Sampler(t, 'a', 600).start()
    ping = PingLog(t, 'a').start()
    time.sleep(5)
    kills = []
    for index, limit in enumerate((20, 25, 45)):
        want = base + index + 1
        t_kill = time.time()
        O('pkill -KILL -x tayga')
        reached, seconds, last = wait_status(lambda s, want=want: state_is('active')(s) and jget(s, 'tayga.restarts') == want
                                             and jget(s, 'tayga.started') is not None, limit + 30)
        time.sleep(4)
        pids = o_tayga_pids()
        kills.append((t_kill, time.time()))
        t.check('a%d-active' % (index + 1), reached and seconds <= limit + TOL,
                'kill %d: active again within %d s (back-off plus start), tayga.restarts plus 1' % (index + 1, limit),
                '%.0f s, %s, tayga.restarts %s (expected %s)' % (seconds, sdesc(last), jget(last, 'tayga.restarts'), want))
        t.check('a%d-one' % (index + 1), len(pids) == 1, 'kill %d: exactly one tayga afterwards' % (index + 1), pids or 'none')
        if not reached:
            wait_active(330)
    time.sleep(8)
    samples = sampler.stop()
    ping.stop()
    for index, (t_kill, t_end) in enumerate(kills):
        window = [s for s in samples if t_kill <= s['tl'] <= t_end]
        without = [s for s in window if not s['tayga']]
        early = [s for s in without if s['rtr'] == 1 and s['tl'] <= t_kill + 2]
        late = [s for s in without if s['rtr'] == 1 and s['tl'] > t_kill + 2]
        t.check('a%d-router' % (index + 1), bool(without) and not late and len(early) <= 1,
                'kill %d: router file absent while no tayga runs' % (index + 1),
                '%d samples without tayga, %d of them with a router file (%d within 2 s of the kill)' % (len(without), len(early) + len(late), len(early)))
        back = first_sample(samples, lambda s: s_state(s) == 'active' and s['tayga'] and s['rtr'] == 1, after=t_kill + 2)
        reply = ping.first_after(back['tl']) if back else None
        t.check('a%d-ping' % (index + 1), reply is not None and reply - back['tl'] <= 10 + TOL, 'kill %d: pings resume' % (index + 1),
                '%.1f s after active' % (reply - back['tl']) if reply is not None else 'no reply')

    # (b) the supervisor dies
    O('kill -KILL $(cat /var/run/clat.pid)')
    time.sleep(5)
    pids = o_tayga_pids()
    details = st(t, 'b-killed')
    t.check('b1', not pids and details.get('state') == 'stopped', 'no tayga process 5 s after the supervisor was killed; st.state is stopped',
            'tayga pids %s; st.state %s' % (pids or 'none', details.get('state')))
    O('configctl clat start', timeout=120)
    # the killed supervisor left its status file behind ("active", tayga.restarts 3): wait for the new one's
    reached, seconds, last = wait_status(lambda s: state_is('active')(s) and jget(s, 'tayga.restarts') == 0, 60 + TOL)
    time.sleep(3)
    daemons = O('pgrep -f clatd.py').out.split()
    pids = o_tayga_pids()
    t.check('b2', reached and len(daemons) == 1 and len(pids) == 1, 'after "configctl clat start": active within 60 s, one clatd, one tayga',
            '%.0f s, %s; clatd %s; tayga %s' % (seconds, sdesc(last), daemons, pids))


def T14(t):
    """ S. The API. """
    try:
        code, answer = api('GET', '/api/clat/service/status')
        t.check('a', code == 200 and jget(answer, 'status') == 'running' and jget(answer, 'clat.state') == 'active',
                'GET service/status: 200, service running, state active',
                'HTTP %s, status %s, clat.state %s' % (code, jget(answer, 'status'), jget(answer, 'clat.state')))
        clat6 = jget(answer, 'clat.address.clat6')

        echo_df(t)
        code, answer = api('POST', '/api/clat/service/test', timeout=180)
        tests = {item.get('id'): item for item in (answer.get('tests', []) if isinstance(answer, dict) else [])}
        t.check('b1', code == 200 and jget(tests, 'plat.ok') is True and jget(tests, 'path.ok') is True, 'POST service/test: the first two tests ok',
                'HTTP %s; %s' % (code, answer.get('text') if isinstance(answer, dict) else str(answer)[:200]))
        t.frag_check('b2', jget(tests, 'mtu.ok') is True and jget(tests, 'mtu.size') == P['mtu'][1], 'the size test is ok with %d' % P['mtu'][1],
                     jget(tests, 'mtu.detail') or 'no result')

        # (c) MSS offset: a filter matter, no restart of anything
        daemon = O('cat /var/run/clat.pid').last()
        sampler = Sampler(t, 'c', 120).start()
        time.sleep(3)
        ok, code, answer = clat_set({'mss_offset': '20'})
        time.sleep(15)
        samples = sampler.stop()
        sr, _sn, _ss, debug = read_rules(t, 'mss-offset')
        mss = scrub_mss(sr) or scrub_mss(debug)
        same, text = tayga_not_restarted(samples)
        daemon_after = O('cat /var/run/clat.pid').last()
        t.check('c', ok and daemon == daemon_after and same and mss == [P['mtu'][2] - 20],
                'mss_offset 20: saved, clatd pid unchanged, tayga not restarted, max-mss on tun464 inet6 now %d' % (P['mtu'][2] - 20),
                'saved %s; clatd %s -> %s; %s; max-mss %s' % (ok, daemon, daemon_after, text, mss))

        # (d) IPv6 MTU override: a new plan, one planned restart
        before = jget(status_json(), 'tayga.restarts')
        sampler = Sampler(t, 'd', 200).start()
        time.sleep(3)
        t_set = time.time()
        ok, code, answer = clat_set({'mss_offset': '', 'ipv6_mtu': '1400'})
        reached, seconds, last = wait_status(lambda s: state_is('active')(s) and jget(s, 'plan.tun_mtu') == 1400, 75 + TOL)
        time.sleep(5)
        samples = sampler.stop()
        details = st(t, 'd')
        tun = O('ifconfig tun464 | head -n 1').out
        once, text = tayga_restarted_once(samples, jget(details, 'tayga.uptime'), time.time() - t_set)
        t.check('d1', ok and reached and ' mtu 1400' in tun and jget(details, 'mtu.ipv4') == 1380 and jget(details, 'mtu.mss') == 1340,
                'ipv6_mtu 1400: within 75 s tun464 MTU 1400, st.mtu.ipv4 1380, MSS 1340',
                '%.0f s; %s; st.mtu %s' % (seconds, tun.strip()[-12:], json.dumps(details.get('mtu'))))
        t.check('d2', once and jget(details, 'tayga.restarts') == before, 'tayga restarted once, tayga.restarts unchanged',
                '%s; tayga.restarts %s -> %s' % (text, before, jget(details, 'tayga.restarts')))
        flush_cache()
        got, res = c_ping(1, opts='-M probe -s 1352')
        t.frag_check('d3', got == 1, 'DF probe of 1380 bytes (-s 1352) is answered', res.lines()[-2:])
        flush_cache()
        _got, res = c_ping(1, opts='-M probe -s 1353')
        t.check('d4', frag_error(res.out)[1] == 1380, 'DF probe of 1381 bytes gets "mtu = 1380"', res.lines()[:2])

        # (e) disable, (f) enable
        ok, code, answer = clat_set({'enabled': '0'})
        time.sleep(20)
        details = st(t, 'e')
        sr, sn, _ss, _debug = read_rules(t, 'disabled')
        facts = O('echo "CLATD=$(pgrep -f clatd.py | wc -l | tr -d " ") TAYGA=$(pgrep -x tayga | wc -l | tr -d " ")"\n'
                  'echo "RECORD=$(pluginctl -g interfaces.clat 2>/dev/null | tr -d " \\n")"\n'
                  'echo "RC=$(cat /etc/rc.conf.d/clat 2>/dev/null | tr -d "\\n")"\n').out
        record = re.search(r'RECORD=(.*)', facts).group(1).strip() if 'RECORD=' in facts else '?'
        routes = o_default4()
        named = [line for line in (sr + sn).splitlines() if 'tun464' in line]
        t.check('e', ok and details.get('state') == 'disabled' and 'CLATD=0 TAYGA=0' in facts
                and record in ('', 'null', '[]', '{}') and not named and not routes and 'clat_enable="NO"' in facts,
                'enabled 0: st.state disabled, no clatd, no tayga, interfaces.clat gone, no rule or NAT line on tun464, '
                'no IPv4 default route, clat_enable="NO"',
                'st.state %s; %s; lines naming tun464 %d; default routes %s' % (details.get('state'), ' '.join(facts.split()), len(named), routes))
        ok, code, answer = clat_set({'enabled': '1'})
        reached, seconds, last = wait_active(60 + TOL)
        t.check('f', ok and reached and jget(last, 'plan.clat6') == clat6 and bool(clat6), 'enabled 1: active within 60 s with the same clat6 as before',
                '%.0f s, %s, clat6 %s (before %s)' % (seconds, sdesc(last), jget(last, 'plan.clat6'), clat6))

        # (g) validation
        code, before = api('GET', '/api/clat/settings/get')
        code, answer = api('POST', '/api/clat/settings/set', {'clat': {'general': {'prefix': 'banana'}}})
        code2, after = api('GET', '/api/clat/settings/get')
        refused = isinstance(answer, dict) and answer.get('result') == 'failed' and any('prefix' in key for key in (answer.get('validations') or {}))
        t.check('g', refused and jget(before, 'clat.general.prefix') == jget(after, 'clat.general.prefix') and code2 == 200,
                'prefix "banana": the API answers with a validation error and the stored value is unchanged',
                'HTTP %s %s; stored "%s" -> "%s"' % (code, json.dumps(answer)[:200], jget(before, 'clat.general.prefix'), jget(after, 'clat.general.prefix')))
    finally:
        tidy(lambda: clat_set({'enabled': '1', 'mss_offset': '', 'ipv6_mtu': ''}))


def T15(t):
    """ S. Reboot; (b) the same in the DNS-only configuration. """
    backups = o_backups()
    kernel = O('uname -v').last()
    ping = PingLog(t, 'a').start()
    time.sleep(5)
    t_cmd, t_down, t_login = reboot_opn()
    sampler = Sampler(t, 'a-boot', 400).start()
    reached, seconds, last = wait_status(state_is('active'), 60)
    seconds = time.time() - t_login
    if not reached:
        reached_late, _s, last = wait_status(state_is('active'), 240)
    time.sleep(10)
    samples = sampler.stop()
    ping.stop()
    t.check('a1', reached and seconds <= 60 + TOL, 'with no manual step: active within 60 s of the first possible login',
            '%.0f s after the first login, %s' % (seconds, sdesc(last)))
    first = ping.first_after(t_down)
    t.info('time from the reboot command to the first answered client ping',
           '%.0f s (ssh closed after %.0f s, first login after %.0f s)' % (first - t_cmd, t_down - t_cmd, t_login - t_cmd) if first else 'no reply after the reboot')
    facts = O('echo BACKUPS=$(ls /conf/backup 2>/dev/null | wc -l)\necho SIGNALS=$(dmesg | grep -c "exited on signal")\necho UNAME=$(uname -v)\n').out
    values = {key: value.strip() for key, value in re.findall(r'^([A-Z]+)=(.*)$', facts, re.M)}
    t.check('a2', values.get('BACKUPS') == str(backups), '/conf/backup count unchanged across the boot', '%d -> %s' % (backups, values.get('BACKUPS')))
    t.check('a3', values.get('SIGNALS') == '0' and values.get('UNAME') == kernel, '0 "exited on signal", kernel as before',
            'signals %s; kernel %s' % (values.get('SIGNALS'), 'same' if values.get('UNAME') == kernel else values.get('UNAME')))
    got, _res = c_ping(3)
    t.check('a4', got == 3, 'client ping 3 of 3', '%d of 3' % got)
    if P['source'] == 'dns':
        route = first_sample(samples, lambda s: bool(s.get('d6')))
        active = first_sample(samples, lambda s: s_state(s) == 'active')
        t.check('a5', bool(samples) and s_get(samples[-1], 'pref64.source') == 'dns', 'the prefix came from DNS again',
                sdesc(samples[-1].get('st')) if samples else 'no sample')
        t.info('time a customer waits after a reboot, from the IPv6 default route to active',
               '%.0f s%s' % (active['tl'] - route['tl'], ' (the route was there at the first login)' if route is samples[0] else '')
               if route and active else 'not measured')
        return      # part (b) is this profile's own configuration: part (a) has measured it

    # (b) DNS-only: no PREF64, the ISP's DNS64 on, Unbound forwarding
    try:
        no_pref64()
        unbound_set('forwarding', {'enabled': '1'})
        reached, seconds, last = wait_status(state_is('active', source='dns'), 400)
        if not t.check('b0', reached, 'DNS-only configuration is active by DNS before the reboot', '%.0f s, %s' % (seconds, sdesc(last))):
            return
        t_cmd, t_down, t_login = reboot_opn()
        sampler = Sampler(t, 'b-boot', 700).start()
        reached, _seconds, last = wait_status(state_is('active', source='dns'), 480)
        time.sleep(5)
        samples = sampler.stop()
        route = first_sample(samples, lambda s: bool(s.get('d6')))
        active = first_sample(samples, lambda s: s_state(s) == 'active' and s_get(s, 'pref64.source') == 'dns')
        delta = active['tl'] - route['tl'] if route and active else None
        t.check('b1', reached and delta is not None and delta <= 420 + TOL,
                'with no manual step: active with source dns no later than 420 s after the IPv6 default route appeared',
                '%s s after the route%s; %s' % ('%.0f' % delta if delta is not None else '-',
                                              ' (the route was there at the first login)' if route and samples and route is samples[0] else '', sdesc(last)))
        if delta is not None:
            t.info('time a customer on a DNS64-only line waits after a reboot', '%.0f s' % delta)
            if delta > 120:
                t.info('FINDING', 'after a reboot the DNS-only configuration needs %.0f s (more than 120 s) to activate' % delta)
        got, _res = c_ping(3)
        t.check('b2', got == 3, 'client ping 3 of 3', '%d of 3' % got)
    finally:
        tidy(lambda: unbound_set('forwarding', {'enabled': '0'}), lambda: W('ispctl pref64 on'))


def T24(t):
    """ S. Throughput, informational. """
    watcher = subprocess.Popen(SSH + [OPN_LOGIN, '/bin/sh', '-s'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    watcher.stdin.write(opn_wrap('(top -b -d 3 -s 4 2>&1 | grep -E "tayga|python|PID" > /tmp/lab-top.txt) &\n'
                                 'timeout 14 tcpdump -ni hn0 -c 20 greater 1515 2>&1\n'
                                 'wait; echo "== top"; cat /tmp/lab-top.txt; rm -f /tmp/lab-top.txt').encode())
    watcher.stdin.close()
    watcher.stdin = None        # communicate() below would flush the closed pipe and raise ValueError
    time.sleep(3)
    up = c_iperf('-t 10', timeout=60)
    try:
        output = watcher.communicate(timeout=60)[0].decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        watcher.kill()
        output = ''
    t.save('hn0-oversize-and-top.txt', output)
    down = c_iperf('-t 10 -R', timeout=60)
    rate_up = (jget(up, 'end.sum_received.bits_per_second') or 0) / 1e6
    rate_down = (jget(down, 'end.sum_received.bits_per_second') or 0) / 1e6
    captured = re.search(r'(\d+) packets? captured', output)
    oversize = int(captured.group(1)) if captured else -1
    t.check('flow', rate_up > 0 and rate_down > 0, 'TCP through the CLAT in both directions carries data',
            'upload %.0f Mbit/s, download %.0f Mbit/s' % (rate_up, rate_down))
    t.check('frames', oversize == 0, 'no frame above 1514 bytes reaches hn0 during the upload (offloads are off)',
            '%s frames captured%s' % (oversize if oversize >= 0 else 'unknown number of', '' if oversize == 0 else '; the numbers carry the remark "offloads active" (PLAN section 7 row 22)'))
    t.info('throughput: a VM on the lab host, says nothing about customer hardware',
           'upload %.0f Mbit/s, download %.0f Mbit/s; top: %s' % (rate_up, rate_down, ' | '.join(output.split('== top')[-1].split('\n')[1:6])))


def T12(t):
    """ S, last of the S group. Renumbering: a new /56 (production profile: a new WAN /64 too), then a single /64. """
    restarts = jget(status_json(), 'tayga.restarts')
    old = jget(status_json(), 'plan.clat6')
    prod = PROFILE == 'prod'
    new56, new_clat64, new_wan64 = (('2001:db8:4900:100::/56', '2001:db8:4900:1ff::/64', '2001:db8:4900::/64') if prod else
                                    ('2001:db8:5700::/56', '2001:db8:5700:ff::/64', None))
    old_text = P['clat64'].split('::')[0] + ':'
    try:
        # (a) another /56
        before = o_prefix_mtime()
        sampler = Sampler(t, 'a', 420).start()
        ping = PingLog(t, 'a').start()
        time.sleep(3)
        t_action = time.time()
        if new_wan64:
            W('ispctl set WAN_PREFIX %s' % new_wan64)
        W('ispctl pd %s' % new56)
        W('ispctl session reset')
        reached, seconds, content = wait_session(prefix=new56, newer_than=before, timeout=240)
        t.check('a1', reached, 'the prefix file holds %s' % new56, '%s after %.0f s' % (content or 'no file', seconds))
        t_pfx = time.time()
        inside = lambda s: bool(jget(s, 'plan.clat6')) and ipaddress.IPv6Address(jget(s, 'plan.clat6')) in ipaddress.ip_network(new_clat64)
        moved, seconds, last = wait_status(lambda s: state_is('active')(s) and inside(s), 120 + TOL)
        time.sleep(8)
        samples = sampler.stop()
        ping.stop()
        details = st(t, 'a')
        t.check('a2', moved, 'clat6 inside %s within 120 s of the prefix file changing' % new_clat64,
                '%.0f s, clat6 %s, %s' % (seconds, jget(last, 'plan.clat6'), sdesc(last)))
        once, text = tayga_restarted_once(samples, jget(details, 'tayga.uptime'), time.time() - t_action)
        t.check('a3', once and jget(details, 'tayga.restarts') == restarts, 'tayga restarted once, tayga.restarts unchanged',
                '%s; tayga.restarts %s -> %s' % (text, restarts, jget(details, 'tayga.restarts')))
        new = jget(details, 'address.clat6', '')
        pair = [line.split()[0] for line in O('netstat -rn -f inet6').out.splitlines() if '/127' in line and 'tun464' in line]
        t.check('a4', len(pair) == 1 and bool(new) and same_net(pair[0], new + '/127') and new != old, 'only the new /127 on tun464',
                '%s (clat6 before %s, now %s)' % (pair, old, new))
        stale = o_int("pfctl -ss | grep -c '%s'" % old_text)
        t.check('a5', stale == 0, 'no state with a %s address' % old_text, '%d states' % stale)
        capture = Capture(t, 'renumbered', 'ppp0', 'ip6 and dst host %s' % TARGET6).start()
        got, _res = c_ping(3)
        sources = sorted({ip['src'] for _moment, ip in ip_packets(capture.stop())})
        t.check('a6', got == 3 and sources == [new], 'pings answered afterwards; translated packets on ppp0 carry the new source',
                'ping %d of 3; sources on ppp0 %s' % (got, sources))
        if prod:
            wan = re.findall(r'inet6 (\S+) prefixlen 64 (\S*)', O('ifconfig pppoe0').out)
            lan = [token for token in re.findall(r'inet6 (\S+)', O('ifconfig hn0').out) if not token.lower().startswith('fe80')]
            new_wan = [a for a, _flag in wan if not a.lower().startswith('fe80') and same_net(a + '/64', new_wan64)]
            new_lan = [a for a in lan if ipaddress.IPv6Address(a) in ipaddress.ip_network(new56)]
            t.check('a7', bool(new_wan) and bool(new_lan), 'the WAN has a SLAAC address in %s and the LAN an address in %s' % (new_wan64, new56),
                    'pppoe0 %s; hn0 %s' % (wan, lan))
            left = [a for a, _flag in wan if not a.lower().startswith('fe80') and same_net(a + '/64', P['wan64'])]
            t.info('addresses of the old WAN /64 and /56 still on the box', 'pppoe0 %s; hn0 %s' % (
                left or 'none', [a for a in lan if ipaddress.IPv6Address(a) in ipaddress.ip_network(PD_DEFAULT)] or 'none'))
            got = c_download()
            t.check('a8', got == '200 104857600', '100 MB download complete', got)
            return      # part (b), a single /64, is not what this ISP delegates

        # (b) a single /64
        new64 = '2001:db8:5800:1::/64'
        opn_cfg('set', 'interfaces.wan.dhcp6-ia-pd-len', '0')
        O('configctl interface reconfigure wan', timeout=180)
        time.sleep(10)
        before = o_prefix_mtime()
        t_action = time.time()
        W('ispctl pd %s' % new64)
        W('ispctl session reset')
        reached, seconds, content = wait_session(prefix=new64, newer_than=before, timeout=240)
        t.check('b1', reached, 'the prefix file holds 2001:db8:5800:1::/64', '%s after %.0f s' % (content or 'no file', seconds))
        inside64 = lambda s: bool(jget(s, 'plan.clat6')) and ipaddress.IPv6Address(jget(s, 'plan.clat6')) in ipaddress.ip_network(new64)
        moved, _seconds, last = wait_status(lambda s: state_is('active')(s) and inside64(s), max(5, 150 + TOL - (time.time() - t_action)))
        t.check('b2', moved, 'active within 150 s with clat6 inside 2001:db8:5800:1::/64',
                '%.0f s after the reset, clat6 %s, %s' % (time.time() - t_action, jget(last, 'plan.clat6'), sdesc(last)))
        got, _res = c_ping(3)
        t.check('b3', got == 3, 'client ping 3 of 3', '%d of 3' % got)
        got = c_download()
        t.check('b4', got == '200 104857600', '100 MB download complete', got)
        lan = [token for token in re.findall(r'inet6 (\S+)', O('ifconfig hn0').out) if not token.lower().startswith('fe80')]
        t.info('whether the LAN kept an IPv6 address with a single /64', lan or 'no global address on hn0')
    finally:
        if prod:        # the ISP's own prefixes again, with a new session
            tidy(lambda: W(P['defaults'], timeout=180), lambda: wait_m5(timeout=300), lambda: wait_active(120))
        else:
            tidy(lambda: opn_cfg('set', 'interfaces.wan.dhcp6-ia-pd-len', '8'), lambda: W('ispctl pd %s' % PD_DEFAULT),
                 lambda: O('configctl interface reconfigure wan', timeout=180))


def T16(t):
    """ H. Native IPv4 through IPCP. """
    try:
        # (a) the BNG offers IPCP, the WAN has IPv4 None
        before = o_prefix_mtime()
        W('ispctl ipv4 on')
        W('ispctl session reset')
        wait_session(newer_than=before, timeout=240)
        reached, seconds, last = wait_active(120)
        address = re.findall(r'inet (\S+)', O('ifconfig pppoe0').out)
        t.check('a', reached and not address, '(a) IPCP offered, WAN IPv4 None: pppoe0 gets no IPv4 address, the state returns to active',
                'inet %s; %s' % (address or 'none', sdesc(last)))

        # (b) WAN IPv4 type PPPoE: native IPv4
        sampler = Sampler(t, 'b', 400).start()
        opn_cfg('set', 'interfaces.wan.ipaddr', 'pppoe')
        O('configctl interface reconfigure wan', timeout=180)
        reached, seconds, last = wait_status(state_is('native-ipv4'), 180)
        time.sleep(10)
        samples = sampler.stop()
        details = st(t, 'b')
        address = re.findall(r'inet (\S+)', O('ifconfig pppoe0').out)
        t.check('b1', address == ['100.64.0.2'], '(b) WAN IPv4 PPPoE: pppoe0 has 100.64.0.2', address or 'none')
        got_addr = W("journalctl -t ispctl --since '-10min' --no-pager | grep 'IPv4 up on' | tail -n 1").last()
        t.info('clat-world: journal line of ip-up.d/50-isp', got_addr or 'none')
        native = first_sample(samples, lambda s: s_state(s) == 'native-ipv4')
        with4 = first_sample(samples, lambda s: 'pppoe0' in s_d4_devs(s))
        delta = native['tl'] - with4['tl'] if native and with4 else None
        t.check('b2', reached and jget(last, 'reason') == 'uplink' and delta is not None and delta <= 10 + TOL,
                'native-ipv4 (reason uplink) within 10 s of the IPv4 default route on pppoe0',
                '%s; %s s after the route appeared' % (sdesc(last), '%.0f' % delta if delta is not None else '-'))
        gateways = o_ipv4_gateways()
        routes = o_default4()
        pids = o_tayga_pids()
        t.check('b3', not pids and gateways is not None and 'CLAT_GW' not in [n for n, _a in gateways] and [dev for _gw, dev in routes] == ['pppoe0'],
                'no tayga, no CLAT_GW, the default route on pppoe0', 'tayga %s; IPv4 gateways %s; routes %s' % (pids or 'none', gateways, routes))
        capture = Capture(t, 'native', 'ppp0', 'icmp and host %s' % TARGET).start()
        got, _res = c_ping(3)
        native_packets = [ip for _moment, ip in ip_packets(capture.stop()) if ip['v'] == 4]
        t.check('b4', got == 3 and len(native_packets) >= 3, "the client's ping is answered and crosses ppp0 as IPv4",
                'ping %d of 3; %d IPv4 ICMP packets on ppp0' % (got, len(native_packets)))
        warned = [row for row in details.get('preflight', []) if row.get('id') == 'wan_ipv4_ppp_native' and row.get('effect') == 'warn']
        t.check('b5', bool(warned), 'preflight shows the warning wan_ipv4_ppp_native', [row.get('id') for row in details.get('preflight', [])])

        # (c) back to IPv4 None: hold, then active
        sampler = Sampler(t, 'c', 400).start()
        time.sleep(3)
        opn_cfg('unset', 'interfaces.wan.ipaddr')
        O('configctl interface reconfigure wan', timeout=180)
        reached, seconds, last = wait_active(260)
        time.sleep(5)
        samples = sampler.stop()
        gone = first_sample(samples, lambda s: 'pppoe0' not in s_d4_devs(s))
        hold = first_sample(samples, lambda s: s_state(s) == 'native-ipv4' and s_get(s, 'reason') == 'hold')
        active = first_sample(samples, lambda s: s_state(s) == 'active', after=gone['tl'] if gone else None)
        delta = active['tl'] - gone['tl'] if active and gone else None
        t.check('c', bool(hold) and delta is not None and 60 - TOL <= delta <= 150 + TOL,
                '(c) IPv4 None again: native-ipv4 with reason hold, then active between 60 and 150 s after the IPv4 address disappeared',
                'hold seen %s; active %s s after the IPv4 default route left pppoe0' % (bool(hold), '%.0f' % delta if delta is not None else '-'))

        # (d) WAN type PPPoE without IPCP: what the setup wizard produces on such a line
        opn_cfg('set', 'interfaces.wan.ipaddr', 'pppoe')
        O('configctl interface reconfigure wan', timeout=180)
        wait_status(state_is('native-ipv4'), 180)
        W('ispctl ipv4 off')
        W('ispctl session reset')
        reached, seconds, last = wait_status(state_is('blocked', 'wan_ipv4_ppp'), 240)
        details = st(t, 'd')
        t.check('d', reached and 'None' in str(details.get('message')) and not o_tayga_pids(),
                '(d) WAN IPv4 PPPoE and no IPCP: blocked, reason wan_ipv4_ppp, the message says to set IPv4 Configuration Type to None',
                '%s; message "%s"' % (sdesc(last), details.get('message')))
        t.info('(d) whether IPv6 came up at all (DESIGN finding 6 expects that it does not)',
               'IPv6 default route %s; pppoe0: %s' % (o_default6() or 'none', re.findall(r'inet6? \S+', O('ifconfig pppoe0').out) or 'no address'))
    finally:
        tidy(lambda: W('ispctl ipv4 off'),
             lambda: opn_cfg('get', 'interfaces.wan.ipaddr') != 'absent' and opn_cfg('unset', 'interfaces.wan.ipaddr'),
             lambda: O('configctl interface reconfigure wan', timeout=180))


def T17(t):
    """ H. A static IPv4 gateway on MGMT as a second WAN; suspend with fail-over. """
    uuid = None
    try:
        code, answer = api('POST', '/api/routing/settings/add_gateway', {'gateway_item': {
            'name': 'LABGW', 'interface': 'opt1', 'ipprotocol': 'inet', 'gateway': '10.99.0.1', 'defaultgw': '0',
            'monitor_disable': '1', 'priority': '255', 'descr': 'lab second WAN'}})
        uuid = answer.get('uuid') if isinstance(answer, dict) else None
        api('POST', '/api/routing/settings/reconfigure', timeout=180)
        time.sleep(20)
        last = status_json()
        routes = o_default4()
        t.check('a', bool(uuid) and jget(last, 'state') == 'active' and routes == [(TAYGA_IPV4, 'tun464')],
                '(a) gateway LABGW at priority 255, not upstream: stays active, the default route stays on tun464',
                'add_gateway %s; %s; routes %s' % (json.dumps(answer)[:120], sdesc(last), routes))
        if not uuid:
            return

        # (d) suspend with fail-over to LABGW
        marks = {}

        def suspend():
            W('systemctl stop isp-pppoe', timeout=60)
            time.sleep(45)
            marks['start'] = time.time()
            W('systemctl start isp-pppoe', timeout=60)
            return marks['start']
        info = session_step(t, 'd', suspend)
        lost = first_sample(info['samples'], s_down, after=info['t_action'])
        if lost is None or lost['tl'] > info['t_done']:
            t.check('d-down', False, 'with the PPPoE server stopped the uplink of OPNsense goes down (pppoe0 loses UP, or the IPv6 default route goes)',
                    'pppoe0 stayed up with its IPv6 default route for the 45 s: "suspended" cannot be reached')
        else:
            first = first_sample(info['samples'], lambda s: s_state(s) == 'suspended', after=lost['tl'])
            delta = first['tl'] - lost['tl'] if first else None
            held = [s for s in info['samples'] if first and first['tl'] + 3 <= s['tl'] <= info['t_done']]
            good = [s for s in held if s_get(s, 'withdrawn') is True and [gw for gw, _dev in s_routes(s['d4'])] == ['10.99.0.1']
                    and s['rtr'] == 0 and s['tayga'] and s['tayga'] == held[0]['tayga']]
            t.check('d1', delta is not None and 15 - TOL <= delta <= 30 + TOL and bool(held) and len(good) == len(held),
                    '(d) suspended between 15 and 30 s after the uplink went down (pppoe0 lost UP), withdrawn true, IPv4 default '
                    'route through 10.99.0.1, no router file, tayga running with the same pid',
                    '%s s after it; %d of %d suspended samples as required%s' % (
                        '%.0f' % delta if delta is not None else '-', len(good), len(held),
                        '' if len(good) == len(held) or not held else ': e.g. %s' % json.dumps({k: [s for s in held if s not in good][0][k] for k in ('d4', 'rtr', 'tayga')})))
        recovery_checks(t, 'd', info, with_ping=False)
        same, text = tayga_not_restarted(info['samples'])
        routes = o_default4()
        got, _res = c_ping(3)
        t.check('d2', same and routes == [(TAYGA_IPV4, 'tun464')] and got == 3,
                'after the start: default route back on tun464, tayga not restarted, ping 3 of 3', '%s; routes %s; ping %d of 3' % (text, routes, got))
        untranslated_after(t, 'd', 'd3')

        # (b) the gateway becomes upstream
        code, answer = api('POST', '/api/routing/settings/set_gateway/%s' % uuid, {'gateway_item': {'defaultgw': '1'}})
        api('POST', '/api/routing/settings/reconfigure', timeout=180)
        reached, seconds, last = wait_status(state_is('native-ipv4', 'gateway'), 15 + TOL + 15)
        time.sleep(5)
        gateways, routes, pids = o_ipv4_gateways(), o_default4(), o_tayga_pids()
        t.check('b', reached and seconds <= 15 + TOL and gateways is not None and 'CLAT_GW' not in [n for n, _a in gateways]
                and [gw for gw, _dev in routes] == ['10.99.0.1'] and not pids,
                '(b) LABGW upstream: native-ipv4 (reason gateway) within 15 s, no CLAT_GW, default route by 10.99.0.1, no tayga',
                '%.0f s, %s; IPv4 gateways %s; routes %s; tayga %s' % (seconds, sdesc(last), gateways, routes, pids or 'none'))

        # (c) the gateway goes away
        sampler = Sampler(t, 'c', 400).start()
        time.sleep(3)
        t_del = time.time()
        api('POST', '/api/routing/settings/del_gateway/%s' % uuid)
        uuid = None
        api('POST', '/api/routing/settings/reconfigure', timeout=180)
        time.sleep(5)
        left = [route for route in o_default4() if route[0] == '10.99.0.1']
        if left:
            O('route delete -inet default 10.99.0.1')
        t.info('(c) whether core left the default route to 10.99.0.1 after the gateway was deleted', 'yes, deleted by hand' if left else 'no')
        reached, seconds, last = wait_active(260)
        time.sleep(5)
        samples = sampler.stop()
        hold = first_sample(samples, lambda s: s_state(s) == 'native-ipv4' and s_get(s, 'reason') == 'hold', after=t_del)
        active = first_sample(samples, lambda s: s_state(s) == 'active', after=t_del)
        delta = active['tl'] - hold['tl'] if active and hold else None
        routes = o_default4()
        t.check('c', delta is not None and 60 - 2 * TOL <= delta <= 150 + TOL and routes == [(TAYGA_IPV4, 'tun464')],
                '(c) gateway deleted: native-ipv4 / hold, then active between 60 and 150 s later, default route on tun464',
                'hold seen %s; active %s s after the first sample in hold (%s s after the delete); routes %s' % (
                    bool(hold), '%.0f' % delta if delta is not None else '-', '%.0f' % (active['tl'] - t_del) if active else '-', routes))
    finally:
        tidy(lambda: uuid and api('POST', '/api/routing/settings/del_gateway/%s' % uuid),
             lambda: uuid and api('POST', '/api/routing/settings/reconfigure', timeout=180),
             lambda: O('route delete -inet default 10.99.0.1 2>/dev/null; true', quiet=True))


def jumbo_observe(t, label, expect_ppp=None, expect_tun=None, wait=150):
    """ Shared by T18 to T20: wait for a session (with PPP MTU expect_ppp when given, for at most 180 s),
        then look at both ends of the PPP link and at the plugin.
    """
    start = time.time()
    while time.time() - start < 180:
        if W('ispctl iface', quiet=True).out.strip() == 'ppp0':
            if expect_ppp is None or W('cat /sys/class/net/ppp0/mtu 2>/dev/null', quiet=True).out.strip() == expect_ppp:
                break
        time.sleep(3)
    time.sleep(5)
    out = {'ppp0': W('cat /sys/class/net/ppp0/mtu 2>/dev/null', quiet=True).out.strip()}
    if expect_tun is not None:
        wait_status(lambda s: state_is('active')(s) and jget(s, 'plan.tun_mtu') == expect_tun, wait)
    else:
        wait_active(wait)
    # The device PPPoE runs on: hn1, or vlan0.40 on the tagged link. The WAN MTU field is the MTU of that device.
    # Under a VLAN device core gives the NIC the VLAN's MTU plus 4, unless the NIC has an MTU field of its own.
    port = O("sed -n 's/^[[:space:]]*set pppoe iface //p' /var/etc/mpd_wan.conf | head -n 1", quiet=True).out.strip() or 'hn1'
    for dev in ('hn1', port, 'pppoe0', 'tun464'):
        m = re.search(r' mtu (\d+)', O('ifconfig %s 2>&1 | head -n 1' % dev, quiet=True).out)
        out[dev] = m.group(1) if m else 'none'
    out['port'] = '%s %s' % (port, out[port])
    out['st'] = st(t, label)
    return out


def jumbo_undo():
    """ WAN MTU field empty again, the BNG back at PPP MTU 1492. """
    opn_cfg('unset', 'interfaces.wan.mtu')
    W('ispctl mtu 1492', timeout=120)
    O('configctl interface reconfigure wan', timeout=180)


def ensure_target():
    code, current = api('GET', '/api/clat/settings/get')
    if jget(current, 'clat.general.test_target') != TARGET:
        clat_set({'test_target': TARGET})
        time.sleep(5)


def T18(t):
    """ H. Jumbo: WAN MTU field 1508 against a BNG that echoes PPP-Max-Payload 1500. """
    ensure_target()
    W('ispctl mtu 1500', timeout=120)
    discovery = Capture(t, 'pppoed', 'wan0', 'ether proto 0x8863').start()
    try:
        opn_cfg('set', 'interfaces.wan.mtu', '1508')
        O('configctl interface reconfigure wan', timeout=180)
        seen = jumbo_observe(t, 'jumbo', expect_ppp='1500', wait=5)
        frames = pppoe_discovery(discovery.peek())
        if seen['ppp0'] != '1500':
            env_set(t.run_dir, 'JUMBO_LINK', 'no-session-at-1500')
            t.check('negotiation', False, 'the session comes up with PPP MTU 1500', 'ppp0 MTU %s; discovery: %s' % (seen['ppp0'] or 'no session', discovery_text(frames)))
            return
        peer = world_session()[1]
        res = W('ping -6 -n -c2 -W2 -M do -s 1452 %s%%ppp0' % peer, timeout=30)
        if ping_counts(res.out)[1] == 0:
            env_set(t.run_dir, 'JUMBO_LINK', 'fail')
            raise Skipped('PLAN section 7 row 17: a 1500-byte IPv6 packet does not cross the private switch; '
                          'T18 to T20 are not runnable on this virtual link')
        env_set(t.run_dir, 'JUMBO_LINK', 'ok')
        t.check('link', True, 'pre-check: a 1500-byte IPv6 packet crosses the private switch', '%d of 2 answered' % ping_counts(res.out)[1])

        def round_(tag):
            seen = jumbo_observe(t, 'jumbo-' + tag, expect_ppp='1500', expect_tun=1500, wait=200)
            if not t.echo_df:
                echo_df(t)
            exchange = last_exchange(pppoe_discovery(discovery.peek()))
            t.check(tag + '-port', seen['port'].endswith(' 1508'), 'the device PPPoE runs on has MTU 1508', '%s; hn1 %s' % (seen['port'], seen['hn1']))
            t.check(tag + '-tags', all(exchange.get(code) == 1500 for code in ('PADI', 'PADO', 'PADR', 'PADS')),
                    'PADI and PADR carry PPP-Max-Payload 1500, PADO and PADS return 1500', exchange or 'no discovery captured')
            t.check(tag + '-ppp', seen['pppoe0'] == '1500' and seen['ppp0'] == '1500', 'pppoe0 and ppp0 MTU 1500', 'pppoe0 %s, ppp0 %s' % (seen['pppoe0'], seen['ppp0']))
            mtu = seen['st'].get('mtu') or {}
            t.check(tag + '-st', (mtu.get('effective'), mtu.get('tun'), mtu.get('ipv4'), mtu.get('mss')) == (1500, 1500, 1480, 1440),
                    'st.mtu: effective 1500, tun 1500, ipv4 1480, mss 1440', json.dumps(mtu))
            flush_cache()
            got, res = c_ping(1, opts='-M probe -s 1452')
            t.frag_check(tag + '-df1', got == 1, 'DF probe of 1480 bytes (-s 1452) is answered', res.lines()[-2:])
            flush_cache()
            _got, res = c_ping(1, opts='-M probe -s 1453')
            t.check(tag + '-df2', frag_error(res.out)[1] == 1480, 'DF probe of 1481 bytes gets "mtu = 1480"', res.lines()[:2])
            _client, ppp, _synack = syn_capture(t, tag)
            t.check(tag + '-mss', bool(ppp) and set(ppp) == {1440}, 'the SYN on ppp0 has MSS 1440', ppp or 'no SYN captured')
            result, tests = plugin_test(t, tag)
            t.frag_check(tag + '-probe', jget(tests, 'mtu.size') == 1480, "the plugin's DF probe reports 1480", jget(tests, 'mtu.detail') or result.get('error') or 'no result')
        round_('first')
        before = o_prefix_mtime()
        W('ispctl session reset')
        wait_session(newer_than=before, timeout=240)
        wait_active(120)
        round_('redial')
    finally:
        discovery.stop()
        if env_get(t.run_dir, 'JUMBO_LINK') != 'ok':
            tidy(jumbo_undo)        # T19 and T20 will not run; with 'ok' they continue from this state


def jumbo_plugin_checks(t, tag, seen, samples, restarts):
    """ The plugin's criterion of T19 and T20: it reports the truth and does not loop or crash. """
    if not t.echo_df:
        echo_df(t)
    result, tests = plugin_test(t, tag)
    size = jget(tests, 'mtu.size')
    mtu = seen['st'].get('mtu') or {}
    t.frag_check(tag + '-probe', isinstance(size, int) and size <= 1472, "the plugin's DF probe reports at most 1472",
                 '%s; st.mtu configured %s, effective %s' % (jget(tests, 'mtu.detail') or result.get('error') or 'no result', mtu.get('configured'), mtu.get('effective')))
    view = tayga_view(samples)
    states = sorted({str(s_state(s)) for s in samples[-60:]})
    t.check(tag + '-stable', states == ['active'] and len(view['pids']) <= 2 and set(view['restarts']) <= {restarts},
            'state stays active, no restart loop (the tayga pid changes at most once), no crash (tayga.restarts unchanged)',
            'states in the last minute %s; %s (before %s)' % (states, tayga_text(view), restarts))


def T19(t):
    """ From T18. Field 1508 against a BNG that does not echo. """
    if env_get(t.run_dir, 'JUMBO_LINK') != 'ok':
        raise Skipped('PLAN section 7 row 17: T18 did not show that the virtual link carries jumbo frames (JUMBO_LINK=%s)' % env_get(t.run_dir, 'JUMBO_LINK'))
    restarts = jget(status_json(), 'tayga.restarts')
    discovery = Capture(t, 'pppoed', 'wan0', 'ether proto 0x8863').start()
    sampler = Sampler(t, 'noecho', 500).start()
    try:
        W('ispctl mtu 1492', timeout=120)
        seen = jumbo_observe(t, 'noecho', expect_ppp='1492', wait=120)
        time.sleep(150)
        seen['st'] = st(t, 'noecho-late')
        samples = sampler.stop()
        exchange = last_exchange(pppoe_discovery(discovery.peek()))
        t.info('recorded: PPP-Max-Payload in PADI (expected 1500) and in PADS (expected none)', exchange or 'no discovery captured')
        t.info('recorded: MTU of ppp0 (expected 1492) and of pppoe0 (expected 1500)', 'ppp0 %s, pppoe0 %s, hn1 %s, PPPoE on %s' % (seen['ppp0'], seen['pppoe0'], seen['hn1'], seen['port']))
        small = O('ping -6 -n -c2 -s 1444 %s 2>&1' % RESOLVER6, timeout=30)
        large = O('ping -6 -n -c2 -s 1452 %s 2>&1' % RESOLVER6, timeout=30)
        t.info('recorded: do 1493 to 1500-byte IPv6 packets from OPNsense vanish without an ICMP error (DESIGN 8.3 defect C)',
               '1492-byte ping6: %d of 2; 1500-byte ping6: %d of 2, output: %s' % (
                   ping_counts(small.out)[1], ping_counts(large.out)[1], ' | '.join(large.lines()[-3:])))
        jumbo_plugin_checks(t, 'noecho', seen, samples, restarts)
    finally:
        sampler.stop()
        discovery.stop()


def T20(t):
    """ From T19. Fields 1518 and 1528, each against a BNG that grants at most 1500. """
    if env_get(t.run_dir, 'JUMBO_LINK') != 'ok':
        raise Skipped('PLAN section 7 row 17: T18 did not show that the virtual link carries jumbo frames (JUMBO_LINK=%s)' % env_get(t.run_dir, 'JUMBO_LINK'))
    try:
        for field in (1518, 1528):
            tag = 'f%d' % field
            restarts = jget(status_json(), 'tayga.restarts')
            discovery = Capture(t, 'pppoed-%d' % field, 'wan0', 'ether proto 0x8863').start()
            sampler = Sampler(t, tag, 500).start()
            try:
                W('ispctl mtu 1500', timeout=120)
                opn_cfg('set', 'interfaces.wan.mtu', str(field))
                O('configctl interface reconfigure wan', timeout=180)
                seen = jumbo_observe(t, tag, expect_ppp='1500', wait=120)
                time.sleep(150)
                seen['st'] = st(t, tag + '-late')
                samples = sampler.stop()
                exchange = last_exchange(pppoe_discovery(discovery.peek()))
                t.info('field %d, recorded: PPP-Max-Payload in PADI (expected %s) and what the BNG returns (expected 1500 or nothing)'
                       % (field, '1510' if field == 1518 else 'no tag = DESIGN 8.3 defect A'), exchange or 'no discovery captured')
                t.info('field %d, recorded: MTU of hn1, pppoe0 and ppp0' % field, 'hn1 %s, pppoe0 %s, ppp0 %s, PPPoE on %s' % (seen['hn1'], seen['pppoe0'], seen['ppp0'], seen['port']))
                jumbo_plugin_checks(t, tag, seen, samples, restarts)
            finally:
                sampler.stop()
                discovery.stop()
        t.info('not shown here', 'DESIGN 8.3 defect B (1501 to 1510 lost at reconnect): the simulator never grants more than 1500')
    finally:
        tidy(jumbo_undo)


def T23(t):
    """ H, optional. Outbound NAT mode manual. """
    try:
        opn_cfg('set', 'nat.outbound.mode', 'advanced')
        O('configctl filter reload', timeout=120)
        reached, seconds, last = wait_status(state_is('blocked', 'nat_mode'), 90 + TOL)
        t.check('blocked', reached, 'outbound NAT mode manual: blocked, reason nat_mode, within 90 s', '%.0f s, %s' % (seconds, sdesc(last)))
        ok, code, answer = clat_set({'manual_nat': '1'})
        reached, seconds, last = wait_active(120)
        time.sleep(5)
        details = st(t, 'manual')
        t.check('manual', ok and reached and details.get('nat_rule') is False and 'NAT rule missing' in str(jget(details, 'text.gateway')),
                'with manual_nat confirmed: active, and the status says the NAT rule is missing',
                '%s; nat_rule %s; "%s"' % (sdesc(last), details.get('nat_rule'), jget(details, 'text.gateway')))
    finally:
        tidy(lambda: opn_cfg('set', 'nat.outbound.mode', 'automatic'), lambda: O('configctl filter reload', timeout=120),
             lambda: clat_set({'manual_nat': '0'}))


def T21(t):
    """ H. Plugin removal, then a second install. """
    res = W('sh %s remove' % INSTALLER, timeout=600)
    t.save('remove.log', res.out)
    time.sleep(10)
    t.check('remove', res.ok, 'install-plugin.sh remove ran to its end', res.last())
    facts = O('ifconfig tun464 >/dev/null 2>&1 && echo TUN=present || echo TUN=absent\n'
              'echo "CLATD=$(pgrep -f clatd.py | wc -l | tr -d " ") TAYGA=$(pgrep -x tayga | wc -l | tr -d " ")"\n'
              'echo "RECORD=$(pluginctl -g interfaces.clat 2>/dev/null | tr -d " \\n")"\n'
              'echo "NODE=$(grep -c "<clat" /conf/config.xml)"\n').out
    record = re.search(r'RECORD=(.*)', facts).group(1).strip() if 'RECORD=' in facts else '?'
    t.check('gone', 'TUN=absent' in facts and 'CLATD=0 TAYGA=0' in facts and record in ('', 'null', '[]', '{}'),
            'after the removal: tun464 does not exist, no clatd, no tayga, interfaces.clat empty', ' '.join(facts.split()))
    sr, sn, _ss, _debug = read_rules(t, 'removed')
    named = [line for line in (sr + sn).splitlines() if 'tun464' in line]
    routes, gateways = o_default4(), o_ipv4_gateways()
    t.check('pf', not named and not routes and gateways is not None and 'CLAT_GW' not in [n for n, _a in gateways],
            'no rule and no NAT line naming tun464, no IPv4 default route, no CLAT_GW',
            'lines naming tun464 %d; routes %s; IPv4 gateways %s' % (len(named), routes or 'none', gateways))
    res = O('ping -6 -n -c2 %s' % RESOLVER6, timeout=30)
    t.check('ipv6', ping_counts(res.out)[1] == 2, 'ping6 to the ISP resolver works', '%d of 2' % ping_counts(res.out)[1])
    left = O("find /usr/local /etc /var/run /var/log /var/db /tmp /conf \\( -name 'clat*' -o -name 'Clat*' -o -name '*_clat*' -o -name 'tun464*' \\) "
             "-prune -print 2>/dev/null | sort", timeout=180).lines()
    expected = ['/etc/rc.conf.d/clat', '/usr/local/etc/clat', '/var/log/clat', '/var/run/clat']
    node = re.search(r'NODE=(\d+)', facts)
    extra = [path for path in left if path not in expected]
    t.check('left', not extra and '/etc/rc.conf.d/clat' in left and '/usr/local/etc/clat' in left and bool(node) and int(node.group(1)) >= 1,
            'left behind are only /etc/rc.conf.d/clat, /usr/local/etc/clat/, /var/run/clat/, /var/log/clat/ and the <clat> node in config.xml',
            'found %s; not on that list: %s; lines with <clat in config.xml: %s' % (left, extra or 'none', node.group(1) if node else '?'))
    res = W('sh %s install' % INSTALLER, timeout=600)
    t.save('install-again.log', res.out)
    reached, seconds, last = wait_active(60 + TOL)
    t.check('again', res.ok and reached, 'after the second install: active within 60 s', 'install exit %d; %.0f s, %s' % (res.rc, seconds, sdesc(last)))


def T25(t):
    """ S, by hand. Record drift: somebody saves and applies the CLAT entry in Interfaces > Assignments. """
    def record():
        return first_json(O('pluginctl -g interfaces.clat', quiet=True).out)

    def drifted(rec):
        return bool(rec) and ('internal_dynamic' not in rec or rec.get('type') != 'none' or rec.get('ipaddr') == 'none')
    print('ACTION NEEDED (T25): run "bash lab.sh gui" on the host, open https://127.0.0.1:8443, go to Interfaces > Assignments,\n'
          'save and apply the CLAT entry, and look at Services > CLAT. Waiting up to 20 minutes for the edit.', flush=True)
    t.save('record-before.json', json.dumps(record(), indent=1))
    start = time.time()
    edited = None
    while time.time() - start < 1200:
        rec = record()
        if drifted(rec):
            edited = time.time()
            t.save('record-drifted.json', json.dumps(rec, indent=1))
            break
        time.sleep(3)
    if edited is None:
        raise Skipped('by hand: no edit of the CLAT interface record was seen within 20 minutes')
    t.info('the edit was seen', 'record: %s' % json.dumps(rec))
    healed = None
    while time.time() - edited < 300 + TOL:
        rec = record()
        if rec and not drifted(rec):
            healed = time.time()
            break
        time.sleep(3)
    reached, seconds, last = wait_active(max(5, 300 - (time.time() - edited)))
    gateways = o_ipv4_gateways()
    t.save('record-after.json', json.dumps(record(), indent=1))
    t.check('healed', healed is not None, 'within 5 minutes the supervisor has run the registration again (type and internal_dynamic back, ipaddr not "none")',
            '%.0f s after the edit' % (healed - edited) if healed else 'record still: %s' % json.dumps(rec))
    t.check('state', reached and gateways is not None and 'CLAT_GW' in [n for n, _a in gateways], 'the gateway is named CLAT_GW and the state is active',
            '%s; IPv4 gateways %s' % (sdesc(last), gateways))
    t.info('clat log', ' | '.join(O('cat /var/log/clat/clat_*.log | tail -n 8').lines()))


# ---- the production profile (lab README section 13) -------------------------------------------------------

def need_prod():
    if PROFILE != 'prod':
        raise Skipped('written for the production profile; this run is --profile %s' % PROFILE)


def dns_question(l4):
    """ (name, type number) of the question of a DNS query in a UDP datagram; None for anything else. """
    message = l4[8:]
    if len(message) < 17 or message[2] & 0x80 or int.from_bytes(message[4:6], 'big') < 1:
        return None
    labels, pos = [], 12
    while pos < len(message) and message[pos]:
        length = message[pos]
        if length > 63 or pos + 1 + length > len(message):
            return None
        labels.append(message[pos + 1:pos + 1 + length].decode('ascii', 'replace'))
        pos += 1 + length
    if pos + 5 > len(message):
        return None
    return '.'.join(labels).lower() + '.', int.from_bytes(message[pos + 1:pos + 3], 'big')


def dns_queries(packets):
    """ [(time, name, type number)] of the DNS queries (UDP, port 53) in a capture. """
    found = []
    for moment, ip in ip_packets(packets):
        if ip['proto'] == 17 and ip['first'] and len(ip['l4']) >= 8 and int.from_bytes(ip['l4'][2:4], 'big') == 53:
            question = dns_question(ip['l4'])
            if question:
                found.append((moment,) + question)
    return found


def dhcp_option(l4, code):
    """ The value of one option in a DHCPv4 message carried in a UDP datagram; None when it is not there. """
    options = l4[8 + 240:]
    if l4[8 + 236:8 + 240] != bytes((99, 130, 83, 99)):
        return None
    pos = 0
    while pos < len(options) and options[pos] != 255:
        if options[pos] == 0:
            pos += 1
            continue
        if pos + 2 > len(options):
            break
        if options[pos] == code:
            return options[pos + 2:pos + 2 + options[pos + 1]]
        pos += 2 + options[pos + 1]
    return None


def all_active(samples, start, end):
    """ (True when every sample between the two times is 'active', text) """
    window = [s for s in samples if start <= s['tl'] <= end]
    other = [s for s in window if s_state(s) != 'active']
    return bool(window) and not other, '%d of %d samples not active%s' % (
        len(other), len(window), ': first %s at %s' % (s_state(other[0]), stamp(other[0]['tl'])) if other else '')


def longest_gap(replies, start, end):
    """ The longest time without a ping reply between the two times, in seconds. """
    marks = [start] + [r for r in replies if start <= r <= end] + [end]
    return max(b - a for a, b in zip(marks, marks[1:]))


def T26(t):
    """ S, production profile. What a subscriber has after the steps of the page and the install of the plugin. """
    need_prod()
    details = st(t, 'active')
    pref = details.get('pref64') or {}
    t.check('1', details.get('state') == 'active' and pref.get('prefix') == WKP and pref.get('source') == 'dns',
            'state active, 64:ff9b::/96 learned from DNS (the RA carries no PREF64)', '%s; %s' % (details.get('state'), json.dumps(pref)))
    clat6 = jget(details, 'address.clat6', '')
    try:
        placed = ipaddress.IPv6Address(clat6) in ipaddress.ip_network(P['clat64'])
    except ValueError:
        placed = False
    t.check('2', placed, 'the CLAT address is in the highest /64 of the delegated /56 (%s)' % P['clat64'], clat6)
    routes, gateways = o_default4(), o_ipv4_gateways()
    t.check('3', routes == [(TAYGA_IPV4, 'tun464')] and gateways is not None and [name for name, _a in gateways] == ['CLAT_GW'],
            'one IPv4 default route, 192.0.0.2 on tun464, and one IPv4 gateway, CLAT_GW', '%s; %s' % (routes, gateways))
    sr, sn, _ss, debug = read_rules(t, 'active')
    nat = [line for line in sn.splitlines() if line.startswith('nat on tun464 inet from (hn0:network) to any -> (tun464:0)')]
    passes = [line for line in sr.splitlines() if CLAT_RULE.match(line)]
    t.check('4', len(nat) == 1 and len(passes) == 1, 'one outbound NAT line for the LAN on tun464 and one pass rule for translated IPv6',
            '%s; %s' % (nat or 'no NAT line', passes or 'no pass rule'))
    mtu = details.get('mtu') or {}
    tun = O('ifconfig tun464 | head -n 1').out
    mss = scrub_mss(sr) or scrub_mss(debug)
    t.check('5', (mtu.get('effective'), mtu.get('ipv4'), mtu.get('mss')) == P['mtu'] and ' mtu %d' % P['mtu'][0] in tun and mss == [P['mtu'][2]],
            'WAN MTU field 1508: PPP MTU %d, translated IPv4 MTU %d, MSS %d; tun464 has that MTU and pf clamps to that MSS' % P['mtu'],
            'st.mtu %s; %s; max-mss %s' % (json.dumps(mtu), tun.strip()[-12:], mss))
    client_syn, ppp_syn, client_synack = syn_capture(t, 'prod')
    t.check('6', bool(ppp_syn) and set(ppp_syn) == {P['mtu'][2]} and bool(client_synack) and set(client_synack) == {P['mtu'][2]},
            'TCP: the SYN on ppp0 (IPv6) and the SYN-ACK reaching the client carry MSS %d' % P['mtu'][2],
            'client SYN %s, SYN on ppp0 %s, SYN-ACK at the client %s' % (client_syn, ppp_syn, client_synack))
    fragment_pair(t)
    echo_df(t)
    flush_cache()
    got, res = c_ping(1, opts='-M probe -s %d' % (P['mtu'][1] - 28))
    t.frag_check('7a', got == 1, 'DF probe of %d bytes is answered' % P['mtu'][1], res.lines()[-2:] or 'no output')
    flush_cache()
    _got, res = c_ping(1, opts='-M probe -s %d' % (P['mtu'][1] - 27))
    t.check('7b', frag_error(res.out) == (TAYGA_IPV4, P['mtu'][1]),
            'DF probe of %d bytes gets "Frag needed and DF set (mtu = %d)" from 192.0.0.2' % (P['mtu'][1] + 1, P['mtu'][1]), res.lines()[:2])
    client_checks(t, '8-')
    resolver = C('cat /etc/resolv.conf').out.split()
    answer = C('dig +short +time=3 +tries=2 %s A' % NAME4).out.split()
    got = C("curl -sS -o /dev/null -m 20 -w '%{http_code} %{remote_ip}' http://" + NAME4 + "/").last()
    t.check('9', resolver == ['nameserver', '192.168.1.1'] and answer == [TARGET] and got == '200 %s' % TARGET,
            'client by name: its DNS server is 192.168.1.1 (from DHCP), the name resolves to its A record, HTTP 200 from 192.88.99.1',
            'resolv.conf %s; A %s; curl %s' % (' '.join(resolver), answer, got))
    res = O('ping -n -c3 -t 10 %s' % TARGET, timeout=40)
    own4 = O("curl -4 -sS -o /dev/null -m 20 -w '%{http_code} %{remote_ip} from %{local_ip}' http://" + TARGET + "/").last()
    t.check('10', ping_counts(res.out) == (3, 3) and own4.startswith('200 %s' % TARGET),
            "the firewall's own IPv4: ping 3 of 3 and HTTP 200 by literal address", 'ping %d of %d; curl %s' % (ping_counts(res.out)[::-1] + (own4,)))
    own_name = O("curl -sS -o /dev/null -m 20 -w '%{http_code} %{remote_ip}' http://" + NAME4 + "/").last()
    own_aaaa = O('drill %s AAAA @127.0.0.1' % NAME4, timeout=40).out
    t.check('11', own_name in ('200 ' + TARGET6, '200 ' + TARGET) and TARGET6 in own_aaaa,
            'the firewall by name: Unbound answers the IPv4-only name with the AAAA of the DNS64, HTTP 200',
            'curl %s; AAAA %s' % (own_name, re.findall(r'IN\s+AAAA\s+(\S+)', own_aaaa)))
    only = opn_cfg('get', 'interfaces.wan.dhcp6prefixonly')
    wan = [a for a in re.findall(r'inet6 (\S+) prefixlen 64 autoconf', O('ifconfig pppoe0').out) if same_net(a + '/64', P['wan64'])]
    lan = [a for a in re.findall(r'inet6 (\S+)', O('ifconfig hn0').out)
           if not a.lower().startswith('fe80') and ipaddress.IPv6Address(a) in ipaddress.ip_network(PD_DEFAULT)]
    t.check('12', only == 'value "1"' and bool(wan) and bool(lan),
            'with "Request prefix only" ticked the WAN has its SLAAC address in %s and the LAN an address of the /56' % P['wan64'],
            'dhcp6prefixonly %s; pppoe0 %s; hn0 %s' % (only, wan or 'none', lan or 'none'))
    result, tests = plugin_test(t, 'prod')
    t.check('13a', jget(tests, 'plat.ok') is True and jget(tests, 'path.ok') is True, "the plugin's own tests: the first two are ok",
            result.get('text') or result.get('error') or 'no JSON')
    t.frag_check('13b', jget(tests, 'mtu.ok') is True and jget(tests, 'mtu.size') == P['mtu'][1], 'the size test is ok with %d' % P['mtu'][1],
                 jget(tests, 'mtu.detail') or 'no result')


def unbound_answers():
    """ True when Unbound on clat-opn gets an answer from its forwarders, asked for a name it cannot have cached. """
    res = O('drill probe-%d.clat.lab A @127.0.0.1 | grep rcode' % int(time.time() * 10), timeout=40, quiet=True)
    return bool(re.search(r'rcode: (NOERROR|NXDOMAIN)', res.out))


def wait_unbound(timeout):
    """ (answered, seconds until then): asks every 5 s, as LAN clients would go on asking. """
    start = time.time()
    while time.time() - start < timeout:
        if unbound_answers():
            return True, time.time() - start
        time.sleep(5)
    return False, time.time() - start


def T27(t):
    """ S, production profile. The DNS64 resolver answers nothing for 10 minutes, then again; a start during an outage; Unbound restarts. """
    need_prod()
    before = status_json()
    restarts, clat6 = jget(before, 'tayga.restarts'), jget(before, 'plan.clat6')
    try:
        # (a) ten minutes without an answer, the CLAT running
        sampler = Sampler(t, 'a', 1900, interval=2).start()
        ping = PingLog(t, 'a', interval='1').start()
        capture = Capture(t, 'dns-a', 'ppp0', 'ip6 and udp dst port 53').start()
        time.sleep(10)
        t_off = time.time()
        W('ispctl resolver off')
        time.sleep(150)
        st(t, 'a-150s')
        client_name = C('dig +time=3 +tries=1 %s A' % NAME4, timeout=30).out
        own_name = O('drill %s AAAA @127.0.0.1' % NAME4, timeout=60).out
        got_mid = c_download()
        time.sleep(max(0, 600 - (time.time() - t_off)))
        late = st(t, 'a-600s')
        t_on = time.time()
        W('ispctl resolver on')
        back, waited = wait_unbound(960)
        time.sleep(75)          # one refresh of the prefix by the plugin lies in here
        t_end = time.time()
        samples = sampler.stop()
        replies = ping.stop()
        queries = dns_queries(capture.stop())
        good, text = all_active(samples, t_off, t_end - 5)
        end = status_json()
        t.check('a1', good and jget(late, 'pref64.source') == 'dns' and jget(late, 'address.clat6') == clat6 and jget(end, 'plan.clat6') == clat6,
                'the CLAT stays active for the 10 minutes and after them, with the prefix it had (source dns, same clat6)',
                '%s; at 600 s: %s, clat6 %s (before %s)' % (text, sdesc(late), jget(late, 'address.clat6'), clat6))
        same, text = tayga_not_restarted(samples)
        gap = longest_gap(replies, t_off, t_end - 5)
        t.check('a2', same and gap <= 3 + TOL and got_mid == '200 104857600',
                'client IPv4 by literal address goes on: tayga not restarted, no ping gap above 3 s, 100 MB download during the outage',
                '%s; longest gap %.1f s; download %s' % (text, gap, got_mid))
        status = re.search(r'status: (\w+)|(timed out|no servers could be reached)', client_name)
        t.info('what a LAN client gets for a name during the outage (150 s in, dig with a 3 s time-out)',
               (status.group(1) or status.group(2)) if status else client_name.strip()[-80:])
        t.info('what the firewall gets for a name during the outage', (re.findall(r'rcode: (\w+)', own_name) or [own_name.strip()[-80:]])[0])
        asked = [m for m, name, kind in queries if name == 'ipv4only.arpa.' and kind == 28 and t_off <= m <= t_on]
        t.info('ipv4only.arpa AAAA queries leaving on ppp0 during the 10 minutes (Unbound, for the plugin)',
               '%d; at %s s after the start' % (len(asked), [int(m - t_off) for m in asked][:40]))
        t.info('all DNS queries leaving on ppp0 during the 10 minutes', '%d (%.1f per minute)' % (
            sum(1 for m, _n, _k in queries if t_off <= m <= t_on), sum(1 for m, _n, _k in queries if t_off <= m <= t_on) / 10.0))
        after_on = [int(m - t_on) for m, _n, _k in queries if m > t_on]
        t.check('a3', back, 'names resolve again on the firewall, and so for the LAN, within 16 minutes of the resolver being back '
                            '(Unbound keeps a silent forwarder marked as down for up to 900 s)',
                '%.0f s after the resolver was back; first queries on ppp0 after that moment at %s s' % (waited, after_on[:6])
                if back else 'no answer in %.0f s' % waited)
        if back and waited > 60:
            t.info('FINDING', 'with OPNsense\'s defaults ("Keep probing down hosts" cleared, host cache TTL 900 s) Unbound went on '
                              'answering SERVFAIL for %.0f s after its forwarders answered again; the CLAT itself stayed active' % waited)

        # (b) the box boots while the resolver is silent: Unbound and the service start without an answer
        W('ispctl resolver off')
        sampler = Sampler(t, 'b', 1500).start()
        O('configctl unbound restart', timeout=120)
        O('configctl clat restart', timeout=120)
        time.sleep(40)
        down = st(t, 'b-down')
        routes = o_default4()
        got_down, _res = c_ping(2)
        t.check('b1', down.get('state') not in ('active', None) and not routes and got_down == 0,
                'started without an answer from DNS: not active, no IPv4 default route, client pings unanswered',
                '%s "%s"; default routes %s; ping %d of 2' % (sdesc(down), down.get('message'), routes or 'none', got_down))
        W('ispctl resolver on')
        back, waited = wait_unbound(960)
        reached, seconds, last = wait_status(state_is('active', source='dns'), 320)
        time.sleep(3)
        sampler.stop()
        got_up, _res = c_ping(3)
        t.check('b2', back and reached and seconds <= 300 + TOL and got_up == 3,
                'active by DNS no later than 300 s after Unbound answers again (the plugin asks again after 10, 30 and 60 s, then every 300 s)',
                'Unbound answered %.0f s after the resolver was back; active %.0f s after that, %s; ping %d of 3' % (
                    waited, seconds, sdesc(last), got_up))

        # (c) Unbound restarts while the CLAT runs
        wait_active(330)
        base = jget(status_json(), 'tayga.restarts')
        sampler = Sampler(t, 'c', 200).start()
        ping = PingLog(t, 'c', interval='0.5').start()
        time.sleep(5)
        t_restart = time.time()
        res = O('configctl unbound restart', timeout=120)
        time.sleep(75)          # one refresh of the prefix by the plugin lies in here
        samples = sampler.stop()
        replies = ping.stop()
        good, text = all_active(samples, t_restart, t_restart + 70)
        same, text2 = tayga_not_restarted(samples)
        gap = longest_gap(replies, t_restart, t_restart + 70)
        after = status_json()
        t.check('c', res.ok and good and same and gap <= 2 + TOL and jget(after, 'tayga.restarts') == base and jget(after, 'pref64.source') == 'dns',
                'an Unbound restart leaves the CLAT as it is: active throughout, tayga not restarted, no ping gap above 2 s',
                '%s; %s; longest gap %.1f s; %s' % (text, text2, gap, sdesc(after)))
    finally:
        tidy(lambda: W('ispctl resolver on'))
    t.check('restarts', jget(status_json(), 'tayga.restarts') in (restarts, 0), 'no tayga crash in the whole test',
            'tayga.restarts %s before, %s now (0 after the restart of part b)' % (restarts, jget(status_json(), 'tayga.restarts')))


def T28(t):
    """ S, production profile. 15 minutes without client traffic: what the box sends by itself. """
    need_prod()
    before = status_json()
    cpu = lambda: O("ps -ax -o time= -o comm= | awk '$2==\"tayga\" || $2 ~ /^python/'", quiet=True).out.split()
    cpu_before = cpu()
    capture = Capture(t, 'idle', 'ppp0',
                      '(icmp6 and (ip6[40] == 133 or ip6[40] == 134)) or (ip6 and udp dst port 53) or (ip6 and dst net %s)' % WKP).start()
    client = Capture(t, 'idle-lan', 'lan0', 'ip and not port 67 and not port 68', netns=True).start()
    sampler = Sampler(t, 'idle', 960, interval=5).start()
    t_start = time.time()
    time.sleep(900)
    t_end = time.time()
    packets, from_client, samples = capture.stop(), client.stop(), sampler.stop()
    cpu_after = cpu()
    minutes = (t_end - t_start) / 60.0
    good, text = all_active(samples, t_start, t_end)
    same, text2 = tayga_not_restarted(samples)
    t.check('state', good and same and jget(status_json(), 'tayga.restarts') == jget(before, 'tayga.restarts'),
            'active for the 15 minutes, tayga not restarted', '%s; %s' % (text, text2))
    sent_by_client = [ip for _m, ip in ip_packets(from_client) if ip['src'].startswith('192.168.1.') and ip['src'] != '192.168.1.1']
    t.check('idle', not sent_by_client, 'the client sent no IPv4 packet in that time (the box was idle)', '%d packets' % len(sent_by_client))
    messages = router_messages(packets)
    solicits = [m for _moment, m in messages if m['type'] == 133]
    adverts = [m for _moment, m in messages if m['type'] == 134]
    t.check('rs', not solicits, 'no Router Solicitation from OPNsense in 15 minutes',
            '%d RS; %d RA from the ISP (its interval is 600 s at most)' % (len(solicits), len(adverts)))
    queries = dns_queries(packets)
    names = {}
    for _moment, name, kind in queries:
        names[(name, kind)] = names.get((name, kind), 0) + 1
    discovery = names.get(('ipv4only.arpa.', 28), 0)
    t.check('dns', discovery <= minutes + 2,
            'ipv4only.arpa AAAA leaves on ppp0 at most once a minute (the lab answers it with TTL 60; the plugin never asks more often)',
            '%d queries in %.1f minutes' % (discovery, minutes))
    t.info('all DNS queries on ppp0', '%d in %.1f minutes (%.1f per minute); by name and type: %s' % (
        len(queries), minutes, len(queries) / minutes,
        ', '.join('%s/%d x%d' % (name, kind, count) for (name, kind), count in sorted(names.items(), key=lambda item: -item[1])[:10])))
    translated = {}
    for _moment, ip in ip_packets(packets):
        try:
            if ip['v'] == 6 and ipaddress.IPv6Address(ip['dst']) in ipaddress.ip_network(WKP):
                key = (ip['src'], ip['dst'], ip['proto'])
                translated[key] = translated.get(key, 0) + 1
        except ValueError:
            pass
    t.info('packets to the NAT64 prefix on ppp0 while idle (the firewall\'s own traffic)',
           '; '.join('%s > %s proto %d x%d' % (key + (count,)) for key, count in sorted(translated.items(), key=lambda item: -item[1])[:8]) or 'none')
    t.info('CPU time of tayga and the daemon, before and after', '%s -> %s' % (' '.join(cpu_before), ' '.join(cpu_after)))


def T29(t):
    """ S, production profile. PREF64 and option 108 on the LAN (the page's "Devices translate") together with the plugin. """
    need_prod()
    before = status_json()
    clat6 = jget(before, 'plan.clat6')
    made = {}
    code, ranges = api('GET', '/api/dnsmasq/settings/search_range')
    lan_range = [row for row in (ranges.get('rows', []) if isinstance(ranges, dict) else []) if row.get('constructor') == 'lan']
    if len(lan_range) != 1:
        raise Invalid('Dnsmasq has %d DHCP ranges with Constructor LAN, the factory configuration has one' % len(lan_range))
    made['range'], made['ra_mode'] = lan_range[0]['uuid'], lan_range[0].get('ra_mode', '')

    def lan_adverts(name, seconds):
        capture = Capture(t, name, 'lan0', 'icmp6 and ip6[40] == 134', netns=True).start()
        W('ispctl client6 off; ispctl client6 on')      # a new Router Solicitation from the client
        time.sleep(seconds)
        return [m for _moment, m in router_messages(capture.stop()) if m['type'] == 134]
    try:
        # the three optional steps of the page as it words them, through the API the GUI pages use
        ok_ra, _code, _answer = api_set('/api/dnsmasq/settings/set', {'dnsmasq': {'dhcp': {'enable_ra': '0'}}})
        api('POST', '/api/dnsmasq/service/reconfigure', timeout=120)
        code, answer = api('POST', '/api/radvd/settings/add_entry',
                           {'entries': {'enabled': '1', 'interface': 'lan', 'mode': 'unmanaged', 'nat64prefix': WKP}})
        made['entry'] = answer.get('uuid') if isinstance(answer, dict) else None
        api('POST', '/api/radvd/service/reconfigure', timeout=120)
        code2, answer2 = api('POST', '/api/dnsmasq/settings/add_option',
                             {'option': {'type': 'set', 'option': '108', 'interface': 'lan', 'value': '1800', 'force': '0'}})
        made['option'] = answer2.get('uuid') if isinstance(answer2, dict) else None
        api('POST', '/api/dnsmasq/service/reconfigure', timeout=120)
        t.check('steps', ok_ra and bool(made['entry']) and bool(made['option']),
                'the three steps are accepted: Router advertisements cleared in Dnsmasq, a Router Advertisements entry for LAN '
                '(Unmanaged, NAT64 prefix 64:ff9b::/96), DHCP option ipv6-only [108] = 1800',
                'enable_ra saved %s; entry %s; option %s' % (ok_ra, json.dumps(answer)[:120], json.dumps(answer2)[:120]))
        time.sleep(8)
        processes = O('pgrep -lf "radvd|dnsmasq" | cut -c1-90').lines()

        # Dnsmasq goes on advertising for a range whose RA mode is set, whatever its general switch says
        adverts = lan_adverts('lan-ra-as-worded', 30)
        bare = [m for m in adverts if not m['pref64']]
        if bare:
            t.info('FINDING', 'with the steps as the page words them and the factory range (RA mode %s) two daemons advertise on the '
                              'LAN: %d of %d RA in 30 s carry no PREF64 (options %s; with PREF64: %s)' % (
                                  made['ra_mode'] or 'empty', len(bare), len(adverts), sorted({str(m['options']) for m in bare}),
                                  sorted({str(m['options']) for m in adverts if m['pref64']})))
        ok_mode, _code, _answer = api_set('/api/dnsmasq/settings/set_range/%s' % made['range'], {'range': {'ra_mode': ''}})
        api('POST', '/api/dnsmasq/service/reconfigure', timeout=120)
        t.check('ra-mode', ok_mode, 'the RA mode of the LAN range with Constructor LAN is cleared (DHCP ranges), so that only radvd advertises',
                'saved %s; it was "%s"' % (ok_mode, made['ra_mode']))
        time.sleep(5)

        # what a device on the LAN is offered
        dhcp_capture = Capture(t, 'lan-dhcp', 'lan0', 'udp and src port 67', netns=True).start()
        C('busybox udhcpc -i lan0 -f -n -q -t 4 -O 108 -s /bin/true', timeout=40)
        adverts = lan_adverts('lan-ra', 40)
        offered = [dhcp_option(ip['l4'], 108) for _moment, ip in ip_packets(dhcp_capture.stop()) if ip['proto'] == 17]
        offered = [int.from_bytes(value, 'big') for value in offered if value]
        t.check('ra', bool(adverts) and all(any(prefix == WKP for _life, prefix in m['pref64']) for m in adverts),
                'every RA on the LAN carries PREF64 64:ff9b::/96 (option 38)',
                '%d RA; PREF64 %s; options %s' % (len(adverts), sorted({str(m['pref64']) for m in adverts}), sorted({str(m['options']) for m in adverts})))
        t.check('108', bool(offered) and set(offered) == {1800}, 'the DHCPv4 answers to a client that asks for option 108 carry it with 1800 s',
                offered or 'option 108 in no answer')
        t.info('RA and DHCP daemons on the box', processes)

        # the plugin is not confused by the PREF64 its own box announces on the LAN
        time.sleep(20)
        after = status_json()
        same, text = (jget(after, 'tayga.restarts') == jget(before, 'tayga.restarts'), 'tayga.restarts %s -> %s' % (
            jget(before, 'tayga.restarts'), jget(after, 'tayga.restarts')))
        t.check('plugin', state_is('active', source='dns')(after) and jget(after, 'plan.clat6') == clat6 and same
                and jget(after, 'pref64.lifetime') is None,
                'the plugin is as before: active, prefix by DNS without a lifetime, same clat6, tayga not restarted',
                '%s; clat6 %s; %s' % (sdesc(after), jget(after, 'plan.clat6'), text))

        # both ways at once: the router translates for the IPv4-only side, a device with its own CLAT sends IPv6 to the prefix
        own = [a for a in re.findall(r'inet6 (\S+)/64 scope global', C('ip -6 addr show dev lan0').out)]
        capture = Capture(t, 'both', 'ppp0', 'ip6 and dst host %s' % TARGET6).start()
        got4, _res = c_ping(3)
        res6 = C('ping -6 -n -c3 -W2 %s' % TARGET6, timeout=30)
        sources = sorted({ip['src'] for _moment, ip in ip_packets(capture.stop())})
        t.check('both', got4 == 3 and ping_counts(res6.out) == (3, 3) and clat6 in sources and bool(set(own) & set(sources)) and len(sources) == 2,
                'IPv4 through the router\'s CLAT and IPv6 straight to the NAT64 prefix both work; on ppp0 the first has the CLAT address '
                'as its source, the second the device\'s own address',
                'IPv4 ping %d of 3; IPv6 ping %d of %d; sources on ppp0 %s (clat6 %s, device %s)' % (
                    (got4,) + ping_counts(res6.out)[::-1] + (sources, clat6, own)))
        got = C("curl -sS -o /dev/null -m 20 -w '%{http_code} %{remote_ip}' http://" + NAME4 + "/").last()
        t.check('name', got == '200 %s' % TARGET6, 'the IPv6 device opens the IPv4-only name through DNS64 and NAT64', got)
    finally:
        steps = [lambda: W('ispctl client6 off'),
                 lambda: api_set('/api/dnsmasq/settings/set_range/%s' % made['range'], {'range': {'ra_mode': made['ra_mode']}})]
        if made.get('option'):
            steps.append(lambda: api('POST', '/api/dnsmasq/settings/del_option/%s' % made['option']))
        if made.get('entry'):
            steps.append(lambda: api('POST', '/api/radvd/settings/del_entry/%s' % made['entry']))
        steps += [lambda: api_set('/api/dnsmasq/settings/set', {'dnsmasq': {'dhcp': {'enable_ra': '1'}}}),
                  lambda: api('POST', '/api/radvd/service/reconfigure', timeout=120),
                  lambda: api('POST', '/api/dnsmasq/service/reconfigure', timeout=120)]
        tidy(*steps)


TESTS = {'T00': T00, 'T01': T01, 'T02': T02, 'T03': T03, 'T03b': T03b, 'T04': T04, 'T22': T22, 'T05': T05, 'T06': T06, 'T07': T07,
         'T08': T08, 'T09': T09, 'T10': T10, 'T11': T11, 'T13': T13, 'T14': T14, 'T15': T15, 'T24': T24, 'T12': T12,
         'T16': T16, 'T17': T17, 'T18': T18, 'T19': T19, 'T20': T20, 'T23': T23, 'T21': T21, 'T25': T25,
         'T26': T26, 'T27': T27, 'T28': T28, 'T29': T29}


# ---- self-test of the parsers (no lab needed) -------------------------------------------------------------

def selftest():
    import tempfile
    failures = []

    def expect(name, got, want):
        if got != want:
            failures.append('%s: got %r, want %r' % (name, got, want))

    # pcap: an RA with PREF64 on a cooked (ppp0) capture, a SYN with MSS on Ethernet, PPPoE discovery
    def ip6(src, dst, nxt, payload, hlim=255):
        return (b'\x60\0\0\0' + struct.pack('!HBB', len(payload), nxt, hlim) + ipaddress.IPv6Address(src).packed
                + ipaddress.IPv6Address(dst).packed + payload)
    pref64 = bytes([38, 2]) + struct.pack('!H', (8 << 3) | 0) + ipaddress.IPv6Address('64:ff9b::').packed[:12]
    rdnss = bytes([25, 3, 0, 0]) + struct.pack('!I', 1800) + ipaddress.IPv6Address(RESOLVER6).packed
    ra = bytes([134, 0, 0, 0, 64, 0x40]) + struct.pack('!HII', 1800, 0, 0) + rdnss + pref64
    rs = bytes([133, 0, 0, 0, 0, 0, 0, 0])
    sll = b'\0\0' + b'\x02\x00' + b'\0\0' + b'\0' * 8
    syn = struct.pack('!HHIIBBHHH', 40000, 80, 1, 0, 0x60, 0x02, 65535, 0, 0) + bytes([2, 4]) + struct.pack('!H', 1432)
    ether = lambda proto: b'\x02\xc1\xa7\x00\x01\x03' + b'\x02\xc1\xa7\x00\x02\x02' + struct.pack('!H', proto)
    ip4 = (bytes([0x45, 0]) + struct.pack('!HHHBBH', 44, 1, 0x4000, 64, 6, 0) + ipaddress.IPv4Address('192.168.1.100').packed
           + ipaddress.IPv4Address(TARGET).packed + syn[:20] + bytes([2, 4]) + struct.pack('!H', 1460))
    padi = bytes([0x11, 0x09, 0, 0]) + struct.pack('!H', 10) + struct.pack('!HH', 0x0101, 0) + struct.pack('!HHH', 0x0120, 2, 1500)
    pads = bytes([0x11, 0x65, 0, 7]) + struct.pack('!H', 4) + struct.pack('!HH', 0x0101, 0)
    with tempfile.TemporaryDirectory() as tmp:
        def write(name, linktype, frames):
            path = os.path.join(tmp, name)
            with open(path, 'wb') as handle:
                handle.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 262144, linktype))
                for index, frame in enumerate(frames):
                    handle.write(struct.pack('<IIII', 1000 + index, 500000, len(frame), len(frame)) + frame)
                handle.write(b'\x01\x02\x03')           # a cut-off record, as while tcpdump still writes
            return path
        cooked = write('ppp.pcap', 113, [sll + b'\x86\xdd' + ip6('fe80::2', 'ff02::2', 58, rs),
                                         sll + b'\x86\xdd' + ip6('fe80::1', 'fe80::2', 58, ra),
                                         sll + b'\x86\xdd' + ip6('2001:db8:56ff::a:2', TARGET6, 6, syn)])
        messages = router_messages(read_pcap(cooked))
        expect('rs/ra types', [m['type'] for _t, m in messages], [133, 134])
        expect('ra pref64', messages[1][1]['pref64'], [(64, '64:ff9b::/96')])
        expect('ra dst', messages[1][1]['dst'], 'fe80::2')
        expect('ra time', messages[1][0], 1001.5)
        expect('syn mss v6', syn_mss(read_pcap(cooked), 6, dst=TARGET6), [1432])
        wired = write('eth.pcap', 1, [ether(0x0800) + ip4, ether(0x8863) + padi, ether(0x8863) + pads])
        expect('syn mss v4', syn_mss(read_pcap(wired), 4, src=lambda a: a.startswith('192.168.1.')), [1460])
        frames = pppoe_discovery(read_pcap(wired))
        expect('pppoe', [(code, payload) for _t, code, payload, _mac in frames], [('PADI', 1500), ('PADS', None)])
        expect('pppoe mac', frames[0][3], '02:c1:a7:00:02:02')
        expect('exchange', last_exchange(frames), {'PADI': 1500, 'PADS': None})
    frag = ip6('2001:db8::1', '2001:db8::2', 44, bytes([17, 0, 0, 1, 0, 0, 0, 1]) + struct.pack('!HHHH', 5000, 5201, 1453, 0))
    parsed = parse_ip(0x86dd, frag)
    expect('fragment', (parsed['proto'], parsed['frag'], parsed['first'], int.from_bytes(parsed['l4'][4:6], 'big')), (17, True, True, 1453))

    # ping, drill, netstat, ps
    expect('ping linux', ping_counts('3 packets transmitted, 2 received, 33% packet loss, time 2003ms'), (3, 2))
    expect('ping errors', ping_counts('2 packets transmitted, 0 received, +2 errors, 100% packet loss'), (2, 0))
    expect('ping freebsd', ping_counts('3 packets transmitted, 3 packets received, 0.0% packet loss'), (3, 3))
    expect('frag needed', frag_error('From 192.0.0.2 icmp_seq=1 Frag needed and DF set (mtu = 1472)'), ('192.0.0.2', 1472))
    drill = (';; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 4711\n;; QUESTION SECTION:\n;; ipv4only.arpa.\tIN\tAAAA\n\n'
             ';; ANSWER SECTION:\nipv4only.arpa.\t60\tIN\tAAAA\t64:ff9b::c000:aa\nipv4only.arpa.\t60\tIN\tAAAA\t64:ff9b::c000:ab\n')
    expect('drill', parse_drill(drill), ('NOERROR', ['64:ff9b::c000:aa', '64:ff9b::c000:ab']))
    expect('drill servfail', parse_drill(';; ->>HEADER<<- opcode: QUERY, rcode: SERVFAIL, id: 1\n'), ('SERVFAIL', []))
    netstat = ('icmp6:\n\t0 calls to icmp6_error\n\tOutput histogram:\n\t\trouter advertisement: 12\n'
               '\t3 messages with bad code fields\n\tInput histogram:\n\t\techo: 4\n\t\trouter advertisement: 7\n\tHistogram of error messages:\n')
    expect('icmp6 counter', icmp6_ra_input(netstat), 7)
    expect('ps time', (ps_seconds('0:01.23'), ps_seconds('1:02:03.50'), ps_seconds('')), (1.23, 3723.5, None))

    # pf listings
    states = parse_states(
        'all tcp 192.88.99.1:80 <- 192.168.1.100:43210       ESTABLISHED:ESTABLISHED\n'
        '   age 00:00:05, expires in 23:59:59, 100:200 pkts, 5200:300000 bytes, rule 80\n   id: 01 creatorid: 02\n   origif: hn0\n'
        'all tcp 192.0.0.1:51234 (192.168.1.100:43210) -> 192.88.99.1:80       ESTABLISHED:ESTABLISHED\n   origif: tun464\n'
        'all tcp 64:ff9b::c058:6301[80] <- 2001:db8:56ff::a1b2:c3d4[51234]       ESTABLISHED:ESTABLISHED\n   origif: tun464\n'
        'all tcp 2001:db8:56ff::a1b2:c3d4[51234] -> 64:ff9b::c058:6301[80]       ESTABLISHED:ESTABLISHED\n   origif: pppoe0\n'
        'all icmp 192.168.1.100:7 -> 10.99.0.1:7       0:0\n   origif: hn2\n'
        'tun464 udp 192.168.1.100:5000 -> 192.88.99.1:5201       SINGLE:NO_TRAFFIC\n')
    found = clat_states(states, '2001:db8:56ff::a1b2:c3d4')
    expect('states nat44', [state_iface(s) for s in found['nat44']], ['tun464'])
    expect('states v6', sorted(state_iface(s) for s in found['v6']), ['pppoe0', 'tun464'])
    expect('states untranslated', [s['line'].split()[2] for s in found['untranslated']], ['192.168.1.100:5000'])
    debug = ('pass in quick on tun464 inet6 from {any} to {any} keep state label "aaa111" # CLAT: translated IPv6 from tayga\n'
             'pass in quick on hn0 inet from {(hn0:network)} to {any} keep state label "bbb222" # Default allow LAN to any rule\n')
    expect('labels', rule_labels(debug), {CLAT_RULE_DESCR: 'aaa111', 'Default allow LAN to any rule': 'bbb222'})
    expect('rule regex', bool(CLAT_RULE.match('pass in log quick on tun464 inet6 all flags S/SA keep state label "aaa111"')), True)
    expect('rule regex v4', bool(CLAT_RULE.match('pass in quick on tun464 inet all flags S/SA keep state label "x"')), False)
    expect('scrub new', scrub_mss('match on tun464 inet all scrub (max-mss 1452)\nmatch on tun464 inet6 all scrub (max-mss 1432)\n'), [1432])
    expect('scrub old', scrub_mss('scrub on tun464 inet6 all max-mss 1412 fragment reassemble\n'), [1412])
    expect('gateways', parse_gateways('{"CLAT_GW":{"name":"CLAT_GW","address":"192.0.0.2"},"WAN_DHCP6":{"name":"WAN_DHCP6","address":"fe80::1%pppoe0"}}',
                                      '{"CLAT_GW":"CLAT_GW - 192.0.0.2","WAN_DHCP6":"WAN_DHCP6 - fe80::1%pppoe0","LABGW":"LABGW - inet"}'),
           [('CLAT_GW', '192.0.0.2'), ('LABGW', 'inet')])
    expect('gateways null', parse_gateways('{"WAN_DHCP6":{"name":"WAN_DHCP6","address":"fe80::1"}}',     # as 26.7.6 prints it
                                           '{"WAN_DHCP6":"WAN_DHCP6 - fe80::1","Null6":"Null6 - ::1","Null4":"Null4 - 127.0.0.1"}'), [])
    expect('gateways unreadable', parse_gateways('Execute error', ''), None)

    # sampler lines and what is read from them
    lines = []
    for second in range(40):
        pid = '100' if second < 20 else ('' if second < 22 else '200')
        started = 900 if second < 20 else (None if second < 22 else 1022)
        state = 'active' if second < 20 or second >= 25 else 'backoff'
        lines.append(json.dumps({'t': 1000 + second, 'st': {'state': state, 'reason': '', 'tayga': {'started': started, 'restarts': 0}},
                                 'd4': '192.0.0.2 tun464' if pid else '', 'd6': '' if 5 <= second < 12 else 'fe80::1%pppoe0 pppoe0',
                                 'nat': 1, 'tayga': pid, 'clatd': '50', 'rtr': 1 if pid else 0,
                                 'pfx': 500 if second < 15 else 1015, 'tun': '192.0.0.1'}))
    lines.insert(3, '{"t":1002,"st":{"state":"act')     # a torn line is skipped
    with tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False) as handle:
        handle.write('\n'.join(lines) + '\n')
    samples = parse_samples(handle.name, offset=2.0)
    os.unlink(handle.name)
    expect('samples', (len(samples), samples[0]['tl']), (40, 998.0))
    expect('not restarted (first 20)', tayga_not_restarted(samples[:20])[0], True)
    expect('not restarted (all)', tayga_not_restarted(samples)[0], False)

    def restamped(value):
        return [dict(s, st=dict(s['st'], tayga=dict(s['st']['tayga'], started=value))) if i >= 10 else s for i, s in enumerate(samples[:20])]
    expect('not restarted, the clock set back by a second', tayga_not_restarted(restamped(899))[0], True)
    expect('not restarted, tayga.started ten seconds lower', tayga_not_restarted(restamped(890))[0], False)
    expect('restarted once', tayga_restarted_once(samples, 17, 40)[0], True)
    expect('restarted once, uptime too long', tayga_restarted_once(samples, 400, 40)[0], False)
    info = analyse_reconnect(samples, 1000.0)
    expect('reconnect', (info['t_pfx'], info['s_active']['t'], info['gap6'], info['t_lost6']), (1013.0, 1015, 6.0, 1003.0))
    expect('uplink down', [s_down(x) for x in ({'d6': 'fe80::1%pppoe0 pppoe0', 'up': 1}, {'d6': 'fe80::1%pppoe0 pppoe0', 'up': 0},
                                               {'d6': '', 'up': 1}, {'d6': 'fe80::1%pppoe0 pppoe0'})], [False, True, True, False])
    expect('d4 devices', s_d4_devs({'d4': '192.0.0.2 tun464;10.99.0.1 hn2'}), ['hn2', 'tun464'])
    expect('first json', first_json('noise {"a": {"b": 1}} trailing'), {'a': {'b': 1}})
    expect('api creds', api_creds({'PPPOE_USER': 'u', 'API_KEY': 'k', 'API_SECRET': 's', 'API_SECRET_CRYPT': '$6$x'}), ('k', 's'))
    expect('opn wrap', opn_wrap('echo hi').count('__LAB_SCRIPT_END__'), 2)
    expect('tests', sorted(TESTS) == sorted(set(TESTS)) and len(TESTS), 31)      # T00 to T29 and T03b
    expect('prod tests exist', [tid for tid in PROD_TESTS if tid not in TESTS], [])
    query = struct.pack('!HHHHHH', 7, 0x0100, 1, 0, 0, 0) + b'\x08ipv4only\x04arpa\x00' + struct.pack('!HH', 28, 1)
    udp = lambda sport, dport, data: struct.pack('!HHHH', sport, dport, 8 + len(data), 0) + data
    expect('dns question', dns_question(udp(40000, 53, query)), ('ipv4only.arpa.', 28))
    expect('dns answer is no question', dns_question(udp(53, 40000, query[:2] + b'\x81\x80' + query[4:])), None)
    bootp = b'\x02' + b'\0' * 235 + bytes((99, 130, 83, 99)) + bytes((53, 1, 5, 0, 108, 4)) + struct.pack('!I', 1800) + bytes((255,))
    expect('dhcp option 108', dhcp_option(udp(67, 68, bootp), 108), struct.pack('!I', 1800))
    expect('dhcp option absent', dhcp_option(udp(67, 68, bootp), 6), None)
    expect('longest gap', longest_gap([1.0, 2.0, 7.0, 8.0], 0.0, 9.0), 5.0)
    use_profile('prod')
    expect('profile prod', (PD_DEFAULT, P['source'], base_config()[1][1]), ('2001:db8:4800:100::/56', 'dns', '1508'))
    use_profile('p0')
    expect('profile p0', (PD_DEFAULT, P['source'], base_config()[1][1]), ('2001:db8:5600::/56', 'ra', None))

    for failure in failures:
        print('SELFTEST FAIL ' + failure)
    print('selftest: %d failure(s)' % len(failures))
    return 1 if failures else 0


# ---- entry point --------------------------------------------------------------------------------------

def main(argv):
    global CUR
    if argv[:1] == ['selftest']:
        return selftest()
    if len(argv) < 3 or argv[1] not in TESTS:
        print('usage: run-tests.sh --inside <run id> <test id> <S|H|guestH|from|none> [reset mode] [profile]   |   --inside selftest')
        return 2
    run_id, tid, reset = argv[0], argv[1], argv[2]
    mode = argv[3] if len(argv) > 3 else '?'
    use_profile(argv[4] if len(argv) > 4 and argv[4] in PROFILES else 'p0')
    run_dir = os.path.join(ROOT, 'results', run_id)
    os.makedirs(run_dir, exist_ok=True)
    t = CUR = Test(tid, run_dir)
    doc = (TESTS[tid].__doc__ or '').strip()
    print('\n== %s  %s  [profile %s, reset %s, mode %s, %s UTC]' % (tid, doc, PROFILE, reset, mode,
                                                                 time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())), flush=True)
    try:
        if PROFILE == 'prod' and tid not in PROD_TESTS:
            raise Skipped('not adapted to the production profile; run it with --profile p0')
        if reset == 'guestH':
            guest_reset(t)
            reset = 'H'
        if reset == 'H':
            hard_post(t, install=(tid != 'T01'))
        elif reset == 'S':
            soft_reset(t)
        problems = guard(t, 'before')
        if problems:
            raise Invalid('guard T00 before the test: ' + '; '.join(problems))
        TESTS[tid](t)
    except Skipped as exc:
        t.forced = ('skipped (%s)' % exc, 'not run')
        print('SKIP    %-9s %s' % (tid, exc), flush=True)
    except Invalid as exc:
        t.forced = ('invalid', str(exc))
        print('INVALID %-9s %s' % (tid, exc), flush=True)
    except Exception:
        text = traceback.format_exc()
        log('\n' + text)
        t.save('runner-error.txt', text)
        t.forced = ('invalid', 'runner error: ' + text.strip().splitlines()[-1][:200])
        print('INVALID %-9s runner error, see %s/runner-error.txt\n%s' % (tid, tid, text), flush=True)
    try:
        if t.echo_df:
            W('ispctl echodf off')      # the ISP is as "ispctl defaults" leaves it again
        evidence(t, 'end')
        if not t.forced:
            problems = guard(t, 'after')
            if problems:
                t.forced = ('invalid', 'guard T00 after the test: ' + '; '.join(problems))
    except Exception:
        log('\n' + traceback.format_exc())
    status, note = t.outcome()
    seconds = int(time.time() - t.started)
    with open(t.path('result.tsv'), 'w') as handle:
        handle.write('%s\t%s\t%d\t%s\n' % (tid, status, seconds, note.replace('\t', ' ').replace('\n', ' ')))
    print('RESULT  %s %s (%d s) %s' % (tid, status, seconds, note), flush=True)
    return 0 if status == 'pass' else 3


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
__INNER_PYTHON__
