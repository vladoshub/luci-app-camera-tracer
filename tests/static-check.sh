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

# minimum_motion_frames must be a user-facing UCI/LuCI option and must be
# validated before being written into the generated Motion configuration.
grep -Fq "option minimum_motion_frames '2'" files/etc/config/camera_tracer || fail "minimum motion frames default config"
grep -Fq "'minimum_motion_frames', _('Minimum motion frames')" files/www/luci-static/resources/view/camera_tracer/settings.js || fail "minimum motion frames LuCI option"
grep -Fq "range(1,30)" files/www/luci-static/resources/view/camera_tracer/settings.js || fail "minimum motion frames LuCI range"
grep -Fq "config_get minimum_motion_frames main minimum_motion_frames '2'" files/usr/libexec/camera-tracer/run-motion || fail "minimum motion frames runtime config"
grep -Fq '[ "$minimum_motion_frames" -le 30 ]' files/usr/libexec/camera-tracer/run-motion || fail "minimum motion frames runtime clamp"
grep -Fq 'minimum_motion_frames $minimum_motion_frames' files/usr/libexec/camera-tracer/run-motion || fail "minimum motion frames Motion config"
pass "minimum motion frames setting"

# Visual alarms must not depend on one picture_output=first callback per Motion
# event. on_motion_detected is allowed to fire repeatedly; motion-trigger keeps
# rejected high-FPS callbacks on a tiny tmpfs fast path and event requests a
# snapshot only after the global reservation succeeds.
grep -Fq 'picture_output off' files/usr/libexec/camera-tracer/run-motion || fail "visual picture_output is not disabled"
grep -Fq 'on_motion_detected /usr/libexec/camera-tracer/motion-trigger $motion_session %v' files/usr/libexec/camera-tracer/run-motion || fail "visual on_motion_detected dispatcher missing"
if grep -Fq 'on_picture_save ' files/usr/libexec/camera-tracer/run-motion; then
	fail "legacy one-picture-per-Motion-event alarm hook remains"
fi
grep -Fq 'BASE=' files/usr/libexec/camera-tracer/motion-trigger || fail "motion trigger dispatcher missing"
grep -Fq 'next_allowed' files/usr/libexec/camera-tracer/motion-trigger || fail "motion trigger dispatcher does not fast-path holdoff"
grep -Fq 'control/motion' files/usr/libexec/camera-tracer/motion-trigger || fail "motion trigger dispatcher does not honor runtime motion state"
grep -Fq 'camera-paused' files/usr/libexec/camera-tracer/motion-trigger || fail "motion trigger dispatcher does not honor camera pause"
grep -Fq 'motion-trigger-dispatch.lock' files/usr/libexec/camera-tracer/motion-trigger || fail "motion trigger dispatcher lacks callback coalescing"
grep -Fq 'ct_motion_action snapshot' files/usr/libexec/camera-tracer/event || fail "accepted visual trigger does not request a snapshot"
pass "visual motion retrigger path"

# Every Motion process gets a session id because Motion event ids restart after
# trusted-device pause/resume. Event/movie callbacks must carry that session so
# old event 1/2 state cannot collide with a new Motion process' event 1/2.
grep -Fq 'motion_session="$(date +%s)-$$"' files/usr/libexec/camera-tracer/run-motion || fail "Motion session generation"
grep -Fq 'on_event_start /usr/libexec/camera-tracer/motion-event-start $motion_session %v' files/usr/libexec/camera-tracer/run-motion || fail "Motion event-start session hook"
grep -Fq 'on_event_end /usr/libexec/camera-tracer/motion-event-end $motion_session %v' files/usr/libexec/camera-tracer/run-motion || fail "Motion event-end session hook"
grep -Fq 'on_movie_start /usr/libexec/camera-tracer/movie-start $motion_session %f %v' files/usr/libexec/camera-tracer/run-motion || fail "movie-start session hook"
grep -Fq 'on_movie_end /usr/libexec/camera-tracer/movie-end $motion_session %f %v' files/usr/libexec/camera-tracer/run-motion || fail "movie-end session hook"
grep -Fq 'state_id="${motion_session}-event-${event_id}"' files/usr/libexec/camera-tracer/event || fail "visual state not session-scoped"
grep -Fq 'map-${motion_session}-${event_id}' files/usr/libexec/camera-tracer/movie-start || fail "synthetic map not session-scoped"
pass "Motion session namespace"
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
CONFIG_VIDEO_ENABLED='0'
CONFIG_VIDEO_MAX_TIME='15'
config_get() {
	var="$1"; section="$2"; option="$3"; default="${4:-}"
	case "$option" in
		holdoff) value="$CONFIG_HOLDOFF" ;;
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
[ "$(ct_effective_holdoff)" = '2' ]
CT_TRUSTED_IPS=''
CONFIG_VIDEO_ENABLED='1'
[ "$(ct_effective_holdoff)" = '17' ]
CT_TRUSTED_IPS='192.168.1.10'
[ "$(ct_effective_holdoff)" = '17' ]
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

