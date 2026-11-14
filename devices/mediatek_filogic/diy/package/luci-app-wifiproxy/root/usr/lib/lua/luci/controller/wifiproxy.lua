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
end
