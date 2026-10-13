#!/bin/sh
# install-plugin.sh install|remove - put the os-clat plugin on clat-opn without a package, or take it off.
#
# Runs on clat-world as root (POSIX sh) and talks to clat-opn (10.99.0.2) over ssh with the lab key.
# Written from PLAN.md decision 19 and the OPNsense sheet 8.2 and 8.3.
# Both verbs have run against OPNsense 26.7.6 many times since 2026-10-11 (README.md section 10). The
# embedded fragment copies have not: lab.sh and run-tests.sh always push the fragments of the source tree.
#
# Input, copied to clat-world by "lab.sh plugin" or by run-tests.sh:
#   /root/os-clat.tar     tar of net/clat/src of this repository (files only, paths relative to /usr/local)
#   /root/os-clat.files   the same paths, one per line; kept on the box as /root/os-clat.files for "remove"
# Optional, the package script fragments of the same source tree (run-tests.sh copies them):
#   /root/os-clat.post-install      net/clat/+POST_INSTALL.post
#   /root/os-clat.pre-deinstall     net/clat/+PRE_DEINSTALL.pre
#   /root/os-clat.post-deinstall    net/clat/+POST_DEINSTALL.post
# Without them the copies embedded below are used (state of 2026-10-12) and a NOTE line says so.
#
# "install" does what "pkg add os-clat" would do: files to /usr/local with the package's modes, then
# the lines of the generated +POST_INSTALL (opnsense/plugins Mk/plugins.mk: configd restart, model
# migration, rc.configure_plugins, template reloads, then the .post fragment).
# "remove" does what "pkg delete os-clat" would do: +PRE_DEINSTALL, the files, rc.configure_plugins,
# +POST_DEINSTALL. It leaves what the package leaves: /etc/rc.conf.d/clat, /usr/local/etc/clat,
# /var/run/clat, /var/log/clat and the <clat> node in config.xml.
# Not done, because only pkg does it: the package registration and /usr/local/opnsense/version/clat.
# Where the plugin came as the package from the lab repository ("lab.sh fw install os-clat"), "remove"
# runs "pkg delete os-clat" instead and leaves tayga in place, and "install" refuses until that is done.
#
# Last line: "PLUGIN INSTALL rc=<n>" or "PLUGIN REMOVE rc=<n>"; the exit status is the same number.
#   install: 0 ok, 2 usage or input, 3 ssh or an unfinished script, 4 tayga missing,
#            5 a template reload did not print OK, 7 the package os-clat is installed
#   remove:  0 ok, 2 usage, 3 ssh or an unfinished script,
#            6 the box has neither /root/os-clat.files nor the package os-clat
set -u

OPN=${OPN:-10.99.0.2}
TAR=${TAR:-/root/os-clat.tar}
FILES=${FILES:-/root/os-clat.files}
FRAG_POST_INSTALL=${FRAG_POST_INSTALL:-/root/os-clat.post-install}
FRAG_PRE_DEINSTALL=${FRAG_PRE_DEINSTALL:-/root/os-clat.pre-deinstall}
FRAG_POST_DEINSTALL=${FRAG_POST_DEINSTALL:-/root/os-clat.post-deinstall}
VERB=${1:-}

# The management switch is private and holds these two VMs only, and the box gets new host keys with
# every rebuild. So the host key is not pinned here.
SSH="ssh -i /root/.ssh/id_ed25519 -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=10 -o ServerAliveCountMax=6 root@$OPN"

TMP=$(mktemp -d /tmp/os-clat.XXXXXX) || exit 2
trap 'rm -rf "$TMP"' EXIT

die() {         # die <rc> <text>
    echo "install-plugin: $2" >&2
    echo "PLUGIN $(echo "$VERB" | tr '[:lower:]' '[:upper:]') rc=$1"
    exit "$1"
}

# opn_run FILE: run a /bin/sh script on the box. root's shell there hands a remote command line to csh,
# so the script travels on stdin; it is stored first and then run with stdin closed, so that no command
# in it can swallow the lines that follow it.
opn_run() {
    {
        echo 'PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin; export PATH'
        echo 'f=$(mktemp /tmp/os-clat-run.XXXXXX) || exit 97'
        echo "cat > \"\$f\" <<'__OS_CLAT_SCRIPT_END__'"
        cat "$1"
        echo '__OS_CLAT_SCRIPT_END__'
        echo '/bin/sh "$f" < /dev/null; rc=$?; rm -f "$f"; exit $rc'
    } | $SSH /bin/sh -s
}

fragment() {    # fragment FILE NAME: print the pushed fragment of the source tree, else the embedded copy
    if [ -s "$1" ]; then
        echo "echo 'fragment $2: from the source tree, sha256 $(sha256sum "$1" | cut -c1-16)'"
        grep -v '^#!' "$1"
        return
    fi
    echo "echo 'NOTE fragment $2: embedded copy of 2026-10-12 used ($1 was not pushed)'"
    case "$2" in
    +POST_INSTALL.post)
        cat <<'EOF'
