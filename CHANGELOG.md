# Changelog

All notable changes to Camera Tracer are documented here.

## 0.3.0 - 2026-09-13

- Added optional microphone audio track in MP4 clips.
- Added shared ALSA sample-rate selection.
- Added configurable AAC bitrate.
- Reworked the audio worker so audio trigger and MP4 audio can share a single
  ALSA capture stream.
- Added per-event PCM state and final FFmpeg stream-copy/AAC muxing.
- Preserved the video-only MP4 when optional audio capture/muxing fails.
- Re-checks the configured maximum video size after audio muxing.

## 0.2.2 - 2026-09-13

- Replaced the hard dependency on the BusyBox `od` applet with `hexdump`, with
  `od` as a fallback.
- Changed Motion movie output from `mp4` (H.264 request) to `mp4:mpeg4` so
  minimal OpenWrt FFmpeg builds do not require libx264.

## 0.2.1 - 2026-09-13

- Made audio-threshold alarms use the same JPEG/video/MQTT/hook pipeline as
  visual-motion alarms.
- Added bounded audio-triggered Motion events through localhost webcontrol.

## 0.2.0 - 2026-09-13

- Added bounded MP4 recording and binary MP4 MQTT delivery.
- Added pre-capture, post-capture, quality, duration and size limits.

## 0.1.0 - 2026-09-13

- Initial LuCI application.
- UVC/Motion visual trigger.
- Trusted Wi-Fi client suppression.
- JPEG capture, MQTT delivery and local alarm hook.
- Optional audio-threshold monitoring.
