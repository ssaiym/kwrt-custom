#!/bin/sh
# wifiproxy-apply.sh - regenerate managed configs from /etc/config/wifiproxy
# Managed sections use the naming convention wwifi<index> in:
#   wireless (wifi-iface), network (interface), dhcp (dhcp),
#   firewall (zone/rule/forwarding), passwall (ACLs)
# Safe to run repeatedly: managed sections are wiped then recreated.

LOG=/tmp/wifiproxy-apply.log
MAX_PROFILES=8

log() { echo "[wifiproxy] $*" >> "$LOG" 2>/dev/null; }

# guard against concurrent applies (racing reloads can wedge netifd)
if [ -f /tmp/wifiproxy-applying ]; then
	log "another apply in progress, exiting"
	exit 0
fi
touch /tmp/wifiproxy-applying
trap 'rm -f /tmp/wifiproxy-applying' EXIT

BASE=$(uci -q get wifiproxy.config.subnet_base)
BASE=${BASE:-10.10}

have_wireless() { [ -f /etc/config/wireless ]; }

# ---- wipe managed sections ------------------------------------------------
wipe() {
	for id in $(uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\(wwifi[0-9]*\)=.*/\1/p'); do
		uci -q delete wireless.$id
	done
	for id in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\(wwifi[0-9]*\)=.*/\1/p'); do
		uci -q delete network.$id
	done
	for id in $(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\(wwifi[0-9]*\)=.*/\1/p'); do
		uci -q delete dhcp.$id
	done
	for id in $(uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\(.*wwifi[0-9]*\)=.*/\1/p'); do
		uci -q delete firewall.$id
	done
	for id in $(uci -q show passwall 2>/dev/null | sed -n 's/^passwall\.\(wwifi[0-9]*\)=.*/\1/p'); do
		uci -q delete passwall.$id
	done
}
wipe

# ---- generate one profile -------------------------------------------------
gen_one() {
	i=$1
	sid=$2
	name=$(uci -q get wifiproxy.$sid.name)
	pass=$(uci -q get wifiproxy.$sid.password)
	radio=$(uci -q get wifiproxy.$sid.radio)
	node=$(uci -q get wifiproxy.$sid.node)
	iso=$(uci -q get wifiproxy.$sid.isolate)
	iso=${iso:-1}
	maxc=$(uci -q get wifiproxy.$sid.max_clients)
	maxc=${maxc:-8}
	case "$maxc" in
		''|*[!0-9]*) maxc=8 ;;
	esac
	[ "$maxc" -gt 64 ] && maxc=64
	[ "$maxc" -lt 1 ] && maxc=1

	id="wwifi$i"
	subnet="$BASE.$i"
	wifi_done=0

	# wireless
	if [ -n "$radio" ] && have_wireless && uci -q get wireless.$radio >/dev/null 2>&1; then
		uci -q set wireless.$id=wifi-iface
		uci set wireless.$id.device="$radio"
		uci set wireless.$id.mode="ap"
		uci set wireless.$id.ssid="$name"
		if [ -n "$pass" ] && [ "${#pass}" -ge 8 ] && [ "${#pass}" -le 63 ]; then
			uci set wireless.$id.encryption="psk2"
			uci set wireless.$id.key="$pass"
		else
			uci set wireless.$id.encryption="none"
			log "profile '$name': password invalid (<8 chars), SSID set to open"
		fi
		uci set wireless.$id.network="$id"
		uci set wireless.$id.isolate="$iso"
		uci set wireless.$id.max_num_sta="$maxc"
		wifi_done=1
	elif [ -n "$radio" ]; then
		log "profile '$name': radio '$radio' not found, wifi part skipped"
	fi

	# network
	uci -q set network.$id=interface
	uci set network.$id.proto="static"
	uci set network.$id.ipaddr="$subnet.1"
	uci set network.$id.netmask="255.255.255.0"

	# dhcp
	uci -q set dhcp.$id=dhcp
	uci set dhcp.$id.interface="$id"
	uci set dhcp.$id.start="100"
	uci set dhcp.$id.limit="150"
	uci set dhcp.$id.leasetime="12h"
	uci set dhcp.$id.force="1"

	# firewall: guest zone (dhcp+dns allowed in, only forward to wan)
	uci -q set firewall.$id=zone
	uci set firewall.$id.name="$id"
	uci -q add_list firewall.$id.network="$id"
	uci set firewall.$id.input="REJECT"
	uci set firewall.$id.output="ACCEPT"
	uci set firewall.$id.forward="REJECT"
	uci -q set firewall.rule_dhcp_$id=rule
	uci set firewall.rule_dhcp_$id.name="Allow-DHCP-$id"
	uci set firewall.rule_dhcp_$id.src="$id"
	uci set firewall.rule_dhcp_$id.proto="udp"
	uci set firewall.rule_dhcp_$id.dest_port="67"
	uci set firewall.rule_dhcp_$id.target="ACCEPT"
	uci -q set firewall.rule_dns_$id=rule
	uci set firewall.rule_dns_$id.name="Allow-DNS-$id"
	uci set firewall.rule_dns_$id.src="$id"
	uci set firewall.rule_dns_$id.proto="tcp udp"
	uci set firewall.rule_dns_$id.dest_port="53"
	uci set firewall.rule_dns_$id.target="ACCEPT"
	uci -q set firewall.fwd_$id=forwarding
	uci set firewall.fwd_$id.src="$id"
	uci set firewall.fwd_$id.dest="wan"

	# passwall ACL (bind this interface to the chosen node)
	# NOTE: runtime (app.sh) enumerates sections of type "acl_rule"
	uci -q set passwall.$id=acl_rule
	uci set passwall.$id.enabled="1"
	uci set passwall.$id.remarks="$name"
	uci set passwall.$id.interface="$id"
	uci -q add_list passwall.$id.sources="$subnet.0/24"
	uci set passwall.$id.mode="1"
	[ -n "$node" ] && uci set passwall.$id.node="$node"

	log "generated $id ($name, subnet $subnet.0/24, max_clients $maxc, wifi $wifi_done)"
}

# ---- enumerate enabled profiles -------------------------------------------
idx=0
skipped=0
for sid in $(uci -q show wifiproxy 2>/dev/null | sed -n 's/^wifiproxy\.\([^.]*\)=profile$/\1/p'); do
	en=$(uci -q get wifiproxy.$sid.enabled)
	[ "$en" = "1" ] || continue
	idx=$((idx + 1))
	if [ "$idx" -gt "$MAX_PROFILES" ]; then
		skipped=$((skipped + 1))
		continue
	fi
	gen_one "$idx" "$sid"
done
[ "$skipped" -gt 0 ] && log "$skipped profile(s) skipped: hard limit $MAX_PROFILES"

uci commit wireless 2>/dev/null
uci commit network 2>/dev/null
uci commit dhcp 2>/dev/null
uci commit firewall 2>/dev/null
uci commit passwall 2>/dev/null

# ---- service reloads ------------------------------------------------------
# Use incremental reloads: a full "network restart" tears down every
# interface (incl. the one LuCI is served on) and can wedge netifd.
/etc/init.d/network reload >/dev/null 2>&1
if have_wireless; then
	/sbin/wifi config >/dev/null 2>&1
	/sbin/wifi reload >/dev/null 2>&1
fi
/etc/init.d/dnsmasq restart >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/passwall restart >/dev/null 2>&1

# passwall v1 gates ACL processing behind global acl_enable (default 0);
# without this the per-SSID node binding is silently ignored.
[ "$idx" -ge 1 ] && uci -q set passwall.@global[0].acl_enable="1"

log "apply finished, $idx profile(s) active"
exit 0
