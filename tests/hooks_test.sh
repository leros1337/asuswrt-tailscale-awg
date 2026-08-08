#!/bin/sh
# Test files/merlin-hooks.sh against a fake /jffs/scripts directory.
#
# Asserts the two properties users depend on: installing twice does not
# duplicate anything, and removing restores pre-existing files byte-for-byte.
set -eu

cd "$(dirname "$0")/.."
HOOKS=$PWD/files/merlin-hooks.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# merlin-hooks.sh targets busybox sed, which takes GNU-style `-i` and `1i`.
# On macOS the system sed is BSD and rejects both, so shim in gsed.
if ! sed --version 2>/dev/null | grep -q GNU; then
	if command -v gsed >/dev/null 2>&1; then
		mkdir -p "$WORK/bin"
		ln -sf "$(command -v gsed)" "$WORK/bin/sed"
		PATH="$WORK/bin:$PATH"
		export PATH
		printf 'note: using gsed (system sed is BSD)\n'
	else
		printf 'SKIP: GNU sed required (brew install gnu-sed)\n'
		exit 0
	fi
fi

SCRIPTS_DIR=$WORK/scripts
export SCRIPTS_DIR
mkdir -p "$SCRIPTS_DIR"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# A user who already has content in two of the hooks.
cat > "$SCRIPTS_DIR/services-start" <<'EOF'
#!/bin/sh
/jffs/scripts/my-own-thing &
EOF
cat > "$SCRIPTS_DIR/firewall-start" <<'EOF'
#!/bin/sh
iptables -I INPUT -p tcp --dport 1234 -j ACCEPT
EOF
chmod 0755 "$SCRIPTS_DIR"/services-start "$SCRIPTS_DIR"/firewall-start
cp -a "$SCRIPTS_DIR" "$WORK/before"

sh "$HOOKS" install >/dev/null
sh "$HOOKS" check >/dev/null || fail "check failed right after install"
pass "install + check"

for f in "$SCRIPTS_DIR"/*; do
	sh -n "$f" || fail "$f is not valid sh"
done
pass "every hook parses as sh"

grep -q 'my-own-thing' "$SCRIPTS_DIR/services-start" || fail "clobbered existing user content"
grep -q 'dport 1234' "$SCRIPTS_DIR/firewall-start" || fail "clobbered existing user content"
pass "existing user content preserved"

# Idempotency: a second install must not add a second block anywhere.
sh "$HOOKS" install >/dev/null
for f in "$SCRIPTS_DIR"/*; do
	n=$(grep -cxF '# BEGIN tailscale-awg' "$f")
	[ "$n" = 1 ] || fail "$(basename "$f") has $n marker blocks after two installs"
done
pass "install is idempotent"

# Every hook must have a non-empty body between the markers.
for f in "$SCRIPTS_DIR"/*; do
	body=$(sed -n '/^# BEGIN tailscale-awg$/,/^# END tailscale-awg$/p' "$f" | sed '1d;$d')
	[ -n "$body" ] || fail "$(basename "$f") has an empty block"
done
pass "no empty blocks"

sh "$HOOKS" remove >/dev/null
if sh "$HOOKS" check >/dev/null 2>&1; then
	fail "check still passes after remove"
fi
diff -r "$WORK/before" "$SCRIPTS_DIR" || fail "remove did not restore the original files"
pass "remove restores the original tree byte-for-byte"

printf '\nall hook tests passed\n'
