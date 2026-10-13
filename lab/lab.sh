#!/usr/bin/env bash
# lab.sh - the driver of the os-clat Hyper-V lab on the Windows host (Git Bash).
#
#   bash lab.sh rights                      does this session have Hyper-V rights (group member or elevated)?
#   bash lab.sh hv <script.ps1> [args]      run hyperv/<script.ps1> with powershell.exe (it needs those rights)
#   bash lab.sh hvlog [script]              print the newest .work/results/hyperv-*.log, e.g. "hvlog create-lab"
#   bash lab.sh addr [--wait] [address]     find clat-world on the Default Switch, write the lab's ssh_config
#   bash lab.sh w [command line]            run on clat-world (no command: a shell)
#   bash lab.sh c <command ...>             run in the IPv4-only client namespace on clat-world
#   bash lab.sh o [sh script text]          run with /bin/sh on clat-opn, through clat-world (no text: stdin)
#   bash lab.sh api GET|POST <path> [json]  web API of clat-opn, called from clat-world
#   bash lab.sh st                          "configctl clat details" on clat-opn (once per step, not in a loop)
#   bash lab.sh world                       M3: push world/ to clat-world, run install.sh, print the checks
#   bash lab.sh opn-wait                    M4: wait for ssh on 10.99.0.2 (up to 15 minutes), then one key login
#   bash lab.sh opn-provision               M6: packages, base, kernel policy, tayga; then reboot clat-opn
#                                           (environment: UPDATE=yes|no, KERNEL=auto|hold|current)
#   bash lab.sh plugin install|remove       M8: put the current net/clat/src on clat-opn, or take it off
#   bash lab.sh gui                         https://127.0.0.1:8443 becomes the GUI of clat-opn (Ctrl-C ends it)
#   bash lab.sh gui-form fields|post|text <page> [...]   a form of the GUI as a browser reads and sends it
#                                           (opnsense/guiform.py; for the legacy *.php pages, which take no API key)
#   bash lab.sh opn-prod                    put clat-opn into the production profile by the steps of the customer
#                                           page (README section 13); the plugin must not be installed, and the
#                                           PPPoE server of clat-world must be on VLAN 40 (ispctl vlan on)
#   bash lab.sh opn-vlan on|off             move the PPPoE of clat-opn to vlan0.40 on hn1 (steps 2 and 3 of the
#                                           page), or back to hn1, and write the same into the configurations the
#                                           in-guest reset puts back; see README section 13 for the whole switch
#   bash lab.sh repo build [revision]       build the package on clat-opn with ../packaging as the release workflow
#                                           does, sign with the lab key, publish on clat-world as https://repo.clat.lab/os-clat
#   bash lab.sh repo subscribe              on clat-opn: trust the lab CA, then the install line of the published site
#   bash lab.sh fw check|update|info [name]|install os-<name>|remove os-<name>
#                                           a button of System > Firmware: the API call and the progress the page polls
#   bash lab.sh screens [options] [step ...]   screenshots of the GUI of clat-opn for the customer page: headless Edge
#                                           through a tunnel of its own (screens/capture.mjs, --list shows the steps;
#                                           README section 15)
#   bash lab.sh t25 [options] [part ...]    test T25: the buttons of the GUI pressed in the same browser, the box asked
#                                           after each step (screens/t25.mjs; parts install, settings, assign, drift,
#                                           remove; it changes the box; README section 15)
#
# Needs: bash build.sh (the lab key and secrets in .work/disks/build) and, for everything after "hvlog",
# a running clat-world. Host -> clat-world goes over the Default Switch, host -> clat-opn through
# clat-world (ProxyJump). The user's own ~/.ssh is neither read nor written.
#
# Everything a verb prints is also appended to .work/results/lab.log (not for "gui" and the bare shell).
# The soft reset and the config.xml helper of the tests are inside run-tests.sh and nowhere else.
#
# In use on the lab since 2026-10-11 (README.md section 10). Not run so far: "hv" (the lab's shells had no
# Hyper-V rights; the hyperv scripts were run in an elevated console) and "gui" ("screens" opens the same tunnel).
set -u

LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$LAB/.work
DISKS=$WORK/disks
BUILD=$DISKS/build
RESULTS=$WORK/results
SSHCFG=$BUILD/ssh_config
KEY=$BUILD/lab_ed25519
KNOWN=$DISKS/clat-known_hosts           # "clat-" prefix: hyperv/remove-lab.ps1 deletes it with the VMs
PLUGIN=$(cd "$LAB/.." && pwd)/net/clat   # the plugin source, read only
REMOTE=/root/clat-tests                 # where run-tests.sh keeps its files on clat-world
OPN=10.99.0.2
WORLD_NAME=clat-world.mshome.net
WORLD_MAC=02-c1-a7-00-01-01             # adapter "nat" of clat-world (hyperv/lab-common.ps1, world/network-config)
SYS32="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"
OPN_PATH='PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin; export PATH'

say() { printf '%s\n' "$*"; }
die() { printf 'lab.sh: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

need_cfg() { [ -s "$SSHCFG" ] || die "no $SSHCFG yet: start clat-world, then run: bash lab.sh addr --wait"; }
wssh() { ssh -F "$SSHCFG" clat-world "$@"; }
quote() {       # the arguments as one command line for the remote shell
    local out='' a
    for a in "$@"; do out="$out $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

# opn_sh TEXT: run TEXT with /bin/sh on clat-opn. root's shell there hands a remote command line to csh,
# so the script travels on stdin; it is stored first and run with stdin closed, so that no command in it
# can swallow the lines that follow it.
opn_sh() {
    printf '%s\n' "$OPN_PATH" 'f=$(mktemp /tmp/lab-run.XXXXXX) || exit 97' \
        "cat > \"\$f\" <<'__LAB_SCRIPT_END__'" "$OPN_PATH" "$1" '__LAB_SCRIPT_END__' \
        '/bin/sh "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc' | ssh -F "$SSHCFG" clat-opn /bin/sh -s
}

hyperv_rights() {       # member of Hyper-V Administrators (S-1-5-32-578) or an elevated shell (high integrity)
    local groups
    # Windows' whoami by its path: Git Bash has a whoami.exe of its own that knows no /groups
    groups=$(MSYS_NO_PATHCONV=1 "$SYS32/whoami.exe" /groups 2>/dev/null) || return 1
    case "$groups" in *S-1-5-32-578*|*S-1-16-12288*|*S-1-16-16384*) return 0 ;; esac
    return 1
}

do_rights() {
    if hyperv_rights; then
        say "this session HAS Hyper-V rights (member of Hyper-V Administrators, or elevated)"
        return 0
    fi
    say "this session has NO Hyper-V rights: its token has neither the group S-1-5-32-578 (Hyper-V Administrators)"
    say "nor high integrity. See README.md, \"Hyper-V rights\". A group change needs a new Windows sign-in."
    return 1
}

do_hv() {
    local script=${1:-}
    case "$script" in
    create-lab.ps1|remove-lab.ps1|status-lab.ps1|reset-lab.ps1|wan-vlan.ps1) shift ;;
    *) die "usage: lab.sh hv create-lab.ps1|remove-lab.ps1|status-lab.ps1|reset-lab.ps1|wan-vlan.ps1 [arguments]" ;;
    esac
    MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$LAB/hyperv/$script")" "$@"
}