# Verify the coarse camera-pause state helpers. Trusted-device presence is
# owned only by the camera supervisor; accepted-event delivery has no second
# presence decision.
cat > "$TMP/camera-pause-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
mkdir -p "$CT_BASE"
! ct_camera_paused
ct_camera_pause_set
ct_camera_paused
[ "$(sed -n '1p' "$CT_BASE/camera-paused")" = trusted ]
ct_camera_pause_clear
! ct_camera_paused
EOS
chmod +x "$TMP/camera-pause-test.sh"
sh "$TMP/camera-pause-test.sh" "$TMP/common.sh" "$TMP/camera-pause" || fail "trusted camera pause state"
pass "trusted camera pause state"

# The trusted-presence camera gate wraps the Motion pipeline. With the gate
# disabled it execs run-motion directly; with the gate enabled it owns all
# trusted-Wi-Fi presence polling and starts/stops run-motion.
grep -Fq 'trusted_camera_pause_enabled' files/etc/init.d/camera_tracer || fail "trusted camera gate init option"
grep -Fq 'run-motion-supervisor' files/etc/init.d/camera_tracer || fail "trusted camera gate supervisor selection"
grep -Fq 'exec /usr/libexec/camera-tracer/run-motion' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted camera gate bypass path"
grep -Fq 'ct_trusted_wifi_present' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted camera gate presence check"
grep -Fq 'ct_camera_pause_set' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted camera pause publish"
grep -Fq '/usr/libexec/camera-tracer/run-motion &' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted camera resume path"
grep -Fq 'ct_camera_paused' files/usr/libexec/camera-tracer/event || fail "pre-trigger camera pause gate"
# Accepted-event and delivery paths must not perform any trusted-device decision.
for f in \
	files/usr/libexec/camera-tracer/event \
	files/usr/libexec/camera-tracer/process-event \
	files/usr/libexec/camera-tracer/movie-end \
	files/usr/libexec/camera-tracer/synthetic-video-stop; do
	grep -Fq 'ct_trusted_wifi_present' "$f" && fail "trusted presence check leaked into delivery path: $f"
	grep -Fq 'trusted_timeout' "$f" && fail "trusted timeout leaked into delivery path: $f"
	done
if grep -Fq 'trusted_timeout' files/etc/config/camera_tracer; then
	fail "obsolete trusted_timeout remains in default config"
fi
if grep -Fq "'trusted_timeout'" files/www/luci-static/resources/view/camera_tracer/settings.js; then
	fail "obsolete trusted_timeout remains in LuCI"
fi
grep -Fq 'ct_media_event_active' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted gate does not drain active media"
grep -Fq 'ct_abandon_active_media' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted gate lacks forced media cleanup"
grep -Fq 'accepted media event is still active' files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted gate drain wait log/path"
pass "trusted camera pause gate"

# Accepted media must keep Motion alive until movie-end owns finalize.lock. Forced
# abandonment must clear the global audio/pending markers and make the event
# non-active without allowing a half-written movie to finalize later.
cat > "$TMP/media-drain-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
gen='gen1'
session='session1'
event_dir="$CT_STATE/$gen/${session}-event-42"
mkdir -p "$event_dir" "$CT_RAW"
printf '%s\n' "$gen" > "$CT_BASE/generation"
printf '%s\n' "$session" > "$CT_BASE/motion-session"
printf '%s\n' video > "$event_dir/source"
printf '%s\n' "$session" > "$event_dir/motion_session"
printf audio > "$event_dir/audio.pcm"
ct_audio_record_active_write "$gen" "$session" "$event_dir"
ct_media_event_active
mkdir "$event_dir/finalize.lock"
! ct_media_event_active
rmdir "$event_dir/finalize.lock"
ct_synthetic_pending_write "$gen" "$session" "$event_dir"
ct_media_event_active
ct_abandon_active_media
[ -d "$event_dir/finalize.lock" ]
[ ! -e "$event_dir/audio.pcm" ]
[ ! -e "$CT_BASE/audio-record-active" ]
[ ! -e "$CT_BASE/synthetic-video-pending" ]
! ct_media_event_active
EOS
chmod +x "$TMP/media-drain-test.sh"
sh "$TMP/media-drain-test.sh" "$TMP/common.sh" "$TMP/media-drain" || fail "trusted media drain state"
pass "trusted media drain state"

