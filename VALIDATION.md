# Validation report

Validation date: 2026-09-13
Version: 0.3.0-r1

## Passed locally

`./tests/static-check.sh` passes:

- shell syntax with the host `/bin/sh`;
- shell syntax with BusyBox `ash`;
- LuCI menu and rpcd ACL JSON parsing;
- LuCI JavaScript syntax with Node.js;
- helper behavior for safe JPEG/MP4 names, JSON escaping and automatic holdoff;
- automatic holdoff with trusted-device and video-duration limits;
- trusted-IP MAC resolution, including static-DHCP precedence over a conflicting active lease;
- audio-trigger pending-state roundtrip used to bind webcontrol-started Motion events to the accepted alarm;
- microphone-recording state marker start/read/stop behavior and path guard;
- verification that ALSA/USB-audio/ffmpeg CLI did not become hard package dependencies;
- DHCP selector output and IP deduplication;
- OpenWrt-like package install staging, including movie-start/movie-end, the bounded audio-video stop worker, audio capture worker, and sh examples.

Expected result:

```text
PASS: shell syntax
PASS: menu/ACL JSON
PASS: LuCI JavaScript syntax
PASS: common.sh helper behavior
PASS: trusted MAC resolution
PASS: audio pending state
PASS: audio recording state
PASS: optional audio dependencies
PASS: DHCP selector helper
PASS: package install staging
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
- `on_movie_start ... %f %v` and `on_movie_end ... %f %v` to bind/finalize the completed movie;
- localhost-only webcontrol `action/eventstart`, `action/eventend`, and `action/snapshot` for making an audio threshold crossing enter the same JPEG/MP4 event pipeline.

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
- USB microphone kernel module matching the running firmware ABI.
