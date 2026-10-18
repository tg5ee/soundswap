"""Marketplace readiness: root-level plugin payload, stable ID, and license scope."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = 'io.github.tg5ee.soundswap'
LEGACY_ID = 'soundswap.sounds'


class MarketplaceTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / 'manifest.json').read_text())

    def test_payload_lives_at_repo_root(self):
        for name in ('manifest.json', 'Panel.qml', 'soundswap.svg', 'preview.png', 'LICENSE'):
            self.assertTrue((ROOT / name).is_file(), name)
        self.assertFalse((ROOT / 'plugin').exists())

    def test_manifest_metadata(self):
        m = self.manifest
        self.assertEqual(m['id'], PLUGIN_ID)
        self.assertRegex(m['version'], r'^\d+\.\d+\.\d+$')
        self.assertEqual(m['license'], 'MIT')
        self.assertEqual(m['kinds'], ['bar-widget'])
        self.assertEqual(m['entryPoints']['barWidget'], 'Panel.qml')
        self.assertTrue((ROOT / m['entryPoints']['barWidget']).is_file())
        self.assertFalse(m['barWidget']['allowMultiple'])

    def test_panel_uses_manifest_id(self):
        panel = (ROOT / 'Panel.qml').read_text()
        self.assertEqual(re.findall(r'(?:moduleName|ipcTarget|target):\s*"([^"]+)"', panel),
                         [PLUGIN_ID] * 3)
        self.assertIn('Qt.resolvedUrl("soundswap.svg")', panel)

    def test_license_excludes_bundled_audio(self):
        text = (ROOT / 'LICENSE').read_text()
        self.assertTrue(text.startswith('MIT License'))
        self.assertIn('sounds/', text)
        self.assertIn('NOT licensed under the MIT License', text)

    def test_legacy_id_only_appears_as_migration_handling(self):
        allowed = {'install.sh', 'uninstall.sh', 'README.md', 'bin/soundswap',
                   'tests/test_install.py', 'tests/test_core.py', 'tests/test_marketplace.py'}
        for path in ROOT.rglob('*'):
            rel = path.relative_to(ROOT).as_posix()
            if (not path.is_file() or rel.startswith(('.git/', '.crush/', '.pytest_cache/', 'sounds/', 'docs/'))
                    or '__pycache__' in rel or path.suffix in {'.png', '.wav', '.pyc'}):
                continue
            if LEGACY_ID in path.read_text(errors='ignore'):
                self.assertIn(rel, allowed, f'{rel} still references {LEGACY_ID}')

    def test_installers_use_root_payload_and_new_id(self):
        install = (ROOT / 'install.sh').read_text()
        uninstall = (ROOT / 'uninstall.sh').read_text()
        self.assertNotIn('plugin/', install)
        self.assertIn(f'PLUGIN_ID={PLUGIN_ID}', install)
        self.assertIn(f'plugins/{PLUGIN_ID}"', uninstall)
        self.assertRegex(install, rf'OLD_PLUGIN_IDS=\({re.escape(LEGACY_ID)} ')
        self.assertRegex(uninstall, rf'OLD_PLUGIN_IDS=\({re.escape(LEGACY_ID)} ')

    def test_new_plugin_is_activated_before_old_ids_are_retired(self):
        install = (ROOT / 'install.sh').read_text()
        enable = install.index('omarchy plugin enable "$PLUGIN_ID" ||')
        retire = install.index('rm -rf -- "$CONFIG_ROOT/omarchy/plugins/$id"')
        self.assertLess(enable, retire)


if __name__ == '__main__':
    unittest.main()
