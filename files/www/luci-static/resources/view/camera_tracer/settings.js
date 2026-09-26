'use strict';

'require view';
'require form';
'require fs';
'require uci';

const HELPER = '/usr/libexec/camera-tracer/luci-helper';

function parseTsv(result) {
	let rows = [];
	let text = (result && result.stdout) ? result.stdout : '';

	text.split(/\n/).forEach(function(line) {
		if (!line)
			return;

		let p = line.split(/\t/);
		if (p[0])
			rows.push([p[0], p.slice(1).join(' ') || p[0]]);
	});

	return rows;
}

function validateFileName(sectionId, value) {
	if (!value || !/^[A-Za-z0-9._-]+$/.test(value) || value === '.' || value === '..')
		return _('Use only A-Z, a-z, 0-9, dot, underscore and dash; directories are not allowed.');

	return true;
}

function validateVideoName(sectionId, value) {
	let base = validateFileName(sectionId, value);
	if (base !== true)
		return base;
	if (!/\.mp4$/i.test(value))
		return _('Video filename must end with .mp4.');
	return true;
}

function validateResolution(sectionId, value) {
	let m = String(value || '').match(/^(\d+)x(\d+)$/);
	if (!m || +m[1] < 16 || +m[2] < 16 || +m[1] > 8192 || +m[2] > 8192)
		return _('Use WIDTHxHEIGHT, for example 640x480.');

	return true;
}

