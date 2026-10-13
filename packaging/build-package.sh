#!/bin/sh
#
# build-package.sh - build the os-clat package from net/clat.
#
#   sh packaging/build-package.sh
#
# Runs as root on FreeBSD 15 or on an OPNsense 26.7 box. Needs pkg and Internet access for two
# things: the plugin framework (below) and the package "tayga", which the framework installs with
# pkg when it is missing. Result: packaging/work/pkg/os-clat-<version>.pkg
#
# The package is made by "make package" of the OPNsense plugin framework (Mk/plugins.mk). The
# framework is not part of this repository: the archive of one fixed commit of opnsense/plugins is
# fetched to packaging/work/, and net/clat is copied into it as net/clat. To build on a box that
# cannot reach github.com, put that archive at packaging/work/plugins-<commit>.tar.gz beforehand.
#
# Environment, all optional:
#   RELEASE_TAG   when set, it must be "v<package version>" (the publish workflow passes the git tag)
#   PLUGIN_HASH   commit written into the package; default: HEAD of this checkout, else "unknown"
#   PLUGINS_REF   commit of opnsense/plugins to take the framework from
#
# Run on an OPNsense 26.7.6 box in the lab (2026-10-12), where it built os-clat-1.0.pkg and, with
# PLUGIN_REVISION=1, os-clat-1.0_1.pkg. NOT run on plain FreeBSD 15.1, the machine of the publish
# workflow. README.md in this folder lists what the first workflow run still has to confirm.
set -eu

# opnsense/plugins tag 26.7.6 (branch stable/26.7). A stable branch has no Mk/devel.mk, so the
# package is named os-clat; built from master it would be os-clat-devel. Without OPNsense on the
# build host the framework of this commit also sets the series (PLUGIN_ABI) to 26.7.
PLUGINS_REF=${PLUGINS_REF:-45b79b80aff277fc9edc97ce18bcd91177c40554}

die() { echo "build-package: $*" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/net/clat
WORK=$ROOT/packaging/work
ARCHIVE=$WORK/plugins-$PLUGINS_REF.tar.gz
TREE=$WORK/plugins-$PLUGINS_REF
DST=$TREE/net/clat

[ "$(uname -s)" = FreeBSD ] || die "this runs on FreeBSD or OPNsense, not on $(uname -s)"
# Without pkg the framework silently uses "true" in its place and builds nothing.
[ -x /usr/local/sbin/pkg ] || die "/usr/local/sbin/pkg is missing (on FreeBSD: pkg bootstrap -y)"
[ -f "$SRC/Makefile" ] || die "$SRC/Makefile not found"

mkdir -p "$WORK"

# 1. The framework: Mk/, Templates/, Scripts/ and Keywords/ of the fixed commit.
if [ ! -s "$ARCHIVE" ]; then
    echo ">>> Fetching opnsense/plugins $PLUGINS_REF"
    fetch -o "$ARCHIVE.part" "https://github.com/opnsense/plugins/archive/$PLUGINS_REF.tar.gz"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
rm -rf "$TREE"
tar -xzf "$ARCHIVE" -C "$WORK" \
    "plugins-$PLUGINS_REF/Mk" "plugins-$PLUGINS_REF/Templates" \
    "plugins-$PLUGINS_REF/Scripts" "plugins-$PLUGINS_REF/Keywords"

# 2. The plugin, as net/clat of that tree (the framework takes the category "net" from the path).
mkdir -p "$DST"
cp -R "$SRC/Makefile" "$SRC/pkg-descr" "$SRC"/+* "$SRC/src" "$DST/"
find "$DST" -name __pycache__ -type d -prune -exec rm -rf {} +
if grep -rl "$(printf '\r')" "$DST" >&2; then
    die "the files named above have CR line ends"
fi

# 3. File modes as the package needs them, whatever the checkout gave (Windows has no execute
#    bit): 644, and 755 for the rc.d script and the scripts, as "make lint" of the framework asks.
find "$DST" -type f -exec chmod 644 {} +
find "$DST/src/etc/rc.d" "$DST/src/opnsense/scripts" -type f -exec chmod 755 {} +

# 4. Name and version come from net/clat/Makefile; a release tag has to agree with it.
name=$(make -C "$DST" -v PLUGIN_PKGNAME)
version=$(make -C "$DST" -v PLUGIN_PKGVERSION)
[ "$name" = os-clat ] || die "the framework names the package '$name', not os-clat (PLUGINS_REF must be on a stable branch)"
[ -n "$version" ] || die "no package version from $SRC/Makefile"
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
    die "tag $RELEASE_TAG does not match net/clat/Makefile, which says $version (the tag would be v$version)"
fi

hash=${PLUGIN_HASH:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}
hash=$(printf '%s' "$hash" | cut -c1-9)

# 5. Build. PLUGIN_NO_ABI makes the framework write "abi: FreeBSD:*:*" into the package, as it
#    does for OPNsense's theme plugins: os-clat holds only scripts, and the one repository
#    directory (make-repo.sh) serves routers of every FreeBSD version. PLUGIN_WWW replaces the
#    framework's default website, https://opnsense.org/, in the package details.
echo ">>> Building $name-$version (commit $hash) with opnsense/plugins $PLUGINS_REF"
make -C "$DST" PLUGIN_NO_ABI=yes PLUGIN_WWW=https://github.com/77997/os-clat PLUGIN_HASH="$hash" package

built=$DST/work/pkg/$name-$version.pkg
[ -s "$built" ] || die "make package did not write $built"
rm -rf "$WORK/pkg"
mkdir -p "$WORK/pkg"
cp "$built" "$WORK/pkg/"
out=$WORK/pkg/$name-$version.pkg

# 6. What was built, for the log, and the two properties the repository relies on.
echo ">>> $out"
echo "name, version, abi, origin: $(pkg query -F "$out" '%n %v %q %o')"
echo "maintainer, website: $(pkg query -F "$out" '%m %w')"
pkg query -F "$out" 'depends on: %dn-%dv'
tar -tvf "$out"
[ "$(pkg query -F "$out" '%n-%v')" = "$name-$version" ] || die "the package does not say $name-$version"
[ "$(pkg query -F "$out" '%q')" = 'FreeBSD:*:*' ] || die "the package ABI is not FreeBSD:*:*"
echo ">>> OK $name-$version"
