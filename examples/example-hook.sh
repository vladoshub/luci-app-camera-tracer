#!/bin/sh
# Example Camera Tracer hook: upload accepted media to a fictional HTTP endpoint.
# Requires: curl
# The .invalid TLD is reserved for examples and will not resolve in normal use.
# Copy this file to your own hook path and adapt the endpoint/protocol as needed.

set -eu

CONF='/etc/camera-tracer-hook.conf'
[ -r "$CONF" ] || {
	logger -t camera-tracer-hook "missing $CONF"
	exit 1
}
. "$CONF"

: "${ENDPOINT:?ENDPOINT is required}"
: "${API_TOKEN:?API_TOKEN is required}"

command -v curl >/dev/null 2>&1 || {
	logger -t camera-tracer-hook "curl is not installed"
	exit 127
}

source_type="${1:-unknown}"
photo="${2:-}"
video="${3:-}"
trigger_epoch="${4:-}"
trigger_timestamp="${5:-}"

curl_common() {
	curl --http1.1 --fail --silent --show-error \
		--connect-timeout 10 --max-time 120 --retry 2 "$@"
}

set -- \
	-H "Authorization: Bearer $API_TOKEN" \
	--form-string "source=$source_type" \
	--form-string "trigger_epoch=$trigger_epoch" \
	--form-string "trigger_timestamp=$trigger_timestamp"

if [ "${CAMERA_TRACER_SEND_PHOTO:-1}" = '1' ] && [ -n "$photo" ] && [ -f "$photo" ]; then
	set -- "$@" -F "photo=@$photo;type=image/jpeg"
fi

if [ "${CAMERA_TRACER_SEND_VIDEO:-0}" = '1' ] && [ -n "$video" ] && [ -f "$video" ]; then
	set -- "$@" -F "video=@$video;type=video/mp4"
fi

curl_common "$@" "$ENDPOINT" >/dev/null
exit 0
