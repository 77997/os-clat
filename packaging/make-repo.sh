#!/bin/sh
#
# make-repo.sh - make the signed pkg repository and the web site around it.
#
#   SIGNING_KEY=/path/to/repo.key sh packaging/make-repo.sh
#
# Runs on FreeBSD 15 or on an OPNsense 26.7 box (pkg, openssl), after build-package.sh.
# Input:  packaging/work/pkg/os-clat-<version>.pkg
# Result: packaging/work/site/   index.html, os-clat.conf, os-clat.fingerprint, repo/
#
# Environment:
#   SIGNING_KEY   RSA private key, PEM, without passphrase (required)
#   SITE_URL      where the site is served. The default below is the address that every
#                 subscribed router has stored; it is set in this one place (README.md in this
#                 folder, "The address"). A lab run gives file:///<directory>.
#   RELEASE_TAG   set by the publish workflow for a release: the version built must then not be
#                 lower than the one the site serves
#
# For an https address the key must be the one whose fingerprint is in packaging/repo-key.sha256.
#
# Run on an OPNsense 26.7.6 box in the lab (2026-10-12) with a lab key, for an https address of the
# lab and for a file:/// address; a router then installed and upgraded from the result. NOT run on
# plain FreeBSD 15.1, the machine of the publish workflow, nor with the release key. README.md in
# this folder lists what the first workflow run still has to confirm.
set -eu

# "pkg repo" calls this script again as its signing command: the SHA256 of a catalogue arrives on
# stdin, the signature and the public key leave on stdout (pkg-repo(8), signing_command).
if [ "${1:-}" = sign ]; then
    read -t 2 sum
    [ -n "$sum" ] || exit 1
    echo SIGNATURE
    printf '%s' "$sum" | openssl dgst -sign "$SIGNING_KEY" -sha256 -binary
    echo
    echo CERT
    cat "$SIGNING_PUB"
    echo END
    exit 0
fi

die() { echo "make-repo: $*" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SELF=$ROOT/packaging/make-repo.sh
TEMPLATES=$ROOT/packaging/site
PIN=$ROOT/packaging/repo-key.sha256
WORK=$ROOT/packaging/work
SITE=$WORK/site

SITE_URL=${SITE_URL:-https://os-pkg.gettuckamore.ca}
SITE_URL=${SITE_URL%/}
case "$SITE_URL" in
https://?*|file:///?*) ;;
*) die "SITE_URL must start with https:// (or file:/// for a local test), got '$SITE_URL'" ;;
esac
case "$SITE_URL" in
*[!A-Za-z0-9:/._~-]*) die "SITE_URL '$SITE_URL' has a character this script does not put into a file" ;;
esac

# pkg joins the words of the signing command with blanks, and sed gets these paths as text
case "$ROOT" in
*[!A-Za-z0-9/._-]*) die "the path $ROOT has a blank or another character this script cannot pass on" ;;
esac

[ -x /usr/local/sbin/pkg ] || die "/usr/local/sbin/pkg is missing"
[ -n "${SIGNING_KEY:-}" ] || die "SIGNING_KEY is not set"
[ -r "$SIGNING_KEY" ] || die "cannot read the signing key $SIGNING_KEY"
SIGNING_KEY=$(cd "$(dirname "$SIGNING_KEY")" && pwd)/$(basename "$SIGNING_KEY")

