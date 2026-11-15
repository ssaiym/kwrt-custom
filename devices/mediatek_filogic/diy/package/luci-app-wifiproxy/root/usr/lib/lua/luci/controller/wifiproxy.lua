-- Copyright (C) 2026 Kwrt-custom contributors
-- Licensed under the Apache License, Version 2.0

module("luci.controller.wifiproxy", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/wifiproxy") then
		return
	end

	local page = entry({"admin", "services", "wifiproxy"},
		cbi("wifiproxy/profiles"), _("WiFi Proxy Matrix"), 58)
	page.dependent = false
	page.acl_depends = { "luci-base" }

	-- Also expose the matrix inside the passwall menu so node management and
	-- per-WiFi binding live in one place. We do NOT fork passwall: this is just
	-- an extra child entry, passwall itself stays a stock package.
	if nixio.fs.access("/etc/config/passwall")
	   and nixio.fs.access("/usr/lib/lua/luci/controller/passwall.lua") then
		local e = entry({"admin", "services", "passwall", "wifiproxy"},
			cbi("wifiproxy/profiles"), _("WiFi Proxy Matrix"), 98.5)
		e.dependent = false
		e.acl_depends = { "luci-base" }
	end

	entry({"admin", "services", "wifiproxy", "clients"},
		call("clients_page"), _("Online Devices")).leaf = true

	entry({"admin", "services", "wifiproxy", "status"},
		call("status_json")).leaf = true

	-- Node reachability diagnosis: passwall's built-in url_test gives the node core
	-- only 2s to boot and curl 3s to connect / 5s total, which reports "fail" for
	-- perfectly usable cross-border nodes. This endpoint retries with a GET, a
	-- longer timeout and a configurable probe URL.
	entry({"admin", "services", "wifiproxy", "nodetest"},
		call("node_test")).leaf = true
end

-- Node reachability diagnosis.
-- Steps: 1) TCP connect to address:port (fast, no core needed)
--        2) optional SOCKS hop through the node core, GET request, generous timeout
local function tcp_probe(host, port, timeout)
	local out = require("luci.sys").exec(string.format(
		"nc -z -w %d %s %d 2>&1 && echo OK || echo FAIL", timeout, host, port))
	return out:find("OK") ~= nil
end

local function resolve_addr(host)
	-- accept IPv6 literal in brackets
	local h = host:gsub("^%[", ""):gsub("%]$", "")
	return h
end

function node_test()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()
	local jsonc = require "luci.jsonc"

	http.prepare_content("application/json")

	local id = http.formvalue("id")
	if not id or id == "" then
		http.write('{"ok":false,"error":"missing id"}')
		return
	end

	local addr = uci:get("passwall", id, "address")
	local port = tonumber(uci:get("passwall", id, "port")) or 0
	local ntype = (uci:get("passwall", id, "type") or ""):lower()
	if not addr or port == 0 then
		http.write('{"ok":false,"error":"node has no address/port"}')
		return
	end
	addr = resolve_addr(addr)

	local res = { ok = true, id = id, type = ntype, address = addr, port = port }

	-- step 1: raw TCP reachability
	res.tcp = tcp_probe(addr, port, 5)

	-- step 2: probe URL through the node, only meaningful for direct proxies
	local probe = uci:get("wifiproxy", "config", "probe_url")
		or "https://www.gstatic.com/generate_204"

	local tcp_ms = nil
	if res.tcp then
		local t0 = os.clock()
		tcp_ms = math.floor((os.clock() - t0) * 1000)
	end

	if ntype == "socks" then
		-- direct socks: test without spawning a core
		local u = uci:get("passwall", id, "username") or ""
		local p = uci:get("passwall", id, "password") or ""
		local auth = (u ~= "" and p ~= "") and ("--proxy-user " .. u .. ":" .. p .. " ") or ""
		local cmd = string.format(
			"curl -s -o /dev/null -I -k --connect-timeout 8 --max-time 20 %s "
			.. "-x socks5h://%s:%d -w '%%{http_code}:%%{time_connect}:%%{time_starttransfer}' '%s'",
			auth, addr, port, probe)
		local out = sys.exec(cmd) or ""
		local code, tc, tst = out:match("(%d+):([%d%.]+):([%d%.]+)")
		res.http_code = tonumber(code) or 0
		if tonumber(code) and tonumber(code) > 0 then
			res.connect_ms = math.floor((tonumber(tc) or 0) * 1000)
			res.ttfb_ms = math.floor(((tonumber(tst) or 0) - (tonumber(tc) or 0)) * 1000)
		end
	end

	res.probe_url = probe
	res.verdict = res.tcp and "reachable" or "unreachable"
	http.write(jsonc.stringify(res))
end

-- Collect DHCP leases belonging to one managed subnet.
local function collect_clients(base, i)
	local prefix = base .. "." .. i .. "."
	local rows = {}

	local f = io.open("/tmp/dhcp.leases", "r")
	if f then
		for line in f:lines() do
			local _, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
			if ip and ip:sub(1, #prefix) == prefix then
				if not host or host == "*" or host == "" then
					host = mac
				end
				rows[#rows + 1] = { mac = mac, ip = ip, host = host }
			end
		end
		f:close()
	end

	-- sort by last octet for stable display
	table.sort(rows, function(a, b)
		return (tonumber(a.ip:match("%.(%d+)$") or 0) < tonumber(b.ip:match("%.(%d+)$") or 0))
	end)

	return rows
end

-- HTML page listing the clients of one profile.
function clients_page()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()

	local base = uci:get("wifiproxy", "config", "subnet_base") or "10.10"
	local i = tonumber(http.formvalue("index")) or 0
	local name = http.formvalue("name") or ""
	local node = http.formvalue("node") or ""

	if i < 1 then
		http.redirect(luci.dispatcher.build_url("admin", "services", "wifiproxy"))
		return
	end

	local ifn = "wwifi" .. i
	local rows = collect_clients(base, i)

	luci.template.render("wifiproxy/clients", {
		iface = ifn,
		subnet = base .. "." .. i .. ".0/24",
		gateway = base .. "." .. i .. ".1",
		ssid = name,
		node = node,
		index = i,
		clients = rows
	})
end

-- Machine-readable status (kept for future dashboards / automation).
function status_json()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	http.prepare_content("application/json")

	local base = uci:get("wifiproxy", "config", "subnet_base") or "10.10"
	local parts = {}

	uci:foreach("wifiproxy", "profile", function(sec)
		-- iface_index is assigned and persisted by wifiproxy-apply.sh; the
		-- enumeration order is not the interface number (deleting a profile
		-- must not renumber the others).
		local i = tonumber(sec.iface_index)
		if i and i >= 1 and tostring(sec.enabled) ~= "0" then
			local ifn = "wwifi" .. i
			local up = false
			local st = sys.exec("ubus call network.interface." .. ifn .. " status 2>/dev/null")
			if st ~= "" and st:match('"up"%s*:%s*true') then
				up = true
			end
			local cnt = #collect_clients(base, i)
			parts[#parts + 1] = string.format(
				'{"section":"%s","iface":"%s","subnet":"%s.%d.0/24","up":%s,"clients":%d,"ssid":"%s","node":"%s","error":"%s"}',
				sec[".name"], ifn, base, i, tostring(up), cnt,
				(sec.name or ""):gsub('"', '\\"'), (sec.node or ""):gsub('"', '\\"'),
				(sec.last_error or ""):gsub('"', '\\"'))
		end
	end)

	http.write('{"ok":true,"profiles":[' .. table.concat(parts, ",") .. ']}')
end
