include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wifiproxy
PKG_VERSION:=1.3.1
PKG_RELEASE:=1

LUCI_TITLE:=WiFi Proxy Matrix for passwall - per-SSID proxy node binding and client limits
LUCI_DESCRIPTION:=Quickly create guest WiFi networks, bind each SSID to an independent \
	passwall proxy node (ACL per interface) and limit concurrent clients per SSID.
LUCI_DEPENDS:=+luci-base +luci-app-passwall

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