set -- "$WORK"/pkg/os-clat-*.pkg
[ $# -eq 1 ] && [ -s "$1" ] || die "expected exactly one package in $WORK/pkg (run build-package.sh first)"
package=$1
version=$(pkg query -F "$package" '%v')

tmp=$(mktemp -d /tmp/os-clat-repo.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# The public key is derived from the private key each time; its SHA256 is the fingerprint that
# routers trust (pkg-repo(8): "sha256 -q repo.pub").
SIGNING_PUB=$tmp/repo.pub
openssl rsa -passin pass: -in "$SIGNING_KEY" -pubout -out "$SIGNING_PUB" 2>/dev/null ||
    die "SIGNING_KEY is not an RSA private key in PEM form without passphrase"
fingerprint=$(sha256 -q "$SIGNING_PUB")
export SIGNING_KEY SIGNING_PUB

# What holds only for the site that routers use (a file:// site is a lab run with its own key).
case "$SITE_URL" in
https://*)
    # The fingerprint that routers trust is fixed in git. Another key must not sign what they
    # fetch: each of them would reject the catalogue and show no firmware updates at all.
    [ -s "$PIN" ] ||
        die "$PIN is missing; the key given has the fingerprint $fingerprint (README.md in this folder, set-up step 4)"
    pinned=$(tr -d '[:space:]' < "$PIN")
    [ "$pinned" = "$fingerprint" ] ||
        die "the key given has the fingerprint $fingerprint, but routers trust $pinned ($PIN); nothing was signed"

    # A release never puts a lower version on the site than the one it serves now, which a run
    # on an old tag would do. Before the first release there is no site and nothing to compare.
    if [ -n "${RELEASE_TAG:-}" ]; then
        live=$(fetch -qT 30 -o - "$SITE_URL/index.html" 2>/dev/null |
            sed -n 's|.*<b>os-clat \([^<]*\)</b>.*|\1|p' | head -n 1) || live=
        if [ -n "$live" ] && [ "$(pkg version -t "$live" "$version")" = '>' ]; then
            die "the site serves os-clat $live, which is higher than os-clat $version"
        fi
    fi
    ;;
esac

# 1. The repository: one directory, only the current package.
rm -rf "$SITE"
mkdir -p "$SITE/repo/All"
cp "$package" "$SITE/repo/All/"
pkg repo "$SITE/repo" signing_command: sh "$SELF" sign

# 2. What a router fetches once, and the page that says how.
sed -e "s|%%SITE_URL%%|$SITE_URL|g" "$TEMPLATES/os-clat.conf" > "$SITE/os-clat.conf"
printf 'function: "sha256"\nfingerprint: "%s"\n' "$fingerprint" > "$SITE/os-clat.fingerprint"
sed -e "s|%%SITE_URL%%|$SITE_URL|g" -e "s|%%VERSION%%|$version|g" -e "s|%%FINGERPRINT%%|$fingerprint|g" \
    "$TEMPLATES/index.html" > "$SITE/index.html"
chmod -R a+rX "$SITE"

# 3. Read the repository back the way a router will: the same definition and fingerprint file,
#    with the address and the two paths pointing here. pkg must accept the signature and find the
#    package. A repository that fails this must never be published: a router whose pkg cannot
#    update one of its repositories shows no firmware updates at all.
mkdir -p "$tmp/repos" "$tmp/fingerprints/trusted" "$tmp/fingerprints/revoked" "$tmp/db" "$tmp/cache"
cp "$SITE/os-clat.fingerprint" "$tmp/fingerprints/trusted/"
sed -e "s|%%SITE_URL%%|file://$SITE|g" -e "s|/usr/local/etc/pkg/fingerprints/os-clat|$tmp/fingerprints|" \
    "$TEMPLATES/os-clat.conf" > "$tmp/repos/os-clat.conf"
grep -q "\"$tmp/fingerprints\"" "$tmp/repos/os-clat.conf" || die "the fingerprints path in $TEMPLATES/os-clat.conf has changed; adjust this script"
pkg -R "$tmp/repos" -o PKG_DBDIR="$tmp/db" -o PKG_CACHEDIR="$tmp/cache" update -f ||
    die "pkg does not accept the repository it has just made"
found=$(pkg -R "$tmp/repos" -o PKG_DBDIR="$tmp/db" -o PKG_CACHEDIR="$tmp/cache" rquery -U '%n-%v' os-clat) || true
[ "$found" = "os-clat-$version" ] || die "the repository offers '$found', not os-clat-$version"

echo ">>> $SITE"
(cd "$SITE" && find . | sort)
echo ">>> OK os-clat-$version, address $SITE_URL, fingerprint $fingerprint"
