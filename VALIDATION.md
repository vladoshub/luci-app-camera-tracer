# Validation report

Validation date: 2026-09-26
Version: 0.6.8-r2

## Passed locally

`./tests/static-check.sh` passes:

- shell syntax with the host `/bin/sh`;
- shell syntax with BusyBox `ash`;
- generic HTTP example hook shell syntax and forced HTTP/1.1 upload mode;
- LuCI menu and rpcd ACL JSON parsing;
- LuCI JavaScript syntax with Node.js;
- LuCI/UCI/runtime wiring for configurable Motion `minimum_motion_frames` (default 2, range 1..30);
- visual-motion retrigger wiring through `on_motion_detected` plus the lightweight holdoff-aware `motion-trigger` dispatcher;
- per-Motion-process session ids carried through event/movie callbacks so event-id reuse after trusted-device pause/resume cannot collide with prior state;
- session-scoped visual state and synthetic event-id mappings, including generation/session validation for pending video and microphone-recording markers;
- synthetic timer/audio/MQTT event-boundary helper behavior: an already-open Motion event is ended and observed idle before a fresh synthetic `eventstart`;
- bounded synthetic stop ownership: `eventend` is issued only for the Motion event id actually bound to that synthetic alarm;
- verification that `picture_output first` / `on_picture_save` are no longer used as the visual alarm source and that accepted visual alarms request a fresh Motion snapshot;
- helper behavior for safe JPEG/MP4 names, JSON escaping and automatic holdoff;
- automatic holdoff based only on video duration (or 2 seconds without video);
- trusted-IP MAC resolution, including static-DHCP precedence over a conflicting active lease;
- trusted-camera pause-state helper roundtrip and supervisor/pre-trigger-gate wiring;
- drain-state detection for accepted media, finalize-lock handoff, forced-abandon cleanup, and microphone marker cleanup without trusted-event decisions;
- bounded `iwinfo assoclist` helper behavior, including a simulated slow query watchdog;
- verification that no post-trigger trusted-device timeout/check remains in accepted-event, movie-finalization, synthetic-finalization, MQTT or hook delivery paths;
- synthetic-trigger pending-state roundtrip used to bind audio/timer/MQTT webcontrol-started Motion events to the accepted alarm;
- runtime motion/audio/timer/MQTT-message enable-state initialization and MQTT control payload parsing;
- always-on timer worker path, runtime enable/disable state, and shared event holdoff path;
- MQTT-message trigger subscriber path into the shared synthetic event pipeline;
- immediate rejection of a second trigger while the global holdoff is active;
- microphone-recording state marker start/read/stop behavior and path guard;
- verification that ALSA/USB-audio/ffmpeg CLI did not become hard package dependencies;
- audio quiet re-arm mode toggle wiring: default enabled, LuCI checkbox/dependencies, runtime flag, no-release detector branch, and lightweight global-holdoff fast path;
- DHCP selector output and IP deduplication;
- OpenWrt-like package install staging, including movie-start/movie-end, the bounded synthetic-video stop worker, timer worker, MQTT trigger subscriber, MQTT control subscriber, audio capture worker, and generic HTTP hook examples.

Expected result:

```text
PASS: shell syntax
PASS: menu/ACL JSON
PASS: LuCI JavaScript syntax
PASS: minimum motion frames setting
PASS: visual motion retrigger path
PASS: Motion session namespace
PASS: common.sh helper behavior
PASS: trusted MAC resolution
PASS: trusted camera pause state
PASS: trusted camera pause gate
PASS: trusted media drain state
PASS: no post-trigger trusted decision
PASS: iwinfo watchdog
PASS: synthetic pending state
PASS: synthetic Motion event boundary
PASS: MQTT trigger control state
PASS: timer trigger path
PASS: synthetic trigger webcontrol
PASS: MQTT message trigger path
PASS: trigger holdoff drop
PASS: audio recording state
PASS: optional audio dependencies
PASS: audio AC-RMS/DC rejection
PASS: audio quiet re-arm mode toggle
PASS: DHCP selector helper
PASS: package install staging
PASS: example hook HTTP/1.1
ALL_STATIC_TESTS_OK
```

