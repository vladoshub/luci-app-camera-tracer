# luci-app-camera-tracer

Camera Tracer is a LuCI application for OpenWrt that turns a UVC camera into a
small motion/audio/timer/MQTT-message alarm sensor. It uses Motion for visual
detection and bounded MP4 recording, can optionally use an ALSA microphone as an
alarm source and/or record microphone audio into the clip, can trigger
periodically from a timer or by receiving a message on a dedicated MQTT topic,
can optionally stop camera capture while trusted Wi-Fi clients are present,
and can deliver accepted events through MQTT or a local executable hook.
Trusted-device presence is used only for the optional camera-capture gate and is
not re-checked during event delivery. Trigger sources can also
be enabled or disabled at runtime from one MQTT control topic.

The project was developed for OpenWrt 25.12.x on the Banana Pi BPI-R3 Mini, but
it is not target-specific. Other OpenWrt devices can use it when the required
kernel/userspace packages are available and the router has enough CPU/RAM for
video encoding.

## Features

- LuCI configuration page under **Services -> Camera Tracer**.
- Select a V4L2/UVC camera from detected `/dev/video*` capture devices.
- Visual motion detection through Motion, with its own enable/disable switch.
- Optional audio-threshold trigger through ALSA.
- Optional periodic timer trigger with a configurable interval in seconds.
- Optional MQTT-message trigger on a configurable topic; any received message is
  one trigger request.
- Motion, audio, timer and MQTT-message triggers enter the same alarm pipeline
  and share the same global holdoff.
- Immediate JPEG capture to `/tmp/camera_tracer/`.
- Optional bounded MP4 recording to `/tmp/camera_tracer/`.
- Optional microphone track muxed into the final MP4 as AAC.
- Trusted-device presence using DHCP IP -> MAC resolution plus the current
  Wi-Fi association list.
- Optional trusted-presence camera gate: stop Motion/close the UVC camera while
  any trusted client is present, then resume when all trusted clients disappear.
- Configurable trusted-presence polling interval (seconds) and trigger holdoff.
- Raw JPEG/MP4 publication over MQTT plus a JSON event topic.
- Optional MQTT runtime control for motion/audio/timer/MQTT-message trigger enable states.
- Optional executable alarm hook.
- Included generic HTTP multipart hook example using a deliberately non-resolving `.invalid` endpoint.
- Runtime media stays in `/tmp` and therefore does not continuously write to
  flash storage.

## Alarm flow

```text
trusted Wi-Fi presence ----> camera capture enabled / paused
                                      |
                                      v
visual motion ------------------\
sound threshold -----------------+--> accepted alarm
periodic timer ------------------+         |
MQTT trigger message -------------/         |
                                          +--> save JPEG immediately
                                          +--> publish JPEG/event MQTT immediately
                                          +--> optionally record MP4
                                                  + optional microphone audio
                                                  + MP4 MQTT/hook after close
```

Trusted-device presence is checked only by the camera supervisor. It is not
queried again after an alarm is accepted and does not delay MQTT or hook
delivery. Timer ticks and MQTT-message trigger requests are never queued: if the
shared trigger holdoff is still active, the request is discarded. This is also
what happens when the configured timer interval is shorter than the effective
holdoff.

## Trusted-presence camera gate

Enable **Pause camera while a trusted device is present** to add a coarse
pre-trigger presence gate. Camera Tracer performs an immediate trusted-device
check when the service starts, then repeats it at **Trusted presence check
interval (seconds)** (default 10 seconds, minimum 5 seconds).

When at least one configured trusted client is currently associated to Wi-Fi,
Camera Tracer stops Motion. That closes the UVC camera device, so frames are not
read or processed while the gate is paused. Timer/audio/MQTT trigger requests
are rejected at the shared event entry point while paused and therefore do not
start the JPEG/video alarm pipeline. When all trusted clients disappear, Motion
is started again and the existing camera pipeline resumes unchanged.

This gate is the only trusted-device presence mechanism. A join/leave can take
up to one polling interval to be noticed. Once an alarm has been accepted, it is
not suppressed later because a trusted device appears, and MQTT/hook delivery
does not perform another Wi-Fi association query.

