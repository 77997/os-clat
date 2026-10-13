#!/usr/bin/env bash
# build.sh - milestone M1 of the os-clat Hyper-V lab: everything the two VMs are made from.
#
#   bash build.sh              download what is missing, verify it, make the lab key and secrets (once),
#                              render the OPNsense configuration and the cloud-init seed, build
#                              .work/disks/base-opnsense-26.7.vhdx, base-debian-13.vhdx, base-world-seed.iso
#   bash build.sh --factory    leave the OPNsense image as published (Path B: the configuration is then
#                              restored through the web GUI with opnsense/web-restore.sh)
#   bash build.sh --force      also rewrite a base-* file while lab VMs exist (results/lab-state.json)
#
# Runs on the Windows host in Git Bash. It calls no Hyper-V cmdlet and installs nothing on Windows.
# What Git Bash lacks (Python for opnsense/seed_config.py, qemu-img, xorriso) runs in throwaway containers
# through wslc: --rm, one at a time, one retry after 30 s on ERROR_TIMEOUT. Only .work is writable there.
#
# Safe to run again: a download that matches its checksum is kept, the key and the secrets are made once
# (the seeded image contains them), and a base file is rebuilt only when what it is made from changed
# (.work/disks/build/built.txt remembers that; delete the file to rebuild everything).
#
# Result lines start with "OK"; the script stops at the first "STOP". Everything is also written to
# .work/results/assets.txt (hashes, sizes, the output of seed_config.py and qemu-img; no secret).
#
# This script has run on the lab host and made the base files (.work/results/assets.txt says when and from
# what). Whether Hyper-V reads them, and whether the VMs boot from them, is NOT TESTED: see README.md,
# "What the first run has to confirm".
set -u

LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$LAB/.work
CACHE=$WORK/cache
DISKS=$WORK/disks
BUILD=$DISKS/build
RESULTS=$WORK/results
STATE=$RESULTS/lab-state.json
ASSETS=$RESULTS/assets.txt
STAMPS=$BUILD/built.txt
RAW=$DISKS/clat-opn.raw                # 3 GiB, exists only while this script runs

OPN_URL=https://pkg.opnsense.org/releases/26.7
OPN_BZ2=OPNsense-26.7-nano-amd64.img.bz2
OPN_SUMS=OPNsense-26.7-checksums-amd64.sha256
DEB_URL=https://cloud.debian.org/images/cloud/trixie/latest
DEB_IMG=debian-13-generic-amd64.qcow2
DEB_SUMS=SHA512SUMS
RAW_BYTES=3221225472
BASE_OPN=base-opnsense-26.7.vhdx
BASE_DEB=base-debian-13.vhdx
SEED_ISO=base-world-seed.iso
PPPOE_USER_DEFAULT=clat-sub

say() { printf '%s\n' "$*"; }
ok()  { printf 'OK %s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

FORCE=no
MODE=seeded
for arg in "$@"; do
    case "$arg" in
    --force) FORCE=yes ;;
    --factory) MODE=factory ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $arg (see: bash build.sh --help)" ;;
    esac
done

for tool in curl sha256sum sha512sum bzip2 openssl ssh-keygen base64 sed awk cmp cygpath df stat wslc.exe; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on the PATH of this shell (run from Git Bash)"
done
mkdir -p "$CACHE" "$BUILD/seed" "$RESULTS" || die "cannot create the folders under $WORK"
WORK_W=$(cygpath -w "$WORK")
OPNDIR_W=$(cygpath -w "$LAB/opnsense")

sha256_of() { sha256sum "$1" | cut -c1-64; }
stamp_get() { [ -f "$STAMPS" ] && sed -n "s/^$1=//p" "$STAMPS" | tail -n 1; }
stamp_set() {
    { [ -f "$STAMPS" ] && grep -v "^$1=" "$STAMPS"; echo "$1=$2"; } > "$STAMPS.new" && mv "$STAMPS.new" "$STAMPS"
}
secret() {      # secret KEY: value from secrets.env (quotes and a CR are tolerated)
    sed -n "s/^$1=//p" "$BUILD/secrets.env" | head -n 1 | tr -d '\r' | sed "s/^[\"']//; s/[\"']\$//"
}
vms_exist() { [ -f "$STATE" ] && grep -q '"Name"' "$STATE"; }
guard_rewrite() {       # a file that exists is not replaced while VMs made from it may be running
    if [ -e "$1" ] && vms_exist && [ "$FORCE" != yes ]; then
        die "$(basename "$1") would be rewritten while lab VMs exist ($STATE). Remove the lab first (hyperv/remove-lab.ps1), or repeat with --force when no lab VM is running."
    fi
}

