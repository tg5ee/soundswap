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
                body += '[ "$1" != configerrors ] || exit 0\n'
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
        conf = self.config / 'beepboop'
        (conf / 'sounds').mkdir(parents=True)
        (conf / 'config').write_text('CLICK=0')
        sound = conf / 'sounds/click.wav'
        sound.write_bytes(b'my sound')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CLICK=0\n', (conf / 'config').read_text())
        self.assertEqual(sound.read_bytes(), b'my sound')
        for file in ('common.sh', 'config.default', 'events.tsv'):
            self.assertTrue((self.data / 'beepboop' / file).is_file(), file)
        self.assertEqual((self.home / '.local/bin/beepboop-daemon').stat().st_mode & 0o777, 0o755)

    def test_install_keeps_spaced_user_settings(self):
        conf = self.config / 'beepboop'
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
            '-- beepboop >>>\nkeep_after = true\n',
            '-- <<< beepboop\n-- beepboop >>>\n',
            '-- beepboop >>>\n-- <<< beepboop\n-- beepboop >>>\n-- <<< beepboop\n',
        )
        for content in cases:
            self.main.write_text(content)
            for script in ('install.sh', 'uninstall.sh'):
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0, (script, content))
                self.assertEqual(self.main.read_text(), content)
                self.assertEqual(self.calls(), '')
                self.assertFalse((self.home / '.local/bin/beepboop').exists())

    def test_legacy_malformed_markers_refused_before_install_or_uninstall(self):
        cases = (
            '-- omarchy-sounds >>>\nkeep_after = true\n',
            '-- <<< omarchy-sounds\n-- omarchy-sounds >>>\n',
            '-- omarchy-sounds >>>\n-- <<< omarchy-sounds\n-- omarchy-sounds >>>\n-- <<< omarchy-sounds\n',
        )
        for content in cases:
            self.main.write_text(content)
            for script in ('install.sh', 'uninstall.sh'):
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0, (script, content))
                self.assertEqual(self.main.read_text(), content)
                self.assertEqual(self.calls(), '')
                self.assertFalse((self.home / '.local/bin/beepboop').exists())

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
        self.assertIn('dbus-monitor', result.stderr)
        self.assertEqual(self.calls(), '')
        self.assertFalse((self.home / '.local/bin/beepboop').exists())

    def test_invalid_staged_config_changes_no_targets_or_services(self):
        self.env['VERIFY_FAIL'] = '1'
        original = self.main.read_bytes()
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertFalse((self.main.parent / 'beepboop.lua').exists())
        self.assertFalse((self.home / '.local/bin/beepboop').exists())
        self.assertNotIn('systemctl ', self.calls())
        self.assertNotIn('hyprctl reload', self.calls())

    def test_backups_cover_replaced_files_and_reload_follows_validation(self):
        files = [self.main,
                 self.main.parent / 'beepboop.lua',
                 self.config / 'beepboop/config',
                 self.config / 'systemd/user/beepboop.service',
                 self.config / 'omarchy/hooks/battery-low.d/beepboop',
                 self.config / 'omarchy/plugins/beepboop.sounds/Panel.qml',
                 self.config / 'omarchy/plugins/beepboop.sounds/beepboop.svg',
                 self.home / '.local/bin/beepboop']
        originals = {}
        for i, file in enumerate(files):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(f'-- original {i}\n' if file.suffix == '.lua' else f'# original {i}\n')
            originals[file] = file.read_bytes()
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list((self.state / 'beepboop/backups').rglob('*'))
        contents = [p.read_bytes() for p in backups if p.is_file()]
        for file, content in originals.items():
            self.assertIn(content, contents, str(file))
        calls = self.calls()
        self.assertLess(calls.index('Hyprland --verify-config'), calls.index('hyprctl reload'))
        self.assertNotIn('omarchy restart shell', calls)
        self.assertNotIn('stop beepboop-shutdown', calls)
        self.assertNotIn('restart beepboop-shutdown', calls)
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
        self.assertTrue((self.main.parent / 'beepboop.lua').is_file())
        self.assertIn('dofile', self.main.read_text())
        plugin = self.config / 'omarchy/plugins/beepboop.sounds'
        self.assertTrue((plugin / 'Panel.qml').is_file())
        self.assertTrue((plugin / 'beepboop.svg').is_file())
        self.assertIn('Qt.resolvedUrl("beepboop.svg")', (plugin / 'Panel.qml').read_text())
        unit = (self.config / 'systemd/user/beepboop-shutdown.service').read_text()
        self.assertIn('PartOf=graphical-session.target', unit)
        self.assertIn('WantedBy=graphical-session.target', unit)
        self.assertIn('After=pipewire.service pipewire-pulse.service wireplumber.service', unit)
        self.assertIn('beepboop shutdown-stop', unit)
        self.assertIn('TimeoutStopSec=25', unit)
        self.assertIn(str(self.config), unit)
        self.assertIn(str(self.data), unit)
        self.assertIn('disable beepboop-shutdown.service', self.calls())

    def test_shutdown_menu_override_preserves_other_rows_and_uninstalls_cleanly(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        original = '{\n  "personal.notes": {"action": "open-notes"}\n}\n'
        menu.write_text(original)
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = menu.read_text()
        self.assertIn('"personal.notes": {"action": "open-notes"}', installed)
        self.assertIn('"action": "beepboop poweroff"', installed)
        self.assertIn('"label": "Shutdown"', installed)
        self.assertIn('"icon": "󰐥"', installed)
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(menu.read_text(), original)

    def test_duplicate_shutdown_menu_markers_abort_without_losing_user_rows(self):
        menu = self.config / 'omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        clean = '{\n  "personal.notes": {"action": "open-notes"}\n}\n'
        malformed = ('{\n'
                     '  // beepboop shutdown >>>\n'
                     '  "system.shutdown": {"action": "beepboop poweroff"},\n'
                     '  // <<< beepboop shutdown\n'
                     '  // beepboop shutdown >>>\n'
                     '  "personal.notes": {"action": "open-notes"},\n'
                     '  // <<< beepboop shutdown\n'
                     '}\n')
        menu.write_text(malformed)
        self.assertNotEqual(self.run_script('install.sh').returncode, 0)
        self.assertEqual(menu.read_text(), malformed)
        self.assertFalse((self.home / '.local/bin/beepboop').exists())

        menu.write_text(clean)
        self.assertEqual(self.run_script('install.sh').returncode, 0)
        menu.write_text(malformed)
        self.assertNotEqual(self.run_script('uninstall.sh').returncode, 0)
        self.assertEqual(menu.read_text(), malformed)
        self.assertTrue((self.home / '.local/bin/beepboop').exists())

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
        self.assertIn('"action": "beepboop poweroff"', installed)
        self.assertNotIn('omarchy-sounds', installed)

    def test_uninstall_preserves_unrelated_files_and_data(self):
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.main.write_text(self.main.read_text() + 'keep_after = true\n\n')
        extras = [self.data / 'beepboop/custom.txt',
                  self.config / 'omarchy/plugins/beepboop.sounds/custom.qml',
                  self.config / 'beepboop/sounds/custom.wav']
        for file in extras:
            file.write_bytes(b'keep')
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(p.is_file() and p.read_bytes() == b'keep' for p in extras))
        self.assertTrue((self.config / 'beepboop/config').exists())
        self.assertIn('keep_after = true\n\n', self.main.read_text())
        self.assertNotIn('-- beepboop >>>', self.main.read_text())
        self.assertFalse((self.home / '.local/bin/beepboop').exists())
        self.assertFalse((self.data / 'beepboop/common.sh').exists())
        self.assertFalse((self.config / 'omarchy/plugins/beepboop.sounds/beepboop.svg').exists())

    def test_invalid_uninstall_validation_retains_installation(self):
        self.assertEqual(self.run_script('install.sh').returncode, 0)
        original = self.main.read_bytes()
        (self.home / 'calls').unlink()
        self.env['VERIFY_FAIL'] = '1'
        result = self.run_script('uninstall.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertTrue((self.home / '.local/bin/beepboop').exists())
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
        self.assertFalse((self.config / 'beepboop').exists())
        self.assertFalse((self.home / '.local/bin/beepboop').exists())

    def test_stale_legacy_comments_replaced_while_preserving_settings(self):
        conf = self.config / 'beepboop'
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
        self.assertIn('# BeepBoop settings. Change with `beepboop` or the bar panel, or edit by hand.', installed)
        self.assertIn('# Record every trigger to $XDG_RUNTIME_DIR/beepboop/events.log (beepboop log)', installed)
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
        installed_config = (self.config / 'beepboop/config').read_text()
        self.assertIn('CLICK=0\n', installed_config)
        self.assertIn('ENABLED=1\n', installed_config)
        self.assertEqual((self.config / 'beepboop/sounds/click.wav').read_bytes(), b'legacy')

    def test_new_paths_take_precedence_over_legacy_migration(self):
        old_conf = self.config / 'omarchy-sounds'
        (old_conf / 'sounds').mkdir(parents=True)
        (old_conf / 'config').write_text('CLICK=0\n')
        new_conf = self.config / 'beepboop'
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