do_hvlog() {    # the logs are UTF-8 with a byte order mark and CRLF (Start-Transcript)
    local newest
    newest=$(ls "$RESULTS"/hyperv-*"${1:-}"*.log 2>/dev/null | sort | tail -n 1)
    [ -n "$newest" ] || die "no hyperv-*${1:-}*.log in $RESULTS"
    say "== $newest"
    sed '1s/^\xEF\xBB\xBF//' "$newest" | tr -d '\r'
}

# ---- addr: where is clat-world? (PLAN decision 20) ---------------------------------------------------------

ssh_probe() {   # true when the host at $1 accepts the lab key and calls itself clat-world; records no host key
    [ "$(ssh -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=6 \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
            -o LogLevel=ERROR "root@$1" hostname 2>/dev/null </dev/null)" = clat-world ]
}

candidates() {  # lines "<address or name> <how it was found>", in the order they are tried
    say "$WORLD_NAME name"
    "$SYS32/ARP.EXE" -a 2>/dev/null | tr -d '\r' | awk -v m="$WORLD_MAC" 'tolower($2) == m { print $1, "neighbour-table" }'
    if hyperv_rights; then      # KVP: needs the hyperv-daemons package in the guest (installed by world/install.sh)
        MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command \
            "(Get-VMNetworkAdapter -VMName clat-world -Name nat -ErrorAction SilentlyContinue).IPAddresses" 2>/dev/null |
            tr -d '\r' | grep -E '^[0-9]+(\.[0-9]+){3}$' | sed 's/$/ kvp/'
    fi
}

write_cfg() {   # write_cfg <address or name of clat-world> <how>
    cat > "$SSHCFG" <<EOF
# written by "bash lab.sh addr" at $(date -u '+%Y-%m-%dT%H:%M:%SZ'); clat-world found by: $2
Host clat-world
    HostName $1
    HostKeyAlias clat-world
Host clat-opn
    HostName $OPN
    ProxyJump clat-world
    # not pinned: the box gets new host keys with every rebuild, and it is reached only through
    # clat-world (pinned below) on a private switch that holds these two VMs
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
Host clat-world clat-opn
    User root
    IdentityFile "$KEY"
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile "$KNOWN"
    GlobalKnownHostsFile /dev/null
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 4
    LogLevel ERROR
EOF
}

do_addr() {
    local wait=0 given='' deadline cand how
    while [ $# -gt 0 ]; do
        case "$1" in
        --wait) wait=600 ;;
        [0-9]*.[0-9]*.[0-9]*.[0-9]*|*.mshome.net) given=$1 ;;
        *) die "usage: lab.sh addr [--wait] [IPv4 address of clat-world]" ;;
        esac
        shift
    done
    [ -s "$KEY" ] || die "no lab key at $KEY (run: bash build.sh)"
    mkdir -p "$BUILD"
    deadline=$(( $(date +%s) + wait ))
    while :; do
        while read -r cand how; do
            [ -n "$cand" ] || continue
            if ssh_probe "$cand"; then
                write_cfg "$cand" "$how"
                say "clat-world is $cand (found by: $how); wrote $SSHCFG"
                if ! wssh true </dev/null; then
                    say "WARNING: ssh with $SSHCFG fails although the probe worked. If the VM was rebuilt, its host key"
                    say "         changed: delete $KNOWN and run this again."
                    return 1
                fi
                return 0
            fi
        done < <(if [ -n "$given" ]; then say "$given given"; else candidates; fi)
        [ "$(date +%s)" -lt "$deadline" ] || break
        sleep 10
    done
    say "clat-world was not found: no candidate ($WORLD_NAME, the neighbour table entry of $WORLD_MAC, KVP with"
    say "Hyper-V rights) accepts the lab key and answers \"hostname\" with clat-world."
    say "Is the VM running? Its first boot needs a minute or two. The nic line \"nat\" of hyperv/status-lab.ps1"
    say "shows its address (ip=...) once the guest reports it; then: bash lab.sh addr <address>"
    return 1
}

# ---- M3: clat-world -------------------------------------------------------------------------------------------

do_world() {
    local rc
    need_cfg
    [ -s "$BUILD/secrets.env" ] && [ -s "$BUILD/clat-opn-config.xml" ] || die "run bash build.sh first"
    say "== push world/install.sh, world/rootfs, the lab key, lab.env and the Path B files to clat-world"
    wssh 'timeout 600 cloud-init status --wait >/dev/null 2>&1; rm -rf /root/world; mkdir -p /root/world /root/.ssh && chmod 700 /root/.ssh' </dev/null \
        || die "clat-world does not answer"
    tar -C "$LAB/world" --owner=0 --group=0 --numeric-owner -cf - install.sh rootfs | wssh 'tar -C /root/world -xf -' \
        || die "cannot copy world/ to clat-world"
    wssh 'umask 077; rm -f /root/.ssh/id_ed25519; cat > /root/.ssh/id_ed25519' < "$KEY" || die "cannot copy the lab key"
    wssh 'umask 077; rm -f /root/lab.env; cat > /root/lab.env' < "$BUILD/secrets.env" || die "cannot copy lab.env"
    wssh 'cat > /root/web-restore.sh' < "$LAB/opnsense/web-restore.sh" || die "cannot copy web-restore.sh"
    wssh 'umask 077; rm -f /root/clat-opn-config.xml; cat > /root/clat-opn-config.xml' < "$BUILD/clat-opn-config.xml" || die "cannot copy the configuration"
    say "== sh /root/world/install.sh"
    wssh 'sh /root/world/install.sh' </dev/null
    rc=$?
    say "install.sh exit $rc"
    say "== M3 checks (run on clat-world; every line is OK, FAIL or INFO)"
    wssh 'bash -s' <<'CHECKS'
bad=0
ok()   { echo "OK   $*"; }
fail() { echo "FAIL $*"; bad=$((bad + 1)); }
info() { echo "INFO $*"; }
R=2001:db8:64::53

s=$(cloud-init status 2>&1 | head -n 1)
case "$s" in *done*) ok "cloud-init: $s" ;; *) fail "cloud-init: $s" ;; esac
[ "$(hostname)" = clat-world ] && ok "hostname clat-world" || fail "hostname is $(hostname)"
for pair in up0=02:c1:a7:00:01:01 mgmt0=02:c1:a7:00:01:02 wan0=02:c1:a7:00:01:03; do
    dev=${pair%%=*}; mac=${pair#*=}; have=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
    [ "$have" = "$mac" ] && ok "$dev has MAC $mac" || fail "$dev has MAC '${have:-none}', expected $mac"
done
have=$(ip netns exec client cat /sys/class/net/lan0/address 2>/dev/null)
[ "$have" = 02:c1:a7:00:01:04 ] && ok "lan0 (namespace client) has MAC 02:c1:a7:00:01:04" \
    || fail "lan0 in the namespace client has MAC '${have:-none}', expected 02:c1:a7:00:01:04"
ip -4 -br addr show dev mgmt0 2>/dev/null | grep -q '10\.99\.0\.1/24' && ok "mgmt0 has 10.99.0.1/24" || fail "mgmt0 does not have 10.99.0.1/24"

n=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
[ "$n" = 0 ] && ok "no failed systemd unit" || fail "$n failed systemd unit(s): $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ')"
for u in isp-base isp-pppoe isp-nat64 isp-www isp-iperf3 isp-client unbound nftables; do
    a=$(systemctl is-active "$u" 2>/dev/null)
    [ "$a" = active ] && ok "$u is active" || fail "$u is ${a:-unknown}"
done
info "radvd is $(systemctl is-active radvd 2>/dev/null), kea-dhcp6-server is $(systemctl is-active kea-dhcp6-server 2>/dev/null) (both run only while a PPP session exists); session on: $(ispctl iface 2>/dev/null)"
info "isp-repo is $(systemctl is-active isp-repo 2>/dev/null) (the package repository; it runs once \"lab.sh repo build\" has brought its certificate)"
v=$(systemd-analyze verify /etc/systemd/system/isp-*.service 2>&1 | grep -c .)
info "systemd-analyze verify on the seven isp-* units printed $v line(s)"

sh -n /usr/local/sbin/ispctl 2>/dev/null && ok "sh -n ispctl" || fail "sh -n ispctl"
nft -c -f /etc/nftables.conf >/dev/null 2>&1 && ok "nft -c -f /etc/nftables.conf" || fail "nft -c -f /etc/nftables.conf"
unbound-checkconf >/dev/null 2>&1 && ok "unbound-checkconf" || fail "unbound-checkconf"
nft list chain inet isp input 2>/dev/null | grep -q 'iifname "mgmt0" ip saddr != 10.99.0.0/24 counter' \
    && ok "input chain drops what reaches mgmt0 from outside 10.99.0.0/24" || fail "the mgmt0 drop rule is not in chain input"
nft list chain inet isp forward 2>/dev/null | grep -v '}' | tail -n 1 | grep -Eq 'reject with icmpv6 (type )?no-route' \
    && ok "the last forward rule rejects with icmpv6 no-route" || fail "the last rule of chain forward is not the icmpv6 no-route reject"
nft list set inet isp provision4 2>/dev/null | grep -q elements && fail "the provisioning NAT set has elements" || ok "provisioning NAT is off (set provision4 is empty)"
e=$(nft list chain inet isp echodf 2>&1)
case "$e" in
    *frag-off*) fail "chain echodf has a rule: the test target answers echo with DF set (ispctl echodf off)" ;;
    *"hook output"*) ok "chain echodf exists and is empty (echo replies of the test target leave as sent)" ;;
    *) fail "chain echodf is missing in table inet isp" ;;
