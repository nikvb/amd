#!/bin/sh
# tools/make-header-bundle.sh - build a per-version Asterisk header bundle for install.sh
#
#   tools/make-header-bundle.sh --tree /usr/src/asterisk-16.30.1-vici [-o bundles]
#   tools/make-header-bundle.sh --tarball asterisk-18.21.0-vici.tar.gz [--configure] [-o bundles]
#
# Output: <out>/asterisk-<ver>-headers.tar.gz + <out>/asterisk-<ver>-headers.tar.gz.sha256
#
# A bundle is everything an out-of-tree module needs to compile against Asterisk <ver> on
# x86_64/glibc: include/asterisk.h, include/asterisk/*.h (with the generated autoconfig.h), the
# tree's .version, the GPLv2 COPYING file and a BUNDLE-INFO manifest, all under asterisk-<ver>/.
# buildopts.h is deliberately NOT shipped: it depends on the menuselect options of the Asterisk
# that RUNS on the target and is synthesised there from its AST_BUILDOPT_SUM (ast-detect.sh).
# build.h (hostname/date of the build box) is left out as well.
#
# --tree      a configured tree (./configure has run, so include/asterisk/autoconfig.h exists)
# --tarball   a source tarball; with --configure it is extracted and ./configure is run in a
#             temporary directory (needs the usual Asterisk build deps on THIS box).  Without
#             --configure the tarball must already contain autoconfig.h (a built tree tarball).
# --version   override the version recorded in the bundle name (default: the tree's .version)
#
# Publish the two files under https://download.amdy.io/asterisk-headers/ (AMD_WS_BUNDLE_URL).

set -eu
LC_ALL=C; export LC_ALL

die() { printf 'make-header-bundle: ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'make-header-bundle: %s\n' "$*" >&2; }

TREE=''; TARBALL=''; OUT=bundles; VER=''; CONFIGURE=0; TMP=''
while [ $# -gt 0 ]; do
    case $1 in
        --tree)      TREE=$2; shift 2;;
        --tarball)   TARBALL=$2; shift 2;;
        --configure) CONFIGURE=1; shift;;
        --version)   VER=$2; shift 2;;
        -o|--out)    OUT=$2; shift 2;;
        -h|--help)   sed -n '2,24p' "$0"; exit 0;;
        *) die "unknown option $1 (see --help)";;
    esac
done
[ -n "$TREE" ] || [ -n "$TARBALL" ] || die "need --tree DIR or --tarball FILE"

cleanup() { if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi; return 0; }
trap cleanup EXIT INT TERM
TMP=$(mktemp -d)

if [ -n "$TARBALL" ]; then
    [ -f "$TARBALL" ] || die "no such file: $TARBALL"
    if [ "$CONFIGURE" = 1 ]; then
        log "extracting $TARBALL (full tree, for ./configure)"
        mkdir -p "$TMP/src"
        tar xzf "$TARBALL" -C "$TMP/src" --strip-components=1
        log "running ./configure (this needs the Asterisk build dependencies)"
        # on failure keep the tree so the operator can read configure.log; on success it is removed
        # with everything else by the EXIT trap
        ( cd "$TMP/src" && ./configure --quiet >"$TMP/configure.log" 2>&1 ) || { trap - EXIT INT TERM; die "./configure failed - see $TMP/configure.log (not removed)"; }
    else
        log "extracting headers from $TARBALL"
        mkdir -p "$TMP/src"
        tar xzf "$TARBALL" -C "$TMP/src" --strip-components=1 --wildcards \
            '*/include/asterisk.h' '*/include/asterisk/*.h' '*/.version' '*/COPYING' '*/LICENSE' 2>/dev/null \
            || die "tar could not extract include/ from $TARBALL"
    fi
    TREE="$TMP/src"
fi

[ -f "$TREE/include/asterisk.h" ]            || die "$TREE/include/asterisk.h missing - not an Asterisk source tree"
[ -f "$TREE/include/asterisk/autoconfig.h" ] || die "$TREE/include/asterisk/autoconfig.h missing - run ./configure in the tree first (or use --tarball FILE --configure)"
[ -n "$VER" ] || VER=$(sed -n 1p "$TREE/.version" 2>/dev/null || true)
[ -n "$VER" ] || die "cannot read $TREE/.version - pass --version <ver>"
# Certified builds are 'certified/18.9-cert1' in .version.  The bundle NAME cannot carry a slash, so
# it uses 'certified-18.9-cert1' (install.sh derives the same name); the .version written INTO the
# bundle keeps the real string, which is what ast-detect.sh compares with the running version.
NAMEVER=$(printf '%s' "$VER" | tr '/' '-')

NAME="asterisk-$NAMEVER"
STAGE="$TMP/stage/$NAME"
mkdir -p "$STAGE/include/asterisk" "$OUT"
cp -p "$TREE/include/asterisk.h" "$STAGE/include/"
n=0
for h in "$TREE"/include/asterisk/*.h; do
    case ${h##*/} in buildopts.h|build.h) continue;; esac
    cp -p "$h" "$STAGE/include/asterisk/"; n=$((n+1))
done
printf '%s\n' "$VER" > "$STAGE/.version"
for lic in COPYING LICENSE; do [ -f "$TREE/$lic" ] && cp -p "$TREE/$lic" "$STAGE/$lic"; done
[ -f "$STAGE/COPYING" ] || [ -f "$STAGE/LICENSE" ] || log "WARNING: no COPYING/LICENSE in the tree - the headers are GPLv2, ship the licence text with the bundle"

ac_sum=$(sha256sum "$STAGE/include/asterisk/autoconfig.h" | cut -c1-64)
{
    printf 'bundle:        %s-headers.tar.gz\n' "$NAME"
    printf 'asterisk:      %s\n' "$VER"
    printf 'source:        %s\n' "${TARBALL:-$TREE}"
    printf 'headers:       asterisk.h + %s files under include/asterisk/ (autoconfig.h included; buildopts.h and build.h excluded)\n' "$n"
    printf 'autoconfig.h:  sha256 %s (generated on %s, %s)\n' "$ac_sum" "$(uname -m)" "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null || uname -s)"
    printf 'buildopts.h:   NOT included - synthesised on the target from the running core'"'"'s AST_BUILDOPT_SUM (ast-detect.sh)\n'
    printf 'generator:     tools/make-header-bundle.sh (app_amd_ws), %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'licence:       the headers are part of Asterisk, GPLv2 (see COPYING)\n'
} > "$STAGE/BUNDLE-INFO"

OUTFILE="$OUT/$NAME-headers.tar.gz"
# deterministic-ish archive: sorted names, numeric owners, no build-box user names
tar -C "$TMP/stage" --sort=name --owner=0 --group=0 --numeric-owner -czf "$OUTFILE" "$NAME" 2>/dev/null \
    || tar -C "$TMP/stage" -czf "$OUTFILE" "$NAME"
( cd "$OUT" && sha256sum "$NAME-headers.tar.gz" > "$NAME-headers.tar.gz.sha256" )
log "wrote $OUTFILE ($(du -k "$OUTFILE" | cut -f1) KB, $n headers) and $OUTFILE.sha256"
cat "$OUT/$NAME-headers.tar.gz.sha256"