# ctr NAME IMAGE SCRIPT [wslc arguments]: run SCRIPT with sh in a throwaway container. The script writes
# its own output to /work/results/build-NAME.log (long output read directly from wslc was seen to lose
# its beginning); that file is printed here afterwards. Returns the container's exit status.
ctr() {
    local name=$1 image=$2 script=$3 try rc out
    shift 3
    rm -f "$RESULTS/build-$name.log"
    for try in 1 2; do
        out=$(MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$WORK_W:/work" "$@" "$image" sh -c "$script" 2>&1 | tr -d '\0'; exit "${PIPESTATUS[0]}")
        rc=$?
        [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    wslc: /'
        case "$out" in
        *ERROR_TIMEOUT*) [ "$try" = 1 ] && { say "    wslc timed out; one more try in 30 s"; sleep 30; continue; } ;;
        esac
        break
    done
    [ -f "$RESULTS/build-$name.log" ] && sed 's/^/    /' "$RESULTS/build-$name.log"
    return "$rc"
}

# ---- 1. free space --------------------------------------------------------------------------------------
free_kb=$(df -k "$WORK" | awk 'NR==2 { print $4 }')
free_gb=$(( ${free_kb:-0} / 1048576 ))
say "== 1 free space on the drive of $WORK: $free_gb GB"
if vms_exist; then need_gb=8; else need_gb=20; fi      # the whole lab needs about 17 GB at its peak; a rebuild about 6
[ "$free_gb" -ge "$need_gb" ] || die "less than $need_gb GB free"

# ---- 2. downloads, 3. checksums -------------------------------------------------------------------------
fetch() { say "   download $1"; curl -fL --retry 3 -C - -o "$2" "$1"; }

say "== 2 downloads (only what is missing) and checksums"
if [ ! -s "$CACHE/$OPN_BZ2" ] || [ ! -s "$CACHE/$OPN_SUMS" ]; then
    rm -f "$CACHE/$OPN_SUMS"
    fetch "$OPN_URL/$OPN_SUMS" "$CACHE/$OPN_SUMS" || die "cannot download $OPN_SUMS"
    fetch "$OPN_URL/$OPN_BZ2" "$CACHE/$OPN_BZ2" || die "cannot download $OPN_BZ2"
fi
if [ ! -s "$CACHE/$DEB_IMG" ] || [ ! -s "$CACHE/$DEB_SUMS" ]; then
    rm -f "$CACHE/$DEB_SUMS"            # "latest" moves: image and checksum file must be from the same moment
    fetch "$DEB_URL/$DEB_SUMS" "$CACHE/$DEB_SUMS" || die "cannot download $DEB_SUMS"
    fetch "$DEB_URL/$DEB_IMG" "$CACHE/$DEB_IMG" || die "cannot download $DEB_IMG"
fi

# BSD format: SHA256 (<file>) = <hex>
opn_want=$(grep -F "($OPN_BZ2)" "$CACHE/$OPN_SUMS" | grep -oE '[0-9a-f]{64}' | head -n 1)
opn_have=$(sha256_of "$CACHE/$OPN_BZ2")
if [ -z "$opn_want" ] || [ "$opn_want" != "$opn_have" ]; then
    die "sha256 of $OPN_BZ2 is $opn_have, the publisher's file says '${opn_want:-nothing}'. Delete $CACHE/$OPN_BZ2 and $CACHE/$OPN_SUMS and run again."
fi
ok "sha256 $OPN_BZ2"
# GNU format: <hex>  <file>
deb_want=$(awk -v f="$DEB_IMG" '$2 == f { print $1 }' "$CACHE/$DEB_SUMS" | head -n 1)
deb_have=$(sha512sum "$CACHE/$DEB_IMG" | cut -c1-128)
if [ -z "$deb_want" ] || [ "$deb_want" != "$deb_have" ]; then
    die "sha512 of $DEB_IMG does not match $DEB_SUMS (has 'latest' moved?). Delete $CACHE/$DEB_IMG and $CACHE/$DEB_SUMS and run again."
fi
ok "sha512 $DEB_IMG"

# ---- 4. lab key and secrets, once -----------------------------------------------------------------------
say "== 4 lab ssh key and secrets"
if [ ! -s "$BUILD/lab_ed25519" ] || [ ! -s "$BUILD/lab_ed25519.pub" ]; then
    guard_rewrite "$DISKS/$BASE_OPN"
    rm -f "$BUILD/lab_ed25519" "$BUILD/lab_ed25519.pub"
    ssh-keygen -q -t ed25519 -N "" -C clat-lab -f "$BUILD/lab_ed25519" || die "ssh-keygen failed"
    say "   made $BUILD/lab_ed25519"
fi
if [ ! -s "$BUILD/secrets.env" ]; then
    guard_rewrite "$DISKS/$BASE_OPN"
    api_secret=$(openssl rand -hex 20) || die "openssl rand failed"
    api_crypt=$(printf '%s' "$api_secret" | openssl passwd -6 -salt "$(openssl rand -hex 8)" -stdin) || die "openssl passwd failed"
    case "$api_crypt" in '$6$'*) ;; *) die "openssl passwd -6 did not return a SHA-512 crypt string" ;; esac
    {
        echo "# Secrets of the os-clat lab, made once by build.sh. They are inside the seeded OPNsense base image"
        echo "# and the cloud-init seed, and \"lab.sh world\" copies this file to clat-world as /root/lab.env."
        echo "# KEY=value, no spaces. They protect nothing outside the lab."
        echo "PPPOE_USER=$PPPOE_USER_DEFAULT"
        echo "PPPOE_PASS=$(openssl rand -hex 12)"
        echo "CONSOLE_PASS=$(openssl rand -hex 8)"
        echo "API_KEY=$(openssl rand -hex 20)"
        echo "API_SECRET=$api_secret"
        echo "API_SECRET_CRYPT='$api_crypt'"
        # the GUI login of clat-opn is OPNsense's published factory default; screens/capture.mjs reads it here
        echo "GUI_USER=root"
        echo "GUI_PASS=opnsense"
    } > "$BUILD/secrets.env"
    say "   made $BUILD/secrets.env"
