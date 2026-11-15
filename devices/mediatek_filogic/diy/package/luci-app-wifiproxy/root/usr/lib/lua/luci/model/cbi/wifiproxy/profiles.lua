-- Copyright (C) 2026 Kwrt-custom contributors
-- Licensed under the Apache License, Version 2.0

local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local base = uci:get("wifiproxy", "config", "subnet_base") or "10.10"

-- Enumerate radios from /etc/config/wireless
local radios = {}
uci:foreach("wireless", "wifi-device", function(sec)
	local band = sec.band or ""
	local label = sec[".name"]
	if band == "2g" then
		label = label .. " (2.4GHz)"
	elseif band == "5g" then
		label = label .. " (5GHz)"
	end
	radios[#radios + 1] = { sec[".name"], label }
end)
local has_wifi = (#radios > 0)

-- Enumerate passwall proxy nodes, label shows protocol type.
-- Client node sections are typed "nodes" (older versions "node").
local nodes = {}
local seen_nodes = {}
local function collect_node(sec)
	if seen_nodes[sec[".name"]] then
		return
	end
	seen_nodes[sec[".name"]] = true
	local label = sec.remarks or sec[".name"]
	local t = sec.type or ""
	if t ~= "" then
		label = label .. " (" .. t .. ")"
	end
	nodes[#nodes + 1] = { sec[".name"], label }
end
uci:foreach("passwall", "nodes", collect_node)
uci:foreach("passwall", "node", collect_node)

-- The apply script numbers profiles by UCI order among enabled ones;
-- mirror that numbering here so the table shows the real mapping.
local iface_map = {}
local idx = 0
uci:foreach("wifiproxy", "profile", function(sec)
	if tostring(sec.enabled) ~= "0" then
		idx = idx + 1
		iface_map[sec[".name"]] = idx
	end
end)

local function esc_dot(s)
	return (s:gsub("%.", "%%."))
end

local function row_info(section)
	local i = iface_map[section]
	if not i then
		return translate("not enabled")
	end
	local ifn = "wwifi" .. i
	local info = ifn .. " | " .. base .. "." .. i .. ".0/24"
	local st = sys.exec("ubus call network.interface." .. ifn .. " status 2>/dev/null")
	if st == "" then
		return info .. " | " .. translate("not applied")
	end
	if st:match('"up"%s*:%s*true') then
		local pat = "^" .. esc_dot(base .. "." .. i) .. "%."
		local cnt = sys.exec("awk '{n+=($3 ~ /" .. pat .. "/)?1:0} END{print n+0}' /tmp/dhcp.leases 2>/dev/null")
		cnt = (cnt or "0"):gsub("%s+", "")
		return info .. " | " .. string.format(translate("%d client(s) online"), tonumber(cnt) or 0)
	end
	return info .. " | " .. translate("interface down")
end

m = Map("wifiproxy", translate("WiFi Proxy Matrix"),
	translate("Quickly create WiFi networks bound to independent passwall proxy nodes. Each SSID gets its own subnet, DHCP pool, client isolation and a configurable client limit. Saving and applying regenerates network/dhcp/firewall/wireless and passwall ACL config."))

-- Global settings
s = m:section(NamedSection, "config", "main", translate("General Settings"))
o = s:option(Value, "subnet_base", translate("Guest subnet base"),
	translate("Profile N uses <base>.N.0/24 (gateway <base>.N.1)."))
o.placeholder = "10.10"
o.rmempty = false

-- Quick create: batch-generate profiles with round-robin node/radio assignment
s = m:section(NamedSection, "batch", "batch", translate("Quick Create"),
	translate("Batch-create WiFi profiles: proxy nodes are assigned round-robin, radios alternate when multiple radios exist, blank password = random per SSID. Takes effect after Save & Apply."))
s.addremove = false

o = s:option(ListValue, "batch_count", translate("WiFi count"))
o:value("", translate("(select count, then Save & Apply)"))
o.rmempty = true
for i = 1, 8 do
	o:value(tostring(i), tostring(i))
end

o = s:option(Value, "batch_prefix", translate("Name prefix"))
o.default = "PROXY"
o.datatype = "rangelength(1,20)"
o.rmempty = false

o = s:option(Value, "batch_password", translate("WiFi password (blank = random)"))
o.password = true
o.datatype = "rangelength(8,63)"
o.rmempty = true

-- Profiles table
s = m:section(TypedSection, "profile", translate("WiFi Profiles"),
	translate("Each profile creates one WiFi signal. The radio list shows the real radios of this device; profiles without a radio (e.g. on devices without wifi) only generate network config."))
s.addremove = true
s.anonymous = true
s.sortable = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enabled", translate("Enable"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "name", translate("SSID"))
o.datatype = "rangelength(1,32)"
o.rmempty = false

o = s:option(Value, "password", translate("WiFi Password"))
o.password = true
o.datatype = "rangelength(8,63)"
o.rmempty = false

if has_wifi then
	o = s:option(ListValue, "radio", translate("Radio"))
	for _, r in ipairs(radios) do
		o:value(r[1], r[2])
	end
end

o = s:option(Value, "max_clients", translate("Max clients"),
	translate("hostapd max_num_sta of this SSID."))
o.datatype = "range(1,64)"
o.placeholder = "8"
o.rmempty = false

o = s:option(ListValue, "node", translate("Proxy Node"))
if #nodes == 0 then
	o:value("", translate("(add nodes in passwall first)"))
end
for _, n in ipairs(nodes) do
	o:value(n[1], n[2])
end
o.rmempty = true

o = s:option(ListValue, "proxy_mode", translate("Proxy Mode"),
	translate("Global: every connection from this WiFi uses the chosen node (one fixed exit IP). "
		.. "Split: passwall's China-direct lists apply, so domestic sites use the local IP."))
o:value("1", translate("Global (all traffic through node)"))
o:value("0", translate("Split (China direct, rest proxied)"))
o.default = "1"
o.rmempty = false

o = s:option(DummyValue, "_iface", translate("Interface / Subnet"))
function o.cfgvalue(self, section)
	return row_info(section)
end

o = s:option(Button, "_clients", translate("Online Devices"))
o.inputstyle = "apply"
o.render = function(self, section, scope)
	self.title = translate("Online Devices")
	Button.render(self, section, scope)
end
function o.write(self, section)
	local i = iface_map[section]
	if not i then
		return
	end
	local uc = require "luci.model.uci".cursor()
	local name = uc:get("wifiproxy", section, "name") or ""
	local node = uc:get("wifiproxy", section, "node") or ""
	local url = luci.dispatcher.build_url("admin", "services", "wifiproxy", "clients")
		.. "?index=" .. i
		.. "&name=" .. luci.util.urlencode(name)
		.. "&node=" .. luci.util.urlencode(node)
	luci.http.redirect(url)
end

o = s:option(Flag, "isolate", translate("Client isolation"))
o.default = "1"

-- After every successful save: handle quick-create batch, then regenerate configs
m.on_after_commit = function(self)
	local uc = require "luci.model.uci".cursor()
	local c = uc:get("wifiproxy", "batch", "batch_count")
	if c and tonumber(c) and tonumber(c) >= 1 then
		local n = math.min(tonumber(c), 8)
		local prefix = uc:get("wifiproxy", "batch", "batch_prefix") or "PROXY"
		prefix = (prefix:gsub("%s+", ""))
		if prefix == "" then
			prefix = "PROXY"
		end
		if #prefix > 20 then
			prefix = prefix:sub(1, 20)
		end
		local pass = uc:get("wifiproxy", "batch", "batch_password") or ""

		local pool = {}
		local seen_pool = {}
		local function pool_node(sec)
			if not seen_pool[sec[".name"]] then
				seen_pool[sec[".name"]] = true
				pool[#pool + 1] = sec[".name"]
			end
		end
		uc:foreach("passwall", "nodes", pool_node)
		uc:foreach("passwall", "node", pool_node)
		local rl = {}
		uc:foreach("wireless", "wifi-device", function(sec)
			rl[#rl + 1] = sec[".name"]
		end)

		local taken = {}
		uc:foreach("wifiproxy", "profile", function(sec)
			if sec.name then
				taken[sec.name] = true
			end
		end)

		local alpha = "abcdefghjkmnpqrstuvwxyz23456789"
		for i = 1, n do
			local nm = prefix .. "-" .. i
			local suffix = 1
			while taken[nm] do
				suffix = suffix + 1
				nm = prefix .. "-" .. i .. "-" .. suffix
			end
			taken[nm] = true

			local pw = pass or ""
			if #pw < 8 then
				math.randomseed((os.time() + i * 7919) % 2147483647)
				pw = ""
				for _ = 1, 12 do
					local k = math.random(#alpha)
					pw = pw .. alpha:sub(k, k)
				end
			end

			local sid = uc:add("wifiproxy", "profile")
			uc:set("wifiproxy", sid, "enabled", "1")
			uc:set("wifiproxy", sid, "name", nm)
			uc:set("wifiproxy", sid, "password", pw)
			if #rl > 0 then
				uc:set("wifiproxy", sid, "radio", rl[((i - 1) % #rl) + 1])
			end
			uc:set("wifiproxy", sid, "max_clients", "8")
			if #pool > 0 then
				uc:set("wifiproxy", sid, "node", pool[((i - 1) % #pool) + 1])
			end
			uc:set("wifiproxy", sid, "isolate", "1")
		end

		uc:delete("wifiproxy", "batch", "batch_count")
		uc:delete("wifiproxy", "batch", "batch_password")
		uc:commit("wifiproxy")
	end
	sys.call("/usr/libexec/wifiproxy-apply.sh >/tmp/wifiproxy-apply.log 2>&1 &")
end

return m
