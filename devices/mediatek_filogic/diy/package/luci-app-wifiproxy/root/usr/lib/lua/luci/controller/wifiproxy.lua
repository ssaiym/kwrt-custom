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

	entry({"admin", "services", "wifiproxy", "clients"},
		call("clients_page"), _("Online Devices")).leaf = true

	entry({"admin", "services", "wifiproxy", "status"},
		call("status_json")).leaf = true
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
	local idx = 0
	local parts = {}

	uci:foreach("wifiproxy", "profile", function(sec)
		if tostring(sec.enabled) ~= "0" then
			idx = idx + 1
			local ifn = "wwifi" .. idx
			local up = false
			local st = sys.exec("ubus call network.interface." .. ifn .. " status 2>/dev/null")
			if st ~= "" and st:match('"up"%s*:%s*true') then
				up = true
			end
			local cnt = #collect_clients(base, idx)
			parts[#parts + 1] = string.format(
				'{"section":"%s","iface":"%s","subnet":"%s.%d.0/24","up":%s,"clients":%d,"ssid":"%s","node":"%s"}',
				sec[".name"], ifn, base, idx, tostring(up), cnt,
				(sec.name or ""):gsub('"', '\\"'), (sec.node or ""):gsub('"', '\\"'))
		end
	end)

	http.write('{"ok":true,"profiles":[' .. table.concat(parts, ",") .. ']}')
end