if grep -R -Fq "decision" files/usr/libexec/camera-tracer/event files/usr/libexec/camera-tracer/process-event files/usr/libexec/camera-tracer/movie-end files/usr/libexec/camera-tracer/synthetic-video-stop; then
	fail "legacy trusted event decision state remains in runtime event paths"
fi
pass "no post-trigger trusted decision"

# iwinfo presence probes must have a dependency-free deadline so a stuck driver
# query cannot freeze the trusted-presence supervisor.
cat > "$TMP/mockbin/iwinfo" <<'EOS'
#!/bin/sh
if [ "$1" = slow0 ]; then
	sleep 5
	exit 0
fi
cat <<'OUT'
AA:BB:CC:DD:EE:01  -40 dBm / -95 dBm (SNR 55)  1000 ms ago
OUT
EOS
chmod +x "$TMP/mockbin/iwinfo"
cat > "$TMP/iwinfo-timeout-test.sh" <<'EOS'
#!/bin/sh
set -eu
PATH="$2:$PATH"
export PATH
. "$1"
CT_BASE="$3"
CT_IWINFO_TIMEOUT=1
ct_log() { :; }
ct_iwinfo_iface_has_mac fast0 aa:bb:cc:dd:ee:01
! ct_iwinfo_iface_has_mac fast0 aa:bb:cc:dd:ee:02
! ct_iwinfo_iface_has_mac slow0 aa:bb:cc:dd:ee:01
EOS
chmod +x "$TMP/iwinfo-timeout-test.sh"
sh "$TMP/iwinfo-timeout-test.sh" "$TMP/common.sh" "$TMP/mockbin" "$TMP/iwinfo-timeout" || fail "iwinfo watchdog"
pass "iwinfo watchdog"

# Verify atomic synthetic-video pending state roundtrip.
cat > "$TMP/pending-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
mkdir -p "$CT_RAW" "$CT_STATE/gen"
ct_synthetic_pending_write gen session1 "$CT_STATE/gen/session1-synthetic-123"
out="$(ct_synthetic_pending_read)"
[ "$(printf '%s\n' "$out" | sed -n '1p')" = gen ]
[ "$(printf '%s\n' "$out" | sed -n '2p')" = session1 ]
[ "$(printf '%s\n' "$out" | sed -n '3p')" = "$CT_STATE/gen/session1-synthetic-123" ]
EOS
chmod +x "$TMP/pending-test.sh"
sh "$TMP/pending-test.sh" "$TMP/common.sh" "$TMP/pending" || fail "synthetic pending state"
pass "synthetic pending state"

# Synthetic timer/audio/MQTT video must get a fresh Motion event. Verify that an
# already-active event is ended and observed idle before eventstart is attempted.
cat > "$TMP/synthetic-boundary-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
mkdir -p "$CT_RAW" "$CT_STATE"
printf '%s\n' session1 > "$CT_BASE/motion-session"
ct_log() { :; }
ct_motion_event_active_write session1 7
ct_motion_action() {
	[ "$1" = eventend ] || return 1
	ct_motion_event_active_clear session1 7
}
ct_motion_prepare_synthetic_event session1 timer
[ ! -e "$CT_BASE/motion-event-active" ]
[ "$(ct_event_dir gen session1-event-1)" != "$(ct_event_dir gen session2-event-1)" ]
EOS
chmod +x "$TMP/synthetic-boundary-test.sh"
sh "$TMP/synthetic-boundary-test.sh" "$TMP/common.sh" "$TMP/synthetic-boundary" || fail "synthetic Motion event boundary"
pass "synthetic Motion event boundary"