Each Motion process also receives a unique runtime session id. Motion restarts its
internal event numbering from 1 when camera capture resumes, so Camera Tracer
includes the session id in visual/synthetic media state and callback mappings.
This prevents event `1`, `2`, etc. from a resumed camera from colliding with
state left by the previous Motion process.

If the trusted-IP list is empty, enabling the camera gate is a no-op and camera
capture remains active.

The polling interval is stored in seconds in 0.6.2 and later. The allowed range is
5..3600 seconds and the default is 10 seconds. When upgrading from 0.6.0/0.6.1,
the legacy minute value is converted to the equivalent number of seconds at
runtime; saving the LuCI page writes the new seconds option.

## Required OpenWrt packages

The package declares these mandatory dependencies:

- `luci-base`
- `motion-ffmpeg`
- `v4l-utils`
- `iwinfo`
- `mosquitto-client-ssl`
- `ca-bundle`
- `uclient-fetch`
- `kmod-video-uvc`

Audio support is intentionally optional and is **not** a hard dependency. This
is important for `kmod-usb-audio`, because OpenWrt kernel modules must match the
running firmware ABI.

For audio trigger and/or microphone recording install/build the matching audio
runtime:

- `kmod-usb-audio`
- `alsa-utils` (`arecord`)
- `alsa-ucm-conf` when required by your audio setup

To mux microphone audio into MP4, also provide:

- `ffmpeg` CLI with an AAC encoder

The alarm still falls back to the video-only MP4 if optional audio muxing fails.

## Build from a full OpenWrt source tree

### 1. Prepare OpenWrt

Use the OpenWrt branch/tag/commit for the firmware you intend to run. This is
especially important if you enable `kmod-usb-audio`.

```sh
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt

# Example: use the branch/tag you actually build for your router.
# git checkout openwrt-25.12

./scripts/feeds update -a
./scripts/feeds install -a
```

Configure your target in the normal OpenWrt way, for example with:

```sh
make menuconfig
```

### 2. Add Camera Tracer to the tree

Clone this repository into `package/`:

```sh
git clone https://github.com/<your-github-user>/luci-app-camera-tracer.git \
  package/luci-app-camera-tracer
```

If you copied the source manually, the layout must look like this:

```text
openwrt/
├── package/
│   └── luci-app-camera-tracer/
│       ├── Makefile
│       ├── files/
│       ├── examples/
│       └── tests/
├── feeds/
├── target/
└── .config
```

Refresh package configuration:

```sh
make defconfig
```

### 3. Select the package

Run:

```sh
make menuconfig
```

Navigate to:

```text
LuCI
  -> Applications
     -> luci-app-camera-tracer
```

Use `M` if you only want a separately installable package, or `*` if Camera
Tracer must be included directly in the firmware image.

Equivalent `.config` values are:

```text
CONFIG_PACKAGE_luci-app-camera-tracer=m   # package only
CONFIG_PACKAGE_luci-app-camera-tracer=y   # included in firmware
```

If you want audio features built into the image as well, also select the audio
packages for the same firmware build, for example:

```text
CONFIG_PACKAGE_alsa-utils=y
CONFIG_PACKAGE_alsa-ucm-conf=y
CONFIG_PACKAGE_kmod-usb-audio=y
CONFIG_PACKAGE_ffmpeg=y
```

### 4. Build only Camera Tracer

```sh
make package/luci-app-camera-tracer/clean
make package/luci-app-camera-tracer/compile V=s
```

On OpenWrt 25.12+ the result is an `.apk`. Locate it with:

```sh
find bin/packages -type f -name 'luci-app-camera-tracer*.apk' -print
```

Older OpenWrt releases using `opkg` may produce an `.ipk` instead.

### 5. Build a complete firmware image

If the package is selected with `CONFIG_PACKAGE_luci-app-camera-tracer=y`, build
OpenWrt normally:

```sh
make -j"$(nproc)"
```

The generated factory/sysupgrade image will contain Camera Tracer and its hard
dependencies.

## Build with an OpenWrt SDK

