#!/bin/sh
# wifiproxy-apply.sh - reconcile managed config with /etc/config/wifiproxy
#
# Managed sections live in wireless/network/dhcp/firewall/passwall under the
# name wwifi<index>. The index is STABLE: it is persisted in
# wifiproxy.<section>.iface_index, so removing profile #1 does not renumber
# profile #2 - and therefore does not rewrite the SSID/subnet of #2 or kick
# its clients off.
#
# Every write is diffed against the running config. Services are reloaded one
# by one, and only for the config files that actually changed, so pressing
# "Save & Apply" on an unchanged page is a no-op instead of a full teardown.

LOG=/tmp/wifiproxy-apply.log
MAX_PROFILES=8
MAX_INDEX=32

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
DIRTY=""     # config files that need commit + reload
FAILED=""    # ACL sections disabled by the post-start health check
SKIP_MSG=""  # human readable list of profiles left on plain routing

# ---- idempotent uci helpers ----------------------------------------------

# mark <config> - remember that a config file was modified
mark() {
	case " $DIRTY " in
		*" $1 "*) ;;
		*) DIRTY="$DIRTY $1" ;;
	esac
}

# cfg_of <uci path> - "wireless.wwifi1.ssid" -> "wireless"
cfg_of() { echo "${1%%.*}"; }

# sec <path> <type> - make sure the section exists with the given type
sec() {
	local cur
	cur=$(uci -q get "$1")
	[ "$cur" = "$2" ] && return 0
	# a type change leaves stale options from the old schema behind
	[ -n "$cur" ] && uci -q delete "$1"
	uci -q set "$1=$2"
	mark "$(cfg_of "$1")"
}

# opt <path> <value> - compare then write; empty value removes the option
opt() {
	local p="$1"
	shift
	local want="$*"
	[ "$(uci -q get "$p")" = "$want" ] && return 0
	if [ -z "$want" ]; then
		uci -q delete "$p"
	else
		uci -q set "$p=$want"
	fi
	mark "$(cfg_of "$p")"
}

# lst <path> <values...> - replace a list option
lst() {
	local p="$1"
	shift
	[ "$(uci -q get "$p")" = "$*" ] && return 0
	uci -q delete "$p"
	local v
	for v in "$@"; do
		[ -n "$v" ] && uci -q add_list "$p=$v"
	done
	mark "$(cfg_of "$p")"
}

have() { command -v "$1" >/dev/null 2>&1; }

# engine binary passwall needs for a node type ("" = unknown, do not check)
node_bin() {
	case "$(echo "$1" | tr 'A-Z' 'a-z')" in
		xray) echo xray ;;
		sing-box) echo sing-box ;;
		ss-rust) echo sslocal ;;
		ssr) echo ssr-local ;;
		hysteria2) echo hysteria ;;
		naiveproxy) echo naive ;;
		*) echo "" ;;
	esac
}

# ---- node preflight -------------------------------------------------------
# NODE_ERR carries a stable code the UI translates. Never bind an ACL to a node
# passwall cannot start: passwall still installs the REDIRECT/DNS rules, so the
# SSID ends up pointing at a dead port - DNS and every TCP flow die with it.
NODE_ERR=""

ensure_node() {
	local n="$1" t proto type bin

	NODE_ERR=""
	[ -n "$n" ] || { NODE_ERR="node_missing"; return 1; }

	t=$(uci -q get "passwall.$n")
	case "$t" in
		nodes|socks) ;;
		*) NODE_ERR="node_missing"; return 1 ;;
	esac

	[ "$(uci -q get "passwall.$n.enabled")" = "0" ] && {
		NODE_ERR="node_disabled"
		return 1
	}

	[ "$t" = "nodes" ] || return 0

	proto=$(uci -q get "passwall.$n.protocol")
	type=$(uci -q get "passwall.$n.type")
	bin=$(node_bin "$type")

	# Do NOT rewrite the node's engine here. passwall rebuilds every node on
	# restart, and a half-understood protocol switch makes it spawn a core per
	# iteration with an ever-increasing port (observed as a runaway process
	# storm). Report it instead and leave the node config untouched.
	if [ -n "$bin" ] && ! have "$bin"; then
		log "node '$n': engine '$type' needs '$bin', which this firmware does not ship"
		NODE_ERR="engine_missing"
		return 1
	fi

	case "$proto" in
		_shunt|_urltest|_balancing|_iface) ;;
		*)
			if [ -z "$(uci -q get "passwall.$n.address")" ] ||
			   [ -z "$(uci -q get "passwall.$n.port")" ]; then
				log "node '$n': address or port is empty"
				NODE_ERR="node_incomplete"
				return 1
			fi
			;;
	esac

	return 0
}

