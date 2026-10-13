#!/bin/sh
# install.sh - make the Debian 13 VM "clat-world" the simulated ISP of the os-clat lab.
#
# Run as root on clat-world:   sh install.sh [ROOTFS_DIR]
#   ROOTFS_DIR  the staged tree, default: the directory "rootfs" next to this script
#   /root/lab.env must hold PPPOE_USER=... and PPPOE_PASS=...
#   (accepted instead of PPPOE_PASS: PPPOE_PASSWORD, or PPPOE_PASSWORD_B64 with the base64 form)
#
# Idempotent: every run stops the lab services, installs the files again and starts the services.
# After a run the ISP is at its defaults (the production profile), provisioning NAT is off, and no PPP
# session exists until the client dials again.
# The unit and package lists below are split into words on purpose:
# shellcheck disable=SC2086
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
export DEBIAN_FRONTEND=noninteractive

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/rootfs}
ENVF=${LAB_ENV:-/root/lab.env}
MARK=/var/lib/isp/provisioned
# dpkg must never ask about a configuration file this lab has replaced (nftables.conf, the PPP secrets)
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ISP sheet 1.3, plus jq, iputils-arping, netcat-openbsd (PLAN 3.1). dns-root-data is what
# unbound recommends (root hints and trust anchor); recommended packages are not installed otherwise.
# procps, iproute2 and kmod are expected in the image already; ispctl cannot work without them.
PKGS="ppp pppoe radvd kea-dhcp6-server tayga unbound dns-root-data nftables python3-scapy udhcpc
iperf3 tcpdump curl iputils-ping iputils-tracepath bind9-dnsutils mtr-tiny conntrack ethtool
hyperv-daemons jq iputils-arping netcat-openbsd procps iproute2 kmod"

# isp-repo is in the first list only: it runs once "lab.sh repo build" has brought its certificate
LAB_UNITS="isp-nat64 isp-pppoe isp-www isp-iperf3 isp-client isp-repo"
ALL_UNITS="isp-base isp-pppoe isp-nat64 isp-www isp-iperf3 isp-client unbound nftables"

step() { echo "install.sh: $*"; }
die()  { echo "install.sh: ERROR: $*" >&2; exit 1; }
states() {      # one line "unit=state ..." for the given units
    s_out=""
    for s_u in "$@"; do s_out="$s_out $s_u=$(systemctl is-active "$s_u" 2>/dev/null || true)"; done
    echo "$s_out"
}
getenv() {      # getenv KEY: value from lab.env; "export", quotes and a CR are tolerated
    sed -n "s/^\(export  *\)\{0,1\}$1=//p" "$ENVF" | head -n 1 | tr -d '\r' | sed "s/^[\"']//; s/[\"']\$//"
}

[ "$(id -u)" = 0 ] || die "must run as root"
[ -f "$SRC/usr/local/sbin/ispctl" ] || die "staged tree not found at $SRC"
[ -r "$ENVF" ] || die "$ENVF is missing"
chmod 600 "$ENVF" 2>/dev/null || true
PPPOE_USER=$(getenv PPPOE_USER)
PPPOE_PASS=$(getenv PPPOE_PASS)
[ -n "$PPPOE_PASS" ] || PPPOE_PASS=$(getenv PPPOE_PASSWORD)
[ -n "$PPPOE_PASS" ] || PPPOE_PASS=$(getenv PPPOE_PASSWORD_B64 | base64 -d 2>/dev/null || true)
if [ -z "$PPPOE_USER" ] || [ -z "$PPPOE_PASS" ]; then die "$ENVF needs PPPOE_USER and PPPOE_PASS"; fi
case "$PPPOE_USER" in
    *[!A-Za-z0-9._@-]*) die "PPPOE_USER may contain letters, digits and . _ @ - only" ;;
esac
case "$PPPOE_PASS" in
    *[!A-Za-z0-9._@%+=:,/-]*) die "PPPOE_PASS has a character this script does not write into chap-secrets" ;;
esac

TMP=$(mktemp)
trap 'rm -f "$TMP" /usr/sbin/policy-rc.d' EXIT

step "state before: $(states $ALL_UNITS radvd kea-dhcp6-server)"
step "failed units before: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"

# --- 1. no service is started by a package installation; apt's own timers stay quiet -------------
step "1 policy-rc.d, apt timers"
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
# stop, then mask: "mask --now" on a running timer leaves it "failed" (Unit to trigger vanished; systemd 257)
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer || step "  apt timers not masked"
apt_busy() {
    for a_u in apt-daily.service apt-daily-upgrade.service; do
        case "$(systemctl is-active "$a_u" 2>/dev/null || true)" in
            active|activating|deactivating) return 0 ;;
        esac
    done
    return 1
}
n=0
while apt_busy; do
    [ "$n" -lt 60 ] || die "apt-daily is still running after 10 minutes"
    [ "$n" -gt 0 ] || step "  waiting for a running apt-daily job"
    sleep 10
    n=$((n + 1))
done