## Media-path checks performed locally

The BusyBox `hexdump` format generated for the default 16 kHz / mono / S16_LE
50 ms analysis window was tested with 800 signed 16-bit samples and produced the
expected 800 numeric samples.

The exact ffmpeg mux pattern used by `movie-end` was also exercised against a
synthetic MPEG-4 Part 2 MP4 plus raw 16 kHz mono S16_LE PCM:

```text
input video:  mpeg4
input audio:  s16le / 16000 Hz / mono
output video: mpeg4 (stream copy)
output audio: aac / 16000 Hz / mono
```

The produced MP4 contained both a video stream and an AAC audio stream.

## Motion behavior used

The implementation relies on these Motion mechanisms already used by Camera
Tracer:

- `movie_output` for FFmpeg movie generation;
- `movie_codec mp4:mpeg4` for a broadly buildable MP4/MPEG-4 path on OpenWrt;
- `movie_max_time` for the per-segment duration limit;
- `pre_capture` and `post_capture`;
- configurable `minimum_motion_frames` for visual trigger persistence;
- `on_motion_detected ... %v` for visual alarm opportunities even while one Motion event stays open;
- localhost `action/snapshot` only after Camera Tracer accepts the visual trigger through its shared holdoff;
- `on_movie_start ... %f %v` and `on_movie_end ... %f %v` to bind/finalize the completed movie;
- always-available localhost-only webcontrol `action/eventstart`, `action/eventend`, and `action/snapshot` for making audio-threshold, timer and MQTT-message triggers enter the same JPEG/MP4 event pipeline, including triggers enabled at runtime.

## Not performed in this environment

A full target package build (`make package/luci-app-camera-tracer/compile V=s`)
was not performed here because a matching OpenWrt source tree/SDK is not
available in the execution container. Static package staging is not a substitute
for the user's real OpenWrt build.

## Hardware validation still required

The following require the actual BPI-R3 Mini and camera/microphone:

- simultaneous UVC video and UAC/ALSA audio capture from the specific camera;
- `arecord` behavior at the selected sample rate on the exact USB microphone;
- availability of the AAC encoder in the router's installed `ffmpeg` CLI build;
- sustained CPU load while Motion encodes video and ffmpeg performs the final stream-copy/AAC mux;
- real A/V sync, especially with non-zero Motion pre-capture;
- actual MP4 sizes and the post-mux size limit;
- MQTT broker maximum-packet configuration for binary MP4 payloads;
- MQTT control/trigger subscription and reconnect behavior against the user's broker, including retained messages if used;
- timer cadence/holdoff behavior under real Motion load;
- trusted-presence camera gate transitions on real Wi-Fi association changes, including UVC close/reopen behavior, active-recording drain behavior, forced-drain fallback, and the configured polling delay;
- real external-hook delivery through the user's WAN connection and chosen receiver;
- USB microphone kernel module matching the running firmware ABI.

## 0.6.3 trusted-presence validation

- Trusted-presence polling uses `trusted_check_interval_seconds`.
- LuCI constrains the value to 5..3600 seconds and defaults to 10 seconds.
- The supervisor clamps runtime values to the same range and accepts the legacy 0.6.0/0.6.1 minute setting as a backward-compatible fallback.
- `process-event`, `movie-end` and `synthetic-video-stop` do not query trusted Wi-Fi presence and do not wait for a trusted-device decision.
- The default config and LuCI page no longer expose `trusted_timeout`; a stale value in an upgraded UCI conffile has no runtime effect.
- The presence supervisor remains drain-safe: it blocks new event entry through the camera-paused state, lets an already accepted movie close, then stops Motion/opens it again when presence changes.
