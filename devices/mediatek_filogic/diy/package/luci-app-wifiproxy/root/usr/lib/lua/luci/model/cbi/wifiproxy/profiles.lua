-- Copyright (C) 2026 Kwrt-custom contributors
-- Licensed under the Apache License, Version 2.0

local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

m = Map("wifiproxy", translate("WiFi Proxy Matrix"),
	translate("Create guest WiFi networks bound to independent passwall proxy nodes. "
		.. "Each SSID gets its own subnet, DHCP pool, client-isolation and a configurable client limit. "
		.. "Apply reloads network/dhcp/firewall/wifi and passwall ACL."))

-- Global settings
s = m:section(NamedSection, "config", "main", translate("General Settings"))
o = s:option(Value, "subnet_base", translate("Guest subnet base"),
	translate("Profile N uses <base>.N.0/24 (gateway <base>.N.1)."))
o.placeholder = "10.10"
o.rmempty = false

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

-- Enumerate passwall proxy nodes
local nodes = {}
uci:foreach("passwall", "node", function(sec)
	nodes[#nodes + 1] = { sec[".name"], sec.remarks or sec[".name"] }
end)

-- Profiles table
s = m:section(TypedSection, "profile", translate("WiFi Profiles"),
	translate("One WiFi per proxy node. Radio list shows real radios of this device; "
		.. "profiles without a radio (e.g. on devices without wifi) only generate network config."))
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

o = s:option(Flag, "isolate", translate("Client isolation"))
o.default = "1"

-- Regenerate managed configs after every successful save
m.on_after_commit = function(self)
	sys.call("/usr/libexec/wifiproxy-apply.sh >/tmp/wifiproxy-apply.log 2>&1 &")
end

return m