# --- 2. AppArmor override for Kea, before the package brings its profile -------------------------
step "2 AppArmor override for kea-dhcp6"
install -D -m 644 "$SRC/etc/apparmor.d/local/usr.sbin.kea-dhcp6" /etc/apparmor.d/local/usr.sbin.kea-dhcp6

# --- 3. packages ----------------------------------------------------------------------------------
missing=""
for p in $PKGS; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing="$missing $p"
done
if [ -n "$missing" ]; then
    step "3 packages to install:$missing"
    n=1
    until $APT update; do
        [ "$n" -lt 6 ] || die "apt-get update failed six times"
        step "  apt-get update failed, next try in 20 s"
        sleep 20
        n=$((n + 1))
    done
    $APT install --no-install-recommends $PKGS
else
    step "3 packages: all installed already"
fi
for c in pppd pppoe-server radvd kea-dhcp6 tayga unbound unbound-checkconf nft python3 busybox iperf3 \
         ethtool ip pkill pgrep sysctl modprobe flock logger cmp; do
    command -v "$c" >/dev/null 2>&1 || die "command not found after the package installation: $c"
done
for c in tcpdump curl dig conntrack jq arping nc tracepath mtr ping; do     # test tools
    command -v "$c" >/dev/null 2>&1 || step "WARNING: test tool not found: $c"
done
python3 -c 'import scapy.all' 2>/dev/null || step "WARNING: python3 cannot import scapy (T10, reading captures)"

# --- 4. the staged tree -----------------------------------------------------------------------------
step "4 stop the lab services, copy $SRC to /"
systemctl stop $LAB_UNITS 2>/dev/null || true
(cd "$SRC" && find . -type f) | sed 's|^\./||' | sort | while IFS= read -r rel; do
    case "$rel" in
        usr/local/sbin/*|usr/local/lib/isp/*|etc/ppp/*-up.d/*|etc/ppp/*-down.d/*|etc/nftables.conf) mode=755 ;;
        *) mode=644 ;;
    esac
    tr -d '\r' < "$SRC/$rel" > "$TMP"   # a copy that passed through Windows must not leave a CR in a script
    install -D -m "$mode" "$TMP" "/$rel"
    echo "  $mode /$rel"
done
cmp -s /etc/isp/isp.env /etc/isp/isp.env.default || die "isp.env and isp.env.default differ in the staged tree"

# --- 5. PPP secrets ---------------------------------------------------------------------------------
step "5 chap-secrets, pap-secrets"
for f in /etc/ppp/chap-secrets /etc/ppp/pap-secrets; do
    rm -f "$f"
    (umask 077; printf '# written by install.sh from %s\n# client\tserver\tsecret\tIP addresses\n%s\t*\t"%s"\t*\n' \
        "$ENVF" "$PPPOE_USER" "$PPPOE_PASS" > "$f")
done

# --- 6. services --------------------------------------------------------------------------------------
step "6 services"
rm -f /usr/sbin/policy-rc.d
systemctl daemon-reload
sysctl --system >/dev/null
# Debian's own units for these would get in the way: radvd and Kea run only from the PPP hooks with a
# generated configuration, tayga.service sets up no tun, iperf3 is bound to the test target by isp-iperf3.
# pppoe-server is in the list only in case the pppoe package brings a unit of that name.
for u in tayga radvd kea-dhcp6-server iperf3 pppoe-server; do
    systemctl disable --now "$u.service" 2>/dev/null || true
done
apparmor_parser -r /etc/apparmor.d/usr.sbin.kea-dhcp6 || true
systemctl start hv-kvp-daemon.service 2>/dev/null || true      # lets the host read this VM's addresses
sh -n /usr/local/sbin/ispctl || die "ispctl does not pass sh -n"
nft -c -f /etc/nftables.conf || die "nft refuses /etc/nftables.conf"

fail=""
systemctl enable nftables.service isp-base.service unbound.service $LAB_UNITS
systemctl restart nftables.service || fail="$fail nftables"
systemctl restart isp-base.service || fail="$fail isp-base"
# unbound was installed without a start, so the trust anchor its unit copies before the first start is
# missing, and unbound-checkconf (ispctl checks before every restart) refuses the configuration without it
/usr/libexec/unbound-helper root_trust_anchor_update || true
/usr/local/sbin/ispctl dns64 on || fail="$fail unbound"
for u in $LAB_UNITS; do
    systemctl start "$u.service" || fail="$fail $u"
done

# --- 7. result ------------------------------------------------------------------------------------------
sleep 3
step "state after: $(states $ALL_UNITS radvd kea-dhcp6-server)"
step "failed units after: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
for u in $ALL_UNITS; do
    [ "$(systemctl is-active "$u" 2>/dev/null || true)" = active ] || fail="$fail $u"
done
if [ -n "$fail" ]; then
    rm -f "$MARK"
    die "not active:$fail  (see: systemctl status <unit>; journalctl -u <unit> -b)"
fi
mkdir -p /var/lib/isp
touch "$MARK"
step "DONE"