esac

q() { dig +time=2 +tries=3 "$@" 2>&1; }
want6="64:ff9b::c000:aa 64:ff9b::c000:ab "
a=$(q +short @$R ipv4only.arpa AAAA | sort | tr '\n' ' ')
[ "$a" = "$want6" ] && ok "dns64 on: ipv4only.arpa AAAA = $a" || fail "dns64 on: ipv4only.arpa AAAA = '$a'"
t=$(q +noall +answer @$R ipv4only.arpa AAAA | awk '{ print $2 }' | sort -u | tr '\n' ' ')
[ "$t" = "60 " ] && ok "dns64 on: TTL 60" || fail "dns64 on: TTL '$t', expected 60"
ispctl dns64 off >/dev/null 2>&1; sleep 1
out=$(q @$R ipv4only.arpa AAAA)
if echo "$out" | grep -q 'status: NOERROR' && echo "$out" | grep -q 'ANSWER: 0' \
    && echo "$out" | grep -Eq '^ipv4only\.arpa\.[[:space:]]+60[[:space:]]+IN[[:space:]]+SOA'; then
    ok "dns64 off: AAAA is NOERROR with no answer and the SOA (TTL 60) in the authority section"
else
    fail "dns64 off: the AAAA answer is not NOERROR/empty with a 60 s SOA: $(echo "$out" | grep -E 'status:|SOA' | tr '\n' ' ')"
fi
a=$(q +short @$R ipv4only.arpa A | sort | tr '\n' ' ')
[ "$a" = "192.0.0.170 192.0.0.171 " ] && ok "dns64 off: ipv4only.arpa A = $a" || fail "dns64 off: ipv4only.arpa A = '$a'"
ispctl dns64 on >/dev/null 2>&1; sleep 1
a=$(q +short @$R ipv4only.arpa AAAA | sort | tr '\n' ' ')
[ "$a" = "$want6" ] && ok "dns64 on again" || fail "dns64 on again: ipv4only.arpa AAAA = '$a'"
for g in 2001:4860:4860::6464 2001:4860:4860::64; do
    a=$(q +short @$g ipv4only.arpa AAAA | sort | tr '\n' ' ')
    [ "$a" = "$want6" ] && ok "the resolver answers on $g (the address the customer page names)" || fail "ipv4only.arpa AAAA asked at $g = '$a'"
done
e=$(nft list chain inet isp resolver 2>&1)
case "$e" in
    *drop*) fail "chain resolver has a rule: the subscriber's DNS queries are dropped (ispctl resolver on)" ;;
    *"chain resolver"*) ok "chain resolver exists and is empty (the subscriber's DNS queries are answered)" ;;
    *) fail "chain resolver is missing in table inet isp" ;;
esac
[ "$(ispctl status 2>/dev/null | sed -n '/^== PPPoE server on/{n;p;}')" = wan0 ] && ok "the PPPoE server is on wan0 (untagged)" \
    || info "the PPPoE server is on $(ispctl status 2>/dev/null | sed -n '/^== PPPoE server on/{n;p;}') (ispctl vlan on is in force)"
info "recursion through the Default Switch (needed in M6): pkg.opnsense.org A = $(dig +short +time=3 +tries=3 @10.99.0.1 pkg.opnsense.org A 2>&1 | tr '\n' ' ')"
a=$(q +short @$R repo.clat.lab AAAA)
case "$a" in
    *:*) ip -6 -br addr show dev isp0 | grep -q " $a/128" && ok "repo.clat.lab AAAA = $a, an address of isp0 (the lab's package repository)" \
            || fail "repo.clat.lab AAAA = $a, which isp0 does not have" ;;
    *) fail "repo.clat.lab AAAA = '$a'" ;;
esac
info "OPNsense's mirror as an IPv6-only router gets it (its own AAAA is ignored, the lab has no IPv6 Internet): pkg.opnsense.org AAAA = $(q +short @$R pkg.opnsense.org AAAA | tr '\n' ' ')"

ping -6 -n -c2 -W2 64:ff9b::c058:6301 2>&1 | grep -q ' 2 received' && ok "ping -6 64:ff9b::c058:6301: 2 received (NAT64 to the local target)" \
    || fail "ping -6 64:ff9b::c058:6301 does not get 2 replies"