/usr/local/sbin/pluginctl -i || :
/usr/local/sbin/configctl clat restart || :
EOF
        ;;
    +PRE_DEINSTALL.pre)
        cat <<'EOF'
/usr/local/etc/rc.d/clat onestop >/dev/null 2>&1 || :
EOF
        ;;
    +POST_DEINSTALL.post)
        cat <<'EOF'
/usr/local/sbin/pluginctl -i || :
clat_pid=$(/sbin/ifconfig tun464 2>/dev/null | /usr/bin/sed -n 's/.*Opened by PID \([0-9][0-9]*\).*/\1/p')
if [ -n "${clat_pid}" ]; then
	/bin/kill ${clat_pid} >/dev/null 2>&1 || :
	/bin/sleep 1
fi
timeout 10 /sbin/ifconfig tun464 destroy >/dev/null 2>&1 || :
/bin/rm -f /tmp/tun464_oldip /tmp/tun464_oldgw
/bin/rm -rf /usr/local/opnsense/scripts/clat/lib/__pycache__
/usr/local/sbin/configctl interface routes configure || :
EOF
        ;;
    esac
}

do_install() {
    [ -s "$TAR" ] || die 2 "$TAR is missing or empty"
    [ -s "$FILES" ] || die 2 "$FILES is missing or empty"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$FILES"; then die 2 "$FILES has an absolute path or a '..'"; fi
    if grep -q "$(printf '\r')" "$FILES"; then die 2 "$FILES has CR line ends"; fi
    if grep -q '__OS_CLAT_' "$FILES"; then die 2 "$FILES has a line this script uses as a delimiter"; fi
    tar -tf "$TAR" | grep -v '/$' | LC_ALL=C sort > "$TMP/in-tar"
    LC_ALL=C sort "$FILES" > "$TMP/in-list"
    cmp -s "$TMP/in-tar" "$TMP/in-list" || die 2 "the content of $TAR and $FILES differ"
    for f in etc/rc.d/clat etc/inc/plugins.inc.d/clat.inc opnsense/scripts/clat/clatd.py \
             opnsense/service/conf/actions.d/actions_clat.conf opnsense/mvc/app/models/OPNsense/Clat/Clat.xml; do
        grep -qx "$f" "$FILES" || die 2 "$FILES does not list $f: is this the tar of net/clat/src?"
    done
    echo "install: $(wc -l < "$FILES") files, tar sha256 $(sha256sum "$TAR" | cut -d' ' -f1)"

    # 1. no package in the way, tayga present? Store the file list first, so that a later failure can still be removed.
    {
        echo 'pkg query %n os-clat >/dev/null 2>&1 && exit 7'
        echo 'test -x /usr/local/sbin/tayga || exit 4'
        echo "cat > /root/os-clat.files <<'__OS_CLAT_LIST_END__'"
        cat "$FILES"
        echo '__OS_CLAT_LIST_END__'
    } > "$TMP/pre.sh"
    opn_run "$TMP/pre.sh"
    case $? in
    0) ;;
    4) die 4 "tayga is not installed on $OPN (in the production profile: bash lab.sh o 'pkg install -y tayga'; else: lab.sh opn-provision)" ;;
    7) die 7 "the package os-clat is installed on $OPN: run \"remove\" first (bash lab.sh plugin remove)" ;;
    *) die 3 "ssh to $OPN failed, or the file list could not be written" ;;
    esac

    # 2. the files (no redirection in this command line: it is parsed by csh)
    $SSH tar -C /usr/local -xof - < "$TAR" || die 3 "cannot unpack the tar on $OPN"

    # 3. modes, then +POST_INSTALL
    {
        cat <<'EOF'
set -u
cd /usr/local || exit 1
# modes of the package: 644, and 755 for the rc.d script and the scripts under scripts/clat
# (Windows has no execute bit; README.md at the top of this repository, "Building the package")
while read -r f; do chown root:wheel "$f"; chmod 644 "$f"; done < /root/os-clat.files
chmod 755 etc/rc.d/clat opnsense/scripts/clat/*.py opnsense/scripts/clat/*.php opnsense/scripts/clat/lib/*.py
if grep -l "$(printf '\r')" $(cat /root/os-clat.files) 2>/dev/null; then echo "WARNING: the files named above have CR line ends"; fi
echo "--- +POST_INSTALL (generated part)"
if [ -f /usr/local/etc/rc.d/configd ]; then /usr/local/etc/rc.d/configd restart; fi
if [ -f /usr/local/opnsense/mvc/script/run_migrations.php ]; then /usr/local/opnsense/mvc/script/run_migrations.php OPNsense/Clat; fi
if [ -f /usr/local/etc/rc.configure_plugins ]; then echo "Reloading plugin configuration"; /usr/local/etc/rc.configure_plugins POST_INSTALL; fi
if [ -f /usr/local/sbin/configctl ]; then echo -n "Reloading template OPNsense/Clat: "; /usr/local/sbin/configctl template reload OPNsense/Clat; fi
if [ -f /usr/local/sbin/configctl ]; then echo -n "Reloading template OPNsense/Syslog: "; /usr/local/sbin/configctl template reload OPNsense/Syslog; fi
echo "--- +POST_INSTALL.post"
EOF
        fragment "$FRAG_POST_INSTALL" +POST_INSTALL.post
        echo 'echo "--- end of +POST_INSTALL"'
    } > "$TMP/install.sh"
    opn_run "$TMP/install.sh" > "$TMP/install.out" 2>&1
    rc=$?
    cat "$TMP/install.out"
    grep -q '^--- end of +POST_INSTALL' "$TMP/install.out" || die 3 "the install script did not run to its end (exit $rc)"
    bad=0
    for tpl in OPNsense/Clat OPNsense/Syslog; do
        line=$(grep "^Reloading template $tpl: " "$TMP/install.out" | tail -n 1)
        case "$line" in
        "Reloading template $tpl: OK") ;;
        *) echo "install-plugin: template $tpl did not reload: '${line:-no such line}'" >&2; bad=1 ;;
        esac
    done
    [ "$bad" -eq 0 ] || die 5 "a template reload did not print OK"
    echo "PLUGIN INSTALL rc=0"
}

do_remove() {
    cat > "$TMP/pre.sh" <<'EOF'
test -s /root/os-clat.files && exit 0
pkg query %n os-clat >/dev/null 2>&1 && exit 7
exit 1
EOF
    opn_run "$TMP/pre.sh"
    case $? in
    0) ;;
    1) die 6 "$OPN has no /root/os-clat.files and no package os-clat: nothing to remove" ;;
    7)  # The package from the repository ("lab.sh fw install os-clat"). tayga stays, because "install" needs it,
        # and is marked as installed on request: it came as a dependency, which the next "pkg autoremove" of a
        # firmware action would take away.
        cat > "$TMP/remove.sh" <<'EOF'
pkg delete -y os-clat && /usr/local/opnsense/scripts/firmware/register.php remove os-clat && pkg set -y -A 0 tayga && echo "--- end of pkg delete"
EOF
        opn_run "$TMP/remove.sh" > "$TMP/remove.out" 2>&1
        rc=$?
        cat "$TMP/remove.out"
        grep -q '^--- end of pkg delete' "$TMP/remove.out" || die 3 "pkg delete os-clat did not run to its end (exit $rc)"
        echo "PLUGIN REMOVE rc=0"
        return ;;
    *) die 3 "ssh to $OPN failed" ;;
    esac
    {
        cat <<'EOF'
set -u
echo "--- +PRE_DEINSTALL.pre"
EOF
        fragment "$FRAG_PRE_DEINSTALL" +PRE_DEINSTALL.pre
        cat <<'EOF'
echo "--- files"
cd /usr/local || exit 1
while read -r f; do rm -f "$f"; done < /root/os-clat.files
echo "--- +POST_DEINSTALL (generated part)"
if [ -f /usr/local/etc/rc.configure_plugins ]; then echo "Reloading plugin configuration"; /usr/local/etc/rc.configure_plugins POST_DEINSTALL; fi
echo "--- +POST_DEINSTALL.post"
EOF
        fragment "$FRAG_POST_DEINSTALL" +POST_DEINSTALL.post
        cat <<'EOF'
echo "--- directories"
# Directories the package created: remove those that are empty now, deepest first (rmdir refuses the rest).
# After the script, as pkg 2.8.4 does: the script is what empties opnsense/scripts/clat/lib of Python's cache.
sed -n 's|/[^/]*$||p' /root/os-clat.files | while read -r d; do
    while [ -n "$d" ]; do
        echo "$d"
        case "$d" in */*) d=${d%/*} ;; *) d= ;; esac
    done
done | sort -u | awk '{ print length($0), $0 }' | sort -rn | cut -d' ' -f2- | while read -r d; do
    if rmdir "$d" 2>/dev/null; then echo "removed directory /usr/local/$d"; fi
done
mv /root/os-clat.files /root/os-clat.files.removed
echo "--- end of +POST_DEINSTALL"
EOF
    } > "$TMP/remove.sh"
    opn_run "$TMP/remove.sh" > "$TMP/remove.out" 2>&1
    rc=$?
    cat "$TMP/remove.out"
    grep -q '^--- end of +POST_DEINSTALL' "$TMP/remove.out" || die 3 "the removal script did not run to its end (exit $rc)"
    echo "PLUGIN REMOVE rc=0"
}

case "$VERB" in
install) do_install ;;
remove)  do_remove ;;
*) echo "usage: install-plugin.sh install|remove" >&2; exit 2 ;;
esac
