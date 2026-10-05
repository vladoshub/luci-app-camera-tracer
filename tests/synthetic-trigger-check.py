#!/usr/bin/env python3
"""Exercise the real shell callbacks with a temporary OpenWrt/Motion fixture."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "files/usr/libexec/camera-tracer"


class SyntheticTriggerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / "state"
        self.runtime = Path(self.temp.name) / "runtime"
        self.bin = Path(self.temp.name) / "bin"
        for directory in (self.base / "raw", self.base / "state/gen", self.runtime, self.bin):
            directory.mkdir(parents=True)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        self.env["CT_TEST_BASE"] = str(self.base)
        self.env["CT_TEST_RUNTIME"] = str(self.runtime)
        for source in RUNTIME.iterdir():
            body = source.read_text().replace("/usr/libexec/camera-tracer", str(self.runtime))
            body = body.replace("/tmp/camera_tracer", str(self.base))
            body = body.replace("/usr/bin/motion", str(self.bin / "motion"))
            if source.name == "common.sh":
                body = body.replace(". /lib/functions.sh", "") + r'''
ct_load_config() { :; }
config_get() {
    local mock_dest="$1" mock_option="$3" mock_result="${4:-}"
    case "$mock_option" in
        holdoff) mock_result="${CT_TEST_HOLDOFF:-1}" ;;
        video_max_time) mock_result=2 ;;
    esac
    eval "$mock_dest=\$mock_result"
}
config_get_bool() {
    local mock_dest="$1" mock_option="$3" mock_result="${4:-0}"
    case "$mock_option" in enabled|video_enabled|motion_enabled|timer_enabled|audio_enabled|mqtt_trigger_enabled) mock_result=1 ;; esac
    eval "$mock_dest=\$mock_result"
}
ct_log() { printf '%s\n' "$*" >> "$CT_BASE/log"; }
ct_motion_action() {
    printf '%s\n' "$1" >> "$CT_BASE/actions"
    case "$1" in
        snapshot) printf 'jpeg\n' > "$CT_RAW/synthetic-snapshot.jpg" ;;
        eventstart) [ "${CT_TEST_FAIL_EVENTSTART:-0}" != 1 ] ;;
        eventend)
            if [ "${CT_TEST_FAIL_EVENTEND:-0}" = 1 ]; then return 1; fi
            if [ "${CT_TEST_END_CALLBACK:-0}" = 1 ]; then
                "$CT_TEST_RUNTIME/motion-event-end" session1 7
            fi
            ;;
    esac
}
'''
            self.write_executable(self.runtime / source.name, body)
        # Keep the workers deterministic; callbacks are invoked explicitly below.
        self.stop_worker = self.runtime / "stop-worker"
        self.stop_worker.write_text((self.runtime / "synthetic-video-stop").read_text())
        self.write_executable(self.runtime / "synthetic-video-stop", "#!/bin/sh\nexit 0\n")
        self.write_executable(self.runtime / "process-event", "#!/bin/sh\nexit 0\n")
        self.write_executable(self.bin / "sleep", "#!/bin/sh\nexit 0\n")
        self.write_executable(self.bin / "motion", "#!/bin/sh\nexit 0\n")
        (self.base / "generation").write_text("gen\n")
        (self.base / "motion-session").write_text("session1\n")

    @staticmethod
    def write_executable(path, body):
        path.write_text(body)
        path.chmod(0o755)

    def run_script(self, name, *args):
        result = subprocess.run(
            ["sh", str(self.runtime / name), *map(str, args)],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def actions(self):
        path = self.base / "actions"
        return path.read_text().splitlines() if path.exists() else []

    def arm_timer(self, bound=True):
        self.run_script("event", "timer")
        directories = list((self.base / "state/gen").glob("session1-synthetic-*"))
        self.assertEqual(len(directories), 1)
        directory = directories[0]
        if bound:
            self.run_script("motion-event-start", "session1", 7)
            self.run_script("movie-start", "session1", self.base / "raw/clip-7.mp4", 7)
            self.assertFalse((self.base / "synthetic-video-pending").exists())
        return directory

    def stop(self, directory, generation="gen", session="session1"):
        self.run_script("stop-worker", generation, session, directory, 2)

    def record_dispatches(self):
        self.write_executable(self.runtime / "event", r'''#!/bin/sh
printf '%s\n' "$*" >> "$CT_TEST_BASE/dispatches"
''')
        (self.base / "next_allowed").write_text("0\n")

    def test_static_frames_cannot_become_visual_alarms(self):
        self.record_dispatches()
        for pixels in (0, 1499, 1500, "invalid", ""):
            self.run_script("motion-trigger", "session1", 7, pixels, 1500)
        self.assertFalse((self.base / "dispatches").exists())

    def test_real_motion_still_dispatches_after_holdoff(self):
        self.record_dispatches()
        self.run_script("motion-trigger", "session1", 8, 1501, 1500)
        self.assertEqual((self.base / "dispatches").read_text().splitlines(), ["video  8 session1"])
        (self.base / "next_allowed").write_text("9999999999\n")
        self.run_script("motion-trigger", "session1", 8, 2000, 1500)
        self.assertEqual(len((self.base / "dispatches").read_text().splitlines()), 1)

    def test_movie_finalization_does_not_lose_user_event_ownership(self):
        directory = self.arm_timer()
        movie = self.base / "raw/clip-7.mp4"
        movie.write_bytes(b"test movie")
        self.run_script("movie-end", "session1", movie, 7)
        self.assertFalse(directory.exists())
        # Motion splits the same user event into another movie segment.
        self.run_script("movie-start", "session1", self.base / "raw/clip-7-next.mp4", 7)
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)
        self.assertFalse((self.base / "synthetic-video-active").exists())

    def test_synthetic_callbacks_do_not_change_alarm_source(self):
        self.arm_timer()
        self.record_dispatches()
        self.run_script("motion-trigger", "session1", 7, 2000, 1500)
        self.assertFalse((self.base / "dispatches").exists())
        self.run_script("motion-event-end", "session1", 7)
        self.run_script("motion-trigger", "session1", 8, 2000, 1500)
        self.assertTrue((self.base / "dispatches").exists())

    def test_short_holdoff_does_not_replace_active_synthetic_owner(self):
        directory = self.arm_timer()
        (self.base / "next_allowed").write_text("0\n")
        for source in ("timer", "mqtt", "audio", "video"):
            self.run_script("event", source, "", 7, "session1")
        self.assertEqual(self.actions().count("eventstart"), 1)
        self.assertTrue(directory.exists())
        self.assertEqual((self.base / "synthetic-video-active").read_text().splitlines()[2], str(directory))
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)

    def test_unbound_movie_still_resets_user_event(self):
        directory = self.arm_timer(bound=False)
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)
        self.assertFalse((self.base / "synthetic-video-pending").exists())
        self.assertFalse((self.base / "synthetic-video-active").exists())
        self.assertFalse(directory.exists())

    def test_eventend_failure_is_retried_and_keeps_owner(self):
        directory = self.arm_timer()
        self.env["CT_TEST_FAIL_EVENTEND"] = "1"
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 2)
        self.assertTrue((self.base / "synthetic-video-active").exists())

    def test_ended_synthetic_event_cannot_stop_later_natural_event(self):
        directory = self.arm_timer()
        self.run_script("motion-event-end", "session1", 7)
        self.run_script("motion-event-start", "session1", 8)
        self.stop(directory)
        self.assertNotIn("eventend", self.actions())

    def test_mismatched_end_callback_cannot_release_synthetic_owner(self):
        directory = self.arm_timer()
        self.run_script("motion-event-end", "session1", 6)
        self.run_script("motion-event-end", "old-session", 7)
        self.assertTrue((self.base / "synthetic-video-active").exists())
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)

    def test_old_worker_cannot_stop_new_session_or_generation(self):
        directory = self.arm_timer()
        self.stop(directory, generation="old-generation")
        self.stop(directory, session="old-session")
        self.assertNotIn("eventend", self.actions())

    def test_motion_restart_cannot_be_stopped_by_old_worker(self):
        directory = self.arm_timer()
        (self.base / "motion-session").write_text("session2\n")
        self.run_script("motion-event-start", "session2", 1)
        self.stop(directory)
        self.assertNotIn("eventend", self.actions())

    def test_motion_launch_clears_stale_latches_and_passes_real_pixel_count(self):
        self.arm_timer(bound=False)
        self.run_script("run-motion")
        self.assertFalse((self.base / "synthetic-video-active").exists())
        self.assertFalse((self.base / "synthetic-video-pending").exists())
        config = (self.base / "motion.conf").read_text()
        callback = next(line for line in config.splitlines() if line.startswith("on_motion_detected "))
        self.assertTrue(callback.endswith(" %v %D 1500"))

    def test_old_worker_cannot_end_replacement_owner_in_same_session(self):
        directory = self.arm_timer()
        replacement = self.base / "state/gen/session1-synthetic-next"
        (self.base / "synthetic-video-active").write_text(f"gen\nsession1\n{replacement}\n8\n")
        self.stop(directory)
        self.assertNotIn("eventend", self.actions())
        self.assertEqual((self.base / "synthetic-video-active").read_text().splitlines()[2], str(replacement))

    def test_missing_active_callback_does_not_lose_user_event_stop(self):
        directory = self.arm_timer()
        (self.base / "motion-event-active").unlink()
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)

    def test_later_natural_event_survives_lost_end_callback(self):
        directory = self.arm_timer()
        self.run_script("motion-event-start", "session1", 8)
        self.stop(directory)
        self.assertNotIn("eventend", self.actions())
        self.assertFalse((self.base / "synthetic-video-active").exists())

    def test_failed_eventstart_keeps_a_stop_worker_owner(self):
        self.env["CT_TEST_FAIL_EVENTSTART"] = "1"
        self.run_script("event", "timer")
        owner = (self.base / "synthetic-video-active").read_text().splitlines()
        directory = Path(owner[2])
        self.assertFalse(directory.exists())
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)
        self.assertFalse((self.base / "synthetic-video-active").exists())

    def test_eventend_callback_can_clear_owner_before_worker_finishes(self):
        directory = self.arm_timer()
        self.env["CT_TEST_END_CALLBACK"] = "1"
        self.stop(directory)
        self.assertEqual(self.actions().count("eventend"), 1)
        self.assertFalse((self.base / "synthetic-video-active").exists())


if __name__ == "__main__":
    unittest.main()