c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://192.88.99.1/ 2>/dev/null)
[ "$c" = 200 ] && ok "http://192.88.99.1/ answers 200" || fail "http://192.88.99.1/ answers '$c'"
c=$(curl -s -o /dev/null -m 120 -w '%{size_download}' http://192.88.99.1/100M.bin 2>/dev/null)
[ "$c" = 104857600 ] && ok "100M.bin has 104857600 bytes" || fail "100M.bin: downloaded '$c' bytes"

for spec in "wan0:" "lan0:ip netns exec client"; do
    dev=${spec%%:*}; pre=${spec#*:}
    out=$($pre ethtool -k "$dev" 2>&1)
    for f in tcp-segmentation-offload generic-segmentation-offload generic-receive-offload tx-checksumming; do
        line=$(echo "$out" | grep "^$f:")
        case "$line" in "$f: off"*) ok "$dev $line" ;; *) fail "$dev ${line:-$f: not listed}" ;; esac
    done
done
echo "M3 checks: $bad failed"
[ "$bad" = 0 ]
CHECKS
    rc=$((rc + $?))
    [ "$rc" = 0 ]
}

# ---- M4, M6: clat-opn -----------------------------------------------------------------------------------------

wait_port() {   # wait_port open|closed <seconds>: TCP 22 of clat-opn as clat-world sees it; no login attempt
    wssh "bash -s $1 $2" <<'EOF'
end=$((SECONDS + $2))
while :; do
    if timeout 3 bash -c 'exec 3<>/dev/tcp/10.99.0.2/22' 2>/dev/null; then state=open; else state=closed; fi
    [ "$state" = "$1" ] && { echo "10.99.0.2:22 is $1 after $SECONDS s"; exit 0; }
    [ "$SECONDS" -lt "$end" ] || { echo "10.99.0.2:22 is still $state after $SECONDS s"; exit 1; }
    sleep 3
done
EOF
}

do_opn_wait() {
    local try out=''
    need_cfg
    say "waiting for TCP 22 on $OPN as clat-world sees it, up to 15 minutes (no login is tried while it is closed)"
    wait_port open 900 || { say "FAIL: no ssh on $OPN. README.md, M4, says how to find out why without a login."; return 1; }
    # few logins on purpose: five failed ones put 10.99.0.1 into OPNsense's sshlockout table
    sleep 5
    for try in 1 2; do
        if out=$(opn_sh 'hostname' 2>&1); then say "OK   key login works: $out"; return 0; fi
        [ "$try" = 2 ] || { say "     the login failed ($out); one more try in 30 s"; sleep 30; }
    done
    say "FAIL: port 22 is open but the key login does not work: $out"
    return 1
}

do_opn_provision() {
    local update=${UPDATE:-yes} kernel=${KERNEL:-auto} rc='' line last='' stamp
    case "$update" in yes|no) ;; *) die "UPDATE must be yes or no" ;; esac
    case "$kernel" in auto|hold|current) ;; *) die "KERNEL must be auto, hold or current" ;; esac
    need_cfg
    undo() {    # runs on every way out: the provisioning route and NAT must never outlive this verb
        say "== provisioning route and NAT off"
        opn_sh 'route delete -inet default 10.99.0.1 >/dev/null 2>&1; echo "IPv4 default routes on clat-opn now: $(netstat -rn -f inet | grep -c "^default")"'
        wssh 'ispctl provision off; systemctl start isp-pppoe; echo "provisioning set on clat-world: $(nft list set inet isp provision4 | grep elements || echo empty)"' </dev/null
    }
    say "== provisioning NAT on, PPPoE server stopped (no IPv6 default route to an ISP without Internet while pkg runs)"
    wssh 'ispctl provision on && systemctl stop isp-pppoe' </dev/null || die "cannot switch provisioning on at clat-world"
    if ! opn_sh 'route add -inet default 10.99.0.1
fetch -4 -T 20 -qo /dev/null https://pkg.opnsense.org/ || { echo "the local resolver or the route does not work yet: using 10.99.0.1 as resolver"; printf "nameserver 10.99.0.1\n" > /etc/resolv.conf; fetch -4 -T 20 -qo /dev/null https://pkg.opnsense.org/; }
echo "fetch https://pkg.opnsense.org/ exit $?"'; then
        undo; say "FAIL: clat-opn does not answer"; return 1
    fi
    say "== provision.sh on clat-opn (UPDATE=$update KERNEL=$kernel); polled every 15 s for its last line"
    opn_sh "cat > /root/provision.sh <<'__LAB_PROVISION_END__'
$(cat "$LAB/opnsense/provision.sh")
__LAB_PROVISION_END__
rm -f /root/provision.log
UPDATE=$update KERNEL=$kernel nohup sh /root/provision.sh > /root/provision.log 2>&1 < /dev/null &
sleep 2; echo started" || { undo; say "FAIL: cannot start provision.sh"; return 1; }
    for _ in $(seq 1 360); do           # up to 90 minutes; package upgrades restart sshd, so a poll may fail
        sleep 15
        line=$(opn_sh 'tail -n 1 /root/provision.log 2>/dev/null' 2>/dev/null | tail -n 1)
        [ -z "$line" ] || [ "$line" = "$last" ] || { say "   $line"; last=$line; }
        case "$line" in "PROVISION DONE rc="*) rc=${line#PROVISION DONE rc=}; break ;; esac
    done
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    opn_sh 'cat /root/provision.log' > "$RESULTS/provision-$stamp.log" 2>/dev/null
    say "== the log of provision.sh is in $RESULTS/provision-$stamp.log; its end:"
    tail -n 15 "$RESULTS/provision-$stamp.log"
    undo
    if [ "$rc" != 0 ]; then
        say "FAIL: provision.sh ended with '${rc:-no DONE line within 90 minutes}'. clat-opn was not rebooted."
        return 1
    fi
    say "== reboot clat-opn"
    opn_sh 'configctl -d system reboot'
    wait_port closed 240 || say "WARNING: port 22 did not close within 240 s of the reboot command"
    do_opn_wait || return 1
    say "== state after the reboot (PLAN M6 checks)"
    opn_sh 'opnsense-version
uname -v
echo "kernel policy: $(cat /root/lab-kernel.policy 2>/dev/null)"
opnsense-update -T -k >/dev/null 2>&1; echo "kernel lock test (1 = locked): $?"
echo "hw.vmbus.tlb_hcall=$(sysctl -n hw.vmbus.tlb_hcall 2>&1)"
echo "tayga $(pkg query %v tayga 2>&1)"
echo "exited on signal lines in dmesg: $(dmesg | grep -c "exited on signal")"
echo "IPv4 default routes: $(netstat -rn -f inet | grep -c "^default")"'
}

# ---- M8: the plugin ---------------------------------------------------------------------------------------------

