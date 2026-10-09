"""Run with python3 -m unittest discover -s tests -v. Never uses desktop audio."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.conf = self.home / '.config/soundswap'
        (self.conf / 'sounds').mkdir(parents=True)
        self.cfg = self.conf / 'config'
        self.cfg.write_text((ROOT / 'config.default').read_text())
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.runtime = self.home / 'run'
        self.runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_DATA_HOME=str(self.home / '.local/share'), XDG_RUNTIME_DIR=str(self.runtime),
                        PATH=f'{self.bin}:{ROOT / "bin"}:/usr/bin:/bin')
        self.backend('printf "%s\\n" "$@" >> "$HOME/played"')

    def backend(self, body):
        player = self.bin / 'pw-play'
        player.write_text('#!/bin/bash\n' + body + '\n')
        player.chmod(0o755)

    def run_cmd(self, name, *args):
        return subprocess.run(['bash', str(ROOT / 'bin' / name), *args], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def cli(self, *args):
        return self.run_cmd('soundswap', *args)

    def doctor_setup(self, plugin_enabled=True, bar_registered=True, loader=True,
                     missing_lifecycle=()):
        omarchy = self.conf.parent / 'omarchy'
        plugin = omarchy / 'plugins/soundswap.sounds'
        plugin.mkdir(parents=True)
        (plugin / 'manifest.json').write_text((ROOT / 'plugin/manifest.json').read_text())
        (plugin / 'Panel.qml').write_text('')
        (plugin / 'soundswap.svg').write_text('')
        layout_id = '{"id": "soundswap.sounds"}' if bar_registered else '{"id": "omarchy.tray"}'
        (omarchy / 'shell.json').write_text('{"bar":{"layout":{"right":[' + layout_id + ']}}}\n')
        listing = '[{"id":"soundswap.sounds","kinds":["bar-widget"],"enabled":' + str(plugin_enabled).lower() + '}]'
        self.fake('omarchy-shell', f'printf \'%s\\n\' \'{listing}\'')
        for lifecycle in ('shutdown', 'reboot', 'logout'):
            if lifecycle not in missing_lifecycle:
                self.fake(f'omarchy-system-{lifecycle}', 'exit 0')
        hypr = self.conf.parent / 'hypr'
        hypr.mkdir()
        module = hypr / 'soundswap.lua'
        module.write_text('')
        main = hypr / 'hyprland.lua'
        main.write_text('dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/soundswap.lua")\n' if loader else '-- no SoundSwap loader\n')
        menu = omarchy / 'extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        menu.write_text('{\n  // soundswap shutdown >>>\n'
                        '  "system.logout": {"action": "soundswap logout"},\n'
                        '  "system.reboot": {"action": "soundswap reboot"},\n'
                        '  "system.shutdown": {"action": "soundswap poweroff"},\n'
                        '  // <<< soundswap shutdown\n}\n')
        units = self.conf.parent / 'systemd/user'
        units.mkdir(parents=True)
        for unit in ('soundswap.service', 'soundswap-shutdown.service'):
            (units / unit).write_text('')
        self.fake('systemctl', 'printf "%s\\n" "$*" >> "$HOME/systemctl.calls"\ncase "$*" in "--user show-environment"|"--user is-enabled --quiet soundswap.service"|"--user is-enabled --quiet soundswap-shutdown.service") exit 0;; esac\nexit 1')

    def fake(self, name, body):
        script = self.bin / name
        script.write_text('#!/bin/bash\n' + body + '\n')
        script.chmod(0o755)

    def test_poweroff_plays_before_stock_command_and_skips_stop_duplicate(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/order"')
        stock = self.bin / 'omarchy-system-shutdown'
        stock.write_text('#!/bin/bash\nprintf "poweroff\\n" >> "$HOME/order"\n')
        stock.chmod(0o755)
        logger = self.bin / 'logger'
        logger.write_text('#!/bin/bash\nexit 0\n')
        logger.chmod(0o755)

        result = self.cli('poweroff')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'order').read_text().splitlines(), ['played', 'poweroff'])
        result = self.cli('shutdown-stop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'order').read_text().splitlines(), ['played', 'poweroff'])

    def test_shutdown_stop_falls_back_without_early_playback(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/order"')
        result = self.cli('shutdown-stop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'order').read_text(), 'played\n')

    def test_failed_poweroff_clears_early_playback_marker(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/order"')
        stock = self.bin / 'omarchy-system-shutdown'
        stock.write_text('#!/bin/bash\nexit 7\n')
        stock.chmod(0o755)
        logger = self.bin / 'logger'
        logger.write_text('#!/bin/bash\nexit 0\n')
        logger.chmod(0o755)

        self.assertEqual(self.cli('poweroff').returncode, 7)
        self.assertEqual(self.cli('shutdown-stop').returncode, 0)
        self.assertEqual((self.home / 'order').read_text().splitlines(), ['played', 'played'])

    def test_reboot_and_logout_play_before_original_omarchy_actions(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/order"')
        for action, command in (('reboot', 'omarchy-system-reboot'),
                                ('logout', 'omarchy-system-logout')):
            stock = self.bin / command
            stock.write_text(f'#!/bin/bash\nprintf "{action}\\n" >> "$HOME/order"\n')
            stock.chmod(0o755)
            result = self.cli(action)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'order').read_text().splitlines(),
                         ['played', 'reboot', 'played', 'logout'])

    def test_reboot_and_logout_continue_when_audio_fails(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('exit 7')
        for action, command in (('reboot', 'omarchy-system-reboot'),
                                ('logout', 'omarchy-system-logout')):
            stock = self.bin / command
            stock.write_text(f'#!/bin/bash\nprintf "{action}\\n" >> "$HOME/order"\n')
            stock.chmod(0o755)
            result = self.cli(action)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'order').read_text().splitlines(), ['reboot', 'logout'])

    def test_reboot_and_logout_preserve_stop_fallback_and_suppress_duplicates(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/order"')
        for action, command in (('reboot', 'omarchy-system-reboot'),
                                ('logout', 'omarchy-system-logout')):
            stock = self.bin / command
            stock.write_text(f'#!/bin/bash\nprintf "{action}\\n" >> "$HOME/order"\n')
            stock.chmod(0o755)
            result = self.cli(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.cli('shutdown-stop')
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / 'order').read_text().splitlines(),
                         ['played', 'reboot', 'played', 'logout'])

    def test_poweroff_waits_for_overlapping_shutdown_playback(self):
        (self.conf / 'sounds/shutdown.wav').touch()
        self.backend('printf "start\\n" >> "$HOME/order"; sleep 0.6; printf "end\\n" >> "$HOME/order"')
        stock = self.bin / 'omarchy-system-shutdown'
        stock.write_text('#!/bin/bash\nprintf "poweroff\\n" >> "$HOME/order"\n')
        stock.chmod(0o755)
        logger = self.bin / 'logger'
        logger.write_text('#!/bin/bash\nexit 0\n')
        logger.chmod(0o755)

        first = subprocess.Popen(['bash', str(ROOT / 'bin/soundswap-play'), '--wait', 'shutdown'],
                                 env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: first.poll() is None and first.kill())
        for _ in range(100):
            if (self.home / 'order').exists():
                break
            time.sleep(0.01)
        self.assertTrue((self.home / 'order').exists())
        result = self.cli('poweroff')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first.wait(timeout=3), 0)
        self.assertEqual((self.home / 'order').read_text().splitlines(),
                         ['start', 'end', 'start', 'end', 'poweroff'])

    def test_config_is_data_and_bad_values_fall_back(self):
        self.cfg.write_text('VOLUME=9\nENABLED=bad\ntouch "$HOME/executed"\n')
        r = self.cli('json')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.home / 'executed').exists())
        self.assertEqual(json.loads(r.stdout)['volume'], 0.6)
        self.assertTrue(json.loads(r.stdout)['enabled'])
        self.assertEqual(json.loads(r.stdout)['pack'], 'SoundSwap Original')

    def test_empty_missing_and_decimal_config(self):
        for content in ('', 'VOLUME=.6\n'):
            self.cfg.write_text(content)
            self.assertEqual(json.loads(self.cli('json').stdout)['volume'], 0.6)
        self.cfg.unlink()
        self.assertEqual(json.loads(self.cli('json').stdout)['volume'], 0.6)
        self.assertEqual(self.cli('off').returncode, 0)
        self.assertFalse(json.loads(self.cli('json').stdout)['enabled'])

    def test_setting_change_rejects_poisoned_config_lock(self):
        victim = self.home / 'private.txt'
        victim.write_text('keep this data')
        (self.conf / 'config.lock').symlink_to(victim)
        result = self.cli('off')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), 'keep this data')
        self.assertIn('ENABLED=1', self.cfg.read_text())

    def test_setting_change_rejects_fifo_lock_without_blocking(self):
        os.mkfifo(self.conf / 'config.lock')
        result = self.cli('off')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unsafe settings lock file', result.stderr)
        self.assertIn('ENABLED=1', self.cfg.read_text())

    def test_setting_change_detects_lock_replaced_during_acquisition(self):
        victim = self.home / 'private.txt'
        victim.write_text('keep this data')
        self.fake('flock', 'if [[ "$*" == "-w 5 9" ]]; then\n'
                  '  rm -- "$XDG_CONFIG_HOME/soundswap/config.lock"\n'
                  '  ln -s "$HOME/private.txt" "$XDG_CONFIG_HOME/soundswap/config.lock"\n'
                  'fi')
        result = self.cli('off')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Settings lock changed while opening', result.stderr)
        self.assertEqual(victim.read_text(), 'keep this data')
        self.assertIn('ENABLED=1', self.cfg.read_text())

    def test_parallel_updates_are_not_lost(self):
        self.cfg.write_text(self.cfg.read_text() + '# padding\n' * 10000)
        commands = [('off',), ('disable', 'click'), ('volume', '0.35'), ('disable', 'workspace')]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda args: self.cli(*args), commands))
        self.assertTrue(all(r.returncode == 0 for r in results))
        state = json.loads(self.cli('json').stdout)
        self.assertFalse(state['enabled'])
        self.assertEqual(state['volume'], 0.35)
        states = {e['id']: e['enabled'] for e in state['events']}
        self.assertFalse(states['click'])
        self.assertFalse(states['workspace'])

    def test_write_failure_is_reported(self):
        self.cfg.unlink()
        self.cfg.mkdir()
        result = self.cli('off')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Sounds off', result.stdout)

    def test_volume_and_event_validation(self):
        (self.conf / 'sounds/click.wav').touch()
        self.cfg.write_text('VOLUME=9\n')
        r = self.run_cmd('soundswap-play', '--wait', 'click')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('0.6', (self.home / 'played').read_text().splitlines())
        self.assertNotEqual(self.run_cmd('soundswap-play', '--wait', '../escape').returncode, 0)

    def test_per_event_gain_multiplies_master_and_is_validated(self):
        (self.conf / 'sounds/click.wav').touch()
        self.cfg.write_text('VOLUME=0.6\nCLICK_VOLUME=0.5\n')
        self.assertEqual(self.run_cmd('soundswap-play', '--wait', 'click').returncode, 0)
        self.assertIn('0.3', (self.home / 'played').read_text().splitlines())
        self.assertEqual(self.cli('event-volume', 'click', '0.25').returncode, 0)
        state = json.loads(self.cli('json').stdout)
        self.assertEqual(next(e for e in state['events'] if e['id'] == 'click')['volume'], 0.25)
        self.assertNotEqual(self.cli('event-volume', 'click', '2').returncode, 0)

    def test_json_escapes_control_characters_in_paths(self):
        self.env['XDG_CONFIG_HOME'] = str(self.home / 'quote"and\nnewline\ttab')
        state = json.loads(self.cli('json').stdout)
        self.assertEqual(state['dir'], self.env['XDG_CONFIG_HOME'] + '/soundswap/sounds')

    def test_disabled_and_missing_events_stay_silent(self):
        (self.conf / 'sounds/click.wav').touch()
        self.cfg.write_text('CLICK=0\n')
        self.assertEqual(self.run_cmd('soundswap-play', '--wait', 'click').returncode, 0)
        self.assertEqual(self.run_cmd('soundswap-play', '--wait', 'workspace').returncode, 0)
        self.assertFalse((self.home / 'played').exists())
        self.assertEqual(self.run_cmd('soundswap-play', '--wait', '--force', 'click').returncode, 0)
        self.assertTrue((self.home / 'played').exists())

    def test_playback_failure_is_logged(self):
        (self.conf / 'sounds/click.wav').touch()
        self.cfg.write_text('LOG=1\n')
        self.backend('echo decoder-error >&2; exit 7')
        r = self.run_cmd('soundswap-play', '--wait', 'click')
        self.assertNotEqual(r.returncode, 0)
        log = (self.runtime / 'soundswap/events.log').read_text()
        self.assertIn('click', log)
        self.assertIn('failed', log)
        self.assertIn('7', log)

    def test_same_event_storm_is_bounded_other_event_can_play(self):
        for event in ('click', 'notification-critical'):
            (self.conf / f'sounds/{event}.wav').touch()
        self.backend('printf "%s\\n" "${@: -1}" >> "$HOME/played"; sleep 0.5')
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(lambda e: self.run_cmd('soundswap-play', '--wait', e),
                          ['click'] * 10 + ['notification-critical']))
        played = (self.home / 'played').read_text().splitlines()
        self.assertEqual(sum(p.endswith('/click.wav') for p in played), 1)
        self.assertEqual(sum(p.endswith('/notification-critical.wav') for p in played), 1)

    def test_unknown_commands_and_log_arguments_fail(self):
        unknown = self.cli('enabel', 'click')
        self.assertNotEqual(unknown.returncode, 0)
        bad_log = subprocess.run(
            ['timeout', '1', 'bash', str(ROOT / 'bin/soundswap'), 'log', 'banana'],
            env=self.env, text=True, capture_output=True, timeout=3)
        self.assertEqual(bad_log.returncode, 2, bad_log.stderr)

    def test_doctor_reports_missing_and_disabled_integrations(self):
        self.doctor_setup(plugin_enabled=False, bar_registered=False, loader=False)
        result = self.cli('doctor')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('FAIL: bar widget is not registered in', result.stdout)
        self.assertIn('FAIL: bar widget is disabled', result.stdout)
        self.assertIn('FAIL: Hyprland loader', result.stdout)
        self.assertIn('omarchy plugin enable soundswap.sounds', result.stdout)

    def test_doctor_passes_with_installed_integrations(self):
        self.doctor_setup()
        result = self.cli('doctor')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS: Omarchy plugin registry reports the SoundSwap widget enabled', result.stdout)
        self.assertIn('PASS: user service enabled: soundswap.service', result.stdout)
        self.assertIn('WARN: no PipeWire or PulseAudio user service is active', result.stdout)

    def test_doctor_warns_when_reboot_or_logout_helpers_are_missing(self):
        self.doctor_setup(missing_lifecycle=('reboot', 'logout'))
        utility_bin = self.home / 'doctor-utilities'
        utility_bin.mkdir()
        for tool in ('bash', 'flock', 'setsid', 'timeout', 'journalctl', 'dbus-monitor',
                     'gdbus', 'udevadm', 'awk', 'cp', 'mv', 'mkdir', 'mktemp', 'stat',
                     'date', 'sleep', 'ps', 'rm', 'tail', 'readlink', 'dirname', 'grep',
                     'chmod', 'touch'):
            target = shutil.which(tool)
            if target:
                (utility_bin / tool).symlink_to(target)
        self.env['PATH'] = f'{self.bin}:{utility_bin}:{ROOT / "bin"}'
        result = self.cli('doctor')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('WARN: omarchy-system-reboot is unavailable', result.stdout)
        self.assertIn('WARN: omarchy-system-logout is unavailable', result.stdout)
        self.assertIn('PASS: Omarchy lifecycle command is available: omarchy-system-shutdown', result.stdout)

    def test_doctor_reports_missing_plugin_and_user_service_without_changes(self):
        self.doctor_setup()
        plugin = self.conf.parent / 'omarchy/plugins/soundswap.sounds'
        (plugin / 'Panel.qml').unlink()
        unit = self.conf.parent / 'systemd/user/soundswap.service'
        unit.unlink()
        before = {p: p.read_bytes() for p in self.conf.parent.rglob('*') if p.is_file()}
        result = self.cli('doctor')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('FAIL: plugin file missing: Panel.qml', result.stdout)
        self.assertIn('FAIL: user service file missing: soundswap.service', result.stdout)
        after = {p: p.read_bytes() for p in self.conf.parent.rglob('*') if p.is_file()}
        self.assertEqual(after, before)
        calls = (self.home / 'systemctl.calls').read_text().splitlines()
        self.assertTrue(all(call.startswith('--user show-environment') or
                            call.startswith('--user is-enabled --quiet') or
                            call.startswith('--user is-active --quiet') for call in calls), calls)

    def test_doctor_detects_missing_or_modified_lifecycle_menu_without_changes(self):
        self.doctor_setup()
        menu = self.conf.parent / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True, exist_ok=True)
        menu.write_text('{\n  // soundswap shutdown >>>\n'
                        '  "system.reboot": {"action": "other-reboot"},\n'
                        '  "system.shutdown": {"action": "soundswap poweroff"},\n'
                        '  // <<< soundswap shutdown\n}\n')
        before = menu.read_bytes()
        result = self.cli('doctor')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('FAIL: reboot menu action is modified', result.stdout)
        self.assertIn('soundswap reboot', result.stdout)
        self.assertIn('FAIL: logout menu action is missing', result.stdout)
        self.assertEqual(menu.read_bytes(), before)

    def test_doctor_accepts_multiline_jsonc_lifecycle_actions_without_changes(self):
        self.doctor_setup()
        menu = self.conf.parent / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.write_text('{\n  // soundswap shutdown >>>\n'
                        '  "system.logout": {\n    "action": "soundswap logout",\n    "label": "Logout"\n  },\n'
                        '  "system.reboot": {\n    "action": "soundswap reboot"\n  },\n'
                        '  "system.shutdown": {\n    "action": "soundswap poweroff"\n  },\n'
                        '  // <<< soundswap shutdown\n}\n')
        before = menu.read_bytes()
        result = self.cli('doctor')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS: shutdown menu action is configured: system.logout', result.stdout)
        self.assertIn('PASS: shutdown menu action is configured: system.reboot', result.stdout)
        self.assertIn('PASS: shutdown menu action is configured: system.shutdown', result.stdout)
        self.assertEqual(menu.read_bytes(), before)

    def test_doctor_does_not_match_action_from_neighboring_menu_entry(self):
        self.doctor_setup()
        menu = self.conf.parent / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.write_text('{\n  // soundswap shutdown >>>\n'
                        '  "system.logout": {"action": "soundswap logout"},\n'
                        '  "system.reboot": {}, "personal.other": {"action": "soundswap reboot"},\n'
                        '  "system.shutdown": {"action": "soundswap poweroff"},\n'
                        '  // <<< soundswap shutdown\n}\n')
        result = self.cli('doctor')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('FAIL: reboot menu action is modified', result.stdout)

    def test_status_shows_one_filename_for_present_sound(self):
        (self.conf / 'sounds/click.wav').touch()
        status = self.cli('status')
        self.assertEqual(status.returncode, 0, status.stderr)
        click_line = next(line for line in status.stdout.splitlines() if line.strip().startswith('click '))
        self.assertTrue(click_line.rstrip().endswith('click.wav'), click_line)
        self.assertNotIn('/', click_line)

    def test_preview_waits_for_same_event_instead_of_succeeding_silently(self):
        (self.conf / 'sounds/click.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/played"; sleep 0.4')
        first = subprocess.Popen(
            ['bash', str(ROOT / 'bin/soundswap-play'), '--wait', 'click'],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 2
            while not (self.home / 'played').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.home / 'played').exists())
            preview = self.run_cmd('soundswap-play', '--wait', '--force', 'click')
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertEqual((self.home / 'played').read_text().splitlines(), ['played', 'played'])
        finally:
            first.communicate(timeout=3)

    def test_two_intentional_clicks_can_play_while_first_tail_fades(self):
        (self.conf / 'sounds/click.wav').touch()
        self.backend('printf "played\\n" >> "$HOME/played"; sleep 0.4')
        first = subprocess.Popen(
            ['bash', str(ROOT / 'bin/soundswap-play'), '--wait', 'click'],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 2
            while not (self.home / 'played').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.home / 'played').exists())
            time.sleep(0.15)
            second = self.run_cmd('soundswap-play', '--wait', 'click')
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual((self.home / 'played').read_text().splitlines(), ['played', 'played'])
        finally:
            first.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