# Verify runtime trigger state and the dependency-free MQTT control payload grammar.
cat > "$TMP/control-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
mkdir -p "$CT_BASE"
config_get_bool() {
	var="$1"; section="$2"; option="$3"; default="${4:-0}"
	case "$option" in
		motion_enabled) value=1 ;;
		audio_enabled) value=0 ;;
		timer_enabled) value=0 ;;
		mqtt_trigger_enabled) value=0 ;;
		*) value="$default" ;;
	esac
	eval "$var=\$value"
}
ct_control_init
[ "$(ct_control_read motion)" = '1' ]
[ "$(ct_control_read audio)" = '0' ]
[ "$(ct_control_read timer)" = '0' ]
[ "$(ct_control_read mqtt)" = '0' ]
ct_trigger_enabled video
! ct_trigger_enabled audio
! ct_trigger_enabled timer
! ct_trigger_enabled mqtt
ct_control_apply_payload 'motion=off audio=on,timer=true mqtt=on'
[ "$(ct_control_read motion)" = '0' ]
[ "$(ct_control_read audio)" = '1' ]
[ "$(ct_control_read timer)" = '1' ]
[ "$(ct_control_read mqtt)" = '1' ]
! ct_trigger_enabled video
ct_trigger_enabled audio
ct_trigger_enabled timer
ct_trigger_enabled mqtt
ct_control_apply_payload 'timer=off'
[ "$(ct_control_read audio)" = '1' ]
[ "$(ct_control_read timer)" = '0' ]
[ "$(ct_control_read mqtt)" = '1' ]
ct_control_apply_payload 'all=off'
[ "$(ct_control_read motion)" = '0' ]
[ "$(ct_control_read audio)" = '0' ]
[ "$(ct_control_read timer)" = '0' ]
[ "$(ct_control_read mqtt)" = '0' ]
! ct_control_apply_payload '{"motion":true}'
! ct_control_apply_payload 'nonsense'
EOS
chmod +x "$TMP/control-test.sh"
sh "$TMP/control-test.sh" "$TMP/common.sh" "$TMP/control" || fail "MQTT trigger control state"
pass "MQTT trigger control state"

# Timer worker must always be supervised while Camera Tracer is enabled, emit
# timer events only when runtime state says timer=1, and share the common
# reservation/holdoff with every other trigger.
grep -Fq 'procd_open_instance timer' files/etc/init.d/camera_tracer || fail "timer procd instance"
if grep -Fq 'need_timer=' files/etc/init.d/camera_tracer; then
	fail "timer worker is still conditionally started"
fi
grep -Fq '/usr/libexec/camera-tracer/event timer' files/usr/libexec/camera-tracer/run-timer || fail "timer event worker"
grep -Fq 'ct_trigger_enabled timer' files/usr/libexec/camera-tracer/run-timer || fail "timer runtime state"
grep -Fq 'ct_reserve_event' files/usr/libexec/camera-tracer/event || fail "shared trigger holdoff"
pass "timer trigger path"

# All synthetic triggers require Motion webcontrol. It must be available even
# when the trigger is enabled later through MQTT runtime control, while staying
# localhost-only.
grep -Fq 'webcontrol_port="$CT_WEBCONTROL_PORT"' files/usr/libexec/camera-tracer/run-motion || fail "Motion webcontrol port"
grep -Fq 'webcontrol_localhost on' files/usr/libexec/camera-tracer/run-motion || fail "Motion webcontrol localhost restriction"
if grep -Fq 'webcontrol_port=0' files/usr/libexec/camera-tracer/run-motion; then
	fail "Motion webcontrol can still be disabled at startup"
fi
pass "synthetic trigger webcontrol"

# MQTT-message worker must turn each subscribed message into the same synthetic event.
grep -Fq '/usr/libexec/camera-tracer/event mqtt' files/usr/libexec/camera-tracer/run-mqtt-trigger || fail "MQTT message trigger worker"
grep -Fq 'video|audio|timer|mqtt' files/usr/libexec/camera-tracer/event || fail "MQTT event source acceptance"
pass "MQTT message trigger path"

