# Changelog

## 0.6.8-r3 - 2026-09-29

- Added a fail-safe `eventend` for synthetic timer/audio/MQTT video requests that were accepted by Motion webcontrol but never reached `on_movie_start` binding.
- This prevents Motion's webcontrol user-event state from remaining latched after a failed synthetic movie start and repeatedly feeding `on_motion_detected` callbacks after the normal Camera Tracer holdoff expires.
- The normal bound-event path remains ownership-safe: a successfully bound synthetic clip still ends only its own Motion event id; the fail-safe is used only while the exact generation/session/event pending marker is still unconsumed.
- Added static regression coverage for the unbound-synthetic fail-safe path.

## 0.6.8 - 2026-09-26

- Repository examples are now service-neutral: the bundled shell hook targets a reserved `.invalid` HTTP endpoint and contains no vendor-specific integration.

- Fixed timer/audio/MQTT synthetic MP4 failures after trusted-device camera resume by giving every Motion process a unique runtime session id; Motion event ids can restart from 1 without colliding with state or map files from an earlier Motion instance.
- Added session ids to Motion event/movie callbacks and synthetic pending/audio-record state so late callbacks from a previous Motion process cannot bind to a resumed camera session.
- Synthetic video triggers now explicitly close an already-open Motion event and wait for its `on_event_end` marker before requesting a fresh `eventstart`. This guarantees that timer/audio/MQTT alarms do not depend on Motion being idle when the trigger arrives.
- Added `on_event_start` / `on_event_end` runtime markers used only for Motion event lifecycle coordination; trusted-device presence is still checked exclusively by the camera supervisor.
- `synthetic-video-stop` now ends only the Motion event actually bound to that synthetic alarm instead of issuing an unconditional `eventend`, preventing it from terminating an unrelated later event.
- Added static/helper coverage for Motion-session isolation and fresh synthetic-event boundaries.

## 0.6.7 - 2026-09-22

- Added **Require quiet re-arm after audio trigger** in LuCI (`audio_rearm_enabled`, default enabled).
- With quiet re-arm enabled, the existing `release level = threshold - hysteresis` plus quiet-time behavior is unchanged.
- With quiet re-arm disabled, the detector does not wait for the level to fall below a release threshold; sustained audio above the configured threshold keeps offering new audio triggers, while the shared Camera Tracer holdoff remains the authoritative rate limiter across all trigger sources.
- Hysteresis and quiet re-arm time fields are hidden in LuCI while quiet re-arm is disabled.
- Added a lightweight `audio-trigger` holdoff fast path so sustained loud audio does not repeatedly enter the heavier event/UCI pipeline while the global holdoff is active.

## 0.6.6 - 2026-09-22

- Fixed visual-motion alarms going quiet while Motion kept one long event open: visual triggering now uses `on_motion_detected` instead of relying on `picture_output first` / `on_picture_save`.
- A fresh JPEG snapshot is requested only after the shared Camera Tracer holdoff accepts a visual trigger, so continuous motion can retrigger after holdoff without creating JPEGs for rejected frames.
- Added a lightweight `motion-trigger` dispatcher that checks the tmpfs runtime motion state, trusted camera-pause state and `next_allowed` timestamp before entering the heavier event pipeline; simultaneous high-FPS callbacks are coalesced with a short-lived lock.
- Kept Motion's own event/video recording behavior intact. With the default automatic holdoff (`video_max_time + 2`), a long Motion event can produce another Camera Tracer alarm on a later Motion movie segment.
- Audio threshold detection is unchanged and remains independent of Motion `event_gap`; its own hysteresis/quiet re-arm and the shared global holdoff still apply.

## 0.6.5 - 2026-09-22

- Forced the bundled HTTP multipart example hook to use HTTP/1.1 for media uploads.
- Avoids HTTP/2 multipart upload hangs / stream resets observed on some WAN paths while keeping the existing timeout and retry behavior.

## 0.6.4 - 2026-09-22

- Exposed Motion `minimum_motion_frames` in LuCI.
- Added the `minimum_motion_frames` UCI option with default `2` and allowed range `1..30`.
- `run-motion` now validates the value, writes it into the generated Motion configuration, and includes it in the startup log.

## 0.6.3 - 2026-09-22

- Removed the post-trigger trusted-device timeout/check from accepted-event processing.
- Trusted devices now affect only the optional camera-capture gate: the supervisor starts/stops Motion and the UVC stream based on Wi-Fi presence.
- MQTT and local-hook delivery no longer wait for or re-check trusted-device presence.
- Removed the `trusted_timeout` LuCI/default-config option; legacy UCI values are ignored if still present after an upgrade.
- Simplified automatic holdoff to 2 seconds without video, or `video_max_time + 2` seconds with video enabled.
- Preserved drain-safe camera shutdown: an already accepted MP4 is allowed to close before Motion is stopped; forced cleanup still prevents half-written media from being published.