bundle() {      # the plugin tree as it is now: files only, modes are set on the box (same as run-tests.sh)
    [ -d "$PLUGIN/src" ] || { say "no plugin source at $PLUGIN/src"; return 1; }
    mkdir -p "$BUILD" || return 1
    ( cd "$PLUGIN/src" && find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' | sed 's|^\./||' | LC_ALL=C sort ) > "$BUILD/os-clat.files" || return 1
    [ -s "$BUILD/os-clat.files" ] || { say "the plugin source tree is empty"; return 1; }
    ( cd "$PLUGIN/src" && tar -cf "$BUILD/os-clat.tar" --owner=0 --group=0 --numeric-owner -T "$BUILD/os-clat.files" ) || return 1
    sha256sum "$BUILD/os-clat.tar" | cut -d' ' -f1 > "$BUILD/os-clat.sha256"
    say "plugin bundle: $(wc -l < "$BUILD/os-clat.files" | tr -d ' ') files, tar sha256 $(cat "$BUILD/os-clat.sha256")"
}

do_plugin() {
    local verb=${1:-}
    case "$verb" in install|remove) ;; *) die "usage: lab.sh plugin install|remove" ;; esac
    if [ "$verb" = install ]; then bundle || die "cannot pack the plugin tree"; fi
    need_cfg
    wssh "mkdir -p $REMOTE && cat > $REMOTE/install-plugin.sh" < "$LAB/opnsense/install-plugin.sh" || die "cannot copy install-plugin.sh to clat-world"
    if [ "$verb" = install ]; then
        wssh 'cat > /root/os-clat.tar' < "$BUILD/os-clat.tar" || die "cannot copy the plugin tar"
        wssh 'cat > /root/os-clat.files' < "$BUILD/os-clat.files" || die "cannot copy the file list"
        wssh 'cat > /root/os-clat.post-install' < "$PLUGIN/+POST_INSTALL.post" || die "cannot copy +POST_INSTALL.post"
        wssh 'cat > /root/os-clat.pre-deinstall' < "$PLUGIN/+PRE_DEINSTALL.pre" || die "cannot copy +PRE_DEINSTALL.pre"
        wssh 'cat > /root/os-clat.post-deinstall' < "$PLUGIN/+POST_DEINSTALL.post" || die "cannot copy +POST_DEINSTALL.post"
    fi
    wssh "sh $REMOTE/install-plugin.sh $verb" </dev/null
}

# ---- the production profile on clat-opn (README section 13) ---------------------------------------------------------

gui_form() {    # the arguments of opnsense/guiform.py, run on clat-world
    wssh "mkdir -p $REMOTE && cat > $REMOTE/guiform.py" < "$LAB/opnsense/guiform.py" || die "cannot copy guiform.py to clat-world"
    wssh "python3 -B $REMOTE/guiform.py $(quote "$@")" </dev/null
}

step() { say; say "== $*"; }

# The steps of the OPNsense section of the customer page, each done through the page or the API the GUI itself uses.
# The steps are done in the page's order, the VLAN device of step 2 included, so the ISP side has to be on the
# tagged link already (README section 13); on an untagged link the box gets no session until "ispctl vlan on".
do_opn_prod() {
    local n out
    need_cfg
    wssh 'test -e /etc/isp/vlan-on' </dev/null || die "the PPPoE server of clat-world is not on VLAN 40: the switch of README section 13 first"
    opn_sh 'test ! -e /usr/local/etc/rc.d/clat' || die "the plugin is installed on clat-opn: bash lab.sh plugin remove"
    opn_sh 'test -s /root/config.lab-base.xml' || die "/root/config.lab-base.xml is missing on clat-opn (milestone M7)"
    step "0. the WAN as on a factory box: the WAN port with DHCP and DHCPv6, no PPPoE device, no VLAN device; reboot"
    opn_sh 'cp /root/config.lab-base.xml /conf/config.xml; rm -f /tmp/config.cache
cat > /tmp/lab-factory-wan.php <<"EOF"
<?php
require_once "config.inc";
require_once "util.inc";
$config["interfaces"]["wan"] = ["enable" => "1", "if" => "hn1", "descr" => "WAN", "ipaddr" => "dhcp", "ipaddrv6" => "dhcp6",
    "blockpriv" => "1", "blockbogons" => "1", "dhcp6-ia-pd-len" => "0"];
unset($config["ppps"]);
if (is_array($config["vlans"] ?? null)) {
    unset($config["vlans"]["vlan"]);
}
write_config("lab: WAN as on a factory box, before the customer page is followed");
echo "written\n";
EOF
php /tmp/lab-factory-wan.php; rm -f /tmp/lab-factory-wan.php; (sleep 2; reboot) >/dev/null 2>&1 &' || die "step 0 failed"
    wait_port closed 180 || die "clat-opn did not go down"
    do_opn_wait || die "clat-opn did not come back"
    sleep 20
    step "1. Interfaces > [WAN]: IPv4 Configuration Type None, IPv6 Configuration Type None; Save, Apply changes"
    gui_form post "/interfaces.php?if=wan" type=none type6=none || die "step 1 failed"
    gui_form post "/interfaces.php?if=wan" --submit apply || die "step 1 (apply) failed"
    step "2. Interfaces > Devices > VLAN: Device vlan0.40, Parent hn1, VLAN tag 40; Save, Apply"
    do_api GET /api/interfaces/vlan_settings/search_item | grep -q '"vlanif":"vlan0.40"' && die "step 2 failed: vlan0.40 exists before the step"
    out=$(do_api POST /api/interfaces/vlan_settings/add_item '{"vlan":{"vlanif":"vlan0.40","if":"hn1","tag":"40"}}'); say "$out"
    case "$out" in *'"result":"saved"'*) ;; *) die "step 2 failed: the VLAN device was not saved" ;; esac
    do_api POST /api/interfaces/vlan_settings/reconfigure '{}'
    do_api GET /api/interfaces/vlan_settings/search_item
    step "3. Interfaces > Devices > Point-to-Point: Link Type PPPoE, Link interface(s) vlan0.40, Username, Password; Save"
    gui_form post "/interfaces_ppps_edit.php" type=pppoe 'ports[]=vlan0.40' username=@PPPOE_USER password=@PPPOE_PASS provider= hostuniq= || die "step 3 failed"
    step "4. Interfaces > Assignments: WAN gets the device pppoe0; a new interface UPLINK on hn1; Apply"
    n=0     # the Device list of the dialog is not rebuilt at once after step 3
    until do_api GET /api/interfaces/assignment/get_item/wan | grep -q '"pppoe0":'; do
        n=$((n + 1))
        [ "$n" -le 36 ] || die "step 4 failed: pppoe0 is not in the Device list of Interfaces > Assignments after 180 s"
        sleep 5
    done
    say "pppoe0 is in the Device list after $((n * 5)) s"
    do_api GET /api/interfaces/assignment/get_item/wan | grep -o '"pppoe0":{"value":"pppoe0 ([^)]*)'     # the label, without the user name
    out=$(do_api POST /api/interfaces/assignment/set_item/wan '{"interface":{"if":"pppoe0","type4":"none","type6":"none"}}'); say "$out"
    case "$out" in *'"result":"saved"'*) ;; *) die "step 4 failed: the WAN row was not saved" ;; esac
    out=$(do_api POST /api/interfaces/assignment/add_item '{"interface":{"if":"hn1","descr":"UPLINK","type4":"none","type6":"none"}}'); say "$out"
    case "$out" in *'"result":"saved"'*) ;; *) die "step 4 failed: the UPLINK row was not saved" ;; esac
    do_api POST /api/interfaces/assignment/reconfigure '{}'
    sleep 10
    step "5. Interfaces > [UPLINK]: Enable ticked, both types None, MTU 1508; Save, Apply changes"
    gui_form fields "/interfaces.php?if=opt2" | grep -E '^(enable|lock) '    # as the page opens, before anything is sent
    gui_form post "/interfaces.php?if=opt2" enable=yes type=none type6=none mtu=1508 || die "step 5 failed"
    gui_form post "/interfaces.php?if=opt2" --submit apply || die "step 5 (apply) failed"
    step "6. Interfaces > [WAN]: Enable, IPv4 None, IPv6 DHCPv6, MTU 1508, Prefix delegation size 56, Request prefix only, Send prefix hint; Save, Apply changes"
    gui_form post "/interfaces.php?if=wan" enable=yes type=none type6=dhcp6 mtu=1508 dhcp6-ia-pd-len=8 dhcp6prefixonly=yes dhcp6-ia-pd-send-hint=yes || die "step 6 failed"
    gui_form post "/interfaces.php?if=wan" --submit apply || die "step 6 (apply) failed"
    step "7. Interfaces > [LAN] and Services > Dnsmasq DNS & DHCP: as the factory configuration has them (Identity association, WAN, prefix ID 0; Router advertisements ticked; a range with Constructor LAN and RA mode slaac)"
    gui_form fields "/interfaces.php?if=lan" | grep -E '^(type6|idassoc6-interface|idassoc6-prefix-id--hex) '
    step "8. System > Settings > General: DNS servers, Allow DNS server list to be overridden by DHCP/PPP on WAN cleared; Save"
    gui_form post "/system_general.php" dns1=2001:4860:4860::6464 dns2=2001:4860:4860::64 dnsallowoverride= || die "step 8 failed"
    step "9. Services > Unbound DNS > Query Forwarding: Use System Nameservers ticked; Apply (DNS64 and DNSSEC support stay cleared)"
    do_api POST /api/unbound/settings/set '{"unbound":{"forwarding":{"enabled":"1"},"general":{"dns64":"0","dnssec":"0"}}}'
    do_api POST /api/unbound/service/reconfigure '{}'
    sleep 15
    step "result"
    opn_sh 'cp /conf/config.xml /root/config.lab-prod.xml; echo prod > /root/lab-profile
