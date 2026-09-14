#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Shell syntax using the host shell and BusyBox ash when available.
for f in files/etc/init.d/camera_tracer files/usr/libexec/camera-tracer/* examples/*.sh; do
	sh -n "$f" || fail "sh syntax: $f"
	if command -v busybox >/dev/null 2>&1; then
		busybox ash -n "$f" || fail "BusyBox ash syntax: $f"
	fi
done
pass "shell syntax"

# JSON syntax.
python3 -m json.tool files/usr/share/luci/menu.d/luci-app-camera-tracer.json >/dev/null
python3 -m json.tool files/usr/share/rpcd/acl.d/luci-app-camera-tracer.json >/dev/null
pass "menu/ACL JSON"

# LuCI JavaScript syntax when Node is available.
if command -v node >/dev/null 2>&1; then
	node --check files/www/luci-static/resources/view/camera_tracer/settings.js >/dev/null
	pass "LuCI JavaScript syntax"
else
	echo "SKIP: node not installed; LuCI JavaScript syntax check"
fi

# Unit-test pure helpers from common.sh without requiring an OpenWrt host.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
sed '/^\. \/lib\/functions\.sh$/d' files/usr/libexec/camera-tracer/common.sh > "$TMP/common.sh"
cat > "$TMP/helpers.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"

CONFIG_HOLDOFF=''
CONFIG_TRUSTED_TIMEOUT='5'
CONFIG_VIDEO_ENABLED='0'
CONFIG_VIDEO_MAX_TIME='15'
config_get() {
	var="$1"; section="$2"; option="$3"; default="${4:-}"
	case "$option" in
		holdoff) value="$CONFIG_HOLDOFF" ;;
		trusted_timeout) value="$CONFIG_TRUSTED_TIMEOUT" ;;
		video_max_time) value="$CONFIG_VIDEO_MAX_TIME" ;;
		*) value="$default" ;;
	esac
	eval "$var=\$value"
}
config_get_bool() {
	var="$1"; section="$2"; option="$3"; default="${4:-0}"
	case "$option" in
		video_enabled) value="$CONFIG_VIDEO_ENABLED" ;;
		*) value="$default" ;;
	esac
	eval "$var=\$value"
}

ct_safe_photo_name 'last.jpg'
! ct_safe_photo_name '../evil.jpg'
! ct_safe_photo_name 'x/y.jpg'
! ct_safe_photo_name '.'
ct_safe_video_name 'last.mp4'
! ct_safe_video_name 'last.mkv'
! ct_safe_video_name '../last.mp4'

CT_TRUSTED_IPS=''
[ "$(ct_effective_holdoff)" = '2' ]
CT_TRUSTED_IPS='192.168.1.10'
[ "$(ct_effective_holdoff)" = '7' ]
CT_TRUSTED_IPS=''
CONFIG_VIDEO_ENABLED='1'
[ "$(ct_effective_holdoff)" = '17' ]
CT_TRUSTED_IPS='192.168.1.10'
CONFIG_TRUSTED_TIMEOUT='20'
[ "$(ct_effective_holdoff)" = '22' ]
CONFIG_HOLDOFF='11'
[ "$(ct_effective_holdoff)" = '11' ]

[ "$(ct_json_escape 'a"b\\c')" = 'a\"b\\\\c' ]
EOS
chmod +x "$TMP/helpers.sh"
sh "$TMP/helpers.sh" "$TMP/common.sh" || fail "common.sh helper behavior"
pass "common.sh helper behavior"

# Verify trusted IP -> MAC resolution: static DHCP must win over an active
# lease for the same IP, while a lease-only IP remains usable.
mkdir -p "$TMP/mockbin"
cat > "$TMP/mockbin/uci" <<'EOS'
#!/bin/sh
case "$*" in
	"-q show dhcp")
		echo 'dhcp.trusted=host'
		;;
	"-q get dhcp.trusted.ip") echo '192.168.1.10' ;;
	"-q get dhcp.trusted.mac") echo 'AA:BB:CC:DD:EE:01' ;;
	"-q get dhcp.@dnsmasq[0].leasefile") echo "$MOCK_LEASE_FILE" ;;
	*) exit 1 ;;
esac
EOS
chmod +x "$TMP/mockbin/uci"
cat > "$TMP/leases" <<'EOS'
0 11:22:33:44:55:66 192.168.1.10 wrong-mac *
0 aa:bb:cc:dd:ee:22 192.168.1.20 lease-only *
EOS
cat > "$TMP/mac-test.sh" <<'EOS'
#!/bin/sh
set -eu
PATH="$2:$PATH"
export PATH MOCK_LEASE_FILE="$3"
. "$1"
[ "$(ct_mac_for_ip 192.168.1.10)" = 'aa:bb:cc:dd:ee:01' ]
[ "$(ct_mac_for_ip 192.168.1.20)" = 'aa:bb:cc:dd:ee:22' ]
EOS
chmod +x "$TMP/mac-test.sh"
sh "$TMP/mac-test.sh" "$TMP/common.sh" "$TMP/mockbin" "$TMP/leases" || fail "trusted MAC resolution"
pass "trusted MAC resolution"

# Verify atomic audio-video pending state roundtrip.
cat > "$TMP/pending-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
mkdir -p "$CT_RAW" "$CT_STATE/gen"
ct_audio_pending_write gen "$CT_STATE/gen/123"
out="$(ct_audio_pending_read)"
[ "$(printf '%s\n' "$out" | sed -n '1p')" = gen ]
[ "$(printf '%s\n' "$out" | sed -n '2p')" = "$CT_STATE/gen/123" ]
EOS
chmod +x "$TMP/pending-test.sh"
sh "$TMP/pending-test.sh" "$TMP/common.sh" "$TMP/pending" || fail "audio pending state"
pass "audio pending state"

# Verify the atomic microphone-recording marker and per-event path guard.
cat > "$TMP/audio-record-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
gen='gen1'
event_dir="$CT_STATE/$gen/42"
mkdir -p "$event_dir"
printf stale > "$event_dir/audio.pcm"
ct_audio_record_start "$gen" "$event_dir"
[ ! -e "$event_dir/audio.pcm" ]
out="$(ct_audio_record_active_read)"
[ "$(printf '%s\n' "$out" | sed -n '1p')" = "$gen" ]
[ "$(printf '%s\n' "$out" | sed -n '2p')" = "$event_dir" ]
ct_audio_record_stop "$event_dir"
[ ! -e "$CT_BASE/audio-record-active" ]
! ct_audio_record_start "$gen" "$CT_BASE/not-state/42"
EOS
chmod +x "$TMP/audio-record-test.sh"
sh "$TMP/audio-record-test.sh" "$TMP/common.sh" "$TMP/audio-record" || fail "audio recording state"
pass "audio recording state"

# New audio-in-video controls must remain optional at package level.
grep -Fq "option video_audio_enabled '0'" files/etc/config/camera_tracer || fail "video audio default"
grep -Fq "option audio_sample_rate '16000'" files/etc/config/camera_tracer || fail "audio sample-rate default"
if grep -Eq 'DEPENDS:.*(alsa-utils|kmod-usb-audio|[ +]ffmpeg([ +]|$))' Makefile; then
	fail "audio runtime tools unexpectedly became hard dependencies"
fi
pass "optional audio dependencies"

DHCP_OUT="$(MOCK_LEASE_FILE="$TMP/leases" PATH="$TMP/mockbin:$PATH" files/usr/libexec/camera-tracer/luci-helper dhcp)"
printf '%s\n' "$DHCP_OUT" | grep -Fq '192.168.1.10' || fail "DHCP helper static entry"
printf '%s\n' "$DHCP_OUT" | grep -Fq '192.168.1.20' || fail "DHCP helper active lease entry"
[ "$(printf '%s\n' "$DHCP_OUT" | grep -c '^192\.168\.1\.10[[:space:]]')" -eq 1 ] || fail "DHCP helper deduplication"
pass "DHCP selector helper"

# Verify that the package install recipe can stage every file with OpenWrt-like
# INSTALL_* macros. This is not a substitute for a target SDK build, but catches
# broken source paths / install directives in the package Makefile.
mkdir -p "$TMP/owrt/include" "$TMP/stage"
cat > "$TMP/owrt/rules.mk" <<'EOS'
INCLUDE_DIR:=$(TOPDIR)/include
EOS
cat > "$TMP/owrt/include/package.mk" <<'EOS'
INSTALL_DIR:=install -d -m0755
INSTALL_CONF:=install -m0600
INSTALL_BIN:=install -m0755
INSTALL_DATA:=install -m0644
define BuildPackage
endef
EOS
cat > "$TMP/driver.mk" <<EOF2
TOPDIR:=$TMP/owrt
REPO:=$ROOT
STAGE:=$TMP/stage
include \$(REPO)/Makefile
.PHONY: stage
stage:
EOF2
printf '\t$(call Package/luci-app-camera-tracer/install,$(STAGE))\n' >> "$TMP/driver.mk"
make -s -f "$TMP/driver.mk" stage || fail "package install staging"

for path in \
	etc/config/camera_tracer \
	etc/init.d/camera_tracer \
	usr/libexec/camera-tracer/event \
	usr/libexec/camera-tracer/process-event \
	usr/libexec/camera-tracer/movie-start \
	usr/libexec/camera-tracer/movie-end \
	usr/libexec/camera-tracer/audio-video-stop \
	usr/libexec/camera-tracer/run-motion \
	usr/libexec/camera-tracer/run-audio \
	usr/libexec/camera-tracer/luci-helper \
	usr/share/luci/menu.d/luci-app-camera-tracer.json \
	usr/share/rpcd/acl.d/luci-app-camera-tracer.json \
	www/luci-static/resources/view/camera_tracer/settings.js; do
	[ -f "$TMP/stage/$path" ] || fail "staged file missing: $path"
done
pass "package install staging"

echo "ALL_STATIC_TESTS_OK"
