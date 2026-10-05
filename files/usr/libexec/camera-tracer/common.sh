#!/bin/sh

. /lib/functions.sh

CT_BASE=/tmp/camera_tracer
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
CT_WEBCONTROL_PORT=8799
CT_IWINFO_TIMEOUT=${CT_IWINFO_TIMEOUT:-3}

ct_log() {
	logger -t camera-tracer "$*"
}

ct_is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

ct_safe_file_name() {
	case "$1" in
		''|.|..|*/*|*\\*|*[!A-Za-z0-9._-]*) return 1 ;;
		*) return 0 ;;
	esac
}

ct_safe_photo_name() {
	ct_safe_file_name "$1"
}

ct_safe_video_name() {
	ct_safe_file_name "$1" || return 1
	case "$1" in
		*.mp4) return 0 ;;
		*) return 1 ;;
	esac
}

ct_load_config() {
	config_load camera_tracer
}

ct_get_trusted_ips() {
	CT_TRUSTED_IPS=''
	_ct_add_trusted_ip() {
		[ -n "$1" ] || return 0
		CT_TRUSTED_IPS="${CT_TRUSTED_IPS}${CT_TRUSTED_IPS:+ }$1"
	}
	config_list_foreach main trusted_ip _ct_add_trusted_ip
}

ct_trusted_count() {
	local n=0 ip
	for ip in $CT_TRUSTED_IPS; do
		n=$((n + 1))
	done
	printf '%s\n' "$n"
}

ct_mac_for_ip() {
	local ip="$1" section hip mac leasefile

	# A configured static DHCP reservation is authoritative. This prevents a
	# transient/dynamic lease from changing the trusted MAC for a saved IP.
	for section in $(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^=]*\)=host$/\1/p'); do
		hip="$(uci -q get "dhcp.$section.ip" 2>/dev/null)"
		[ "$hip" = "$ip" ] || continue
		mac="$(uci -q get "dhcp.$section.mac" 2>/dev/null | awk '{ print $1 }')"
		[ -n "$mac" ] || continue
		printf '%s\n' "$mac" | tr 'A-F' 'a-f'
		return 0
	done

	leasefile="$(uci -q get 'dhcp.@dnsmasq[0].leasefile' 2>/dev/null)"
	[ -n "$leasefile" ] || leasefile='/tmp/dhcp.leases'
	if [ -r "$leasefile" ]; then
		mac="$(awk -v ip="$ip" '$3 == ip { print tolower($2); exit }' "$leasefile" 2>/dev/null)"
		if [ -n "$mac" ]; then
			printf '%s\n' "$mac"
			return 0
		fi
	fi

	return 1
}

ct_iwinfo_iface_has_mac() {
	local iface="$1" want="$2" timeout pid elapsed tmp rc safe_iface
	timeout="$CT_IWINFO_TIMEOUT"
	ct_is_uint "$timeout" || timeout=3
	[ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
	[ "$timeout" -le 10 ] 2>/dev/null || timeout=10

	safe_iface="$(printf '%s' "$iface" | tr -c 'A-Za-z0-9_.-' '_')"
	tmp="$CT_BASE/.iwinfo-${safe_iface}.$$"
	mkdir -p "$CT_BASE" || return 1
	rm -f "$tmp"

	# iwinfo normally returns immediately, but a wedged wireless driver must not
	# stall the trusted-presence supervisor forever. Do not depend on an optional
	# `timeout` utility: run iwinfo asynchronously and enforce a small deadline.
	iwinfo "$iface" assoclist > "$tmp" 2>/dev/null &
	pid=$!
	elapsed=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$elapsed" -ge "$timeout" ]; then
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
			rm -f "$tmp"
			ct_log "iwinfo assoclist timed out for interface $iface after ${timeout}s"
			return 1
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	if wait "$pid" 2>/dev/null; then
		rc=0
	else
		rc=$?
	fi
	if [ "$rc" -eq 0 ] && awk -v want="$want" '
		/^[0-9A-Fa-f][0-9A-Fa-f]:/ {
			mac = tolower($1)
			if (mac == want) found = 1
		}
		END { exit(found ? 0 : 1) }' "$tmp"; then
		rm -f "$tmp"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

ct_wifi_mac_present() {
	local want iface path
	want="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
	[ -n "$want" ] || return 1

	for path in /sys/class/net/*; do
		[ -e "$path" ] || continue
		iface="${path##*/}"
		if ct_iwinfo_iface_has_mac "$iface" "$want"; then
			return 0
		fi
	done

	return 1
}