ifconfig pppoe0 | grep -E "mtu|inet6"; ifconfig vlan0.40 | grep mtu; ifconfig hn1 | grep mtu; ifconfig hn0 | grep "inet6 2"; cat /tmp/pppoe0_prefixv6
grep -E "pppoe iface|max-payload" /var/etc/mpd_wan.conf; drill ipv4only.arpa AAAA @127.0.0.1 | grep -c "IN.AAAA.64:ff9b"
netstat -rn -f inet | grep -c "^default"; ls -la /root/config.lab-prod.xml'
}

# The stored configurations that the in-guest reset of run-tests.sh puts back (one per profile) get the switch
# as well, so that a reset cannot move PPPoE away from the side the ISP is on. Only the two nodes "opn-vlan"
# changes are copied from the running configuration: with the plugin installed /conf/config.xml has the
# plugin's nodes, and a base configuration must not.
opn_vlan_base() {
    opn_sh 'cat > /tmp/lab-vlan-base.php <<"EOF"
<?php
function load($file) { $doc = new DOMDocument(); return @$doc->load($file) ? $doc : null; }
function node($doc, $path) { return $doc ? (new DOMXPath($doc))->query($path)->item(0) : null; }
$ports = "/opnsense/ppps/ppp[if=\"pppoe0\"]/ports";
$live = load("/conf/config.xml");
$from = node($live, $ports);
$vlans = node($live, "/opnsense/vlans");
$bad = 0;
foreach (array_slice($argv, 1) as $file) {
    if (!is_file($file)) {
        echo "not there  $file (a reset to it is refused, nothing to save)\n";
        continue;
    }
    $doc = load($file);
    $to = node($doc, $ports);
    if (!$from || !$vlans || !$to) {
        echo "NOT SAVED  $file: no PPPoE device pppoe0 or no VLAN section in it or in /conf/config.xml\n";
        $bad++;
        continue;
    }
    $to->nodeValue = $from->nodeValue;
    $new = $doc->importNode($vlans, true);
    $old = node($doc, "/opnsense/vlans");
    if ($old) {
        $old->parentNode->replaceChild($new, $old);
    } else {
        $doc->documentElement->appendChild($new);
    }
    if ($doc->save("$file.new") === false || !chmod("$file.new", 0640) || !rename("$file.new", $file)) {
        echo "NOT SAVED  $file: cannot write it\n";
        $bad++;
        continue;
    }
    printf("saved      %s: PPPoE on %s, %d VLAN device(s)\n", $file, $from->nodeValue, $vlans->getElementsByTagName("vlan")->length);
}
exit($bad ? 1 : 0);
EOF
php /tmp/lab-vlan-base.php /root/config.lab-prod.xml /root/config.lab-base.xml; rc=$?; rm -f /tmp/lab-vlan-base.php; exit $rc'
}

do_opn_vlan() { # steps 2 and 3 of the page for the PPPoE that exists, and their undoing
    local verb=${1:-} port uuid rc=0
    case "$verb" in on|off) ;; *) die "usage: lab.sh opn-vlan on|off" ;; esac
    need_cfg
    if [ "$verb" = on ]; then
        port=vlan0.40
        step "2. Interfaces > Devices > VLAN: Device vlan0.40, Parent hn1, VLAN tag 40; Apply"
        if do_api GET /api/interfaces/vlan_settings/search_item | grep -q '"vlanif":"vlan0.40"'; then
            say "vlan0.40 exists already"
        else
            do_api POST /api/interfaces/vlan_settings/add_item '{"vlan":{"vlanif":"vlan0.40","if":"hn1","tag":"40","pcp":"0","descr":"ISP"}}'
            do_api POST /api/interfaces/vlan_settings/reconfigure '{}'
        fi
    else
        port=hn1
    fi
    step "3. Interfaces > Devices > Point-to-Point, pppoe0: Link interface(s) $port; Save"
    gui_form post "/interfaces_ppps_edit.php?id=0" "ports[]=$port" || die "the Point-to-Point device was not saved"
    step "6. Interfaces > [WAN]: Save and Apply changes, so that PPPoE dials on $port"
    gui_form post "/interfaces.php?if=wan" || die "the WAN was not saved"
    gui_form post "/interfaces.php?if=wan" --submit apply || die "the WAN was not applied"
    if [ "$verb" = off ]; then
        uuid=$(do_api GET /api/interfaces/vlan_settings/search_item | sed -n 's/.*"uuid":"\([0-9a-f-]*\)"[^}]*"vlanif":"vlan0.40".*/\1/p')
        if [ -n "$uuid" ]; then
            step "the VLAN device is removed"
            do_api POST "/api/interfaces/vlan_settings/del_item/$uuid" '{}'
            do_api POST /api/interfaces/vlan_settings/reconfigure '{}'
        fi
    fi
    step "the configurations that the in-guest reset of run-tests.sh puts back get the same PPPoE port and VLAN device"
    if ! opn_vlan_base; then
        rc=1
        say "A reset to a configuration marked NOT SAVED would put PPPoE back where it was before this switch."
        say "Before the next run of run-tests.sh in that profile, with clat-opn in that profile:"
        say "  bash lab.sh plugin remove"
        say "  bash lab.sh o 'cp /conf/config.xml <the file marked NOT SAVED>'"
        say "  bash lab.sh plugin install        (or, for the package: bash lab.sh fw install os-clat)"
    fi
    sleep 10
    step "result"
    opn_sh 'for i in hn1 vlan0.40 pppoe0; do ifconfig $i 2>&1 | head -n 1; done; grep -E "pppoe iface|max-payload|link mtu" /var/etc/mpd_wan.conf'
    return $rc
}