A matching SDK is convenient when you only need an installable package and do
not want to rebuild the entire firmware.

Use an SDK matching the target and OpenWrt release of the router. For the
BPI-R3 Mini this is the MediaTek Filogic / `aarch64_cortex-a53` SDK.

Inside the unpacked SDK:

```sh
./scripts/feeds update -a
./scripts/feeds install -a

git clone https://github.com/<your-github-user>/luci-app-camera-tracer.git \
  package/luci-app-camera-tracer

make defconfig
make package/luci-app-camera-tracer/clean
make package/luci-app-camera-tracer/compile V=s
```

Find the result with:

```sh
find bin/packages -type f \( \
  -name 'luci-app-camera-tracer*.apk' -o \
  -name 'luci-app-camera-tracer*.ipk' \
\) -print
```

If compilation reports a missing dependency, make sure the standard OpenWrt
`packages` and `luci` feeds were updated and installed in that SDK.

## Install a locally built package

### OpenWrt 25.12+ (`apk`)

Copy the package to the router:

```sh
scp luci-app-camera-tracer-*.apk root@192.168.1.1:/tmp/
```

Then install it:

```sh
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/luci-app-camera-tracer-*.apk
```

`--allow-untrusted` is normally required for a local package that was not signed
by a repository key trusted by the router.

After installation, log out and back into LuCI if the menu entry is not visible.
It should appear under:

```text
Services -> Camera Tracer
```

### Upgrade an existing local build

Copy the newer package and run the same `apk add --allow-untrusted ...` command.
The UCI configuration file is declared as a conffile and is preserved across a
normal package upgrade.

## Basic configuration

Typical first-test settings:

```text
Enabled:                     yes
Camera:                      /dev/video0
Resolution:                  640x480
FPS:                         5
Motion trigger:              enabled
Video threshold:             1500
Minimum motion frames:       2
Timer trigger:               disabled
Timer interval:              60 s
Pause camera on trusted:     disabled
Trusted check interval:      10 s
Trigger holdoff:             Auto
Photo:                       enabled
Photo filename:              last.jpg
Video:                       enabled
Video max duration:          15 s
Video max delivered size:    32 MiB
Video quality:               60
Pre-capture:                 2 frames
Post-capture:                5 s
```

Final media paths are fixed below:

```text
/tmp/camera_tracer/last.jpg
/tmp/camera_tracer/last.mp4
```

The directory cannot be changed from LuCI by design.

The **Minimum motion frames** setting maps directly to Motion's
`minimum_motion_frames` option. Camera Tracer accepts values from 1 to 30 and
defaults to 2. At a fixed FPS, increasing it requires motion to persist for more
frames before a visual event is accepted; for example, 2 frames are about 133 ms
at 15 FPS and about 67 ms at 30 FPS.

## Timer trigger

The timer is a first-class trigger source. Enable **Enable timer trigger** and
set **Timer interval (seconds)** from 1 to 86400 seconds. When a timer tick is
accepted it follows the same pipeline as motion/audio: immediate JPEG capture,
optional MP4 and microphone audio, MQTT publishing, and the local hook.

The timer does not wait for an earlier alarm to finish and does not build a
queue. Every tick passes through the same global trigger reservation. If the
current time is still before `next_allowed`, the tick exits immediately. For
example, with a 10-second effective holdoff and a 3-second timer, ticks at 3, 6
and 9 seconds after an accepted event are simply ignored; a later tick can be
accepted after the holdoff expires. Enabling the timer over MQTT starts a fresh
interval; it does not fire immediately.

With video enabled, timer/audio/MQTT triggers require a fresh Motion movie. If
Motion already has a natural-motion event open, Camera Tracer first requests
`eventend`, waits for the matching `on_event_end` marker, and only then requests
`eventstart` for the synthetic alarm. Visual motion alarms do not force this
boundary; they remain attached to Motion's normal movie segments.

## Video safety limits

Video recording is disabled by default. When enabled, LuCI exposes bounded
limits:

- maximum clip duration: 1-120 seconds, default 15;
- pre-capture: 0-5 frames, default 2;
- post-capture: 0-30 seconds, default 5;
- video quality: 1-100, default 60;
- maximum delivered MP4 size: 1-256 MiB, default 32 MiB;
- optional AAC microphone bitrate: 16-192 kbit/s, default 64.

Motion writes `mp4:mpeg4` rather than requesting H.264. This avoids requiring
`libx264` on minimal OpenWrt FFmpeg builds. The final MP4 may optionally receive
an AAC microphone track using a second `ffmpeg` mux step.

The automatic holdoff is:

```text
2 seconds                         (video disabled)
2 + video maximum duration        (video enabled)
```

This prevents a new accepted event from overwriting the previous event's
`last.jpg` / `last.mp4` while the clip is still being created. A manually
configured holdoff overrides the automatic value.

Visual motion alarms are driven by Motion's `on_motion_detected` callback, not by
`picture_output first`. Motion can keep one internal event open for a long time
when movement never fully stops; Camera Tracer still becomes eligible for a new
visual alarm as soon as the shared holdoff expires. Rejected motion callbacks do
not request a JPEG snapshot.

## Audio configuration

Audio functions are independent:

- **Enable audio trigger** — loud sound can start the same alarm chain as visual
  motion or the timer. This checkbox is also the default runtime state restored
  after a Camera Tracer restart/reload.
- **Record microphone audio in MP4** — accepted video clips receive a microphone
  track even if sound itself is not used as a trigger.

Both options may be enabled at the same time.

The audio detector uses 50 ms AC-RMS windows (the per-window DC offset is removed before dBFS calculation). **Require quiet re-arm after audio trigger** is enabled by default: after an alarm, the detector rearms only after the level has stayed below `threshold - hysteresis` for the configured quiet re-arm interval (defaults: 6 dB and 500 ms). If this checkbox is disabled, there is no release-level/quiet-time gate: sustained sound above the threshold continues to present new audio-trigger opportunities after each configured threshold-duration window, while the shared Camera Tracer holdoff still decides which alarms are actually accepted. This behavior is independent of Motion `event_gap` and the visual-event lifecycle. The ALSA capture device is opened
once and the stream is shared internally.

Suggested starting point:

```text
Audio sample rate:           16000 Hz
Audio threshold:             -24 dBFS
Threshold duration:          250 ms
MP4 audio bitrate:           64 kbit/s
```

Useful router-side checks:

```sh
which arecord
which ffmpeg
arecord -l
ffmpeg -hide_banner -encoders 2>/dev/null | grep -i aac
```

Never force-install a `kmod-usb-audio` built for a different kernel ABI. Build
or install it from the exact same OpenWrt build/repository as the running
firmware.

## MQTT

MQTT publishing and MQTT trigger control are independent checkboxes and use the
same broker host/port/credentials/TLS settings.

### Publishing

Camera Tracer can publish three independent payload types:

```text
camera_tracer/image   raw JPEG binary payload
camera_tracer/video   raw MP4 binary payload
camera_tracer/event   JSON event payload
```

Example event:

```json
{"event":"trigger","source":"timer","timestamp":"2026-09-16T23:55:00+0300","photo":"last.jpg","video_pending":true,"audio_requested":true}
```

`source` is `video` for visual Motion events, `audio` for microphone threshold
events, `timer` for periodic events, or `mqtt` for MQTT-message-triggered
events. JPEG and MP4 are sent as binary MQTT payloads; they are not Base64
encoded. Media messages are not retained. Make
sure the broker and consumers accept packets at least as large as the configured
maximum MP4 size.


### MQTT message trigger

Enable **MQTT message trigger** and set a dedicated topic, default:

```text
camera_tracer/trigger
```

Every message received on that topic requests one alarm. The message body is
ignored. The request enters exactly the same global reservation/holdoff, JPEG,
optional MP4+audio and delivery path as motion, audio and timer alarms. If the global holdoff is still active, the MQTT trigger request is
dropped immediately and is not queued for later.

Use a dedicated, non-output topic. In particular, do not reuse
`camera_tracer/event`, `camera_tracer/image` or `camera_tracer/video` as the
trigger topic. Retained messages are broker messages too, so a retained trigger
may fire when the subscriber reconnects; use non-retained publications for
command-like trigger messages unless that behavior is intentional.