# A second trigger inside the configured holdoff must be dropped immediately.
cat > "$TMP/holdoff-drop-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
CT_TRUSTED_IPS=''
mkdir -p "$CT_BASE" "$CT_RAW" "$CT_STATE"
config_get() {
	var="$1"; section="$2"; option="$3"; default="${4:-}"
	case "$option" in
		holdoff) value=10 ;;
		video_max_time) value=15 ;;
		*) value="$default" ;;
	esac
	eval "$var=\$value"
}
config_get_bool() {
	var="$1"; section="$2"; option="$3"; default="${4:-0}"
	case "$option" in
		video_enabled) value=0 ;;
		*) value="$default" ;;
	esac
	eval "$var=\$value"
}
ct_reserve_event
! ct_reserve_event
EOS
chmod +x "$TMP/holdoff-drop-test.sh"
sh "$TMP/holdoff-drop-test.sh" "$TMP/common.sh" "$TMP/holdoff-drop" || fail "trigger holdoff drop"
pass "trigger holdoff drop"

# Verify the atomic microphone-recording marker and per-event path guard.
cat > "$TMP/audio-record-test.sh" <<'EOS'
#!/bin/sh
set -eu
. "$1"
CT_BASE="$2"
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
gen='gen1'
session='session1'
event_dir="$CT_STATE/$gen/${session}-event-42"
mkdir -p "$event_dir"
printf stale > "$event_dir/audio.pcm"
ct_audio_record_start "$gen" "$session" "$event_dir"
[ ! -e "$event_dir/audio.pcm" ]
out="$(ct_audio_record_active_read)"
[ "$(printf '%s\n' "$out" | sed -n '1p')" = "$gen" ]
[ "$(printf '%s\n' "$out" | sed -n '2p')" = "$session" ]
[ "$(printf '%s\n' "$out" | sed -n '3p')" = "$event_dir" ]
ct_audio_record_stop "$event_dir"
[ ! -e "$CT_BASE/audio-record-active" ]
! ct_audio_record_start "$gen" "$session" "$CT_BASE/not-state/42"
EOS
chmod +x "$TMP/audio-record-test.sh"
sh "$TMP/audio-record-test.sh" "$TMP/common.sh" "$TMP/audio-record" || fail "audio recording state"
pass "audio recording state"

# New audio-in-video controls must remain optional at package level.
grep -Fq "option video_audio_enabled '0'" files/etc/config/camera_tracer || fail "video audio default"
grep -Fq "option audio_sample_rate '16000'" files/etc/config/camera_tracer || fail "audio sample-rate default"
grep -Fq "option motion_enabled '1'" files/etc/config/camera_tracer || fail "motion trigger default"
grep -Fq "option timer_enabled '0'" files/etc/config/camera_tracer || fail "timer trigger default"
grep -Fq "option timer_interval '60'" files/etc/config/camera_tracer || fail "timer interval default"
grep -Fq "option trusted_camera_pause_enabled '0'" files/etc/config/camera_tracer || fail "trusted camera pause default"
grep -Fq "option trusted_check_interval_seconds '10'" files/etc/config/camera_tracer || fail "trusted camera check interval default"
if grep -Fq 'trusted_timeout' files/etc/config/camera_tracer; then fail "obsolete trusted timeout default"; fi
grep -Fq "range(5,3600)" files/www/luci-static/resources/view/camera_tracer/settings.js || fail "trusted camera check interval range"
grep -Fq "legacy_check_minutes" files/usr/libexec/camera-tracer/run-motion-supervisor || fail "trusted camera legacy interval migration"
grep -Fq "option mqtt_trigger_enabled '0'" files/etc/config/camera_tracer || fail "MQTT message trigger default"
grep -Fq "option mqtt_trigger_topic 'camera_tracer/trigger'" files/etc/config/camera_tracer || fail "MQTT message trigger topic default"
grep -Fq "option mqtt_control_enabled '0'" files/etc/config/camera_tracer || fail "MQTT control default"
grep -Fq "option mqtt_control_topic 'camera_tracer/control'" files/etc/config/camera_tracer || fail "MQTT control topic default"
if grep -Eq 'DEPENDS:.*(alsa-utils|kmod-usb-audio|[ +]ffmpeg([ +]|$))' Makefile; then
	fail "audio runtime tools unexpectedly became hard dependencies"
fi
pass "optional audio dependencies"

# Verify audio detector math: a large constant DC offset must not look like sound,
# while an AC signal of the same amplitude must remain detectable.
python3 - <<'PY' > "$TMP/audio-levels.txt"
for _ in range(5):
    print(' '.join(['2500'] * 800))