# ---- the package and its repository (../packaging/README.md, "In the lab") ------------------------------------------

REPO_URL=https://repo.clat.lab/os-clat  # stands in for https://os-pkg.gettuckamore.ca (world/rootfs: ispctl, isp-repo.service)
REPO_CA='os-clat lab CA'

repo_secrets() {        # made once, kept in .work and never in git: the signing key, a CA, the certificate of repo.clat.lab
    ( cd "$BUILD" && umask 077 && export MSYS_NO_PATHCONV=1 || exit 1
      [ -s repo-signing.key ] || openssl genrsa -out repo-signing.key 4096 2>/dev/null || exit 1
      if [ ! -s repo-tls.crt ]; then
          openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout repo-ca.key -out repo-ca.crt -days 3650 \
              -subj "/CN=$REPO_CA" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null &&
          openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout repo-tls.key -out repo-tls.csr \
              -subj /CN=repo.clat.lab -addext subjectAltName=DNS:repo.clat.lab -addext basicConstraints=critical,CA:FALSE \
              -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=serverAuth 2>/dev/null &&
          openssl x509 -req -in repo-tls.csr -CA repo-ca.crt -CAkey repo-ca.key -CAcreateserial -days 825 -copy_extensions copy \
              -out repo-tls.crt 2>/dev/null || exit 1
          rm -f repo-tls.csr repo-ca.srl
      fi
      # the fingerprint as set-up step 4 of ../packaging/README.md computes it
      openssl rsa -in repo-signing.key -pubout 2>/dev/null | tr -d '\r' | sha256sum | cut -c1-64 > repo-signing.sha256 )
}

do_repo() {
    local verb=${1:-} rev=${2:-} hash line body
    need_cfg
    case "$verb" in
    build)      # the two scripts of ../packaging as publish.yml calls them, on clat-opn; then the site goes to clat-world
        case "$rev" in ''|[1-9]|[1-9][0-9]) ;; *) die "usage: lab.sh repo build [revision 1..99]" ;; esac
        repo_secrets || die "cannot make the lab's signing key and certificates in $BUILD"
        bundle || die "cannot pack the plugin tree"
        hash=$(cat "$BUILD/os-clat.sha256")     # stands in for the commit: the lab builds the working tree as it is
        step "net/clat and packaging to clat-opn:/root/os-clat (a framework archive fetched earlier is kept)"
        opn_sh 'mkdir -p /root/os-clat.keep && mv /root/os-clat/packaging/work/plugins-*.tar.gz /root/os-clat.keep/ 2>/dev/null