Example:

```sh
mosquitto_pub -h 192.168.1.10 -t camera_tracer/trigger -m trigger
```

The payload may be any text because Camera Tracer ignores it.

### Runtime trigger control

Enable **MQTT trigger control** and set one topic, default:

```text
camera_tracer/control
```

Camera Tracer subscribes with `mosquitto_sub`. The payload is deliberately a
small dependency-free key/value protocol rather than JSON. A single message can
change any subset of trigger sources:

```text
motion=1 audio=0 timer=1 mqtt=1
```

Comma-separated form is also accepted:

```text
motion=off,timer=on,mqtt=on
```

To change every trigger source at once:

```text
all=off
all=on
```

Accepted boolean values are `1/0`, `on/off`, `true/false`, `yes/no`, and
`enable/disable` (also `enabled/disabled`). Unknown or invalid payloads are
ignored. Omitted keys keep their current value.

These changes are **runtime-only** and are stored below `/tmp/camera_tracer/`;
MQTT control never writes UCI or flash. Restarting/reloading Camera Tracer resets
motion/audio/timer/MQTT-message states to their LuCI/UCI checkboxes. If you want
a broker to reapply desired state after reconnect/restart, publish the control message as a
retained MQTT message.

MQTT control may enable audio remotely even when the local audio-trigger checkbox
is off. For that to work, configure an audio device and install the optional
audio dependencies. Motion, timer and MQTT-message trigger control do not need ALSA.

## Alarm hook interface

The optional hook must be an executable absolute path and is called as:

```text
hook <source> <photo-path> <video-path> <trigger-epoch> <trigger-timestamp>
```

The same information is exported in these variables:

```text
CAMERA_TRACER_SOURCE
CAMERA_TRACER_PHOTO
CAMERA_TRACER_VIDEO
CAMERA_TRACER_SEND_PHOTO
CAMERA_TRACER_SEND_VIDEO
CAMERA_TRACER_TRIGGER_EPOCH
CAMERA_TRACER_TRIGGER_TIMESTAMP
```

`<source>` is `video`, `audio`, `timer` or `mqtt`. With video enabled, the hook runs
after the MP4 has been closed so it can send both the JPEG and the final video.
With video disabled, it runs immediately after the alarm is accepted.

## Generic HTTP hook example

The package installs a deliberately non-functional HTTP multipart example:

```text
/usr/share/camera-tracer/examples/example-hook.sh
/usr/share/camera-tracer/examples/example-hook.conf.example
```

The example uses the reserved `.invalid` TLD, so it will not contact a real
service until you replace the endpoint with one you control. It requires `curl`:

```sh
apk add curl
```

Install a working copy:

```sh
cp /usr/share/camera-tracer/examples/example-hook.sh \
  /root/camera-alarm.sh
cp /usr/share/camera-tracer/examples/example-hook.conf.example \
  /etc/camera-tracer-hook.conf

chmod 700 /root/camera-alarm.sh
chmod 600 /etc/camera-tracer-hook.conf
```

Edit `/etc/camera-tracer-hook.conf` and replace the example values:

```sh
ENDPOINT='https://camera-tracer.invalid/v1/events'
API_TOKEN='replace_me'
```

Then set the Camera Tracer alarm script to:

```text
/root/camera-alarm.sh
```

or from shell:

```sh
uci set camera_tracer.main.hook_script='/root/camera-alarm.sh'
uci commit camera_tracer
/etc/init.d/camera_tracer restart
```

The example submits metadata plus the accepted JPEG and optional MP4 as a
multipart request. It forces `curl --http1.1` to avoid transport-specific
multipart upload issues on some WAN/NAT paths. The endpoint is intentionally
fictional; adapt the field names, authentication and response handling to your
own receiver.

## Validation

Run the repository's static checks on a Linux development host:

```sh
./tests/static-check.sh
```

The script checks shell/BusyBox syntax, JSON, LuCI JavaScript syntax when Node is
available, helper behavior, trusted-client resolution, trusted-presence camera-gate state/path, drain safety and iwinfo watchdog, trigger-control state, timer path, audio state handling,
optional dependency rules and package install staging.