for _ in range(5):
    print(' '.join(['2500' if i % 2 == 0 else '-2500' for i in range(800)]))
PY
awk '
BEGIN { ln10 = log(10); quiet_ok = 1; loud_ok = 1 }
{
    sum = 0; sumsq = 0; n = 0
    for (i = 1; i <= NF; i++) { v = $i + 0; sum += v; sumsq += v*v; n++ }
    mean = sum / n
    variance = sumsq / n - mean * mean
    if (variance < 0) variance = 0
    rms = sqrt(variance)
    db = (rms < 1) ? -96 : 20 * log(rms / 32768) / ln10
    if (NR <= 5 && db >= -24) quiet_ok = 0
    if (NR > 5 && db < -24) loud_ok = 0
}
END { exit (quiet_ok && loud_ok) ? 0 : 1 }
' "$TMP/audio-levels.txt" || fail "audio AC-RMS/DC rejection"
pass "audio AC-RMS/DC rejection"

# Quiet re-arm is optional. Enabled keeps the release threshold / hysteresis
# behavior; disabled keeps presenting threshold-qualified audio opportunities and
# relies on the shared event holdoff to accept at most one alarm per holdoff.
grep -Fq "option audio_rearm_enabled '1'" files/etc/config/camera_tracer || fail "audio quiet re-arm default"
grep -Fq "'audio_rearm_enabled', _('Require quiet re-arm after audio trigger')" files/www/luci-static/resources/view/camera_tracer/settings.js || fail "audio quiet re-arm LuCI checkbox"
grep -Fq "config_get_bool rearm_enabled main audio_rearm_enabled 1" files/usr/libexec/camera-tracer/run-audio || fail "audio quiet re-arm runtime flag"
grep -Fq "if (!rearm_enabled)" files/usr/libexec/camera-tracer/run-audio || fail "audio no-release detector branch"
grep -Fq "/usr/libexec/camera-tracer/audio-trigger >/dev/null 2>&1 &" files/usr/libexec/camera-tracer/run-audio || fail "audio no-release fast path"
grep -Fq "next_allowed" files/usr/libexec/camera-tracer/audio-trigger || fail "audio trigger dispatcher does not fast-path holdoff"
grep -Fq "control/audio" files/usr/libexec/camera-tracer/audio-trigger || fail "audio trigger dispatcher does not honor runtime audio state"
grep -Fq "camera-paused" files/usr/libexec/camera-tracer/audio-trigger || fail "audio trigger dispatcher does not honor camera pause"
pass "audio quiet re-arm mode toggle"

DHCP_OUT="$(MOCK_LEASE_FILE="$TMP/leases" PATH="$TMP/mockbin:$PATH" sh files/usr/libexec/camera-tracer/luci-helper dhcp)"
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
	usr/libexec/camera-tracer/motion-trigger \
	usr/libexec/camera-tracer/motion-event-start \
	usr/libexec/camera-tracer/motion-event-end \
	usr/libexec/camera-tracer/audio-trigger \
	usr/libexec/camera-tracer/process-event \
	usr/libexec/camera-tracer/movie-start \
	usr/libexec/camera-tracer/movie-end \
	usr/libexec/camera-tracer/synthetic-video-stop \
	usr/libexec/camera-tracer/run-motion \
	usr/libexec/camera-tracer/run-motion-supervisor \
	usr/libexec/camera-tracer/run-audio \
	usr/libexec/camera-tracer/run-timer \
	usr/libexec/camera-tracer/run-mqtt-control \
	usr/libexec/camera-tracer/run-mqtt-trigger \
	usr/libexec/camera-tracer/luci-helper \
	usr/share/luci/menu.d/luci-app-camera-tracer.json \
	usr/share/rpcd/acl.d/luci-app-camera-tracer.json \
	www/luci-static/resources/view/camera_tracer/settings.js \
	usr/share/camera-tracer/examples/example-hook.sh \
	usr/share/camera-tracer/examples/example-hook.conf.example; do
	[ -f "$TMP/stage/$path" ] || fail "staged file missing: $path"
done
pass "package install staging"

grep -q -- '--http1.1' "$ROOT/examples/example-hook.sh" || fail "example hook does not force HTTP/1.1"
pass "example hook HTTP/1.1"

echo "ALL_STATIC_TESTS_OK"
