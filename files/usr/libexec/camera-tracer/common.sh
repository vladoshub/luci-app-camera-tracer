#!/bin/sh

. /lib/functions.sh

CT_BASE=/tmp/camera_tracer
CT_RAW="$CT_BASE/raw"
CT_STATE="$CT_BASE/state"
CT_WEBCONTROL_PORT=8799

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

ct_wifi_mac_present() {
	local want iface path
	want="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
	[ -n "$want" ] || return 1

	for path in /sys/class/net/*; do
		[ -e "$path" ] || continue
		iface="${path##*/}"
		if iwinfo "$iface" assoclist 2>/dev/null | awk -v want="$want" '
			/^[0-9A-Fa-f][0-9A-Fa-f]:/ {
				mac = tolower($1)
				if (mac == want) found = 1
			}
			END { exit(found ? 0 : 1) }'; then
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

ct_effective_holdoff() {
	local configured trusted_timeout trusted_count video_enabled video_max_time base
	config_get configured main holdoff ''
	config_get trusted_timeout main trusted_timeout '5'
	config_get_bool video_enabled main video_enabled 0
	config_get video_max_time main video_max_time '15'
	trusted_count="$(ct_trusted_count)"

	if ct_is_uint "$configured" && [ "$configured" -gt 0 ]; then
		printf '%s\n' "$configured"
		return 0
	fi

	ct_is_uint "$trusted_timeout" || trusted_timeout=5
	ct_is_uint "$video_max_time" || video_max_time=15
	base=0
	if [ "$trusted_count" -gt 0 ]; then
		base="$trusted_timeout"
	fi
	if [ "$video_enabled" -eq 1 ] && [ "$video_max_time" -gt "$base" ]; then
		base="$video_max_time"
	fi
	printf '%s\n' $((base + 2))
}

ct_reserve_event() {
	local now next holdoff
	mkdir -p "$CT_BASE" "$CT_RAW" "$CT_STATE"
	mkdir "$CT_BASE/reserve.lock" 2>/dev/null || return 1

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
	local generation="$1" event_id="$2"
	case "$generation" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
	ct_is_uint "$event_id" || return 1
	printf '%s/%s/%s\n' "$CT_STATE" "$generation" "$event_id"
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

ct_audio_pending_write() {
	local generation="$1" event_dir="$2" tmp
	mkdir -p "$CT_BASE"
	tmp="$CT_BASE/.audio-video-pending.tmp.$$"
	{
		printf '%s\n' "$generation"
		printf '%s\n' "$event_dir"
	} > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/audio-video-pending"
}

ct_audio_pending_read() {
	local line=0 generation='' event_dir=''
	[ -r "$CT_BASE/audio-video-pending" ] || return 1
	while IFS= read -r value; do
		line=$((line + 1))
		case "$line" in
			1) generation="$value" ;;
			2) event_dir="$value"; break ;;
		esac
	done < "$CT_BASE/audio-video-pending"
	[ -n "$generation" ] && [ -n "$event_dir" ] || return 1
	printf '%s\n%s\n' "$generation" "$event_dir"
}

ct_audio_record_active_write() {
	local generation="$1" event_dir="$2" tmp
	mkdir -p "$CT_BASE"
	tmp="$CT_BASE/.audio-record-active.tmp.$$"
	{
		printf '%s\n' "$generation"
		printf '%s\n' "$event_dir"
	} > "$tmp" || return 1
	mv -f "$tmp" "$CT_BASE/audio-record-active"
}

ct_audio_record_active_read() {
	local line=0 generation='' event_dir=''
	[ -r "$CT_BASE/audio-record-active" ] || return 1
	while IFS= read -r value; do
		line=$((line + 1))
		case "$line" in
			1) generation="$value" ;;
			2) event_dir="$value"; break ;;
		esac
	done < "$CT_BASE/audio-record-active"
	[ -n "$generation" ] && [ -n "$event_dir" ] || return 1
	printf '%s\n%s\n' "$generation" "$event_dir"
}

ct_audio_record_start() {
	local generation="$1" event_dir="$2" lock rc
	[ -n "$generation" ] && [ -n "$event_dir" ] || return 1
	case "$event_dir" in "$CT_STATE/$generation/"*) ;; *) return 1 ;; esac
	mkdir -p "$event_dir" || return 1
	lock="$CT_BASE/audio-record-control.lock"
	mkdir "$lock" 2>/dev/null || return 1
	rm -f "$event_dir/audio.pcm"
	ct_audio_record_active_write "$generation" "$event_dir"
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
	active_dir="$(printf '%s\n' "$active" | sed -n '2p')"
	if [ "$active_dir" = "$event_dir" ]; then
		rm -f "$CT_BASE/audio-record-active"
	fi
	rmdir "$lock" 2>/dev/null || true
	return 0
}