rm -rf /root/os-clat && mkdir -p /root/os-clat/packaging/work && mv /root/os-clat.keep/* /root/os-clat/packaging/work/ 2>/dev/null
rmdir /root/os-clat.keep' || die "clat-opn does not answer"
        ( cd "$LAB/.." && tar --owner=0 --group=0 --numeric-owner --exclude=__pycache__ --exclude='*.pyc' --exclude=packaging/work \
            -cf - net/clat packaging ) | ssh -F "$SSHCFG" clat-opn tar -C /root/os-clat -xf - || die "cannot copy the two folders"
        # the key as the workflow places it; the fingerprint file as committed for a release (here: the lab key's)
        ssh -F "$SSHCFG" clat-opn 'umask 077; cat > /root/os-clat/packaging/work/signing.key' < "$BUILD/repo-signing.key" || die "cannot copy the signing key"
        ssh -F "$SSHCFG" clat-opn 'cat > /root/os-clat/packaging/repo-key.sha256' < "$BUILD/repo-signing.sha256" || die "cannot copy the fingerprint"
        if [ -n "$rev" ]; then
            opn_sh "cd /root/os-clat/net/clat && printf 'PLUGIN_REVISION=\\t$rev\\n' | cat - Makefile > Makefile.rev && mv Makefile.rev Makefile && head -n 3 Makefile" || die "cannot set the revision"
        fi
        step "build-package.sh and make-repo.sh (RELEASE_TAG='${RELEASE_TAG:-}', PLUGIN_HASH=$hash, SITE_URL=$REPO_URL)"
        opn_sh "cd /root/os-clat || exit 1
export RELEASE_TAG='${RELEASE_TAG:-}' PLUGIN_HASH=$hash SIGNING_KEY=packaging/work/signing.key
sh packaging/build-package.sh < /dev/null && SITE_URL=$REPO_URL sh packaging/make-repo.sh < /dev/null
rc=\$?
rm -f packaging/work/signing.key
exit \$rc" || die "the build failed; nothing was published"
        step "the site to clat-world:/srv/isp-repo/os-clat, served as $REPO_URL"
        cat "$BUILD/repo-tls.crt" "$BUILD/repo-tls.key" | wssh 'umask 077; cat > /etc/isp/repo-tls.pem' || die "cannot copy the certificate"
        wssh 'cat > /etc/isp/repo-ca.crt' < "$BUILD/repo-ca.crt" || die "cannot copy the CA certificate"
        ssh -F "$SSHCFG" clat-opn tar -C /root/os-clat/packaging/work/site -cf - . |
            wssh 'rm -rf /srv/isp-repo/os-clat.new && mkdir -p /srv/isp-repo/os-clat.new && tar -C /srv/isp-repo/os-clat.new -xf - &&
rm -rf /srv/isp-repo/os-clat && mv /srv/isp-repo/os-clat.new /srv/isp-repo/os-clat && systemctl restart isp-repo && sleep 1 &&
echo "isp-repo is $(systemctl is-active isp-repo)" && cd /srv/isp-repo && find os-clat -type f | sort | xargs ls -l &&
curl -sS -m 10 --cacert /etc/isp/repo-ca.crt --resolve "repo.clat.lab:443:[$(dig +short @2001:db8:64::53 repo.clat.lab AAAA)]" https://repo.clat.lab/os-clat/os-clat.conf' ||
            die "the site was not published"
        ;;
    subscribe)  # what a subscriber does in the shell of the router, with the lab's address
        step "System > Trust > Authorities: the lab CA that signed the certificate of repo.clat.lab (the real site needs no such step)"
        if do_api GET /api/trust/ca/search | grep -q "\"descr\":\"$REPO_CA\""; then
            say "\"$REPO_CA\" is there already"
        else
            body=$(awk -v d="$REPO_CA" 'BEGIN { printf "{\"ca\":{\"action\":\"existing\",\"descr\":\"%s\",\"crt_payload\":\"", d }
                { printf "%s\\n", $0 } END { printf "\"}}" }' "$BUILD/repo-ca.crt") || die "no $BUILD/repo-ca.crt (bash lab.sh repo build)"
            do_api POST /api/trust/ca/add "$body"
        fi
        step "the install line of the site, pasted into root's shell (csh) on clat-opn"
        line=$(wssh "sed -n 's|.*<pre><code>\\(mkdir -p .*\\)</code></pre>.*|\\1|p' /srv/isp-repo/os-clat/index.html | sed 's/&amp;/\\&/g'" </dev/null)
        [ -n "$line" ] || die "no install line in /srv/isp-repo/os-clat/index.html on clat-world (bash lab.sh repo build)"
        say "$line"
        ssh -F "$SSHCFG" clat-opn "$line" </dev/null
        say "exit status $?"
        opn_sh 'ls -l /usr/local/etc/pkg/repos/os-clat.conf /usr/local/etc/pkg/fingerprints/os-clat/trusted/os-clat.fingerprint /usr/local/etc/pkg/fingerprints/os-clat/revoked
cat /usr/local/etc/pkg/repos/os-clat.conf /usr/local/etc/pkg/fingerprints/os-clat/trusted/os-clat.fingerprint'
        ;;
    *) die "usage: lab.sh repo build [revision] | subscribe" ;;
    esac
}

do_fw() {       # what a button under System > Firmware does: the API call, then the progress the page polls
    local action=${1:-} pkg=${2:-}
    case "$action" in
    check|update) [ -z "$pkg" ] || die "lab.sh fw $action takes no package" ;;
    install|remove) case "$pkg" in os-*[!a-z0-9-]*|os-) die "not a plugin name: $pkg" ;; os-*) ;; *) die "usage: lab.sh fw $action os-<name>" ;; esac ;;
    info) pkg=${pkg:-os-clat} ;;
    *) die "usage: lab.sh fw check | update | info [name] | install os-<name> | remove os-<name>" ;;
    esac
    need_cfg
    wssh "bash -s $action $pkg" <<'EOF'
. /root/lab.env
api() { curl -sk -m 120 -u "$API_KEY:$API_SECRET" "$@"; }
base=https://10.99.0.2/api/core/firmware
if [ "$1" = info ]; then        # the row of the Plugins tab
    api "$base/info" | jq -c --arg n "$2" '[.plugin[] | select(.name == $n)]'
    exit
fi
echo "POST /api/core/firmware/$1${2:+/$2}: $(api -H 'Content-Type: application/json' -d '{}' "$base/$1${2:+/$2}")"
sleep 3
while :; do
    out=$(api "$base/upgradestatus")
    status=$(printf '%s' "$out" | jq -r .status 2>/dev/null)
    case "$status" in done|reboot) break ;; esac
    [ "$SECONDS" -lt 900 ] || { echo "no end within 900 s"; break; }
    sleep 2
done
printf '%s' "$out" | jq -r .log
echo "== upgradestatus: $status after $SECONDS s"
if [ "$1" = check ]; then       # what the Status tab shows afterwards
    api "$base/status" | jq -c '{status, status_msg, connection, repository, product_version, needs_reboot, new_packages, upgrade_packages, reinstall_packages, remove_packages, downgrade_packages}'
fi
EOF
}

# ---- the small verbs ----------------------------------------------------------------------------------------------

do_api() {
    local method=${1:-} path=${2:-} body=${3:-}
    case "$method" in GET|POST) ;; *) die "usage: lab.sh api GET|POST /api/<path> [json]" ;; esac
    case "$path" in /api/*) ;; *) die "the path must start with /api/" ;; esac
    case "$path" in *[!A-Za-z0-9/_.?=%-]*) die "the path has a character this script does not pass on" ;; esac
    need_cfg
    if [ "$method" = GET ]; then
        wssh ". /root/lab.env && curl -sk -m 120 -u \"\$API_KEY:\$API_SECRET\" -w '\nHTTP %{http_code}\n' 'https://$OPN$path'" </dev/null
    else
        [ -n "$body" ] || body='{}'
        printf '%s' "$body" | wssh ". /root/lab.env && curl -sk -m 180 -u \"\$API_KEY:\$API_SECRET\" -H 'Content-Type: application/json' --data-binary @- -w '\nHTTP %{http_code}\n' 'https://$OPN$path'"
    fi
}

main() {
    local verb=${1:-}
    [ $# -eq 0 ] || shift
    case "$verb" in
    rights) do_rights ;;
    hv) do_hv "$@" ;;
    hvlog) do_hvlog "$@" ;;
    addr) do_addr "$@" ;;
    w)  need_cfg
        if [ $# -eq 0 ]; then wssh; elif [ $# -eq 1 ]; then wssh "$1"; else wssh "$(quote "$@")"; fi ;;
    c)  need_cfg
        [ $# -gt 0 ] || die "usage: lab.sh c <command ...>"
        if [ $# -eq 1 ]; then wssh "ispctl client sh -c $(quote "$1")"; else wssh "ispctl client $(quote "$@")"; fi ;;
    o)  need_cfg
        if [ $# -eq 0 ]; then opn_sh "$(cat)"; else opn_sh "$*"; fi ;;
    api) do_api "$@" ;;
    st) need_cfg; opn_sh 'configctl clat details' ;;
    world) do_world ;;
    opn-wait) do_opn_wait ;;
    opn-provision) do_opn_provision ;;
    plugin) do_plugin "$@" ;;
    gui-form) need_cfg
        [ $# -ge 2 ] || die "usage: lab.sh gui-form fields|post|text <page> [--submit NAME] [NAME=VALUE ...]"
        gui_form "$@" ;;
    opn-prod) do_opn_prod ;;
    opn-vlan) do_opn_vlan "$@" ;;
    repo) do_repo "$@" ;;
    fw) do_fw "$@" ;;
    screens) command -v node >/dev/null 2>&1 || die "node is not on the PATH"
        node "$LAB/screens/capture.mjs" "$@" ;;
    t25) need_cfg
        command -v node >/dev/null 2>&1 || die "node is not on the PATH"
        node "$LAB/screens/t25.mjs" "$@" ;;
    gui) need_cfg
        say "https://127.0.0.1:8443 is the GUI of clat-opn while this runs (user root; the certificate is self-signed). Ctrl-C ends it."
        ssh -F "$SSHCFG" -N -L 127.0.0.1:8443:$OPN:443 clat-world ;;
    ''|-h|--help|help) usage ;;
    *) die "unknown verb '$verb' (see: bash lab.sh --help)" ;;
    esac
}

log=yes
case "${1:-}" in
gui|''|-h|--help|help) log=no ;;
w) [ $# -gt 1 ] || log=no ;;            # the bare shell on clat-world
esac
if [ "$log" = no ]; then
    main "$@"
    exit $?
fi
mkdir -p "$RESULTS" || die "cannot create $RESULTS"
printf '\n### %s UTC  lab.sh %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$*" >> "$RESULTS/lab.log"
main "$@" 2>&1 | tee -a "$RESULTS/lab.log"
exit "${PIPESTATUS[0]}"