# ---- generate one profile -------------------------------------------------
gen_one() {
	local i="$1" sid="$2" id subnet name pass radio node iso mode maxc

	name=$(uci -q get "wifiproxy.$sid.name")
	pass=$(uci -q get "wifiproxy.$sid.password")
	radio=$(uci -q get "wifiproxy.$sid.radio")
	node=$(uci -q get "wifiproxy.$sid.node")
	iso=$(uci -q get "wifiproxy.$sid.isolate"); iso=${iso:-1}
	mode=$(uci -q get "wifiproxy.$sid.proxy_mode"); mode=${mode:-1}
	maxc=$(uci -q get "wifiproxy.$sid.max_clients"); maxc=${maxc:-8}

	case "$maxc" in ''|*[!0-9]*) maxc=8 ;; esac
	[ "$maxc" -gt 64 ] && maxc=64
	[ "$maxc" -lt 1 ] && maxc=1

	id="wwifi$i"
	subnet="$BASE.$i"

	# ---- wireless ----
	if [ -n "$radio" ] && [ -f /etc/config/wireless ] &&
	   uci -q get "wireless.$radio" >/dev/null 2>&1; then
		sec "wireless.$id" "wifi-iface"
		opt "wireless.$id.device" "$radio"
		opt "wireless.$id.mode" "ap"
		opt "wireless.$id.ssid" "$name"
		if [ -n "$pass" ] && [ ${#pass} -ge 8 ] && [ ${#pass} -le 63 ]; then
			opt "wireless.$id.encryption" "psk2"
			opt "wireless.$id.key" "$pass"
		else
			opt "wireless.$id.encryption" "none"
			opt "wireless.$id.key" ""
			[ -n "$pass" ] && log "profile '$name': password shorter than 8 chars, SSID left open"
		fi
		opt "wireless.$id.network" "$id"
		opt "wireless.$id.isolate" "$iso"
		opt "wireless.$id.max_num_sta" "$maxc"
	elif [ -n "$(uci -q get "wireless.$id")" ]; then
		# radio removed from the profile: drop the stale SSID
		uci -q delete "wireless.$id"
		mark wireless
	fi

	# ---- network ----
	sec "network.$id" "interface"
	opt "network.$id.proto" "static"
	opt "network.$id.ipaddr" "$subnet.1"
	opt "network.$id.netmask" "255.255.255.0"

	# ---- dhcp ----
	sec "dhcp.$id" "dhcp"
	opt "dhcp.$id.interface" "$id"
	opt "dhcp.$id.start" "100"
	opt "dhcp.$id.limit" "150"
	opt "dhcp.$id.leasetime" "12h"
	opt "dhcp.$id.force" "1"

	# ---- firewall: guest zone, DHCP/DNS in, forward to wan only ----
	sec "firewall.$id" "zone"
	opt "firewall.$id.name" "$id"
	lst "firewall.$id.network" "$id"
	opt "firewall.$id.input" "REJECT"
	opt "firewall.$id.output" "ACCEPT"
	opt "firewall.$id.forward" "REJECT"

	sec "firewall.rule_dhcp_$id" "rule"
	opt "firewall.rule_dhcp_$id.name" "Allow-DHCP-$id"
	opt "firewall.rule_dhcp_$id.src" "$id"
	opt "firewall.rule_dhcp_$id.proto" "udp"
	opt "firewall.rule_dhcp_$id.dest_port" "67"
	opt "firewall.rule_dhcp_$id.target" "ACCEPT"

	sec "firewall.rule_dns_$id" "rule"
	opt "firewall.rule_dns_$id.name" "Allow-DNS-$id"
	opt "firewall.rule_dns_$id.src" "$id"
	opt "firewall.rule_dns_$id.proto" "tcp udp"
	opt "firewall.rule_dns_$id.dest_port" "53"
	opt "firewall.rule_dns_$id.target" "ACCEPT"

	sec "firewall.fwd_$id" "forwarding"
	opt "firewall.fwd_$id.src" "$id"
	opt "firewall.fwd_$id.dest" "wan"

	# ---- passwall ACL ----
	if [ ! -f /etc/config/passwall ]; then
		log "passwall not installed, $id keeps plain routing"
		opt "wifiproxy.$sid.last_error" ""
		return 0
	fi

	# No node picked means "let passwall's global node handle it". Writing an
	# ACL without a node would still hijack DNS to a dedicated resolver that
	# has no upstream, so the ACL is removed instead.
	if [ -z "$node" ]; then
		if [ -n "$(uci -q get "passwall.$id")" ]; then
			uci -q delete "passwall.$id"
			mark passwall
		fi
		opt "wifiproxy.$sid.last_error" ""
		log "profile '$name': no node selected, $id follows the global passwall node"
		return 0
	fi

	if ensure_node "$node"; then
		opt "wifiproxy.$sid.last_error" ""
		sec "passwall.$id" "acl_rule"
		opt "passwall.$id.enabled" "1"
		opt "passwall.$id.remarks" "$name"
		# Scope by source subnet only. passwall resolves `interface` through
		# network_get_device(), which silently keeps the previous interface's
		# device when the target interface is down - two ACLs then end up
		# matching the same iifname. The subnet is 1:1 with the interface, so
		# `sources` alone is exact and immune to that.
		opt "passwall.$id.interface" ""
		lst "passwall.$id.sources" "$subnet.0/24"
		opt "passwall.$id.mode" "1"
		opt "passwall.$id.node" "$node"
		opt "passwall.$id.tcp_proxy_mode" "proxy"
		opt "passwall.$id.udp_proxy_mode" "proxy"
		if [ "$mode" = "1" ]; then
			# Pin the whole subnet to one node. Leaving the China list on would
			# send domestic destinations out with the local IP, so the exit IP
			# would depend on the destination instead of the SSID.
			opt "passwall.$id.use_direct_list" "0"
			opt "passwall.$id.use_proxy_list" "0"
			opt "passwall.$id.use_block_list" "0"
			opt "passwall.$id.use_gfw_list" "0"
			opt "passwall.$id.chn_list" "0"
		else
			opt "passwall.$id.use_direct_list" "1"
			opt "passwall.$id.use_proxy_list" "1"
			opt "passwall.$id.use_block_list" "1"
			opt "passwall.$id.use_gfw_list" "1"
			opt "passwall.$id.chn_list" "direct"
		fi
	else
		# Keep the guest network usable: with no ACL the subnet falls back to
		# plain routing instead of a redirect port nothing listens on.
		if [ -n "$(uci -q get "passwall.$id")" ]; then
			uci -q delete "passwall.$id"
			mark passwall
		fi
		opt "wifiproxy.$sid.last_error" "$NODE_ERR"
		SKIP_MSG="$SKIP_MSG $name($NODE_ERR)"
		log "profile '$name': proxy not bound ($NODE_ERR), $id stays on plain routing"
	fi
}

# ---- assign stable interface indices --------------------------------------
enabled_sids() {
	local s
	for s in $(uci -q show wifiproxy 2>/dev/null | sed -n 's/^wifiproxy\.\([^.]*\)=profile$/\1/p'); do
		[ "$(uci -q get "wifiproxy.$s.enabled")" = "0" ] && continue
		echo "$s"
	done
}

is_taken() {
	case " $USED " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

COUNT=0
SKIPPED=0
PENDING=""
USED=""
MAP=""

for sid in $(enabled_sids); do
	COUNT=$((COUNT + 1))
	if [ "$COUNT" -gt "$MAX_PROFILES" ]; then
		SKIPPED=$((SKIPPED + 1))
		continue
	fi
	i=$(uci -q get "wifiproxy.$sid.iface_index")
	case "$i" in ''|*[!0-9]*) i=0 ;; esac
	if [ "$i" -ge 1 ] && [ "$i" -le "$MAX_INDEX" ] && ! is_taken "$i"; then
		USED="$USED $i"
		MAP="$MAP $i:$sid"
	else
		PENDING="$PENDING $sid"
	fi
done

for sid in $PENDING; do
	n=1
	while [ "$n" -le "$MAX_INDEX" ] && is_taken "$n"; do
		n=$((n + 1))
	done
	if [ "$n" -gt "$MAX_INDEX" ]; then
		log "no free interface index left for '$sid', skipped"
		continue
	fi
	USED="$USED $n"
	MAP="$MAP $n:$sid"
	opt "wifiproxy.$sid.iface_index" "$n"
	log "assigned iface index $n to '$sid'"
done

[ "$SKIPPED" -gt 0 ] && log "$SKIPPED profile(s) skipped: hard limit $MAX_PROFILES"

# ---- generate every active profile ---------------------------------------
for pair in $MAP; do
	gen_one "${pair%%:*}" "${pair#*:}"
done

# ---- prune sections of removed profiles ----------------------------------
# Runs after generation so an index that was just freed and immediately
# reused is not deleted again.
ACTIVE=" $USED "

prune_cfg() {
	local cfg="$1" s n
	for s in $(uci -q show "$cfg" 2>/dev/null |
		sed -n "s/^$cfg\.\([^.]*\)=.*/\1/p" | grep 'wwifi[0-9]' | sort -u); do
		n=$(echo "$s" | sed -n 's/.*wwifi\([0-9][0-9]*\)$/\1/p')
		[ -n "$n" ] || continue
		case "$ACTIVE" in
			*" $n "*) continue ;;
		esac
		uci -q delete "$cfg.$s"
		mark "$cfg"
		log "pruned $cfg.$s (profile removed)"
	done
}