## 0.6.2 - 2026-09-19

- Changed the optional trusted-presence camera-gate polling interval from minutes to seconds.
- New default is 10 seconds; allowed range is 5..3600 seconds.
- Preserved 0.6.0/0.6.1 configurations by converting the legacy minute value to the equivalent seconds value until the LuCI page is saved.
- Kept the existing post-trigger trusted-device check unchanged.

## 0.6.1 - 2026-09-19

- Made trusted-presence camera pausing drain-safe: detecting a trusted client blocks new triggers immediately but no longer stops Motion in the middle of an accepted MP4 event.
- Added a bounded media-drain deadline before camera shutdown. If an event cannot close in time, Camera Tracer suppresses/abandons unfinished media and clears microphone recording state before forcing Motion down.
- Added protection against an indefinitely growing `audio.pcm` after a forced Motion termination.
- Avoided an indefinite supervisor wait after `SIGKILL`; a driver-stuck Motion task is logged and the gate remains responsive.
- Added a bounded `iwinfo assoclist` watchdog (3 seconds per interface by default) so a wedged Wi-Fi query cannot freeze trusted-presence polling.
- Preserved the existing post-trigger trusted-device timeout/check in `process-event` unchanged.

## 0.6.0 - 2026-09-19

- Added an optional trusted-presence camera gate. When enabled, Camera Tracer checks trusted Wi-Fi presence before opening the camera and periodically afterwards.
- Added a configurable trusted-presence polling interval in minutes (default 5).
- While any trusted client is present, Motion is stopped and the UVC camera is closed, so frames are not read or processed.
- When all trusted clients disappear, the original Motion camera pipeline is started again unchanged.
- Added a shared pre-trigger pause state so timer/audio/MQTT requests do not enter the alarm/media pipeline while camera capture is intentionally paused.
- Preserved the existing post-trigger trusted-device timeout/check unchanged as a second suppression layer for races between presence polls.
- Kept the feature disabled by default and made it a no-op when no trusted IPs are configured.

## 0.5.2 - 2026-09-17

- Fixed false audio alarms caused by USB microphone DC offset by measuring AC RMS (window mean removed) instead of raw RMS.
- Added audio trigger re-arm hysteresis and a configurable quiet re-arm interval so steady noise cannot repeatedly retrigger after holdoff.
- Added a log entry with measured dBFS whenever the audio threshold is crossed.
- Added LuCI controls for audio re-arm hysteresis and quiet re-arm time.

## 0.5.1 - 2026-09-17

- Fixed timer reliability after package upgrades / runtime setting changes by keeping the lightweight timer worker alive whenever Camera Tracer is enabled.
- Fixed standalone MQTT-message triggering: Motion localhost webcontrol is now always available while Camera Tracer runs, rather than only when audio/timer/control happened to enable it at service start.
- Kept Motion webcontrol localhost-only. No LAN/WAN control endpoint is exposed.

All notable changes to Camera Tracer are documented here.

## 0.5.0 - 2026-09-17

- Added an optional MQTT-message alarm source with its own enable checkbox and configurable trigger topic.
- Every received message on the trigger topic enters the same photo/video/audio, trusted-device timeout, MQTT publication and local-hook pipeline as motion/audio/timer.
- MQTT-message trigger requests share the global holdoff; messages arriving while an accepted event is locked are dropped rather than queued.
- Extended runtime MQTT trigger control with `mqtt=on/off` and included the new source in `all=on/off`.
- Added a dedicated procd MQTT trigger subscriber worker and static validation for the new source.

## 0.4.0 - 2026-09-17

- Added a periodic timer trigger with a configurable 1-86400 second interval.
- Timer alarms use the same JPEG, trusted-device delay, bounded video/audio,
  MQTT and hook pipeline as motion/audio alarms.
- Timer ticks that occur while the global trigger holdoff is active are dropped
  instead of queued, including when the timer interval is shorter than holdoff.
- Added a dedicated visual-motion trigger enable checkbox.
- Added optional MQTT runtime control for motion, audio and timer trigger enable
  states through one configurable topic.
- MQTT control is runtime-only under `/tmp` and does not write UCI/flash;
  restart/reload restores the LuCI checkbox defaults.
- MQTT control can enable an already configured audio trigger without restarting
  Camera Tracer; the audio worker remains available when needed.
- Generalized the synthetic Motion webcontrol path so audio and timer triggers
  share the same bounded video-event binding/finalization logic.
- Made GitHub Actions/static checks tolerant of lost executable bits by invoking
  the test script/helper through an explicit shell where appropriate.

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
- Added video delivery support to the bundled HTTP hook example.

## 0.1.0 - 2026-09-13

- Initial LuCI application.
- UVC/Motion visual trigger.
- Trusted Wi-Fi client suppression.
- JPEG capture, MQTT delivery and local alarm hook.
- Optional audio-threshold monitoring.
