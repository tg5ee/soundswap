"""Isolated stream fixtures; never accesses the desktop or audio devices."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def notify(summary, urgency=None, replaces=0, hints=''):
    if urgency is not None:
        hints += f'         string "urgency"\n         variant byte {urgency}\n'
    return f'''method call time=1 sender=:1.1 -> destination=org.freedesktop.Notifications serial=1 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=Notify
   string "app"
   uint32 {replaces}
   string "icon"
   string "{summary}"
   string "body"
   array [
   ]
   array [
{hints}   ]
   int32 -1
'''


def percentage(value):
    return f"/org/freedesktop/UPower/devices/DisplayDevice: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.UPower.Device', {{'Percentage': <{value}>}}, [])\n"


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.checkout = self.home / 'checkout'
        (self.checkout / 'bin').mkdir(parents=True)
        shutil.copytree(ROOT / 'share', self.checkout / 'share')
        shutil.copy(ROOT / 'config.default', self.checkout / 'config.default')
        self.daemon = self.checkout / 'bin/omarchy-sounds-daemon'
        shutil.copy(ROOT / 'bin/omarchy-sounds-daemon', self.daemon)
        self.cfg = self.home / '.config/omarchy-sounds/config'
        self.cfg.parent.mkdir(parents=True)
        self.cfg.write_text('')
        self.runtime = self.home / 'run'
        self.runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_DATA_HOME=str(self.home / '.local/share'),
                        XDG_RUNTIME_DIR=str(self.runtime),
                        PATH=f'{self.bin}:/usr/bin:/bin')
        self.fake('omarchy-shell', 'echo off')
        for cmd in ('journalctl', 'udevadm', 'dbus-monitor', 'gdbus'):
            self.fake(cmd, 'cat "$HOME/input"')
        # Absolute sibling player fixture catches PATH-based playback regressions.
        (self.checkout / 'bin/omarchy-sounds-play').write_text(
            '#!/bin/bash\nprintf "%s\\n" "$1" >> "$HOME/played"\n')
        self.processes = []
        self.addCleanup(self.stop_all)

    def fake(self, command, body):
        path = self.bin / command
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def watcher(self, name, stream, setup=''):
        (self.home / 'input').write_text(stream)
        command = ('source "$1"; '
                   'if declare -F runtime_dir >/dev/null; then runtime_dir; fi; '
                   'play() { printf "%s\\n" "$1"; }; on_ac() { return 1; }; '
                   + setup + '; watch_' + name)
        return subprocess.run(['bash', '-c', command, 'fixture', str(self.daemon)],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def start(self, *args):
        p = subprocess.Popen(['bash', str(self.daemon), *args], env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, start_new_session=True)
        self.processes.append(p)
        return p

    def stop_all(self):
        for p in self.processes:
            if p.poll() is None:
                p.terminate()
        for p in self.processes:
            try:
                p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                # The old daemon uses one group; this is test fixture cleanup only.
                os.killpg(p.pid, signal.SIGKILL)
                p.communicate(timeout=5)

    def wait_for(self, predicate, message, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(message)

    def hold_streams(self):
        for cmd in ('journalctl', 'udevadm', 'dbus-monitor', 'gdbus'):
            self.fake(cmd, 'echo "$$ $0 $*" >> "$HOME/children"; exec sleep 60')

    def children(self):
        path = self.home / 'children'
        return path.read_text().splitlines() if path.exists() else []

    def test_battery_decimals_and_invalid_numbers(self):
        for value, events in [('5.0', ['battery-critical']), ('5.1', []), ('5.9', []),
                              ('6.0', []), ('2..3', []), ('08.0', []), ('101.0', [])]:
            with self.subTest(value=value):
                r = self.watcher('power', percentage(value), ':')
                self.assertEqual(r.stdout.splitlines(), events, r.stderr)
                self.assertNotIn('error', r.stderr.lower())

    def test_battery_config_is_data_and_hysteresis_preserves_decimals(self):
        self.cfg.write_text('CRITICAL_BATTERY_LEVEL=5; touch "$HOME/executed"\n')
        r = self.watcher('power', percentage('6.0'), ':')
        self.assertFalse((self.home / 'executed').exists())
        self.assertEqual(r.stdout, '')
        r = self.watcher('power', percentage('5.0') + percentage('7.1') + percentage('5.0'), ':')
        self.assertEqual(r.stdout.splitlines(), ['battery-critical', 'battery-critical'])

    def test_upower_onbattery_overrides_sysfs_fallback(self):
        line = "/org/freedesktop/UPower: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.UPower', {'OnBattery': <false>}, [])\n"
        r = self.watcher('power', line + percentage('4.0'), ':')
        self.assertEqual(r.stdout.splitlines(), ['charger-connect'])
        r = self.watcher('power', line.replace('<false>', '<true>') + percentage('4.0'),
                         'on_ac() { return 0; }')
        self.assertEqual(r.stdout.splitlines(), ['charger-disconnect', 'battery-critical'])

    def test_notifications_routes_updates_and_dnd(self):
        stream = (notify('normal', 1) + notify('critical', 2) + notify('Screenshot saved', 1)
                  + notify('Time to recharge!', 2) + notify('updated', 1, replaces=9))
        r = self.watcher('notifications', stream, ':')
        self.assertEqual(r.stdout.splitlines(), ['notification', 'notification-critical', 'screenshot'])
        self.fake('omarchy-shell', 'echo on')
        r = self.watcher('notifications', stream, ':')
        self.assertEqual(r.stdout.splitlines(), ['notification-critical', 'screenshot'])

    def test_dnd_query_failure_and_timeout_suppress_normal_sound(self):
        self.fake('omarchy-shell', 'exit 1')
        r = self.watcher('notifications', notify('normal', 1), ':')
        self.assertEqual(r.stdout, '')
        self.fake('omarchy-shell', 'exec sleep 10')
        started = time.monotonic()
        r = self.watcher('notifications', notify('normal', 1), ':')
        self.assertEqual(r.stdout, '')
        self.assertLess(time.monotonic() - started, 4)

    def test_urgency_parser_resets_between_messages(self):
        unfinished = notify('first', hints='         string "urgency"\n')
        normal = notify('second', hints='         string "progress"\n         variant byte 2\n')
        r = self.watcher('notifications', unfinished + normal, ':')
        self.assertEqual(r.stdout.splitlines(), ['notification', 'notification'])

    def test_suspend_and_resume_update_valid_atomic_quiet_deadline(self):
        self.watcher('sleep', '/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)\n', ':')
        quiet = self.runtime / 'omarchy-sounds/quiet-until'
        self.assertGreater(int(quiet.read_text()), time.time() + 8)
        self.watcher('sleep', '/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)\n', ':')
        self.assertAlmostEqual(int(quiet.read_text()), time.time() + 8, delta=1.5)
        r = self.watcher('usb', 'UDEV [1.0] add /devices/usb1 (usb)\n', ':')
        self.assertEqual(r.stdout, '')
        quiet.write_text('malformed\n')
        r = self.watcher('usb', 'UDEV [1.0] add /devices/usb1 (usb)\n', ':')
        self.assertEqual(r.stdout.splitlines(), ['device-connect'])

    def test_duplicate_daemon_does_not_start_more_streams(self):
        self.hold_streams()
        first = self.start()
        self.wait_for(lambda: len(self.children()) == 6, 'first daemon streams did not start')
        second = self.start()
        self.wait_for(lambda: second.poll() is not None, 'duplicate daemon remained active')
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(len(self.children()), 6)
        self.assertIsNone(first.poll())

    def test_stop_cleans_watchers_and_releases_lock(self):
        self.hold_streams()
        daemon = self.start()
        self.wait_for(lambda: len(self.children()) == 6, 'streams did not start')
        pids = [int(line.split()[0]) for line in self.children()]
        daemon.terminate()
        daemon.communicate(timeout=5)
        self.wait_for(lambda: all(not Path(f'/proc/{pid}').exists() for pid in pids),
                      'stream processes leaked after daemon stop')
        again = self.start()
        self.wait_for(lambda: len(self.children()) == 12, 'daemon lock was held by a child')
        self.assertIsNone(again.poll())

    def test_failed_optional_stream_restarts_independently(self):
        self.hold_streams()
        self.fake('gdbus', 'if [[ "$*" == *login1* ]]; then echo attempt >> "$HOME/attempts"; exit 7; fi; '
                           'echo "$$ $0 $*" >> "$HOME/children"; exec sleep 60')
        daemon = self.start()
        attempts = self.home / 'attempts'
        self.wait_for(lambda: attempts.exists() and len(attempts.read_text().splitlines()) >= 2,
                      'failed stream was not retried')
        self.assertIsNone(daemon.poll(), 'optional stream stopped the whole daemon')
        self.assertEqual(len(self.children()), 5, 'healthy stream was restarted')
        daemon.terminate()
        _, errors = daemon.communicate(timeout=5)
        self.assertEqual(errors.count('Watcher sleep ended'), 1, errors)

    def test_dead_watcher_leader_does_not_leave_its_monitor_behind(self):
        self.hold_streams()
        daemon = self.start()
        self.wait_for(lambda: len(self.children()) == 6, 'streams did not start')
        old_line = next(line for line in self.children() if 'journalctl' in line)
        old_pid = int(old_line.split()[0])
        group = os.getpgid(old_pid)
        self.addCleanup(lambda: os.killpg(group, signal.SIGKILL)
                        if Path(f'/proc/{old_pid}').exists() else None)
        os.kill(group, signal.SIGKILL)
        self.wait_for(lambda: len(self.children()) >= 7, 'watcher was not restarted')
        self.wait_for(lambda: not Path(f'/proc/{old_pid}').exists(),
                      'old monitor survived its watcher replacement')
        self.assertIsNone(daemon.poll())

    def test_child_entry_rejects_uncontained_groups_and_reports_eof(self):
        (self.home / 'input').write_text('')
        r = subprocess.run(['bash', str(self.daemon), '--watch', 'lock'], env=self.env,
                           text=True, capture_output=True, timeout=3)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('isolated', r.stderr)
        p = self.start('--watch', 'lock')
        p.communicate(timeout=3)
        self.assertEqual(p.returncode, 1, 'EOF must remain a failure, not SIGTERM or success')
        p = self.start('--watch', 'not-a-watcher')
        p.communicate(timeout=3)
        self.assertEqual(p.returncode, 2)


if __name__ == '__main__':
    unittest.main()
