#!/bin/sh
# Apply (or remove) the netfilter rules tailscale needs on Asuswrt-Merlin.
#
# Why this exists: tailscaled normally installs its own ts-input/ts-forward/
# ts-postrouting chains, but Merlin's start_firewall does `iptables -F; -X` on
# every WAN event, VPN client start and firewall setting change, and tailscaled
# only reconciles on *link* changes -- so its rules silently disappear.
# We therefore run tailscaled with --netfilter-mode=off and own the rules here,
# re-applying from /jffs/scripts/firewall-start and /jffs/scripts/nat-start
# (both of which run after Merlin has finished rebuilding).
#
# Usage: firewall.sh apply [wan-iface] | remove
set -u

TUN=tailscale0
PORT=41641
CGNAT=100.64.0.0/10
CGNAT6=fd7a:115c:a1e0::/48

[ -f /opt/etc/tailscale/tailscaled.conf ] && . /opt/etc/tailscale/tailscaled.conf

ACTION=${1:-apply}
WAN=${2:-}
if [ -z "$WAN" ]; then
	WAN=$(nvram get wan0_pppoe_ifname 2>/dev/null)
	[ -n "$WAN" ] || WAN=$(nvram get wan0_ifname 2>/dev/null)
fi
LAN=$(nvram get lan_ifname 2>/dev/null)
[ -n "$LAN" ] || LAN=br0

IPT=/usr/sbin/iptables
IPT6=/usr/sbin/ip6tables
[ -x "$IPT" ] || IPT=iptables
[ -x "$IPT6" ] || IPT6=ip6tables

ipv6_on() {
	svc=$(nvram get ipv6_service 2>/dev/null)
	[ -n "$svc" ] && [ "$svc" != "disabled" ]
}

# Insert only if the rule is absent, so repeated calls never stack up.
ipt_add() {
	t=$1; shift
	"$IPT" -t "$t" -C "$@" 2>/dev/null || "$IPT" -t "$t" -I "$@" 2>/dev/null
}
ipt_del() {
	t=$1; shift
	while "$IPT" -t "$t" -C "$@" 2>/dev/null; do
		"$IPT" -t "$t" -D "$@" 2>/dev/null || break
	done
}
ipt6_add() {
	t=$1; shift
	"$IPT6" -t "$t" -C "$@" 2>/dev/null || "$IPT6" -t "$t" -I "$@" 2>/dev/null
}
ipt6_del() {
	t=$1; shift
	while "$IPT6" -t "$t" -C "$@" 2>/dev/null; do
		"$IPT6" -t "$t" -D "$@" 2>/dev/null || break
	done
}

sysctls() {
	# Merlin re-asserts its own values on WAN up, so set these every time.
	# There is no sysctl binary in the firmware -- write /proc directly.
	[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward
	# rp_filter: 0 = off (already permissive), 1 = strict, 2 = loose. Loose is
	# what subnet-route return traffic needs, so only relax 1 -- never tighten 0.
	if [ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)" = 1 ]; then
		echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null
	fi
	if ipv6_on && [ -w /proc/sys/net/ipv6/conf/all/forwarding ]; then
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi
	return 0
}

apply() {
	# firewall-start fires while Merlin is still appending its own rules.
	[ "${NO_SLEEP:-0}" = 1 ] || sleep 2

	sysctls
	ip link show "$TUN" >/dev/null 2>&1 || {
		echo "firewall.sh: $TUN not up yet, nothing to do"
		return 0
	}

	ipt_add filter INPUT -i "$TUN" -j ACCEPT
	ipt_add filter INPUT -p udp --dport "$PORT" -j ACCEPT
	ipt_add filter INPUT -p udp --dport 3478 -j ACCEPT
	ipt_add filter FORWARD -i "$TUN" -j ACCEPT
	ipt_add filter FORWARD -o "$TUN" -j ACCEPT

	# SNAT for subnet-router and exit-node traffic on its way out.
	ipt_add nat POSTROUTING -s "$CGNAT" -o "$WAN" -j MASQUERADE
	[ "$LAN" = "$WAN" ] || ipt_add nat POSTROUTING -s "$CGNAT" -o "$LAN" -j MASQUERADE

	if ipv6_on; then
		ipt6_add filter INPUT -i "$TUN" -j ACCEPT
		ipt6_add filter FORWARD -i "$TUN" -j ACCEPT
		ipt6_add filter FORWARD -o "$TUN" -j ACCEPT
		ipt6_add nat POSTROUTING -s "$CGNAT6" -o "$WAN" -j MASQUERADE
	fi

	echo "firewall.sh: rules applied (tun=$TUN wan=$WAN lan=$LAN)"
}

remove() {
	ipt_del filter INPUT -i "$TUN" -j ACCEPT
	ipt_del filter INPUT -p udp --dport "$PORT" -j ACCEPT
	ipt_del filter INPUT -p udp --dport 3478 -j ACCEPT
	ipt_del filter FORWARD -i "$TUN" -j ACCEPT
	ipt_del filter FORWARD -o "$TUN" -j ACCEPT
	ipt_del nat POSTROUTING -s "$CGNAT" -o "$WAN" -j MASQUERADE
	ipt_del nat POSTROUTING -s "$CGNAT" -o "$LAN" -j MASQUERADE
	ipt6_del filter INPUT -i "$TUN" -j ACCEPT
	ipt6_del filter FORWARD -i "$TUN" -j ACCEPT
	ipt6_del filter FORWARD -o "$TUN" -j ACCEPT
	ipt6_del nat POSTROUTING -s "$CGNAT6" -o "$WAN" -j MASQUERADE
	echo "firewall.sh: rules removed"
}

case "$ACTION" in
	apply|"") apply ;;
	remove)   remove ;;
	*) echo "usage: $0 apply [wan-iface] | remove" >&2; exit 2 ;;
esac
