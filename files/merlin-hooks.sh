#!/bin/sh
# Install / remove the Asuswrt-Merlin user-script hooks that tailscale-awg needs.
#
# Every hook file is edited by replacing a marker-fenced block, never by
# overwriting the file -- users routinely have their own content in these
# scripts. Running `install` twice is a no-op, and `remove` restores the file
# to exactly what it was before.
#
# Usage: merlin-hooks.sh install | remove | check
set -eu

SCRIPTS_DIR=${SCRIPTS_DIR:-/jffs/scripts}
BEGIN='# BEGIN tailscale-awg'
END='# END tailscale-awg'

HOOKS='post-mount services-start services-stop unmount firewall-start nat-start'

ensure_script() {
	[ -f "$1" ] || printf '#!/bin/sh\n' > "$1"
	head -n 1 "$1" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$1"
	chmod 0755 "$1"
}

strip_block() {
	[ -f "$1" ] || return 0
	sed -i "/^${BEGIN}\$/,/^${END}\$/d" "$1"
}

# add_block <file>; body on stdin
add_block() {
	ensure_script "$1"
	strip_block "$1"
	{
		printf '%s\n' "$BEGIN"
		cat
		printf '%s\n' "$END"
	} >> "$1"
}

has_block() {
	[ -f "$1" ] && grep -qxF "$BEGIN" "$1"
}

body_post_mount() {
	# $1 is the mount point of the partition that just came up. The standard
	# Entware-on-Merlin setup links /tmp/opt here and starts everything from
	# rc.unslung in services-start; we only act when rc.unslung is absent
	# (hand-rolled Entware installs).
	cat <<'EOF'
if [ ! -x /opt/etc/init.d/rc.unslung ] && [ -x "$1/entware/etc/init.d/rc.unslung" ]; then
	ln -nsf "$1/entware" /tmp/opt
fi
if [ ! -x /opt/etc/init.d/rc.unslung ] && [ -x /opt/etc/init.d/S60tailscaled ]; then
	/opt/etc/init.d/S60tailscaled start
fi
EOF
}

body_services_start() {
	# Late safety net: rc.unslung normally has already started us.
	cat <<'EOF'
( sleep 30
  if [ -x /opt/etc/init.d/S60tailscaled ] && ! pidof tailscaled >/dev/null 2>&1; then
	/opt/etc/init.d/S60tailscaled start
  fi ) &
EOF
}

body_services_stop() {
	cat <<'EOF'
[ -x /opt/etc/init.d/S60tailscaled ] && /opt/etc/init.d/S60tailscaled stop
EOF
}

body_unmount() {
	# Stop the daemon before the USB partition holding /opt disappears,
	# otherwise the unmount fails and tailscaled.state can be truncated.
	cat <<'EOF'
if [ -x /opt/etc/init.d/S60tailscaled ] && [ -n "$1" ] && [ "${1#*/}" != "$1" ]; then
	case "$(readlink -f /opt 2>/dev/null)" in
		"$1"|"$1"/*) /opt/etc/init.d/S60tailscaled stop ;;
	esac
fi
EOF
}

body_firewall() {
	# Merlin flushes and deletes custom chains on every firewall rebuild, and
	# rebuilds the nat table separately, so both hooks must re-apply.
	cat <<'EOF'
[ -x /opt/etc/tailscale/firewall.sh ] && /opt/etc/tailscale/firewall.sh apply "$1" &
EOF
}

hook_body() {
	case "$1" in
		post-mount)     body_post_mount ;;
		services-start) body_services_start ;;
		services-stop)  body_services_stop ;;
		unmount)        body_unmount ;;
		firewall-start) body_firewall ;;
		nat-start)      body_firewall ;;
	esac
}

do_install() {
	[ -d "$SCRIPTS_DIR" ] || mkdir -p "$SCRIPTS_DIR"
	for h in $HOOKS; do
		hook_body "$h" | add_block "$SCRIPTS_DIR/$h"
		echo "hook installed: $SCRIPTS_DIR/$h"
	done
}

do_remove() {
	for h in $HOOKS; do
		f=$SCRIPTS_DIR/$h
		has_block "$f" || continue
		strip_block "$f"
		# Remove a file we created that now holds nothing but the shebang.
		if [ "$(grep -cv '^\(#!/bin/sh\)\?[[:space:]]*$' "$f")" = 0 ]; then
			rm -f "$f"
			echo "hook removed (file deleted): $f"
		else
			echo "hook removed: $f"
		fi
	done
}

do_check() {
	rc=0
	for h in $HOOKS; do
		if has_block "$SCRIPTS_DIR/$h"; then
			echo "ok      $SCRIPTS_DIR/$h"
		else
			echo "MISSING $SCRIPTS_DIR/$h"
			rc=1
		fi
	done
	return $rc
}

case "${1:-}" in
	install) do_install ;;
	remove)  do_remove ;;
	check)   do_check ;;
	*) echo "usage: $0 install|remove|check" >&2; exit 2 ;;
esac
