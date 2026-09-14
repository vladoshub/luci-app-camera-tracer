include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-camera-tracer
PKG_VERSION:=0.3.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Camera Tracer contributors
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-camera-tracer
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI interface for UVC motion/audio tracing
  DEPENDS:=+luci-base +motion-ffmpeg +v4l-utils +iwinfo +mosquitto-client-ssl +ca-bundle +uclient-fetch +kmod-video-uvc
endef

define Package/luci-app-camera-tracer/description
 Camera Tracer monitors a UVC camera with Motion, optionally records bounded
 MP4 clips, optionally monitors an ALSA microphone and can mux microphone audio
 into completed clips, checks trusted Wi-Fi clients after a configurable delay,
 publishes JPEG/video/event messages over MQTT and can invoke a local alarm hook.
 ALSA/ffmpeg CLI runtime packages for audio features remain optional.
endef

define Build/Compile
endef

define Package/luci-app-camera-tracer/conffiles
/etc/config/camera_tracer
endef

define Package/luci-app-camera-tracer/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/camera_tracer $(1)/etc/config/camera_tracer

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/camera_tracer $(1)/etc/init.d/camera_tracer

	$(INSTALL_DIR) $(1)/usr/libexec/camera-tracer
	$(INSTALL_BIN) ./files/usr/libexec/camera-tracer/* $(1)/usr/libexec/camera-tracer/

	$(INSTALL_DIR) $(1)/usr/share/camera-tracer/examples

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-camera-tracer.json \
		$(1)/usr/share/luci/menu.d/luci-app-camera-tracer.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-camera-tracer.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-camera-tracer.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/camera_tracer
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/camera_tracer/settings.js \
		$(1)/www/luci-static/resources/view/camera_tracer/settings.js
endef

define Package/luci-app-camera-tracer/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
/etc/init.d/camera_tracer enable >/dev/null 2>&1 || true
/etc/init.d/camera_tracer restart >/dev/null 2>&1 || true
exit 0
endef

define Package/luci-app-camera-tracer/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/camera_tracer stop >/dev/null 2>&1 || true
/etc/init.d/camera_tracer disable >/dev/null 2>&1 || true
exit 0
endef

define Package/luci-app-camera-tracer/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-camera-tracer))
