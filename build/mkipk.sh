#!/bin/sh
# Assemble an Entware-compatible .ipk without the OpenWrt SDK.
#
# An Entware ipk is a *gzip-compressed tar* holding three members:
#   ./debian-binary  ./data.tar.gz  ./control.tar.gz
# It is NOT the Debian `ar` format. Modern opkg (Entware ships the OpenWrt one)
# rejects an ar archive outright with "Malformed package file" -- verified on an
# RT-BE92U against opkg 80503d94. Compare with a stock package if in doubt:
#   gzip -dc jq_1.8.1-1_aarch64-3.10.ipk | tar -tf -
#
# Usage: build/mkipk.sh [version] [release]
set -eu

cd "$(dirname "$0")/.."
. ./.config/tailscale-version

VER=${1:-$TAILSCALE_VERSION}
REL=${2:-$PKG_RELEASE}
ARCH=${ENTWARE_ARCH:-aarch64-3.10}
OUT=${OUT:-out}
BIN=${BIN:-$OUT/tailscaled}
: "${SOURCE_DATE_EPOCH:=$(git log -1 --format=%ct 2>/dev/null || echo 1700000000)}"

[ -f "$BIN" ] || { echo "error: $BIN not found -- run build/build.sh first" >&2; exit 1; }

# GNU tar is required for --sort/--owner/--numeric-owner; BSD tar (macOS) is not
# enough. `gtar` comes from `brew install gnu-tar`.
TAR=${TAR:-}
if [ -z "$TAR" ]; then
	for t in tar gtar gnutar; do
		if command -v "$t" >/dev/null 2>&1 && "$t" --version 2>/dev/null | grep -q 'GNU tar'; then
			TAR=$t
			break
		fi
	done
fi
[ -n "$TAR" ] || { echo "error: GNU tar not found (macOS: brew install gnu-tar)" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM
ROOT=$STAGE/data
CTRL=$STAGE/control

install -d -m 0755 "$ROOT/opt/sbin" "$ROOT/opt/etc/init.d" "$ROOT/opt/etc/tailscale" \
                   "$ROOT/opt/var/log" "$CTRL"
install -d -m 0700 "$ROOT/opt/var/lib/tailscale"

install -m 0755 "$BIN"                  "$ROOT/opt/sbin/tailscaled"
ln -sf tailscaled                       "$ROOT/opt/sbin/tailscale"
install -m 0755 files/S60tailscaled     "$ROOT/opt/etc/init.d/S60tailscaled"
install -m 0644 files/tailscaled.conf   "$ROOT/opt/etc/tailscale/tailscaled.conf"
install -m 0755 files/merlin-hooks.sh   "$ROOT/opt/etc/tailscale/merlin-hooks.sh"
install -m 0755 files/firewall.sh       "$ROOT/opt/etc/tailscale/firewall.sh"

SIZE=$(( $(du -sk "$ROOT" | cut -f1) * 1024 ))
sed -e "s/@VERSION@/$VER-$REL/" -e "s/@ARCH@/$ARCH/" -e "s/@SIZE@/$SIZE/" \
	build/control.in > "$CTRL/control"
printf '/opt/etc/tailscale/tailscaled.conf\n' > "$CTRL/conffiles"
for s in postinst prerm postrm; do
	install -m 0755 "build/$s.in" "$CTRL/$s"
done

# Reproducible tarballs: fixed ownership, sorted entries, fixed mtime.
set -- --numeric-owner --owner=0 --group=0 --sort=name --format=gnu \
       --mtime="@$SOURCE_DATE_EPOCH"

printf '2.0\n' > "$STAGE/debian-binary"
"$TAR" "$@" -czf "$STAGE/control.tar.gz" -C "$CTRL" .
"$TAR" "$@" -czf "$STAGE/data.tar.gz"    -C "$ROOT" .

mkdir -p "$OUT"
IPK=$(cd "$OUT" && pwd)/tailscale_${VER}-${REL}_${ARCH}.ipk
rm -f "$IPK"
# Member order matches what Entware's own packages use.
"$TAR" "$@" -czf "$IPK" -C "$STAGE" ./debian-binary ./data.tar.gz ./control.tar.gz

( cd "$OUT" && sha256sum "$(basename "$IPK")" > "$(basename "$IPK").sha256" )
echo "==> $IPK"
"$TAR" -tzf "$IPK"
