#!/bin/sh
# tailscale-awg installer for Asuswrt-Merlin 3006+ (aarch64) via Entware.
#
# POSIX sh only -- this runs under busybox ash on the router. No bashisms:
# use `=` not `==`, `printf` not `echo -e`, plain `read`, `>/dev/null 2>&1`.
#
#   sh install.sh install [options]
#   sh install.sh update | uninstall | status | logs | repair
set -u

VERSION=2.0.0
REPO=leros1337/asuswrt-tailscale-awg
FEED_BASE=${TS_FEED_BASE:-https://leros1337.github.io/asuswrt-tailscale-awg}
RELEASE_BASE="https://github.com/$REPO/releases/latest/download"

ENTWARE_ARCH=aarch64-3.10
PKG_RELEASE=1
MIN_BUILD=3006
MIN_FREE_KB=61440          # 60 MB on the Entware filesystem

OPKG=/opt/bin/opkg
INITD=/opt/etc/init.d/S60tailscaled
HOOKS=/opt/etc/tailscale/merlin-hooks.sh
FWSH=/opt/etc/tailscale/firewall.sh
CONF=/opt/etc/tailscale/tailscaled.conf
STATE_DIR=/opt/var/lib/tailscale
LOGFILE=/opt/var/log/tailscaled.log
TS=/opt/sbin/tailscale

# options
ASSUME_YES=0
ASSUME_ENTWARE=0
SET_JFFS=0
DIRECT=0
NO_UPX=0
ACCEPT_DNS=0
EXIT_NODE=0
PURGE=0
AUTHKEY=${TS_AUTHKEY:-}
ROUTES=
PIN_VERSION=

# ---------------------------------------------------------------- output ----

# Merlin's busybox is built without the `command` builtin, so `command -v`
# fails with "command: not found". `type` is what is actually available.
have() { type "$1" >/dev/null 2>&1; }

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*" >&2; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }
head_() { printf '\n== %s\n' "$*"; }

confirm() {
	[ "$ASSUME_YES" = 1 ] && return 0
	printf '  %s [y/N] ' "$1"
	read -r _ans
	case "$_ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
	cat <<EOF
tailscale-awg installer $VERSION -- Asuswrt-Merlin 3006+, aarch64, Entware

usage: sh install.sh <command> [options]

commands:
  install     install the package, hooks and service, then bring the node up
  update      upgrade the package in place (keeps node identity)
  uninstall   remove the package, hooks and firewall rules
  status      report firmware, Entware, package, service and rule state
  repair      reinstall the /jffs hooks (use after a factory reset)
  logs        tail $LOGFILE

options:
  --yes                    do not prompt
  --authkey KEY            non-interactive login (or set TS_AUTHKEY)
  --advertise-routes CIDR  advertise LAN subnets, e.g. 192.168.50.0/24
  --exit-node              advertise this router as an exit node
  --accept-dns             let tailscaled manage DNS (off by default, see README)
  --version V              install a specific version instead of the newest
  --direct                 download the .ipk from GitHub Releases, skip the feed
  --no-upx                 install the uncompressed binary (--direct only)
  --purge                  on uninstall, also delete the node identity in
                           /opt/var/lib/tailscale (irreversible)
  --set-jffs               set nvram jffs2_scripts=1 for me (needs a reboot)
  --assume-entware         skip the Entware-on-USB checks (CI/testing)
EOF
}

# ------------------------------------------------------------ detection ----

FW_LINE=; FW_BUILD=; MODEL=; ARCH=; OPT_DIR=; OPT_FREE_KB=

detect() {
	head_ "Checking this router"

	have nvram || die "no nvram command -- this is not an ASUSWRT router."
	[ -f /usr/sbin/helper.sh ] || die "Asuswrt-Merlin required (/usr/sbin/helper.sh not found). Stock ASUS firmware is not supported."

	# The "3006" everyone quotes is firmver with the dots removed (3.0.0.6);
	# buildno is the *second* component (e.g. 102.8), not the release line.
	FW_LINE=$(nvram get firmver 2>/dev/null | tr -d '.')
	FW_BUILD=$(nvram get buildno 2>/dev/null)
	MODEL=$(nvram get odmpid 2>/dev/null)
	[ -n "$MODEL" ] || MODEL=$(nvram get productid 2>/dev/null)
	ok "Asuswrt-Merlin $FW_LINE.$FW_BUILD on ${MODEL:-unknown model}"

	case "$FW_LINE" in
		''|*[!0-9]*) die "cannot parse firmware version '$(nvram get firmver 2>/dev/null)'." ;;
	esac
	[ "$FW_LINE" -ge "$MIN_BUILD" ] || \
		die "firmware $FW_LINE.$FW_BUILD is older than $MIN_BUILD. Please update Asuswrt-Merlin."

	ARCH=$(uname -m)
	[ "$ARCH" = aarch64 ] || \
		die "unsupported CPU architecture '$ARCH'. Only aarch64 routers are supported."
	ok "architecture aarch64"

	check_jffs
	check_tun
	check_entware
}