fi
PPPOE_USER=$(secret PPPOE_USER); PPPOE_PASS=$(secret PPPOE_PASS); CONSOLE_PASS=$(secret CONSOLE_PASS)
API_KEY=$(secret API_KEY); API_SECRET=$(secret API_SECRET); API_SECRET_CRYPT=$(secret API_SECRET_CRYPT)
for v in PPPOE_USER PPPOE_PASS CONSOLE_PASS API_KEY API_SECRET API_SECRET_CRYPT; do
    [ -n "${!v}" ] || die "$BUILD/secrets.env has no $v"
done
# what world/install.sh, the YAML string in user-data and the sed calls below can carry
case "$PPPOE_USER" in *[!A-Za-z0-9._@-]*) die "PPPOE_USER may contain letters, digits and . _ @ - only" ;; esac
case "$PPPOE_PASS" in *[!A-Za-z0-9._@%+=:,/-]*) die "PPPOE_PASS has a character world/install.sh does not accept" ;; esac
case "$CONSOLE_PASS" in *[!A-Za-z0-9]*) die "CONSOLE_PASS may contain letters and digits only" ;; esac
case "$API_KEY$API_SECRET" in *[!A-Za-z0-9]*) die "API_KEY and API_SECRET may contain letters and digits only" ;; esac
case "$API_SECRET_CRYPT" in *[!A-Za-z0-9./\$]*) die "API_SECRET_CRYPT is not a crypt string" ;; esac
PUBKEY=$(head -n 1 "$BUILD/lab_ed25519.pub" | tr -d '\r')
case "$PUBKEY" in "ssh-ed25519 "*) ;; *) die "$BUILD/lab_ed25519.pub is not an ed25519 public key" ;; esac
case "$PUBKEY" in *[\|\&\\\"]*) die "the public key line has a character the templates cannot carry" ;; esac
ok "key and secrets present (PPPoE user $PPPOE_USER)"

# ---- 5. render the OPNsense configuration and the cloud-init seed ---------------------------------------
say "== 5 render clat-opn-config.xml and the cloud-init seed"
keys_b64=$(printf '%s\n' "$PUBKEY" | base64 -w0)
pass_b64=$(printf '%s' "$PPPOE_PASS" | base64 -w0)
# adapter order of hyperv/lab-common.ps1 for clat-opn: lan, wan, mgmt = hn0, hn1, hn2
sed -e "s|@@LAN_IF@@|hn0|" -e "s|@@WAN_PORT@@|hn1|" -e "s|@@MGMT_IF@@|hn2|" \
    -e "s|@@AUTHORIZED_KEYS_B64@@|$keys_b64|" \
    -e "s|@@API_KEY@@|$API_KEY|" -e "s|@@API_SECRET_CRYPT@@|$API_SECRET_CRYPT|" \
    -e "s|@@PPPOE_USER@@|$PPPOE_USER|" -e "s|@@PPPOE_PASSWORD_B64@@|$pass_b64|" \
    "$LAB/opnsense/config.xml.template" | tr -d '\r' > "$BUILD/clat-opn-config.xml" || die "cannot render the OPNsense configuration"
if grep -q '@@' "$BUILD/clat-opn-config.xml"; then die "clat-opn-config.xml still has a @@PLACEHOLDER@@"; fi
grep -qF "<apikeys>$API_KEY|\$6\$" "$BUILD/clat-opn-config.xml" || die "clat-opn-config.xml: the API key line is not as expected"

sed -e "s|@@LAB_SSH_PUBKEY@@|$PUBKEY|g" -e "s|@@CONSOLE_PASS@@|$CONSOLE_PASS|" \
    "$LAB/world/user-data.tmpl" | tr -d '\r' > "$BUILD/seed/user-data" || die "cannot render user-data"
if grep -q '@@' "$BUILD/seed/user-data"; then die "user-data still has a @@PLACEHOLDER@@"; fi
[ "$(head -n 1 "$BUILD/seed/user-data")" = "#cloud-config" ] || die "user-data does not start with #cloud-config"
tr -d '\r' < "$LAB/world/network-config" > "$BUILD/seed/network-config"
# a new key means a new instance: cloud-init then runs again on a disk that has seen another seed
printf 'instance-id: clat-world-%s\nlocal-hostname: clat-world\n' "$(printf '%s' "$PUBKEY" | sha256sum | cut -c1-8)" > "$BUILD/seed/meta-data"
cfg_sha=$(sha256_of "$BUILD/clat-opn-config.xml")
seed_sha=$(cat "$BUILD/seed/user-data" "$BUILD/seed/meta-data" "$BUILD/seed/network-config" | sha256sum | cut -c1-64)
ok "rendered: clat-opn-config.xml $(stat -c %s "$BUILD/clat-opn-config.xml") bytes, seed/user-data, seed/meta-data, seed/network-config"

# ---- what has to be built -----------------------------------------------------------------------------------
py_sha=$(sha256_of "$LAB/opnsense/seed_config.py")
opn_id=$(printf '%s %s %s %s' "$opn_have" "$cfg_sha" "$py_sha" "$MODE" | sha256sum | cut -c1-64)
do_opn=1; do_deb=1; do_iso=1
[ -s "$DISKS/$BASE_OPN" ] && [ "$(stamp_get OPN_BASE_ID)" = "$opn_id" ] && do_opn=0
[ -s "$DISKS/$BASE_DEB" ] && [ "$(stamp_get DEB_BASE_ID)" = "$deb_have" ] && do_deb=0
[ -s "$DISKS/$SEED_ISO" ] && [ "$(stamp_get SEED_ID)" = "$seed_sha" ] && do_iso=0
[ "$do_opn" = 1 ] && guard_rewrite "$DISKS/$BASE_OPN"
[ "$do_deb" = 1 ] && guard_rewrite "$DISKS/$BASE_DEB"
[ "$do_iso" = 1 ] && guard_rewrite "$DISKS/$SEED_ISO"
say "== to build: $BASE_OPN=$do_opn $BASE_DEB=$do_deb $SEED_ISO=$do_iso (1 = build, 0 = kept: made from the same inputs)"

# ---- 6. decompress, 7. seed the configuration into the raw image --------------------------------------------
OPN_CONFIG=$(stamp_get OPN_CONFIG)
if [ "$do_opn" = 1 ]; then
    say "== 6 decompress $OPN_BZ2 (some minutes)"
    rm -f "$RAW"
    bzip2 -dc "$CACHE/$OPN_BZ2" > "$RAW" || { rm -f "$RAW"; die "bzip2 failed"; }
    raw_bytes=$(stat -c %s "$RAW")
    [ "$raw_bytes" = "$RAW_BYTES" ] || { rm -f "$RAW"; die "the raw image has $raw_bytes bytes, expected $RAW_BYTES"; }
    ok "raw $raw_bytes bytes"

    OPN_CONFIG=factory
    if [ "$MODE" = seeded ]; then
        say "== 7 seed_config.py: dry run, then the replacement (container python:3.11-alpine)"
        seed_script='exec > /work/results/build-seed.log 2>&1
S=__SCRIPT__
if [ "__RO__" = yes ]; then
    if touch /lab/opnsense/.build-write-test 2>/dev/null; then rm -f /lab/opnsense/.build-write-test; echo "MOUNT writable"; exit 21; fi
    echo "MOUNT read-only"
fi
python -V
sha256sum "$S"
python -I "$S" /work/disks/clat-opn.raw
rc=$?; echo "DRYRUN rc=$rc"
[ "$rc" -eq 0 ] || exit 0
python -I "$S" /work/disks/clat-opn.raw /work/disks/build/clat-opn-config.xml
echo "SEED rc=$?"
exit 0'
        s=${seed_script//__SCRIPT__//lab/opnsense/seed_config.py}
        ctr seed python:3.11-alpine "${s//__RO__/yes}" -v "$OPNDIR_W:/lab/opnsense:ro"
        rc=$?
        if [ "$rc" = 21 ]; then
            # wslc did not honour ":ro": no script folder is mounted writable; a copy inside .work is used
            cp "$LAB/opnsense/seed_config.py" "$BUILD/seed_config.py" || die "cannot copy seed_config.py"
            s=${seed_script//__SCRIPT__//work/disks/build/seed_config.py}
            ctr seed python:3.11-alpine "${s//__RO__/no}"
            rc=$?
            say "FALLBACK script copied into .work"
        elif grep -q '^MOUNT read-only' "$RESULTS/build-seed.log" 2>/dev/null; then
            ok "script mount is read-only"
        fi
        log=$RESULTS/build-seed.log
        [ "$rc" = 0 ] && grep -q '^DRYRUN rc=' "$log" 2>/dev/null || { rm -f "$RAW"; die "the seed container did not finish (exit $rc)"; }
        if grep -q '^DRYRUN rc=0' "$log"; then
            if ! grep -q '^SEED rc=0' "$log" || ! grep -q '^replaced [0-9]* bytes at offset [0-9]*' "$log"; then
                rm -f "$RAW"
                die "seed_config.py found its target but did not replace it (see $log). If the configuration is too long, shorten opnsense/config.xml.template (ntpd, timeservers); or build with --factory."
            fi
            # read the slot back from the host side and compare with what the script reported
            slot_len=$(sed -n 's/^replaced \([0-9]*\) bytes at offset \([0-9]*\).*/\1/p' "$log" | tail -n 1)
            slot_off=$(sed -n 's/^replaced \([0-9]*\) bytes at offset \([0-9]*\).*/\2/p' "$log" | tail -n 1)
            slot_sha=$(sed -n 's/^replaced .*new sha256=\([0-9a-f]*\).*/\1/p' "$log" | tail -n 1)
            tail -c "+$((slot_off + 1))" "$RAW" | head -c "$slot_len" > "$BUILD/seeded-slot.xml"
            [ "$(sha256_of "$BUILD/seeded-slot.xml")" = "$slot_sha" ] || { rm -f "$RAW"; die "the bytes at offset $slot_off do not have the sha256 the script reported"; }
            grep -q '<hostname>clat-opn</hostname>' "$BUILD/seeded-slot.xml" || { rm -f "$RAW"; die "the seeded slot is not the lab configuration"; }
            if grep -q 'trigger_initial_wizard\|mismatch0' "$BUILD/seeded-slot.xml"; then rm -f "$RAW"; die "the seeded slot still has factory content"; fi
            rm -f "$BUILD/seeded-slot.xml"
            OPN_CONFIG=seeded
            stamp_set OPN_SEED_SLOT "offset=$slot_off length=$slot_len sha256=$slot_sha"
            ok "seeded: $slot_len bytes at offset $slot_off replaced by the lab configuration (read back from the host)"
        else
            # the dry run opens the image read-only, so the image is still the published one
            say "seed_config.py printed STOP: the image is left as published. OPN_CONFIG=factory, M4 uses Path B (opnsense/web-restore.sh)."
        fi
    else
        say "== 7 skipped (--factory): the image is left as published"
    fi
    [ "$OPN_CONFIG" = seeded ] || stamp_set OPN_SEED_SLOT none
fi

# ---- 8. conversion and the seed image (container alpine:3.22) ------------------------------------------------
if [ "$do_opn$do_deb$do_iso" != 000 ]; then
    say "== 8 qemu-img and xorriso (container alpine:3.22)"
    conv_script='exec > /work/results/build-convert.log 2>&1
set -e
apk add --no-cache qemu-img xorriso >/dev/null
qemu-img --version | head -n 1
xorriso -version 2>&1 | grep -i "xorriso version" | head -n 1 || true
B=/work/disks/build
if [ __OPN__ = 1 ]; then
    echo "--- base-opnsense-26.7.vhdx"
    rm -f $B/tmp-opnsense.vhdx
    qemu-img convert -f raw -O vhdx -o subformat=dynamic /work/disks/clat-opn.raw $B/tmp-opnsense.vhdx
    qemu-img check -f vhdx $B/tmp-opnsense.vhdx
    qemu-img compare -f raw -F vhdx /work/disks/clat-opn.raw $B/tmp-opnsense.vhdx
    qemu-img info $B/tmp-opnsense.vhdx
    echo "DONE opnsense"
fi
if [ __DEB__ = 1 ]; then
    echo "--- base-debian-13.vhdx"
    rm -f $B/tmp-debian.vhdx
    qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic /work/cache/__DEBIMG__ $B/tmp-debian.vhdx
    qemu-img check -f vhdx $B/tmp-debian.vhdx
    qemu-img compare -f qcow2 -F vhdx /work/cache/__DEBIMG__ $B/tmp-debian.vhdx
    qemu-img info $B/tmp-debian.vhdx
    echo "DONE debian"
fi
if [ __ISO__ = 1 ]; then
    echo "--- base-world-seed.iso"
    rm -f $B/tmp-seed.iso
    cd $B/seed
    xorriso -as mkisofs -o $B/tmp-seed.iso -V CIDATA -J -r user-data meta-data network-config
    echo "--- volume id and content, read back from the image"
    xorriso -indev $B/tmp-seed.iso -pvd_info 2>&1 | grep -E "^Volume Id"
    xorriso -indev $B/tmp-seed.iso -lsl / 2>&1 | grep -E "user-data|meta-data|network-config"
    rm -rf /tmp/seedcheck; mkdir /tmp/seedcheck
    xorriso -osirrox on -indev $B/tmp-seed.iso -extract / /tmp/seedcheck >/dev/null 2>&1
    for f in user-data meta-data network-config; do cmp $f /tmp/seedcheck/$f; done
    echo "DONE seed"
fi
echo "DONE all"'
    s=${conv_script//__OPN__/$do_opn}; s=${s//__DEB__/$do_deb}; s=${s//__ISO__/$do_iso}; s=${s//__DEBIMG__/$DEB_IMG}
    ctr convert alpine:3.22 "$s"
    rc=$?
    log=$RESULTS/build-convert.log
    [ "$rc" = 0 ] && grep -q '^DONE all' "$log" 2>/dev/null || { rm -f "$RAW"; die "the conversion container did not finish (exit $rc; see $log)"; }
    if [ "$do_opn" = 1 ]; then
        grep -q '^DONE opnsense' "$log" || die "no DONE line for the OPNsense image"
        mv -f "$BUILD/tmp-opnsense.vhdx" "$DISKS/$BASE_OPN" || die "cannot move the OPNsense base into place (is it attached to a running VM?)"
        stamp_set OPN_BASE_ID "$opn_id"; stamp_set OPN_CONFIG "$OPN_CONFIG"
        ok "$BASE_OPN written, identical to the raw image (qemu-img compare), OPN_CONFIG=$OPN_CONFIG"
    fi
    if [ "$do_deb" = 1 ]; then
        grep -q '^DONE debian' "$log" || die "no DONE line for the Debian image"
        mv -f "$BUILD/tmp-debian.vhdx" "$DISKS/$BASE_DEB" || die "cannot move the Debian base into place"
        stamp_set DEB_BASE_ID "$deb_have"
        ok "$BASE_DEB written, identical to the qcow2 (qemu-img compare)"
    fi
    if [ "$do_iso" = 1 ]; then
        grep -q '^DONE seed' "$log" || die "no DONE line for the seed image"
        grep -q '^Volume Id *: CIDATA' "$log" || die "the seed image does not have the volume id CIDATA"
        mv -f "$BUILD/tmp-seed.iso" "$DISKS/$SEED_ISO" || die "cannot move the seed image into place (a running clat-world holds it open)"
        stamp_set SEED_ID "$seed_sha"
        ok "$SEED_ISO written: volume id CIDATA; user-data, meta-data, network-config read back identical"
    fi
fi

# ---- 9. the raw file goes ------------------------------------------------------------------------------------
rm -f "$RAW"
[ ! -e "$RAW" ] || die "cannot delete $RAW"

# ---- 10. record ----------------------------------------------------------------------------------------------
say "== 10 $ASSETS"
for f in "$DISKS/$BASE_OPN" "$DISKS/$BASE_DEB" "$DISKS/$SEED_ISO"; do [ -s "$f" ] || die "$f is missing"; done
OPN_CONFIG=$(stamp_get OPN_CONFIG)
{
    echo "# written by build.sh at $(date -u '+%Y-%m-%dT%H:%M:%SZ') (clock of the host). Hashes and sizes of what the lab is"
    echo "# built from. Nothing here says that a VM boots: no Hyper-V command has run on these files."
    echo "OPN_CONFIG=$OPN_CONFIG"
    echo "OPN_SEED_SLOT=$(stamp_get OPN_SEED_SLOT)"
    echo
    echo "## downloads (checked against the publisher's checksum files in the same folder)"
    echo "$OPN_BZ2 bytes=$(stat -c %s "$CACHE/$OPN_BZ2") sha256=$opn_have"
    echo "$OPN_SUMS bytes=$(stat -c %s "$CACHE/$OPN_SUMS") sha256=$(sha256_of "$CACHE/$OPN_SUMS")"
    echo "$DEB_IMG bytes=$(stat -c %s "$CACHE/$DEB_IMG") sha512=$deb_have"
    echo "$DEB_SUMS bytes=$(stat -c %s "$CACHE/$DEB_SUMS") sha256=$(sha256_of "$CACHE/$DEB_SUMS")"
    echo
    echo "## base files in .work/disks (kept by hyperv/remove-lab.ps1)"
    for f in "$BASE_OPN" "$BASE_DEB" "$SEED_ISO"; do
        echo "$f bytes=$(stat -c %s "$DISKS/$f") sha256=$(sha256_of "$DISKS/$f")"
    done
    echo
    echo "## inputs"
    echo "clat-opn-config.xml bytes=$(stat -c %s "$BUILD/clat-opn-config.xml") sha256=$cfg_sha"
    echo "opnsense/seed_config.py sha256=$py_sha"
    echo "seed (user-data + meta-data + network-config) sha256=$seed_sha"
    echo "lab key fingerprint: $(ssh-keygen -l -f "$BUILD/lab_ed25519.pub" 2>/dev/null)"
    for l in seed convert; do
        if [ -f "$RESULTS/build-$l.log" ]; then
            echo
            echo "## output of the last $l container (build-$l.log; it is from the run that built the files, not always this one)"
            cat "$RESULTS/build-$l.log"
        fi
    done
} > "$ASSETS.new" && mv -f "$ASSETS.new" "$ASSETS" || die "cannot write $ASSETS"

say
ls -l "$DISKS"
ok "build finished: OPN_CONFIG=$OPN_CONFIG; three base-* files in $DISKS; record in $ASSETS"
if [ "$OPN_CONFIG" != seeded ]; then
    say "NOTE: the OPNsense base is the published image. After its first boot run Path B (README.md, M4)."
fi
exit 0