for cfg in wireless network dhcp firewall passwall; do
	[ -f "/etc/config/$cfg" ] && prune_cfg "$cfg"
done

# ---- passwall gate --------------------------------------------------------
# passwall v1 ignores ACLs entirely unless @global[0].acl_enable is 1, and it
# has to be set before the restart below or the first apply is silently inert.
if [ -f /etc/config/passwall ] && [ -n "$USED" ]; then
	if [ "$(uci -q get 'passwall.@global[0].acl_enable')" != "1" ]; then
		uci -q set 'passwall.@global[0].acl_enable=1'
		mark passwall
		log "enabled passwall ACL processing (acl_enable=1)"
	fi
fi

# ---- commit ---------------------------------------------------------------
CFG_CHANGED=0
for cfg in $DIRTY; do
	uci commit "$cfg" 2>/dev/null && CFG_CHANGED=1
done

# ---- reload only what changed --------------------------------------------
if [ "$CFG_CHANGED" = "0" ]; then
	log "no configuration change, nothing reloaded"
else
	case " $DIRTY " in
		*" network "*|*" dhcp "*)
			/etc/init.d/network reload >/dev/null 2>&1
			for pair in $MAP; do
				ifup "wwifi${pair%%:*}" >/dev/null 2>&1
			done
			/etc/init.d/dnsmasq restart >/dev/null 2>&1
			;;
	esac
	case " $DIRTY " in
		*" wireless "*)
			# wifi reload bounces every radio, so only do it when an SSID
			# actually changed
			/sbin/wifi config >/dev/null 2>&1
			/sbin/wifi reload >/dev/null 2>&1
			;;
	esac
	case " $DIRTY " in
		*" firewall "*) /etc/init.d/firewall reload >/dev/null 2>&1 ;;
	esac
	case " $DIRTY " in
		*" passwall "*)
			[ -x /etc/init.d/passwall ] && /etc/init.d/passwall restart >/dev/null 2>&1
			;;
	esac