See [VALIDATION.md](VALIDATION.md) for the current validation matrix and the
hardware tests that still require a real router/camera/microphone.

GitHub Actions also runs the same static check for pushes and pull requests.

## Trusted-presence camera gate diagnostics

When the gate is enabled, these commands show its configuration and runtime
state:

```sh
uci -q get camera_tracer.main.trusted_camera_pause_enabled
uci -q get camera_tracer.main.trusted_check_interval_seconds
pgrep -af 'run-motion-supervisor|run-motion|motion'
ls -l /tmp/camera_tracer/camera-paused 2>/dev/null
logread | grep 'trusted presence gate' | tail -n 30
```

`/tmp/camera_tracer/camera-paused` is published as soon as the coarse presence
gate detects a trusted client. From that moment new motion/audio/timer/MQTT
triggers are rejected before entering the alarm/media pipeline. If an accepted
MP4 event is already recording, Motion is allowed to finish and close that movie
before the supervisor closes the camera. The raw-movie close is detected via the
existing per-event `finalize.lock`, so later muxing/MQTT/hook work does not keep
the camera open unnecessarily.

The drain wait is bounded to `video_max_time + 15 seconds` (clamped to
20..180 seconds). If an event cannot close before that deadline, Camera Tracer
marks the unfinished media finalized/abandoned, stops microphone appends,
removes pending synthetic-video state, and then terminates Motion. This prevents
a stale `audio.pcm` from growing indefinitely in tmpfs.

Trusted Wi-Fi association queries are also bounded: each `iwinfo ... assoclist`
probe has a small watchdog (3 seconds by default), so a stuck Wi-Fi query cannot
freeze the presence supervisor forever.

No trusted-device query runs in `process-event`, `movie-end`, the local hook,
or MQTT delivery. The supervisor is the single owner of trusted presence and
uses it only to start/stop camera capture.

## Timer / synthetic trigger diagnostics

On the router, these commands confirm the timer worker, runtime state and Motion localhost control path:

```sh
uci -q get camera_tracer.main.timer_enabled
uci -q get camera_tracer.main.timer_interval
cat /tmp/camera_tracer/control/timer 2>/dev/null
pgrep -af run-timer
cat /tmp/camera_tracer/motion-session 2>/dev/null
cat /tmp/camera_tracer/motion-event-active 2>/dev/null
grep -E 'webcontrol_(port|localhost|parms)' /tmp/camera_tracer/motion.conf
logread | grep camera-tracer | tail -n 80
```

A manual synthetic trigger can be tested with:

```sh
/usr/libexec/camera-tracer/event timer
```

A successful synthetic-video path logs the Motion session/event binding, for
example `bound timer trigger to Motion session ... event ...`. If a natural
Motion event was open, an earlier log reports that Camera Tracer is ending it
before starting the synthetic movie.

## Troubleshooting

Follow Camera Tracer, Motion and FFmpeg logs:

```sh
logread -f | grep -E 'camera-tracer|motion|ffmpeg'
```

Inspect generated runtime files:

```sh
ls -lah /tmp/camera_tracer/
ls -lah /tmp/camera_tracer/raw/ 2>/dev/null
```

Inspect the generated Motion configuration:

```sh
cat /tmp/camera_tracer/motion.conf
```

Check camera formats:

```sh
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --list-formats-ext
```

Check audio devices:

```sh
cat /proc/asound/cards
arecord -l
```

## Repository layout

```text
.
├── Makefile                         OpenWrt package definition
├── files/
│   ├── etc/config/camera_tracer     UCI defaults
│   ├── etc/init.d/camera_tracer     procd service
│   ├── usr/libexec/camera-tracer/   runtime workers/helpers
│   └── www/luci-static/...          LuCI JavaScript view
├── examples/                        generic hook/config examples
├── tests/static-check.sh            host-side static validation
├── VALIDATION.md                    validation status
├── CHANGELOG.md                     release history
└── LICENSE                          GPL-2.0-or-later license text
```

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