ct_trusted_wifi_present() {
	local ip mac
	for ip in $CT_TRUSTED_IPS; do
		mac="$(ct_mac_for_ip "$ip" 2>/dev/null)" || mac=''
		[ -n "$mac" ] || continue
		if ct_wifi_mac_present "$mac"; then
			ct_log "trusted Wi-Fi client present: ip=$ip mac=$mac"
			return 0
		fi
	done
	return 1
}

# Presence-gate state is the only trusted-device gate. When enabled, the
# supervisor stops Motion and closes the camera device while a trusted Wi-Fi
# client is present. Event delivery does not perform a second trusted-device
# presence check.
ct_camera_pause_set() {
	local tmp
	mkdir -p "$CT_BASE" || return 1
	tmp="$CT_BASE/.camera-paused.tmp.$$"
	{
		printf 'trusted\n'
		date +%s
	} > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/camera-paused"
}

ct_camera_pause_clear() {
	rm -f "$CT_BASE/camera-paused"
}

ct_camera_paused() {
	[ -r "$CT_BASE/camera-paused" ]
}

ct_motion_session_read() {
	[ -r "$CT_BASE/motion-session" ] || return 1
	cat "$CT_BASE/motion-session"
}

ct_motion_session_is_current() {
	local expected="$1" current
	[ -n "$expected" ] || return 1
	current="$(ct_motion_session_read 2>/dev/null || true)"
	[ "$current" = "$expected" ]
}

ct_motion_event_active_write() {
	local motion_session="$1" event_id="$2" tmp
	ct_motion_session_is_current "$motion_session" || return 1
	ct_is_uint "$event_id" || return 1
	tmp="$CT_BASE/.motion-event-active.tmp.$$"
	{
		printf '%s\n' "$motion_session"
		printf '%s\n' "$event_id"
	} > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/motion-event-active"
}

ct_motion_event_active_read() {
	local line=0 motion_session='' event_id=''
	[ -r "$CT_BASE/motion-event-active" ] || return 1
	while IFS= read -r value; do
		line=$((line + 1))
		case "$line" in
			1) motion_session="$value" ;;
			2) event_id="$value"; break ;;
		esac
	done < "$CT_BASE/motion-event-active"
	[ -n "$motion_session" ] && ct_is_uint "$event_id" || return 1
	printf '%s\n%s\n' "$motion_session" "$event_id"
}

ct_motion_event_active_clear() {
	local motion_session="$1" event_id="$2" active active_session active_id
	active="$(ct_motion_event_active_read 2>/dev/null || true)"
	active_session="$(printf '%s\n' "$active" | sed -n '1p')"
	active_id="$(printf '%s\n' "$active" | sed -n '2p')"
	[ "$active_session" = "$motion_session" ] || return 0
	[ "$active_id" = "$event_id" ] || return 0
	rm -f "$CT_BASE/motion-event-active"
}

# End an already-open Motion event before a synthetic timer/audio/MQTT movie is
# requested. A webcontrol eventstart only starts a new movie when Motion is idle;
# if an event is already open it merely keeps that event active. Waiting for the
# on_event_end marker prevents eventend/eventstart from collapsing into the same
# frame and losing the synthetic start request.
ct_motion_prepare_synthetic_event() {
	local motion_session="$1" source_type="${2:-synthetic}" active active_session active_id i
	ct_motion_session_is_current "$motion_session" || return 1
	active="$(ct_motion_event_active_read 2>/dev/null || true)"
	active_session="$(printf '%s\n' "$active" | sed -n '1p')"
	active_id="$(printf '%s\n' "$active" | sed -n '2p')"
	[ "$active_session" = "$motion_session" ] || return 0
	ct_is_uint "$active_id" || return 0

	ct_log "$source_type trigger: ending active Motion event $active_id before synthetic movie"
	ct_motion_action eventend || return 1
	i=0
	while [ "$i" -lt 5 ]; do
		sleep 1
		ct_motion_session_is_current "$motion_session" || return 1
		active="$(ct_motion_event_active_read 2>/dev/null || true)"
		active_session="$(printf '%s\n' "$active" | sed -n '1p')"
		active_id="$(printf '%s\n' "$active" | sed -n '2p')"
		[ "$active_session" = "$motion_session" ] || return 0
		i=$((i + 1))
	done
	ct_log "$source_type trigger: active Motion event did not close within 5s"
	return 1
}