check_jffs() {
	if [ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ]; then
		ok "JFFS custom scripts enabled"
		return 0
	fi
	if [ "$SET_JFFS" = 1 ]; then
		nvram set jffs2_scripts=1
		nvram commit
		die "jffs2_scripts enabled. Reboot the router, then run this installer again."
	fi
	say ""
	say "  JFFS custom scripts are disabled, so none of the boot/firewall hooks"
	say "  would ever run. Enable them in the web UI:"
	say "    Administration -> System -> Enable JFFS custom scripts and configs = Yes"
	say "  then reboot. Or re-run with --set-jffs to have this script do it."
	die "JFFS custom scripts disabled."
}

check_tun() {
	if [ ! -c /dev/net/tun ]; then
		mkdir -p /dev/net 2>/dev/null
		modprobe tun 2>/dev/null
	fi
	[ -c /dev/net/tun ] || die "/dev/net/tun is missing and the tun module could not be loaded."
	ok "/dev/net/tun present"
}

check_entware() {
	if [ "$ASSUME_ENTWARE" = 1 ]; then
		warn "skipping Entware checks (--assume-entware)"
		OPT_DIR=/opt
		OPT_FREE_KB=$MIN_FREE_KB
		return 0
	fi

	if [ ! -x "$OPKG" ]; then
		say ""
		say "  Entware is not installed ($OPKG not found). tailscaled and its"
		say "  state must live on a USB drive, so Entware is required."
		say "  Install it from the router shell with:  amtm   then pick 'ep'."
		die "Entware not installed."
	fi

	OPT_DIR=$(readlink -f /opt 2>/dev/null)
	[ -n "$OPT_DIR" ] || OPT_DIR=/opt
	case "$OPT_DIR" in
		/tmp/mnt/*|/mnt/*) : ;;
		*) warn "/opt resolves to '$OPT_DIR', which does not look like a USB mount. State may not survive a reboot." ;;
	esac

	if ! touch /opt/.ts-write-test 2>/dev/null; then
		die "/opt is not writable. Is the USB drive mounted read-only?"
	fi
	rm -f /opt/.ts-write-test

	OPT_FREE_KB=$(df -k /opt 2>/dev/null | awk 'NR>1 {print $4; exit}')
	case "$OPT_FREE_KB" in ''|*[!0-9]*) OPT_FREE_KB=0 ;; esac
	if [ "$OPT_FREE_KB" -lt "$MIN_FREE_KB" ]; then
		die "only $((OPT_FREE_KB / 1024)) MB free on /opt; at least $((MIN_FREE_KB / 1024)) MB is needed."
	fi
	ok "Entware on $OPT_DIR, $((OPT_FREE_KB / 1024)) MB free"

	_arch=$("$OPKG" print-architecture 2>/dev/null | awk '{print $2}' | grep -v '^all$' | head -n 1)
	if [ -n "$_arch" ] && [ "$_arch" != "$ENTWARE_ARCH" ]; then
		warn "Entware reports architecture '$_arch' but the package is built for '$ENTWARE_ARCH'; opkg may refuse it."
	fi
}

# --------------------------------------------------------------- fetch ----

fetch() {  # fetch <url> <dest>
	if have curl; then
		curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
	else
		wget -q -O "$2" "$1"
	fi
}

install_from_feed() {
	_line="src/gz tailscale-awg $FEED_BASE/$ENTWARE_ARCH"
	_added=0
	if ! grep -qF "$_line" /opt/etc/opkg.conf 2>/dev/null; then
		# Drop any stale line for this feed name before adding the current one.
		sed -i '/^src\/gz tailscale-awg /d' /opt/etc/opkg.conf 2>/dev/null
		printf '%s\n' "$_line" >> /opt/etc/opkg.conf
		_added=1
		info "added feed: $_line"
	fi
	if ! "$OPKG" update; then
		# Do not leave an unreachable feed behind: opkg treats a failed list as
		# a hard error, so every later `opkg update` on this router would fail.
		if [ "$_added" = 1 ]; then
			sed -i '/^src\/gz tailscale-awg /d' /opt/etc/opkg.conf 2>/dev/null
			info "removed the feed line again"
		fi
		die "opkg update failed. Check the router's internet access, or use --direct."
	fi
	if [ -n "$PIN_VERSION" ]; then
		"$OPKG" install "tailscale=$PIN_VERSION" || die "opkg install failed."
	else
		"$OPKG" install tailscale || die "opkg install failed."
	fi
}

install_direct() {
	_ipk=/tmp/tailscale-awg.ipk
	_ver=$PIN_VERSION
	if [ -z "$_ver" ]; then
		# The feed publishes the current version string at its root.
		fetch "$FEED_BASE/latest" /tmp/ts-latest 2>/dev/null || \
			die "could not determine the latest version; pass --version X.Y.Z."
		_ver=$(tr -d ' \t\r\n' < /tmp/ts-latest)
		rm -f /tmp/ts-latest
		[ -n "$_ver" ] || die "could not determine the latest version; pass --version X.Y.Z."
	fi
	_name="tailscale_${_ver}-${PKG_RELEASE}_${ENTWARE_ARCH}.ipk"
	_url="$RELEASE_BASE/$_name"
	info "downloading $_url"
	fetch "$_url" "$_ipk" || die "download failed: $_url"
	if fetch "$_url.sha256" "$_ipk.sha256" 2>/dev/null; then
		_want=$(awk '{print $1; exit}' "$_ipk.sha256")
		_have=$(sha256sum "$_ipk" | awk '{print $1}')
		[ "$_want" = "$_have" ] || die "sha256 mismatch (expected $_want, got $_have)."
		ok "sha256 verified"
	else
		warn "no .sha256 published for this release; integrity not verified"
	fi
	"$OPKG" install --force-reinstall "$_ipk" || die "opkg install failed."
	rm -f "$_ipk" "$_ipk.sha256"

	if [ "$NO_UPX" = 1 ]; then
		info "installing the uncompressed binary instead of the UPX one"
		fetch "$RELEASE_BASE/tailscaled.raw" /tmp/tailscaled.raw || \
			die "could not download the uncompressed binary."
		"$INITD" stop >/dev/null 2>&1
		# No `install` binary in the firmware or in Entware's base set.
		cp -f /tmp/tailscaled.raw /opt/sbin/tailscaled
		chmod 0755 /opt/sbin/tailscaled
		rm -f /tmp/tailscaled.raw
	fi
}

# ------------------------------------------------------------ node up ----

wait_socket() {
	i=0
	while [ "$i" -lt 30 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -S /var/run/tailscale/tailscaled.sock ]
}

bring_up() {
	# netfilter-mode is a pref applied by `tailscale up`, not a daemon flag.
	_nfmode=off
	[ -f "$CONF" ] && _nfmode=$(awk -F= '/^NETFILTER_MODE=/{gsub(/"/,"",$2); print $2}' "$CONF")
	[ -n "$_nfmode" ] || _nfmode=off

	if [ "$ACCEPT_DNS" = 1 ]; then
		set -- --accept-dns=true "--netfilter-mode=$_nfmode"
	else
		set -- --accept-dns=false "--netfilter-mode=$_nfmode"
	fi
	[ -n "$ROUTES" ] && set -- "$@" "--advertise-routes=$ROUTES"
	[ "$EXIT_NODE" = 1 ] && set -- "$@" --advertise-exit-node

	if "$TS" status >/dev/null 2>&1; then
		ok "node is already logged in"
		"$TS" up "$@" >/dev/null 2>&1 || warn "tailscale up reported an error"
		return 0
	fi

	if [ -n "$AUTHKEY" ]; then
		info "logging in with the supplied auth key"
		"$TS" up --authkey="$AUTHKEY" "$@" || die "tailscale up failed."
		ok "node is up"
		return 0
	fi

	# Never block forever waiting for a browser login.
	_log=/tmp/ts-up.log
	: > "$_log"
	"$TS" up "$@" >"$_log" 2>&1 &
	i=0
	_url=
	while [ "$i" -lt 30 ]; do
		_url=$(grep -o 'https://login\.tailscale\.com/[A-Za-z0-9/._-]*' "$_log" | head -n 1)
		[ -n "$_url" ] && break
		sleep 1
		i=$((i + 1))
	done
	if [ -z "$_url" ]; then
		warn "no login URL appeared within 30s; see $_log"
		return 0
	fi
	say ""
	say "  Open this URL to authorise the router:"
	say ""
	say "    $_url"
	say ""
	printf '  waiting for authorisation'
	i=0
	while [ "$i" -lt 180 ]; do
		if "$TS" status 2>/dev/null | grep -q .; then
			if "$TS" status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then
				printf ' done.\n'
				ok "node is up"
				return 0
			fi
		fi
		printf '.'
		sleep 3
		i=$((i + 3))
	done
	printf '\n'
	warn "still not authorised after 3 minutes. Finish in the browser, the daemon keeps waiting."
}

# ------------------------------------------------------------ commands ----

cmd_install() {
	detect
	head_ "Installing the package"
	if [ "$DIRECT" = 1 ]; then
		install_direct
	else
		install_from_feed
	fi
	[ -x /opt/sbin/tailscaled ] || die "/opt/sbin/tailscaled is missing after install."
	ok "$("$TS" version 2>/dev/null | head -n 1)"

	head_ "Installing Merlin hooks"
	[ -x "$HOOKS" ] || die "$HOOKS is missing."
	"$HOOKS" install

	head_ "Starting the service"
	"$INITD" restart || die "could not start tailscaled. See $LOGFILE"
	wait_socket || die "tailscaled did not create its socket. See $LOGFILE"
	ok "tailscaled running (pid $(pidof tailscaled))"

	head_ "Joining your tailnet"
	bring_up

	head_ "Done"
	info "status:    sh install.sh status"
	info "logs:      sh install.sh logs"
	info "service:   $INITD start|stop|restart|check"
	[ "$ACCEPT_DNS" = 0 ] && info "MagicDNS is off by default -- see the README to enable it via dnsmasq."
}

cmd_update() {
	detect
	head_ "Updating"
	if [ "$DIRECT" = 1 ]; then
		install_direct
	else
		"$OPKG" update || die "opkg update failed."
		"$OPKG" install --force-reinstall tailscale || die "opkg install failed."
	fi
	"$HOOKS" install >/dev/null
	"$INITD" restart || die "could not restart tailscaled. See $LOGFILE"
	wait_socket || warn "socket did not appear within 30s; check $LOGFILE"
	ok "updated to $("$TS" version 2>/dev/null | head -n 1)"
	info "node identity in $STATE_DIR was kept; no re-login needed."
}

cmd_uninstall() {
	head_ "Uninstalling"
	confirm "Remove tailscale-awg from this router?" || die "aborted."

	[ -x "$TS" ] && "$TS" down >/dev/null 2>&1
	[ -x "$INITD" ] && "$INITD" stop >/dev/null 2>&1
	[ -x "$FWSH" ] && "$FWSH" remove >/dev/null 2>&1
	[ -x /opt/sbin/tailscaled ] && /opt/sbin/tailscaled --cleanup >/dev/null 2>&1
	[ -x "$HOOKS" ] && "$HOOKS" remove
	[ -x "$OPKG" ] && "$OPKG" remove tailscale >/dev/null 2>&1
	ok "package, hooks and rules removed"

	if confirm "Also remove the opkg feed line from /opt/etc/opkg.conf?"; then
		sed -i '/^src\/gz tailscale-awg /d' /opt/etc/opkg.conf 2>/dev/null
		ok "feed removed"
	fi
	if [ -d "$STATE_DIR" ]; then
		say "  $STATE_DIR holds this node's identity. Deleting it means"
		say "  re-authenticating (and a new node in your tailnet) next time."
		# Destroying the node identity needs its own explicit opt-in: --yes is
		# for skipping prompts, not for consenting to irreversible data loss.
		if [ "$PURGE" = 1 ]; then
			rm -rf "$STATE_DIR"
			ok "state deleted (--purge)"
		elif [ "$ASSUME_YES" = 1 ]; then
			info "state kept at $STATE_DIR (pass --purge to delete it)"
		elif confirm "Delete $STATE_DIR?"; then
			rm -rf "$STATE_DIR"
			ok "state deleted"
		else
			info "state kept at $STATE_DIR"
		fi
	fi
}

cmd_repair() {
	detect
	head_ "Reinstalling hooks"
	[ -x "$HOOKS" ] || die "$HOOKS is missing -- run 'install' instead."
	"$HOOKS" install
	"$INITD" restart >/dev/null 2>&1
	ok "hooks reinstalled"
}

cmd_status() {
	head_ "Router"
	FW_LINE=$(nvram get firmver 2>/dev/null | tr -d '.')
	FW_BUILD=$(nvram get buildno 2>/dev/null)
	MODEL=$(nvram get odmpid 2>/dev/null); [ -n "$MODEL" ] || MODEL=$(nvram get productid 2>/dev/null)
	info "model         ${MODEL:-unknown}"
	info "firmware      $FW_LINE.$FW_BUILD"
	info "architecture  $(uname -m)"
	info "jffs scripts  $(nvram get jffs2_scripts 2>/dev/null)"
	info "/dev/net/tun  $( [ -c /dev/net/tun ] && echo present || echo MISSING )"

	head_ "Entware"
	if [ -x "$OPKG" ]; then
		info "mount         $(readlink -f /opt 2>/dev/null)"
		info "free space    $(df -h /opt 2>/dev/null | awk 'NR>1 {print $4; exit}')"
		info "architecture  $("$OPKG" print-architecture 2>/dev/null | awk '$2!="all"{print $2}' | tr '\n' ' ')"
		info "package       $("$OPKG" list-installed tailscale 2>/dev/null | head -n 1)"
	else
		info "not installed"
	fi

	head_ "Service"
	if [ -x "$TS" ]; then
		info "binary        $("$TS" version 2>/dev/null | head -n 1)"
	else
		info "binary        not installed"
	fi
	if pidof tailscaled >/dev/null 2>&1; then
		info "daemon        running (pid $(pidof tailscaled))"
	else
		info "daemon        NOT running"
	fi
	info "socket        $( [ -S /var/run/tailscale/tailscaled.sock ] && echo present || echo missing )"
	info "interface     $(ip -4 addr show tailscale0 2>/dev/null | awk '/inet /{print $2; exit}')"
	[ -f "$CONF" ] && info "config        $CONF"

	head_ "Merlin hooks"
	if [ -x "$HOOKS" ]; then
		"$HOOKS" check || {
			warn "some hooks are missing (a factory reset clears /jffs)."
			warn "run: sh install.sh repair"
		}
	else
		info "$HOOKS not installed"
	fi

	head_ "Netfilter / routing"
	info "iptables rules referencing tailscale0: $(iptables -S 2>/dev/null | grep -c tailscale0)"
	info "nat MASQUERADE for 100.64/10:          $(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c '100.64.0.0/10')"
	info "ip rules for table 52:                 $(ip rule show 2>/dev/null | grep -c 52)"

	head_ "Tailnet"
	if [ -x "$TS" ] && "$TS" status 2>/dev/null | grep -q .; then
		"$TS" status 2>/dev/null | sed 's/^/  /'
	else
		info "not logged in / daemon unavailable"
	fi
}

cmd_logs() {
	[ -f "$LOGFILE" ] || die "$LOGFILE does not exist yet."
	tail -n "${1:-100}" "$LOGFILE"
}

# ----------------------------------------------------------------- main ----

CMD=
while [ $# -gt 0 ]; do
	case "$1" in
		install|update|uninstall|status|logs|repair) CMD=$1 ;;
		--yes|-y)          ASSUME_YES=1 ;;
		--assume-entware)  ASSUME_ENTWARE=1 ;;
		--set-jffs)        SET_JFFS=1 ;;
		--direct)          DIRECT=1 ;;
		--no-upx)          NO_UPX=1 ;;
		--purge)           PURGE=1 ;;
		--accept-dns)      ACCEPT_DNS=1 ;;
		--exit-node)       EXIT_NODE=1 ;;
		--authkey)         shift; AUTHKEY=${1:-} ;;
		--authkey=*)       AUTHKEY=${1#--authkey=} ;;
		--advertise-routes) shift; ROUTES=${1:-} ;;
		--advertise-routes=*) ROUTES=${1#--advertise-routes=} ;;
		--version)         shift; PIN_VERSION=${1:-} ;;
		--version=*)       PIN_VERSION=${1#--version=} ;;
		-h|--help)         usage; exit 0 ;;
		*) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

case "$CMD" in
	install)   cmd_install ;;
	update)    cmd_update ;;
	uninstall) cmd_uninstall ;;
	repair)    cmd_repair ;;
	status)    cmd_status ;;
	logs)      cmd_logs ;;
	*) usage; exit 2 ;;
esac
