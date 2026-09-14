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
			_('UVC motion/audio alarm with trusted Wi-Fi suppression, bounded MP4 clips and MQTT delivery. Runtime media is always stored below /tmp/camera_tracer/.'));

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

		o = s.option(form.Value, 'video_threshold', _('Video threshold'));
		o.datatype = 'uinteger';
		o.default = '1500';
		o.description = _('Number of changed pixels required by Motion to trigger an event.');
		o.rmempty = false;

		o = s.option(form.DynamicList, 'trusted_ip', _('Trusted DHCP IP addresses'));
		dhcpChoices.forEach(function(row) {
			o.value(row[0], '%s — %s'.format(row[0], row[1]));
		});
		o.datatype = 'ip4addr';
		o.rmempty = true;
		o.description = _('Empty list means no presence check: delivery starts immediately. Presence is verified by matching the selected IP to its DHCP MAC and checking that MAC in the current Wi-Fi association table.');

		o = s.option(form.Value, 'trusted_timeout', _('Trusted-device wait (seconds)'));
		o.datatype = 'range(0,300)';
		o.default = '5';
		o.description = _('Ignored when the trusted IP list is empty. The trigger photo is saved immediately; delivery waits for this timeout.');
		o.rmempty = false;

		o = s.option(form.Value, 'holdoff', _('Trigger lock timeout (seconds)'));
		o.datatype = 'uinteger';
		o.placeholder = _('Auto');
		o.rmempty = true;
		o.description = _('While locked, new triggers cannot overwrite accepted media. Empty/0 = automatic: 2 seconds plus the larger of the trusted-device wait and the configured video maximum duration.');

		o = s.option(form.Value, 'photo_name', _('Photo filename'));
		o.default = 'last.jpg';
		o.rmempty = false;
		o.validate = validateFileName;
		o.description = _('Saved immediately as /tmp/camera_tracer/<filename>. The directory is fixed and cannot be changed from LuCI.');

		o = s.option(form.Flag, 'send_photo', _('Deliver photo'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('When disabled, the trigger JPEG is still kept locally for event correlation and hooks, but is not published to the MQTT JPEG topic.');

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Video clip'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'video_enabled', _('Record and deliver MP4 video'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Uses Motion/FFmpeg. Either visual motion or an enabled audio threshold starts the same photo/video alarm chain. Media is written under /tmp/camera_tracer/ and delivered only after the trusted-device decision; MP4 delivery waits until Motion closes the file.');

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
		o.description = _('Hard Motion movie_max_time limit for each MP4 segment. Camera Tracer accepts only the first completed segment of an event. Audio-triggered recording is also forcibly ended at this limit so continuous sound cannot record indefinitely.');

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

		o = s.option(form.Flag, 'mqtt_enabled', _('Enable MQTT'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_host', _('Broker host'));
		o.depends('mqtt_enabled', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_port', _('Broker port'));
		o.datatype = 'port';
		o.default = '1883';
		o.depends('mqtt_enabled', '1');
		o.rmempty = false;

		o = s.option(form.Value, 'mqtt_user', _('Username'));
		o.depends('mqtt_enabled', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'mqtt_password', _('Password'));
		o.password = true;
		o.depends('mqtt_enabled', '1');
		o.rmempty = true;

		o = s.option(form.Flag, 'mqtt_tls', _('TLS'));
		o.default = '0';
		o.depends('mqtt_enabled', '1');
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
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Local hook'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'hook_script', _('Alarm script'));
		o.placeholder = '/root/camera-alarm.sh';
		o.rmempty = true;
		o.description = _('Optional executable absolute path. Arguments: <source> <photo-path> <video-path> <trigger-epoch> <trigger-timestamp>. For either visual or audio triggers with video enabled it runs once after the MP4 is closed, with both paths. If video is disabled or could not be started, the video path is empty.');

		s = m.section(form.NamedSection, 'main', 'camera_tracer', _('Audio'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'audio_enabled', _('Enable audio trigger'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Optional. Crossing the audio threshold is treated like visual motion: the JPEG is captured immediately, the trusted-device timeout is applied, and when video is enabled the same bounded MP4 chain is started.');

		o = s.option(form.ListValue, 'audio_device', _('Audio capture device'));
		audioDevices.forEach(function(row) {
			o.value(row[0], '%s — %s'.format(row[0], row[1]));
		});
		if (configuredAudio && !audioDevices.some(function(row) { return row[0] === configuredAudio; }))
			o.value(configuredAudio, '%s (%s)'.format(configuredAudio, _('configured / not currently detected')));
		o.depends('audio_enabled', '1');
		o.depends({ video_enabled: '1', video_audio_enabled: '1' });
		o.rmempty = false;
		o.description = _('Shared by audio-trigger detection and optional MP4 microphone recording. Requires alsa-utils/arecord and matching USB-audio kernel support installed separately.');

		o = s.option(form.ListValue, 'audio_sample_rate', _('Audio sample rate'));
		[ '8000', '16000', '32000', '44100', '48000' ].forEach(function(v) { o.value(v, v + ' Hz'); });
		o.default = '16000';
		o.depends('audio_enabled', '1');
		o.depends({ video_enabled: '1', video_audio_enabled: '1' });
		o.rmempty = false;
		o.description = _('Mono S16_LE capture rate used by both threshold detection and MP4 audio recording. 16 kHz is a good default for speech/security audio.');

		o = s.option(form.Value, 'audio_threshold_db', _('Audio threshold (dBFS)'));
		o.default = '-24';
		o.depends('audio_enabled', '1');
		o.validate = validateAudioDb;
		o.rmempty = false;

		o = s.option(form.Value, 'audio_trigger_ms', _('Audio threshold duration (ms)'));
		o.datatype = 'range(50,5000)';
		o.default = '250';
		o.depends('audio_enabled', '1');
		o.rmempty = false;

		return m.render();
	}
});
