#!/bin/sh
# Build amdy.tar.gz — the EAGI client package that the ViciDial installers
# (installamd*.sh) download from http://download.amdy.io/amdy.tar.gz and unpack
# into /var/lib/asterisk/agi-bin. Same layout as the one served today: exactly
# one member, amd.py, owner root:root, mode 0755.
#
# Usage: tools/make-amdy-tarball.sh [output.tar.gz]      (default: ./amdy.tar.gz)
#
# Reproducible: the member mtime is the last commit time of agi/amd.py and gzip
# runs with -n, so the same source commit always yields the same bytes.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
src="$here/agi/amd.py"
out=${1:-"$here/amdy.tar.gz"}

[ -f "$src" ] || { echo "make-amdy-tarball: $src not found" >&2; exit 1; }
python3 -m py_compile "$src" || { echo "make-amdy-tarball: amd.py does not compile" >&2; exit 1; }
rm -rf "${src}c" "$here/agi/__pycache__"

mtime=$(git -C "$here" log -1 --format=%cI -- agi/amd.py 2>/dev/null || true)
[ -n "$mtime" ] || mtime=$(date -u +%Y-%m-%dT%H:%M:%SZ)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install -m 0755 "$src" "$tmp/amd.py"

tar --owner=root --group=root --numeric-owner --mode=0755 --mtime="$mtime" \
    -C "$tmp" -cf - amd.py | gzip -n -9 > "$out"

echo "wrote $out ($(stat -c %s "$out") bytes)"
tar -tzvf "$out"
sha256sum "$out"