fi

# ---- post-start health check ---------------------------------------------
# passwall installs the REDIRECT and DNS rules even when the ACL core died,
# which takes the whole SSID offline. Detect the dead port and disable only
# that ACL so the subnet keeps working through the plain routing path.
#
# Only meaningful while passwall itself is enabled: with passwall off there
# are no rules at all and every ACL is correctly inactive.
redir_port_of() {
	local var="ACL_$1_redir_port"
	[ -s /tmp/etc/passwall/var ] || { echo ""; return 0; }
	( . /tmp/etc/passwall/var 2>/dev/null; eval "echo \${$var}" )
}

port_listening() {
	netstat -tln 2>/dev/null | grep -q ":$1 "
}

if [ "$(uci -q get 'passwall.@global[0].enabled')" = "1" ]; then
	for pair in $MAP; do
		i=${pair%%:*}
		sid=${pair#*:}
		id="wwifi$i"

		[ "$(uci -q get "passwall.$id")" = "acl_rule" ] || continue
		[ "$(uci -q get "passwall.$id.enabled")" = "1" ] || continue

		rp=$(redir_port_of "$id")
		[ -n "$rp" ] || continue

		w=0
		while [ "$w" -lt 5 ]; do
			port_listening "$rp" && break
			sleep 1
			w=$((w + 1))
		done
		port_listening "$rp" && continue

		log "health check: $id redirect port $rp never came up, disabling its ACL"
		uci -q set "passwall.$id.enabled=0"
		opt "wifiproxy.$sid.last_error" "start_failed"
		SKIP_MSG="$SKIP_MSG $(uci -q get "wifiproxy.$sid.name")(start_failed)"
		FAILED="$FAILED $id"
	done
fi

if [ -n "$FAILED" ]; then
	uci commit passwall 2>/dev/null
	uci commit wifiproxy 2>/dev/null
	/etc/init.d/passwall restart >/dev/null 2>&1
	log "passwall restarted without the failed ACL(s):$FAILED"
fi

[ -n "$SKIP_MSG" ] && log "proxy inactive:$SKIP_MSG"

BOUND=0
for pair in $MAP; do
	[ "$(uci -q get "passwall.wwifi${pair%%:*}.enabled")" = "1" ] && BOUND=$((BOUND + 1))
done
log "apply finished, $(echo $MAP | wc -w) WiFi active, $BOUND proxied"
exit 0
