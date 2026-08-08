#!/bin/sh
# Cross-compile tailscaled (AmneziaWG fork) as a static aarch64 binary for
# Asuswrt-Merlin / Entware, then UPX-compress a copy.
#
# Expects the fork's source tree in ./src (see .github/workflows/build-asuswrt.yml)
# and a Go toolchain on PATH. Outputs:
#   out/tailscaled        UPX-compressed (unless UPX=0)
#   out/tailscaled.raw    uncompressed fallback, always produced
set -eu

cd "$(dirname "$0")/.."
. ./.config/tailscale-version

SRC=${SRC:-src}
OUT=${OUT:-out}
UPX=${UPX:-1}

# Same trim set as the OpenWrt package this repo grew out of. ts_include_cli
# folds the `tailscale` CLI into the daemon binary, which is why we ship
# /opt/sbin/tailscale as a symlink instead of a second binary.
TAGS="ts_include_cli,ts_omit_aws,ts_omit_bird,ts_omit_completion,ts_omit_kube,\
ts_omit_systray,ts_omit_tap,ts_omit_tpm,ts_omit_relayserver,ts_omit_capture,\
ts_omit_syspolicy,ts_omit_debugeventbus,ts_omit_webclient"

STAMP="$TAILSCALE_VERSION-$PKG_RELEASE (asuswrt-merlin/entware)"

[ -f "$SRC/go.mod" ] || { echo "error: no Go module in $SRC/" >&2; exit 1; }

mkdir -p "$OUT"
echo "==> building tailscaled $TAILSCALE_VERSION for linux/arm64"
( cd "$SRC" && \
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOFLAGS=-trimpath \
  go build -tags "$TAGS" \
    -ldflags "-s -w \
-X 'tailscale.com/version.longStamp=$STAMP' \
-X 'tailscale.com/version.shortStamp=$TAILSCALE_VERSION' \
-X 'tailscale.com/version.gitCommitStamp=$UPSTREAM_COMMIT'" \
    -o "../$OUT/tailscaled.raw" tailscale.com/cmd/tailscaled )

# Guard against a silently-native build.
file "$OUT/tailscaled.raw" | grep -q 'ARM aarch64' || {
	echo "error: output is not an aarch64 binary:" >&2
	file "$OUT/tailscaled.raw" >&2
	exit 1
}

cp -f "$OUT/tailscaled.raw" "$OUT/tailscaled"
if [ "$UPX" = 1 ] && command -v upx >/dev/null 2>&1; then
	echo "==> compressing with UPX"
	upx --best --lzma "$OUT/tailscaled"
	upx -t "$OUT/tailscaled"
else
	echo "==> UPX skipped (UPX=$UPX)"
fi

ls -l "$OUT"