function validateAudioDb(sectionId, value) {
	let n = Number(value);
	if (!Number.isFinite(n) || n < -96 || n > 0)
		return _('Audio threshold must be between -96 and 0 dBFS.');

	return true;
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec(HELPER, [ 'cameras' ]).catch(function() { return { stdout: '' }; }),
			fs.exec(HELPER, [ 'resolutions' ]).catch(function() { return { stdout: '' }; }),
			fs.exec(HELPER, [ 'audio' ]).catch(function() { return { stdout: '' }; }),
			fs.exec(HELPER, [ 'dhcp' ]).catch(function() { return { stdout: '' }; }),
			uci.load('camera_tracer')
		]);
	},

	render: function(data) {
		let cameras = parseTsv(data[0]);
		let resolutions = parseTsv(data[1]);
		let audioDevices = parseTsv(data[2]);
		let dhcpChoices = parseTsv(data[3]);
		let configuredCamera = uci.get('camera_tracer', 'main', 'video_device') || '/dev/video0';
		let configuredAudio = uci.get('camera_tracer', 'main', 'audio_device') || '';
		let m, s, o;

		m = new form.Map('camera_tracer', _('Camera Tracer'),
			_('UVC motion/audio/timer/MQTT-message alarm with trusted Wi-Fi suppression, bounded MP4 clips, MQTT delivery and optional MQTT trigger control. Runtime media is always stored below /tmp/camera_tracer/.'));

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('General'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable Camera Tracer'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'video_device', _('Camera'));
		cameras.forEach(function(row) {
			o.value(row[0], '%s — %s'.format(row[0], row[1]));
		});
		if (!cameras.some(function(row) { return row[0] === configuredCamera; }))
			o.value(configuredCamera, '%s (%s)'.format(configuredCamera, _('configured / not currently detected')));
		o.default = configuredCamera;
		o.rmempty = false;

		o = s.option(form.Value, 'resolution', _('Resolution'));
		let known = {};
		resolutions.forEach(function(row) {
			if (row[0] === configuredCamera && !known[row[1]]) {
				o.value(row[1]);
				known[row[1]] = true;
			}
		});
		[ '320x240', '640x360', '640x480', '1280x720', '1920x1080' ].forEach(function(v) {
			if (!known[v]) o.value(v);
		});
		o.default = '640x480';
		o.validate = validateResolution;
		o.rmempty = false;

		o = s.option(form.Value, 'fps', _('FPS'));
		o.datatype = 'range(1,60)';
		o.default = '5';
		o.rmempty = false;

		o = s.option(form.Flag, 'motion_enabled', _('Enable motion trigger'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Initial runtime state for visual-motion alarms. MQTT trigger control can override it until Camera Tracer is restarted/reloaded.');

		o = s.option(form.Value, 'video_threshold', _('Video threshold'));
		o.datatype = 'uinteger';
		o.default = '1500';
		o.description = _('Number of changed pixels required by Motion to trigger an event.');
		o.rmempty = false;

		o = s.option(form.Value, 'minimum_motion_frames', _('Minimum motion frames'));
		o.datatype = 'range(1,30)';
		o.default = '2';
		o.description = _('Minimum number of motion-detected frames required before Motion starts an event. Higher values reject shorter image changes but add trigger latency.');
		o.rmempty = false;

		o = s.option(form.DynamicList, 'trusted_ip', _('Trusted DHCP IP addresses'));
		dhcpChoices.forEach(function(row) {
			o.value(row[0], '%s — %s'.format(row[0], row[1]));
		});
		o.datatype = 'ip4addr';
		o.rmempty = true;
		o.description = _('Used only by the optional camera-pause gate. The selected IP is mapped to its DHCP MAC and that MAC is checked in the current Wi-Fi association table. With an empty list, the camera-pause gate is a no-op.');

		o = s.option(form.Flag, 'trusted_camera_pause_enabled', _('Pause camera while a trusted device is present'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Camera Tracer checks the configured trusted Wi-Fi clients before opening the camera and periodically afterwards. If any trusted client is associated, Motion is stopped and the camera device is closed; when all trusted clients disappear, camera capture is started again. Trusted-device presence is not checked again when an alarm is accepted or delivered.');

		o = s.option(form.Value, 'trusted_check_interval_seconds', _('Trusted presence check interval (seconds)'));
		o.datatype = 'range(5,3600)';
		o.default = '10';
		o.depends('trusted_camera_pause_enabled', '1');
		o.rmempty = false;
		o.cfgvalue = function(sectionId) {
			let value = uci.get('camera_tracer', sectionId, 'trusted_check_interval_seconds');
			if (value != null && value !== '')
				return value;

			// Preserve the effective interval for upgrades from 0.6.0/0.6.1,
			// where this setting was stored in minutes. Saving the page writes
			// the new seconds option and removes the legacy key.
			let legacy = parseInt(uci.get('camera_tracer', sectionId, 'trusted_check_interval_minutes'), 10);
			if (Number.isFinite(legacy))
				return String(Math.max(5, Math.min(3600, legacy * 60)));

			return '10';
		};
		o.write = function(sectionId, value) {
			uci.set('camera_tracer', sectionId, 'trusted_check_interval_seconds', value);
			uci.unset('camera_tracer', sectionId, 'trusted_check_interval_minutes');
		};
		o.description = _('Presence is checked immediately when Camera Tracer starts, then at this interval. Minimum 5 seconds, default 10 seconds. A join/leave can therefore take up to one interval to affect camera capture. With no trusted IPs configured, this gate is a no-op and the camera remains active.');

		o = s.option(form.Value, 'holdoff', _('Trigger lock timeout (seconds)'));
		o.datatype = 'uinteger';
		o.placeholder = _('Auto');
		o.rmempty = true;
		o.description = _('While locked, new triggers cannot overwrite accepted media. Empty/0 = automatic: 2 seconds without video, or 2 seconds plus the configured video maximum duration when video recording is enabled.');

		o = s.option(form.Value, 'photo_name', _('Photo filename'));
		o.default = 'last.jpg';
		o.rmempty = false;
		o.validate = validateFileName;
		o.description = _('Saved immediately as /tmp/camera_tracer/<filename>. The directory is fixed and cannot be changed from LuCI.');

		o = s.option(form.Flag, 'send_photo', _('Deliver photo'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('When disabled, the trigger JPEG is still kept locally for event correlation and hooks, but is not published to the MQTT JPEG topic.');

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Timer'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'timer_enabled', _('Enable timer trigger'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Initial runtime state for periodic alarms. Each accepted timer tick follows exactly the same photo, video/audio and delivery chain as motion/audio triggers. MQTT trigger control can override this state until restart/reload.');

		o = s.option(form.Value, 'timer_interval', _('Timer interval (seconds)'));
		o.datatype = 'range(1,86400)';
		o.default = '60';
		o.depends('timer_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = false;
		o.description = _('Timer ticks are never queued. If a tick occurs while the global trigger lock/holdoff from a previous event is still active (including when this interval is shorter than the holdoff), that tick is simply discarded.');

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Video clip'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'video_enabled', _('Record and deliver MP4 video'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Uses Motion/FFmpeg. Visual motion, audio threshold, timer and MQTT-message triggers all use the same photo/video alarm chain. Media is written under /tmp/camera_tracer/. JPEG/event delivery starts immediately after acceptance; MP4 delivery waits until Motion closes the file.');

		o = s.option(form.Value, 'video_name', _('Video filename'));
		o.default = 'last.mp4';
		o.depends('video_enabled', '1');
		o.validate = validateVideoName;
		o.rmempty = false;
		o.description = _('Saved as /tmp/camera_tracer/<filename>.');

		o = s.option(form.Value, 'video_max_time', _('Maximum clip duration (seconds)'));
		o.datatype = 'range(1,120)';
		o.default = '15';
		o.depends('video_enabled', '1');
		o.rmempty = false;
		o.description = _('Hard Motion movie_max_time limit for each MP4 segment. Camera Tracer accepts only the first completed segment of an event. Synthetic audio/timer recording is also forcibly ended at this limit.');

		o = s.option(form.Value, 'video_pre_capture_frames', _('Pre-capture frames'));
		o.datatype = 'range(0,5)';
		o.default = '2';
		o.depends('video_enabled', '1');
		o.rmempty = false;
		o.description = _('Frames buffered before motion is detected. Kept deliberately at 0–5 because larger Motion pre-capture values can cause frame skipping and extra RAM/CPU load.');

		o = s.option(form.Value, 'video_post_capture_seconds', _('Post-capture (seconds)'));
		o.datatype = 'range(0,30)';
		o.default = '5';
		o.depends('video_enabled', '1');
		o.rmempty = false;
		o.description = _('Converted to Motion post-capture frames using the configured FPS.');

		o = s.option(form.Value, 'video_quality', _('Video quality'));
		o.datatype = 'range(1,100)';
		o.default = '60';
		o.depends('video_enabled', '1');
		o.rmempty = false;
		o.description = _('Motion/FFmpeg variable-quality setting: 1 is lowest, 100 is highest/largest.');

		o = s.option(form.Value, 'video_max_size_mb', _('Maximum delivered video size (MiB)'));
		o.datatype = 'range(1,256)';
		o.default = '32';
		o.depends('video_enabled', '1');
		o.rmempty = false;
		o.description = _('Safety limit checked when the MP4 closes. Oversized clips are deleted instead of being copied/published. Maximum duration is the primary limit while the file is being recorded.');

		o = s.option(form.Flag, 'video_audio_enabled', _('Record microphone audio in MP4'));
		o.default = '0';
		o.depends('video_enabled', '1');
		o.rmempty = false;
		o.description = _('Optional. Uses the same ALSA capture stream as audio-trigger detection, so the microphone is opened only once. Requires alsa-utils/arecord and matching USB-audio support; final muxing requires the ffmpeg CLI. If audio capture or muxing fails, Camera Tracer keeps and delivers the video-only MP4.');

		o = s.option(form.Value, 'video_audio_bitrate_kbps', _('MP4 audio bitrate (kbit/s)'));
		o.datatype = 'range(16,192)';
		o.default = '64';
		o.depends({ video_enabled: '1', video_audio_enabled: '1' });
		o.rmempty = false;
		o.description = _('AAC bitrate used when the captured microphone PCM is muxed into the completed MP4.');

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('MQTT'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'mqtt_enabled', _('Enable MQTT publishing'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Flag, 'mqtt_trigger_enabled', _('Enable MQTT message trigger'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Initial runtime state for alarms triggered by receiving any message on the configured MQTT trigger topic. The payload is ignored. The alarm uses the same global holdoff, photo/video/audio and delivery path as motion/audio/timer. MQTT trigger control can override this state until restart/reload.');

		o = s.option(form.Value, 'mqtt_trigger_topic', _('MQTT trigger topic'));
		o.default = 'camera_tracer/trigger';
		o.depends('mqtt_trigger_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = false;
		o.description = _('Every received message requests one alarm; message body is ignored. Requests received while the global trigger holdoff is active are dropped, not queued. Use a dedicated topic and avoid reusing Camera Tracer output topics.');

		o = s.option(form.Flag, 'mqtt_control_enabled', _('Enable MQTT trigger control'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Subscribes to one control topic and changes the runtime enable state of motion, audio, timer and MQTT-message triggers without writing UCI/flash. Restart/reload restores the LuCI checkbox defaults.');

		o = s.option(form.Value, 'mqtt_control_topic', _('Trigger control topic'));
		o.default = 'camera_tracer/control';
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = false;
		o.description = _('Payload examples: motion=1 audio=0 timer=1 mqtt=1, motion=off,mqtt=on, or all=off. Partial updates are allowed.');

		o = s.option(form.Value, 'mqtt_host', _('Broker host'));
		o.depends('mqtt_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.depends('mqtt_trigger_enabled', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_port', _('Broker port'));
		o.datatype = 'port';
		o.default = '1883';
		o.depends('mqtt_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.depends('mqtt_trigger_enabled', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_user', _('Username'));
		o.depends('mqtt_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.depends('mqtt_trigger_enabled', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'mqtt_password', _('Password'));
		o.password = true;
		o.depends('mqtt_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.depends('mqtt_trigger_enabled', '1');
		o.rmempty = true;

		o = s.option(form.Flag, 'mqtt_tls', _('TLS'));
		o.default = '0';
		o.depends('mqtt_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.depends('mqtt_trigger_enabled', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_cafile', _('CA certificate path'));
		o.default = '/etc/ssl/certs/ca-certificates.crt';
		o.depends('mqtt_tls', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_image_topic', _('JPEG topic'));
		o.default = 'camera_tracer/image';
		o.depends('mqtt_enabled', '1');
		o.rmempty = true;
		o.description = _('Raw JPEG binary payload. Retain is intentionally not used.');

		o = s.option(form.Value, 'mqtt_video_topic', _('MP4 topic'));
		o.default = 'camera_tracer/video';
		o.depends({ mqtt_enabled: '1', video_enabled: '1' });
		o.rmempty = true;
		o.description = _('Raw MP4 binary payload after the clip is closed. Ensure the broker/consumer MQTT packet-size limits are large enough.');

		o = s.option(form.Value, 'mqtt_event_topic', _('Event topic'));
		o.default = 'camera_tracer/event';
		o.depends('mqtt_enabled', '1');
		o.rmempty = true;
		o.description = _('Optional JSON event sent after the trusted-device check. With video enabled, video_pending=true indicates that the MP4 will follow on its own topic.');

		o = s.option(form.ListValue, 'mqtt_qos', _('QoS'));
		o.value('0', '0');
		o.value('1', '1');
		o.value('2', '2');
		o.default = '1';
		o.depends('mqtt_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.depends('mqtt_trigger_enabled', '1');
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Local hook'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'hook_script', _('Alarm script'));
		o.placeholder = '/root/camera-alarm.sh';
		o.rmempty = true;
		o.description = _('Optional executable absolute path. Arguments: <source> <photo-path> <video-path> <trigger-epoch> <trigger-timestamp>. Source is video, audio, timer or mqtt. With video enabled it runs once after the MP4 is closed, with both paths. If video is disabled or could not be started, the video path is empty.');

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Audio'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'audio_enabled', _('Enable audio trigger'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Initial runtime state for the audio threshold trigger. Crossing the threshold uses the same alarm chain as motion/timer/MQTT-message triggers. MQTT trigger control can override this state until restart/reload.');

		o = s.option(form.ListValue, 'audio_device', _('Audio capture device'));
		audioDevices.forEach(function(row) {
			o.value(row[0], '%s — %s'.format(row[0], row[1]));
		});
		if (configuredAudio && !audioDevices.some(function(row) { return row[0] === configuredAudio; }))
			o.value(configuredAudio, '%s (%s)'.format(configuredAudio, _('configured / not currently detected')));
		o.depends('audio_enabled', '1');
		o.depends({ video_enabled: '1', video_audio_enabled: '1' });
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = true;
		o.description = _('Shared by audio-trigger detection and optional MP4 microphone recording. Leave empty if MQTT control will only manage motion/timer/MQTT-message triggers. Enabling audio requires alsa-utils/arecord and matching USB-audio kernel support installed separately.');

		o = s.option(form.ListValue, 'audio_sample_rate', _('Audio sample rate'));
		[ '8000', '16000', '32000', '44100', '48000' ].forEach(function(v) { o.value(v, v + ' Hz'); });
		o.default = '16000';
		o.depends('audio_enabled', '1');
		o.depends({ video_enabled: '1', video_audio_enabled: '1' });
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = false;
		o.description = _('Mono S16_LE capture rate used by both threshold detection and MP4 audio recording. 16 kHz is a good default for speech/security audio.');

		o = s.option(form.Value, 'audio_threshold_db', _('Audio threshold (dBFS)'));
		o.default = '-24';
		o.depends('audio_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.validate = validateAudioDb;
		o.rmempty = false;

		o = s.option(form.Value, 'audio_trigger_ms', _('Audio threshold duration (ms)'));
		o.datatype = 'range(50,5000)';
		o.default = '250';
		o.depends('audio_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = false;


		o = s.option(form.Flag, 'audio_rearm_enabled', _('Require quiet re-arm after audio trigger'));
		o.default = '1';
		o.depends('audio_enabled', '1');
		o.depends('mqtt_control_enabled', '1');
		o.rmempty = false;
		o.description = _('When enabled, an audio trigger disarms the detector until the level stays below threshold minus hysteresis for the configured quiet time. When disabled, sustained sound above the threshold can trigger again as soon as the shared Camera Tracer holdoff permits it.');

		o = s.option(form.Value, 'audio_hysteresis_db', _('Audio re-arm hysteresis (dB)'));
		o.datatype = 'range(0,30)';
		o.default = '6';
		o.depends({ audio_enabled: '1', audio_rearm_enabled: '1' });
		o.depends({ mqtt_control_enabled: '1', audio_rearm_enabled: '1' });
		o.rmempty = false;
		o.description = _('After an audio alarm, the measured level must fall this many dB below the trigger threshold before the detector can arm again. This prevents a steady hum/noise floor from repeatedly retriggering.');

		o = s.option(form.Value, 'audio_rearm_ms', _('Audio quiet re-arm time (ms)'));
		o.datatype = 'range(50,10000)';
		o.default = '500';
		o.depends({ audio_enabled: '1', audio_rearm_enabled: '1' });
		o.depends({ mqtt_control_enabled: '1', audio_rearm_enabled: '1' });
		o.rmempty = false;
		o.description = _('How long the level must remain below the hysteresis release level before a new audio alarm is allowed.');

		return m.render();
	}
});