# Return success while an accepted video event in the current Motion session
# still needs Motion to remain alive. movie-end creates finalize.lock only after
# Motion has closed the raw MP4, at which point the camera process may safely be
# stopped even while muxing or delivery continues in the callback process.
ct_media_event_active() {
	local generation motion_session pending pending_generation pending_session active active_generation active_session active_dir dir state_session
	generation="$(cat "$CT_BASE/generation" 2>/dev/null)"
	motion_session="$(ct_motion_session_read 2>/dev/null || true)"
	[ -n "$generation" ] && [ -n "$motion_session" ] || return 1
	ct_synthetic_active_current && return 0

	pending="$(ct_synthetic_pending_read 2>/dev/null || true)"
	pending_generation="$(printf '%s\n' "$pending" | sed -n '1p')"
	pending_session="$(printf '%s\n' "$pending" | sed -n '2p')"
	[ "$pending_generation" = "$generation" ] && [ "$pending_session" = "$motion_session" ] && return 0

	active="$(ct_audio_record_active_read 2>/dev/null || true)"
	active_generation="$(printf '%s\n' "$active" | sed -n '1p')"
	active_session="$(printf '%s\n' "$active" | sed -n '2p')"
	active_dir="$(printf '%s\n' "$active" | sed -n '3p')"
	if [ "$active_generation" = "$generation" ] && [ "$active_session" = "$motion_session" ] && [ -n "$active_dir" ]; then
		# Once movie-end owns finalize.lock the raw movie is already closed.
		[ -d "$active_dir/finalize.lock" ] || return 0
	fi

	[ -d "$CT_STATE/$generation" ] || return 1
	for dir in "$CT_STATE/$generation"/*; do
		[ -d "$dir" ] || continue
		[ -r "$dir/source" ] || continue
		state_session="$(ct_state_read "$dir" motion_session 2>/dev/null || true)"
		[ "$state_session" = "$motion_session" ] || continue
		[ -d "$dir/finalize.lock" ] && continue
		return 0
	done
	return 1
}

# Emergency cleanup is used only after the trusted-presence gate waited for an
# accepted movie to close and exceeded its bounded drain deadline. Only state
# owned by the current Motion session is abandoned; older finalized callbacks
# may still be finishing delivery in parallel.
ct_abandon_active_media() {
	local generation motion_session dir state_session
	generation="$(cat "$CT_BASE/generation" 2>/dev/null)"
	motion_session="$(ct_motion_session_read 2>/dev/null || true)"
	rm -f "$CT_BASE/synthetic-video-pending" "$CT_BASE/synthetic-video-active" "$CT_BASE/audio-record-active"
	rm -rf "$CT_BASE/audio-record-control.lock" "$CT_BASE/synthetic-video-bind.lock"

	[ -n "$generation" ] && [ -n "$motion_session" ] && [ -d "$CT_STATE/$generation" ] || return 0
	for dir in "$CT_STATE/$generation"/*; do
		[ -d "$dir" ] || continue
		[ -r "$dir/source" ] || continue
		state_session="$(ct_state_read "$dir" motion_session 2>/dev/null || true)"
		[ "$state_session" = "$motion_session" ] || continue
		mkdir "$dir/finalize.lock" 2>/dev/null || true
		rm -f "$dir/audio.pcm"
	done
}

ct_control_key() {
	case "$1" in
		video|motion) printf '%s\n' motion ;;
		audio) printf '%s\n' audio ;;
		timer) printf '%s\n' timer ;;
		mqtt) printf '%s\n' mqtt ;;
		*) return 1 ;;
	esac
}

ct_control_default() {
	local key value
	key="$(ct_control_key "$1")" || return 1
	case "$key" in
		motion) config_get_bool value main motion_enabled 1 ;;
		audio) config_get_bool value main audio_enabled 0 ;;
		timer) config_get_bool value main timer_enabled 0 ;;
		mqtt) config_get_bool value main mqtt_trigger_enabled 0 ;;
	esac
	[ "$value" -eq 1 ] 2>/dev/null && printf '1\n' || printf '0\n'
}

ct_control_write() {
	local key value tmp
	key="$(ct_control_key "$1")" || return 1
	case "$2" in
		1|on|true|yes|enable|enabled) value=1 ;;
		0|off|false|no|disable|disabled) value=0 ;;
		*) return 1 ;;
	esac
	mkdir -p "$CT_BASE/control" || return 1
	tmp="$CT_BASE/control/.${key}.tmp.$$"
	printf '%s\n' "$value" > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/control/$key"
}

ct_control_read() {
	local key value
	key="$(ct_control_key "$1")" || return 1
	if [ -r "$CT_BASE/control/$key" ]; then
		read -r value < "$CT_BASE/control/$key"
		case "$value" in 0|1) printf '%s\n' "$value"; return 0 ;; esac
	fi
	ct_control_default "$key"
}

ct_trigger_enabled() {
	[ "$(ct_control_read "$1" 2>/dev/null || printf '0\n')" = '1' ]
}

ct_control_init() {
	local key value
	mkdir -p "$CT_BASE/control" || return 1
	for key in motion audio timer mqtt; do
		value="$(ct_control_default "$key")" || value=0
		ct_control_write "$key" "$value" || return 1
	done
}

# Apply a single-line MQTT control payload. The protocol intentionally avoids
# JSON so it has no extra parser dependency on minimal OpenWrt images.
# Examples:
#   motion=1 audio=0 timer=1 mqtt=1
#   motion=off,timer=on,mqtt=off
#   all=off
ct_control_apply_payload() {
	local payload token key value normalized changed=0
	payload="${1:-}"
	[ -n "$payload" ] || return 1

	# Only the tiny command grammar is accepted. This also makes unquoted token
	# splitting below safe from shell glob / command syntax supplied over MQTT.
	case "$payload" in
		*[!A-Za-z0-9_=,[:space:].-]*) return 1 ;;
	esac

	payload="$(printf '%s' "$payload" | tr ',' ' ')"
	for token in $payload; do
		case "$token" in
			*=*) ;;
			*) continue ;;
		esac
		key="${token%%=*}"
		value="${token#*=}"
		case "$value" in
			1|on|true|yes|enable|enabled) normalized=1 ;;
			0|off|false|no|disable|disabled) normalized=0 ;;
			*) continue ;;
		esac
		case "$key" in
			motion|audio|timer|mqtt)
				ct_control_write "$key" "$normalized" && changed=1
				;;
			all)
				ct_control_write motion "$normalized" || return 1
				ct_control_write audio "$normalized" || return 1
				ct_control_write timer "$normalized" || return 1
				ct_control_write mqtt "$normalized" || return 1
				changed=1
				;;
		esac
	done
	[ "$changed" -eq 1 ]
}

ct_effective_holdoff() {
	local configured video_enabled video_max_time base
	config_get configured main holdoff ''
	config_get_bool video_enabled main video_enabled 0
	config_get video_max_time main video_max_time '15'

	if ct_is_uint "$configured" && [ "$configured" -gt 0 ]; then
		printf '%s\n' "$configured"
		return 0
	fi

	ct_is_uint "$video_max_time" || video_max_time=15
	base=0
	if [ "$video_enabled" -eq 1 ]; then
		base="$video_max_time"
	fi
	printf '%s\n' $((base + 2))
}

ct_reserve_event() {
	local now next holdoff
	mkdir -p "$CT_BASE" "$CT_RAW" "$CT_STATE"
	mkdir "$CT_BASE/reserve.lock" 2>/dev/null || return 1

	# A manually short holdoff must not let another source replace a synthetic
	# user-event owner while Motion is still recording it.
	if ct_synthetic_active_current; then
		rmdir "$CT_BASE/reserve.lock" 2>/dev/null || true
		return 1
	fi

	now="$(date +%s)"
	next=0
	[ -r "$CT_BASE/next_allowed" ] && read -r next < "$CT_BASE/next_allowed"
	ct_is_uint "$next" || next=0

	if [ "$now" -lt "$next" ]; then
		rmdir "$CT_BASE/reserve.lock" 2>/dev/null || true
		return 1
	fi

	holdoff="$(ct_effective_holdoff)"
	printf '%s\n' $((now + holdoff)) > "$CT_BASE/next_allowed"
	rmdir "$CT_BASE/reserve.lock" 2>/dev/null || true
	CT_TRIGGER_EPOCH="$now"
	CT_HOLDOFF="$holdoff"
	return 0
}

ct_json_escape() {
	printf '%s' "$1" | tr -d '\r\n' | sed \
		-e 's/\\/\\\\/g' \
		-e 's/"/\\"/g'
}

ct_event_dir() {
	local generation="$1" state_id="$2"
	case "$generation" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
	case "$state_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
	printf '%s/%s/%s\n' "$CT_STATE" "$generation" "$state_id"
}

ct_state_write() {
	local dir="$1" key="$2" value="$3" tmp
	case "$key" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
	mkdir -p "$dir" || return 1
	tmp="$dir/.${key}.tmp.$$"
	printf '%s\n' "$value" > "$tmp" || return 1
	mv -f "$tmp" "$dir/$key"
}

ct_state_read() {
	local dir="$1" key="$2"
	[ -r "$dir/$key" ] || return 1
	cat "$dir/$key"
}

ct_call_hook() {
	local hook_script="$1" source_type="$2" photo="$3" video="$4" trigger_epoch="$5" trigger_timestamp="$6"
	local send_photo send_video

	[ -n "$hook_script" ] || return 0
	case "$hook_script" in
		/*) ;;
		*) ct_log "hook script must be an absolute path: $hook_script"; return 1 ;;
	esac
	[ -x "$hook_script" ] || {
		ct_log "hook script is not executable: $hook_script"
		return 1
	}

	config_get_bool send_photo main send_photo 1
	config_get_bool send_video main video_enabled 0

	CAMERA_TRACER_SOURCE="$source_type" \
	CAMERA_TRACER_PHOTO="$photo" \
	CAMERA_TRACER_VIDEO="$video" \
	CAMERA_TRACER_SEND_PHOTO="$send_photo" \
	CAMERA_TRACER_SEND_VIDEO="$send_video" \
	CAMERA_TRACER_TRIGGER_EPOCH="$trigger_epoch" \
	CAMERA_TRACER_TRIGGER_TIMESTAMP="$trigger_timestamp" \
		"$hook_script" "$source_type" "$photo" "$video" "$trigger_epoch" "$trigger_timestamp"
}

ct_motion_action() {
	local action="$1"
	case "$action" in
		eventstart|eventend|snapshot) ;;
		*) return 2 ;;
	esac
	/bin/uclient-fetch -q -O /dev/null \
		"http://127.0.0.1:${CT_WEBCONTROL_PORT}/0/action/${action}" >/dev/null 2>&1
}

ct_synthetic_marker_write() {
	local kind="$1" generation="$2" motion_session="$3" event_dir="$4" event_id="${5:-}" tmp
	case "$kind" in pending|active) ;; *) return 1 ;; esac
	mkdir -p "$CT_BASE"
	tmp="$CT_BASE/.synthetic-video-${kind}.tmp.$$"
	{
		printf '%s\n' "$generation"
		printf '%s\n' "$motion_session"
		printf '%s\n' "$event_dir"
		printf '%s\n' "$event_id"
	} > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/synthetic-video-$kind"
}

ct_synthetic_marker_read() {
	local kind="$1" line=0 generation='' motion_session='' event_dir='' event_id='' value
	case "$kind" in pending|active) ;; *) return 1 ;; esac
	[ -r "$CT_BASE/synthetic-video-$kind" ] || return 1
	while IFS= read -r value; do
		line=$((line + 1))
		case "$line" in
			1) generation="$value" ;;
			2) motion_session="$value" ;;
			3) event_dir="$value" ;;
			4) event_id="$value"; break ;;
		esac
	done < "$CT_BASE/synthetic-video-$kind"
	[ -n "$generation" ] && [ -n "$motion_session" ] && [ -n "$event_dir" ] || return 1
	printf '%s\n%s\n%s\n' "$generation" "$motion_session" "$event_dir"
	[ -z "$event_id" ] || printf '%s\n' "$event_id"
	return 0
}

ct_synthetic_pending_write() {
	ct_synthetic_marker_write pending "$1" "$2" "$3"
}

ct_synthetic_pending_read() {
	ct_synthetic_marker_read pending
}

# Unlike the pending movie binding, this marker belongs to Motion's event_user
# latch. movie-end may delete the media directory at movie_max_time, but must
# never delete the ownership needed by the stop worker to reset event_user.
ct_synthetic_active_write() {
	ct_synthetic_marker_write active "$1" "$2" "$3" "${4:-}"
}

ct_synthetic_active_read() {
	ct_synthetic_marker_read active
}

ct_synthetic_active_owned() {
	local marker
	marker="$(ct_synthetic_active_read 2>/dev/null)" || return 1
	[ "$(printf '%s\n' "$marker" | sed -n '1p')" = "$1" ] &&
		[ "$(printf '%s\n' "$marker" | sed -n '2p')" = "$2" ] &&
		[ "$(printf '%s\n' "$marker" | sed -n '3p')" = "$3" ]
}

ct_synthetic_active_clear() {
	ct_synthetic_active_owned "$1" "$2" "$3" || return 0
	rm -f "$CT_BASE/synthetic-video-active"
}

ct_synthetic_active_current() {
	local marker generation motion_session
	marker="$(ct_synthetic_active_read 2>/dev/null)" || return 1
	generation="$(printf '%s\n' "$marker" | sed -n '1p')"
	motion_session="$(printf '%s\n' "$marker" | sed -n '2p')"
	[ "$generation" = "$(cat "$CT_BASE/generation" 2>/dev/null)" ] &&
		ct_motion_session_is_current "$motion_session"
}

ct_audio_record_active_write() {
	local generation="$1" motion_session="$2" event_dir="$3" tmp
	mkdir -p "$CT_BASE"
	tmp="$CT_BASE/.audio-record-active.tmp.$$"
	{
		printf '%s\n' "$generation"
		printf '%s\n' "$motion_session"
		printf '%s\n' "$event_dir"
	} > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/audio-record-active"
}

ct_audio_record_active_read() {
	local line=0 generation='' motion_session='' event_dir=''
	[ -r "$CT_BASE/audio-record-active" ] || return 1
	while IFS= read -r value; do
		line=$((line + 1))
		case "$line" in
			1) generation="$value" ;;
			2) motion_session="$value" ;;
			3) event_dir="$value"; break ;;
		esac
	done < "$CT_BASE/audio-record-active"
	[ -n "$generation" ] && [ -n "$motion_session" ] && [ -n "$event_dir" ] || return 1
	printf '%s\n%s\n%s\n' "$generation" "$motion_session" "$event_dir"
}

ct_audio_record_start() {
	local generation="$1" motion_session="$2" event_dir="$3" lock rc
	[ -n "$generation" ] && [ -n "$motion_session" ] && [ -n "$event_dir" ] || return 1
	case "$event_dir" in "$CT_STATE/$generation/"*) ;; *) return 1 ;; esac
	mkdir -p "$event_dir" || return 1
	lock="$CT_BASE/audio-record-control.lock"
	mkdir "$lock" 2>/dev/null || return 1
	rm -f "$event_dir/audio.pcm"
	ct_audio_record_active_write "$generation" "$motion_session" "$event_dir"
	rc=$?
	rmdir "$lock" 2>/dev/null || true
	return "$rc"
}

ct_audio_record_stop() {
	local event_dir="$1" lock active active_dir
	[ -n "$event_dir" ] || return 0
	lock="$CT_BASE/audio-record-control.lock"
	mkdir "$lock" 2>/dev/null || return 0
	active="$(ct_audio_record_active_read 2>/dev/null || true)"
	active_dir="$(printf '%s\n' "$active" | sed -n '3p')"
	if [ "$active_dir" = "$event_dir" ]; then
		rm -f "$CT_BASE/audio-record-active"
	fi
	rmdir "$lock" 2>/dev/null || true
	return 0
}
