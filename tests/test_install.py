"""Packaging regression checks; all installs use temporary HOME and fake desktop tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='sounds-package-test-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.config = self.home / '.config'
        self.data = self.home / '.local/share'
        self.state = self.home / '.local/state'
        self.runtime = self.home / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.tools = self.home / 'tools'
        self.tools.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.config),
                        XDG_DATA_HOME=str(self.data), XDG_STATE_HOME=str(self.state),
                        XDG_RUNTIME_DIR=str(self.runtime), DBUS_SESSION_BUS_ADDRESS='unix:path=fake',
                        HYPRLAND_INSTANCE_SIGNATURE='test', BASH_ENV='',
                        PATH=f'{self.tools}:/usr/bin:/bin')
        for name in ('systemctl', 'hyprctl', 'Hyprland', 'omarchy', 'omarchy-shell', 'pw-play'):
            body = 'printf "%s %s\\n" "${0##*/}" "$*" >> "$HOME/calls"\n'
            if name == 'Hyprland':
                body += '[ "${VERIFY_FAIL:-0}" = 0 ] || exit 9\n'
            if name == 'hyprctl':
                body += '[ "$1" != reload ] || [ "${RELOAD_FAIL:-0}" = 0 ] || exit 9\n'
                body += '[ "$1" != configerrors ] || exit 0\n'
            if name == 'omarchy':
                body += ('if [[ "$*" == "plugin enable soundswap.sounds" && '
                         '"${OMARCHY_ENABLE_FAIL:-0}" = 1 ]]; then\n'
                         '  mkdir -p "$XDG_CONFIG_HOME/omarchy"\n'
                         '  printf \'{"plugins":[{"id":"soundswap.sounds"}]}\\n\' > '
                         '"$XDG_CONFIG_HOME/omarchy/shell.json"\n'
                         '  exit 9\n'
                         'fi\n')
            script = self.tools / name
            script.write_text('#!/bin/bash\n' + body)
            script.chmod(0o755)
        self.main = self.config / 'hypr/hyprland.lua'
        self.main.parent.mkdir(parents=True)
        self.main.write_text('keep_before = true\n')

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(ROOT / name), *args], env=self.env,
                              text=True, capture_output=True, timeout=20)

    def calls(self):
        path = self.home / 'calls'
        return path.read_text() if path.exists() else ''

    def test_install_preserves_values_and_assets_without_final_newline(self):
        conf = self.config / 'soundswap'
        (conf / 'sounds').mkdir(parents=True)
        (conf / 'config').write_text('CLICK=0')
        sound = conf / 'sounds/click.wav'
        sound.write_bytes(b'my sound')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CLICK=0\n', (conf / 'config').read_text())
        self.assertEqual(sound.read_bytes(), b'my sound')
        for file in ('common.sh', 'config.default', 'events.tsv'):
            self.assertTrue((self.data / 'soundswap' / file).is_file(), file)
        self.assertEqual((self.home / '.local/bin/soundswap-daemon').stat().st_mode & 0o777, 0o755)

    def test_install_keeps_spaced_user_settings(self):
        conf = self.config / 'soundswap'
        conf.mkdir(parents=True)
        (conf / 'config').write_text('  CLICK = 0\nVOLUME = .25\n')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = (conf / 'config').read_text()
        self.assertIn('  CLICK = 0\n', installed)
        self.assertNotIn('CLICK=1\n', installed)
        self.assertNotIn('VOLUME=0.6\n', installed)

    def test_malformed_markers_refused_before_install_or_uninstall(self):
        cases = (
            '-- soundswap >>>\nkeep_after = true\n',
            '-- <<< soundswap\n-- soundswap >>>\n',
            '-- soundswap >>>\n-- <<< soundswap\n-- soundswap >>>\n-- <<< soundswap\n',
        )
        for content in cases:
            self.main.write_text(content)
            for script in ('install.sh', 'uninstall.sh'):
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0, (script, content))
                self.assertEqual(self.main.read_text(), content)
                self.assertEqual(self.calls(), '')
                self.assertFalse((self.home / '.local/bin/soundswap').exists())

    def test_legacy_malformed_markers_refused_before_install_or_uninstall(self):
        for identity in ('beepboop', 'omarchy-sounds'):
            cases = (
                f'-- {identity} >>>\nkeep_after = true\n',
                f'-- <<< {identity}\n-- {identity} >>>\n',
                f'-- {identity} >>>\n-- <<< {identity}\n-- {identity} >>>\n-- <<< {identity}\n',
            )
            for content in cases:
                self.main.write_text(content)
                for script in ('install.sh', 'uninstall.sh'):
                    result = self.run_script(script)
                    self.assertNotEqual(result.returncode, 0, (script, content))
                    self.assertEqual(self.main.read_text(), content)
                    self.assertEqual(self.calls(), '')
                    self.assertFalse((self.home / '.local/bin/soundswap').exists())

    def test_unknown_arguments_refused_before_side_effects(self):
        for script in ('install.sh', 'uninstall.sh'):
            self.assertNotEqual(self.run_script(script, '--surprise').returncode, 0)
        self.assertNotEqual(self.run_script('uninstall.sh', '--purge', 'extra').returncode, 0)
        self.assertEqual(self.calls(), '')

    def test_missing_event_stream_tool_is_caught_before_changes(self):
        startup = self.home / 'hide-dbus-monitor.bash'
        startup.write_text('command() {\n'
                           '  if [[ ${1:-} == -v && ${2:-} == dbus-monitor ]]; then return 1; fi\n'
                           '  builtin command "$@"\n'
                           '}\n')
        self.env['BASH_ENV'] = str(startup)
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL: required command missing: dbus-monitor', result.stderr)
        self.assertIn('pacman -F dbus-monitor', result.stderr)
        self.assertIn('dbus-monitor', result.stderr)
        self.assertEqual(self.calls(), '')
        self.assertFalse((self.home / '.local/bin/soundswap').exists())

    def test_missing_optional_runtime_dependencies_warn_and_install_continues(self):
        startup = self.home / 'hide-optional-deps.bash'
        startup.write_text('command() {\n'
                           '  if [[ ${1:-} == -v ]]; then\n'
                           '    case ${2:-} in pw-play|paplay|mpv|omarchy-shell) return 1;; esac\n'
                           '  fi\n'
                           '  builtin command "$@"\n'
                           '}\n')
        self.env['BASH_ENV'] = str(startup)
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('WARN: no audio playback command found', result.stdout)
        self.assertIn('WARN: omarchy-shell is unavailable', result.stdout)
        self.assertIn('Fix:', result.stdout)
        self.assertTrue((self.home / '.local/bin/soundswap').is_file())

    def test_invalid_staged_config_changes_no_targets_or_services(self):
        self.env['VERIFY_FAIL'] = '1'
        original = self.main.read_bytes()
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertFalse((self.main.parent / 'soundswap.lua').exists())
        self.assertFalse((self.home / '.local/bin/soundswap').exists())
        self.assertNotIn('systemctl ', self.calls())
        self.assertNotIn('hyprctl reload', self.calls())

    def test_failed_live_reload_retains_working_beepboop_installation(self):
        self.main.write_text(
            'keep = true\n-- beepboop >>>\ndofile("/legacy/beepboop.lua")\n-- <<< beepboop\n')
        old_module = self.main.parent / 'beepboop.lua'
        old_module.write_text('legacy module\n')
        old_bin = self.home / '.local/bin/beepboop-play'
        old_bin.parent.mkdir(parents=True)
        old_bin.write_text('legacy player\n')
        old_conf = self.config / 'beepboop'
        old_conf.mkdir(parents=True)
        (old_conf / 'config').write_text('CLICK=0\n')
        self.env['RELOAD_FAIL'] = '1'

        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('/legacy/beepboop.lua', self.main.read_text())
        self.assertTrue(old_module.exists())
        self.assertTrue(old_bin.exists())
        self.assertTrue(old_conf.exists())
        self.assertFalse((self.config / 'soundswap').exists())

    def test_backups_cover_replaced_files_and_reload_follows_validation(self):
        files = [self.main,
                 self.main.parent / 'soundswap.lua',
                 self.config / 'soundswap/config',
                 self.config / 'systemd/user/soundswap.service',
                 self.config / 'omarchy/hooks/battery-low.d/soundswap',
                 self.config / 'omarchy/plugins/soundswap.sounds/Panel.qml',
                 self.config / 'omarchy/plugins/soundswap.sounds/soundswap.svg',
                 self.home / '.local/bin/soundswap']
        originals = {}
        for i, file in enumerate(files):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(f'-- original {i}\n' if file.suffix == '.lua' else f'# original {i}\n')
            originals[file] = file.read_bytes()
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list((self.state / 'soundswap/backups').rglob('*'))
        contents = [p.read_bytes() for p in backups if p.is_file()]
        for file, content in originals.items():
            self.assertIn(content, contents, str(file))
        calls = self.calls()
        self.assertLess(calls.index('Hyprland --verify-config'), calls.index('hyprctl reload'))
        self.assertNotIn('omarchy restart shell', calls)
        self.assertNotIn('stop soundswap-shutdown', calls)
        self.assertNotIn('restart soundswap-shutdown', calls)
        self.assertNotIn('disable --now', calls)

    def test_xdg_paths_and_shutdown_session_coupling(self):
        self.config = self.home / 'custom-config'
        self.data = self.home / 'custom-data'
        self.state = self.home / 'custom-state'
        self.env.update(XDG_CONFIG_HOME=str(self.config), XDG_DATA_HOME=str(self.data), XDG_STATE_HOME=str(self.state))
        self.main = self.config / 'hypr/hyprland.lua'
        self.main.parent.mkdir(parents=True)
        self.main.write_text('keep_before = true\n')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.main.parent / 'soundswap.lua').is_file())
        self.assertIn('dofile', self.main.read_text())
        plugin = self.config / 'omarchy/plugins/soundswap.sounds'
        self.assertTrue((plugin / 'Panel.qml').is_file())
        self.assertTrue((plugin / 'soundswap.svg').is_file())
        self.assertIn('Qt.resolvedUrl("soundswap.svg")', (plugin / 'Panel.qml').read_text())
        unit = (self.config / 'systemd/user/soundswap-shutdown.service').read_text()
        self.assertIn('PartOf=graphical-session.target', unit)
        self.assertIn('WantedBy=graphical-session.target', unit)
        self.assertIn('After=pipewire.service pipewire-pulse.service wireplumber.service pulseaudio.service', unit)
        self.assertIn('soundswap shutdown-stop', unit)
        self.assertIn('TimeoutStopSec=25', unit)
        self.assertIn(str(self.config), unit)
        self.assertIn(str(self.data), unit)
        self.assertIn('disable soundswap-shutdown.service', self.calls())

    def test_shutdown_menu_override_preserves_other_rows_and_uninstalls_cleanly(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        original = '{\n  "personal.notes": {"action": "open-notes"}\n}\n'
        menu.write_text(original)
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = menu.read_text()
        self.assertIn('"personal.notes": {"action": "open-notes"}', installed)
        self.assertIn('"action": "soundswap poweroff"', installed)
        self.assertIn('"system.logout": {"icon": "󰍃", "label": "Logout", "action": "soundswap logout"}', installed)
        self.assertIn('"system.reboot": {"icon": "󰜉", "label": "Reboot", "action": "soundswap reboot"}', installed)
        self.assertIn('"label": "Shutdown"', installed)
        self.assertIn('"icon": "󰐥"', installed)
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(menu.read_text(), original)

    def test_existing_user_reboot_action_is_preserved_when_upgrading_menu_block(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        original = ('{\n'
                    '  // soundswap shutdown >>>\n'
                    '  "system.shutdown": {"icon": "󰐥", "label": "Shutdown", "action": "soundswap poweroff"},\n'
                    '  // <<< soundswap shutdown\n'
                    '  "system.reboot": {"action": "my-reboot"}\n'
                    '}\n')
        menu.write_text(original)
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already customizes system.reboot', result.stderr)
        self.assertEqual(menu.read_text(), original)

    def test_duplicate_shutdown_menu_markers_abort_without_losing_user_rows(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        clean = '{\n  "personal.notes": {"action": "open-notes"}\n}\n'
        malformed = ('{\n'
                     '  // soundswap shutdown >>>\n'
                     '  "system.shutdown": {"action": "soundswap poweroff"},\n'
                     '  // <<< soundswap shutdown\n'
                     '  // soundswap shutdown >>>\n'
                     '  "personal.notes": {"action": "open-notes"},\n'
                     '  // <<< soundswap shutdown\n'
                     '}\n')
        menu.write_text(malformed)
        self.assertNotEqual(self.run_script('install.sh').returncode, 0)
        self.assertEqual(menu.read_text(), malformed)
        self.assertFalse((self.home / '.local/bin/soundswap').exists())

        menu.write_text(clean)
        self.assertEqual(self.run_script('install.sh').returncode, 0)
        menu.write_text(malformed)
        self.assertNotEqual(self.run_script('uninstall.sh').returncode, 0)
        self.assertEqual(menu.read_text(), malformed)
        self.assertTrue((self.home / '.local/bin/soundswap').exists())

    def test_legacy_shutdown_menu_is_replaced_during_migration(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        original = ('{\n'
                    '  // omarchy-sounds shutdown >>>\n'
                    '  "system.shutdown": {"action": "omarchy-sounds poweroff"},\n'
                    '  // <<< omarchy-sounds shutdown\n'
                    '  "personal.notes": {"action": "open-notes"}\n'
                    '}\n')
        menu.write_text(original)
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = menu.read_text()
        self.assertIn('"personal.notes": {"action": "open-notes"}', installed)
        self.assertIn('"action": "soundswap poweroff"', installed)
        self.assertNotIn('omarchy-sounds', installed)

    def test_beepboop_shutdown_menu_is_replaced_during_migration(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        menu.write_text('''{
  // beepboop shutdown >>>
  "system.shutdown": {"action": "beepboop poweroff"},
  // <<< beepboop shutdown
  "personal.notes": {"action": "open-notes"}
}
''')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = menu.read_text()
        self.assertIn('"action": "soundswap poweroff"', installed)
        self.assertNotIn('beepboop', installed)

    def test_legacy_hyprland_loaders_are_replaced_with_one_soundswap_block(self):
        for identity, module in (('beepboop', 'beepboop.lua'),
                                 ('omarchy-sounds', 'omarchy_sounds.lua')):
            self.main.write_text(
                f'keep_before = true\n-- {identity} >>>\n'
                f'dofile("/old/{module}")\n-- <<< {identity}\nkeep_after = true\n')
            result = self.run_script('install.sh')
            self.assertEqual(result.returncode, 0, result.stderr)
            installed = self.main.read_text()
            self.assertEqual(installed.count('-- soundswap >>>'), 1)
            self.assertEqual(installed.count('-- <<< soundswap'), 1)
            self.assertNotIn(f'-- {identity} >>>', installed)
            self.assertNotIn(f'/old/{module}', installed)
            self.assertIn('/hypr/soundswap.lua', installed)

    def test_reinstall_is_idempotent(self):
        self.assertEqual(self.run_script('install.sh').returncode, 0)
        first_main = self.main.read_bytes()
        first_menu = (self.config / 'omarchy/extensions/omarchy-menu.jsonc').read_bytes()
        self.assertEqual(self.run_script('install.sh').returncode, 0)
        self.assertEqual(self.main.read_bytes(), first_main)
        self.assertEqual((self.config / 'omarchy/extensions/omarchy-menu.jsonc').read_bytes(), first_menu)

    def test_shell_enable_failure_after_config_write_is_a_warning(self):
        self.env['OMARCHY_ENABLE_FAIL'] = '1'
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Widget enabling failed', result.stderr)
        self.assertIn('soundswap.sounds', (self.config / 'omarchy/shell.json').read_text())

    def test_uninstall_preserves_unrelated_files_and_data(self):
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.main.write_text(self.main.read_text() + 'keep_after = true\n\n')
        extras = [self.data / 'soundswap/custom.txt',
                  self.config / 'omarchy/plugins/soundswap.sounds/custom.qml',
                  self.config / 'soundswap/sounds/custom.wav']
        for file in extras:
            file.write_bytes(b'keep')
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(p.is_file() and p.read_bytes() == b'keep' for p in extras))
        self.assertTrue((self.config / 'soundswap/config').exists())
        self.assertIn('keep_after = true\n\n', self.main.read_text())
        self.assertNotIn('-- soundswap >>>', self.main.read_text())
        self.assertFalse((self.home / '.local/bin/soundswap').exists())
        self.assertFalse((self.data / 'soundswap/common.sh').exists())
        self.assertFalse((self.data / 'soundswap/original').exists())
        self.assertFalse((self.config / 'omarchy/plugins/soundswap.sounds/soundswap.svg').exists())

    def test_invalid_uninstall_validation_retains_installation(self):
        self.assertEqual(self.run_script('install.sh').returncode, 0)
        original = self.main.read_bytes()
        (self.home / 'calls').unlink()
        self.env['VERIFY_FAIL'] = '1'
        result = self.run_script('uninstall.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertTrue((self.home / '.local/bin/soundswap').exists())
        self.assertNotIn('systemctl ', self.calls())

    def test_uninstall_removes_legacy_only_markers(self):
        legacy = ('keep_before = true\n'
                  '-- omarchy-sounds >>>\n'
                  'dofile("/old/path.lua")\n'
                  '-- <<< omarchy-sounds\n'
                  'keep_after = true\n')
        self.main.write_text(legacy)
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        main = self.main.read_text()
        self.assertNotIn('-- omarchy-sounds', main)
        self.assertNotIn('-- <<< omarchy-sounds', main)
        self.assertIn('keep_before = true', main)
        self.assertIn('keep_after = true', main)

    def test_failed_validation_preserves_legacy_artifacts(self):
        old_conf = self.config / 'omarchy-sounds'
        (old_conf / 'sounds').mkdir(parents=True)
        (old_conf / 'config').write_text('CLICK=0\n')
        old_unit = self.config / 'systemd/user/omarchy-sounds.service'
        old_unit.parent.mkdir(parents=True)
        old_unit.write_text('legacy unit\n')
        old_bin = self.home / '.local/bin/omarchy-sounds'
        old_bin.parent.mkdir(parents=True)
        old_bin.write_text('#!/bin/bash\nlegacy\n')
        self.env['VERIFY_FAIL'] = '1'
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(old_conf.exists())
        self.assertTrue(old_unit.exists())
        self.assertTrue(old_bin.exists())
        self.assertFalse((self.config / 'soundswap').exists())
        self.assertFalse((self.home / '.local/bin/soundswap').exists())

    def test_stale_legacy_comments_replaced_while_preserving_settings(self):
        conf = self.config / 'soundswap'
        conf.mkdir(parents=True)
        (conf / 'config').write_text(
            '# Omarchy Sounds settings. Change with `omarchy-sounds` or the bar panel, or edit by hand.\n'
            'CLICK=0\n'
            '# Record every trigger to $XDG_RUNTIME_DIR/omarchy-sounds/events.log (omarchy-sounds log)\n'
            'LOG=1\n'
            '# User comment that should stay\n'
            'VOLUME=0.3\n')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = (conf / 'config').read_text()
        self.assertIn('# SoundSwap settings. Change with `soundswap` or the bar panel, or edit by hand.', installed)
        self.assertIn('# Record every trigger to $XDG_RUNTIME_DIR/soundswap/events.log (soundswap log)', installed)
        self.assertIn('# User comment that should stay', installed)
        self.assertIn('CLICK=0', installed)
        self.assertIn('LOG=1', installed)
        self.assertIn('VOLUME=0.3', installed)

    def test_legacy_paths_are_migrated_without_overwriting_new(self):
        old_conf = self.config / 'omarchy-sounds'
        (old_conf / 'sounds').mkdir(parents=True)
        (old_conf / 'config').write_text('CLICK=0\n')
        (old_conf / 'sounds/click.wav').write_bytes(b'legacy')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old_conf.exists())
        installed_config = (self.config / 'soundswap/config').read_text()
        self.assertIn('CLICK=0\n', installed_config)
        self.assertIn('ENABLED=1\n', installed_config)
        self.assertEqual((self.config / 'soundswap/sounds/click.wav').read_bytes(), b'legacy')

    def test_beepboop_upgrade_preserves_preferences_and_custom_sounds(self):
        old_conf = self.config / 'beepboop'
        (old_conf / 'sounds').mkdir(parents=True)
        (old_conf / 'config').write_text('ENABLED=0\nCLICK=0\nVOLUME=0.35\n')
        (old_conf / 'sounds/click.wav').write_bytes(b'curated-by-user')
        old_data = self.data / 'beepboop'
        old_data.mkdir(parents=True)
        (old_data / 'custom.txt').write_text('keep')
        old_state = self.state / 'beepboop'
        old_state.mkdir(parents=True)
        (old_state / 'state.txt').write_text('keep')

        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old_conf.exists())
        self.assertFalse(old_data.exists())
        self.assertFalse(old_state.exists())
        installed = self.config / 'soundswap'
        self.assertIn('ENABLED=0\n', (installed / 'config').read_text())
        self.assertIn('CLICK=0\n', (installed / 'config').read_text())
        self.assertIn('VOLUME=0.35\n', (installed / 'config').read_text())
        self.assertEqual((installed / 'sounds/click.wav').read_bytes(), b'curated-by-user')
        self.assertEqual((self.data / 'soundswap/custom.txt').read_text(), 'keep')
        self.assertEqual((self.state / 'soundswap/state.txt').read_text(), 'keep')

    def test_beepboop_integrations_are_retired_without_duplicate_services(self):
        unit_dir = self.config / 'systemd/user'
        unit_dir.mkdir(parents=True)
        for name in ('beepboop.service', 'beepboop-shutdown.service'):
            (unit_dir / name).write_text('legacy unit\n')
        binary_dir = self.home / '.local/bin'
        binary_dir.mkdir(parents=True)
        for name in ('beepboop', 'beepboop-play', 'beepboop-daemon'):
            (binary_dir / name).write_text('legacy binary\n')
        systemctl = self.tools / 'systemctl'
        systemctl.write_text(
            '#!/bin/bash\n'
            'printf "%s %s\\n" "${0##*/}" "$*" >> "$HOME/calls"\n'
            'if [[ "$1 $2" == "stop beepboop-shutdown.service" && '
            '-e "$HOME/.local/bin/beepboop-play" ]]; then echo chime >> "$HOME/chimes"; fi\n')
        systemctl.chmod(0o755)
        for event in ('battery-low', 'theme-set', 'post-update'):
            hook = self.config / f'omarchy/hooks/{event}.d/beepboop'
            hook.parent.mkdir(parents=True)
            hook.write_text('legacy hook\n')
        plugin = self.config / 'omarchy/plugins/beepboop.sounds'
        plugin.mkdir(parents=True)
        (plugin / 'Panel.qml').write_text('legacy panel\n')
        old_lua = self.config / 'hypr/beepboop.lua'
        old_lua.write_text('legacy lua\n')

        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('beepboop.service', 'beepboop-shutdown.service'):
            self.assertFalse((unit_dir / name).exists())
        for name in ('beepboop', 'beepboop-play', 'beepboop-daemon'):
            self.assertFalse((binary_dir / name).exists())
        self.assertFalse(plugin.exists())
        self.assertFalse(old_lua.exists())
        self.assertTrue((unit_dir / 'soundswap.service').exists())
        self.assertIn('stop beepboop-shutdown.service', self.calls())
        reset = next(line for line in self.calls().splitlines() if 'reset-failed' in line)
        self.assertIn('beepboop-shutdown.service', reset)
        self.assertFalse((self.home / 'chimes').exists())

    def test_original_pack_is_preserved_separately_from_customizable_copies(self):
        conf = self.config / 'soundswap/sounds'
        conf.mkdir(parents=True)
        (conf / 'click.wav').write_bytes(b'user-custom')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((conf / 'click.wav').read_bytes(), b'user-custom')
        original = self.data / 'soundswap/original/click.wav'
        self.assertTrue(original.is_file())
        self.assertNotEqual(original.read_bytes(), b'user-custom')

    def test_existing_custom_extension_is_not_shadowed_by_bundled_wav(self):
        conf = self.config / 'soundswap/sounds'
        conf.mkdir(parents=True)
        (conf / 'click.mp3').write_bytes(b'user-mp3')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((conf / 'click.mp3').read_bytes(), b'user-mp3')
        self.assertFalse((conf / 'click.wav').exists())
        self.assertTrue((self.data / 'soundswap/original/click.wav').is_file())

    def test_legacy_directory_symlinks_are_rejected_before_changes(self):
        target = self.home / 'outside'
        target.mkdir()
        for root, legacy in ((self.config, 'beepboop'), (self.data, 'beepboop'),
                             (self.state, 'beepboop'), (self.state, 'soundswap')):
            root.mkdir(parents=True, exist_ok=True)
            link = root / legacy
            link.symlink_to(target, target_is_directory=True)
            result = self.run_script('install.sh')
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(link.is_symlink())
            self.assertFalse((self.home / '.local/bin/soundswap').exists())
            link.unlink()

    def test_uninstall_rejects_symlinked_soundswap_state(self):
        target = self.home / 'outside'
        target.mkdir()
        self.state.mkdir(parents=True)
        (self.state / 'soundswap').symlink_to(target, target_is_directory=True)
        result = self.run_script('uninstall.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.state / 'soundswap').is_symlink())
        self.assertEqual(self.calls(), '')

    def test_new_paths_take_precedence_over_legacy_migration(self):
        old_conf = self.config / 'omarchy-sounds'
        (old_conf / 'sounds').mkdir(parents=True)
        (old_conf / 'config').write_text('CLICK=0\n')
        new_conf = self.config / 'soundswap'
        (new_conf / 'sounds').mkdir(parents=True)
        (new_conf / 'config').write_text('CLICK=1\n')
        (new_conf / 'sounds/click.wav').write_bytes(b'new')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(old_conf.exists())
        installed_config = (new_conf / 'config').read_text()
        self.assertIn('CLICK=1\n', installed_config)
        self.assertNotIn('CLICK=0\n', installed_config)
        self.assertEqual((new_conf / 'sounds/click.wav').read_bytes(), b'new')


if __name__ == '__main__':
    unittest.main()
