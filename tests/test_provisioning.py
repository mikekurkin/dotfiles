import json
from pathlib import Path
import tempfile
import unittest
from test_workflow import ROOT, load


class ProvisioningTests(unittest.TestCase):
    def test_loaded_old_job_shutdown_failure_preserves_registration(self):
        module = load(ROOT / 'scripts/provision.py')
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve(); calls = []
            old = home / 'Library/LaunchAgents/com.github.domt4.homebrew-autoupdate.plist'
            old.parent.mkdir(parents=True); old.write_text('old')
            (old.parent / 'net.kurkin.dotfiles.maintenance.plist').write_text('new')
            def runner(args):
                calls.append(args)
                return 0 if args[1] == 'print' else 5
            self.assertEqual(module.register_maintenance(home, runner), 1)
            self.assertTrue(old.exists())
            self.assertFalse(any(c[1] == 'bootstrap' for c in calls))

    def test_already_unloaded_old_job_can_be_archived(self):
        module = load(ROOT / 'scripts/provision.py')
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve(); calls = []
            old = home / 'Library/LaunchAgents/com.github.domt4.homebrew-autoupdate.plist'
            old.parent.mkdir(parents=True); old.write_text('old')
            (old.parent / 'net.kurkin.dotfiles.maintenance.plist').write_text('new')
            def runner(args):
                calls.append(args)
                return 0 if args[1] == 'bootstrap' or (args[1] == 'print' and args[2].count('/') == 1) else 3
            self.assertEqual(module.register_maintenance(home, runner), 0)
            self.assertTrue(any(c[1] == 'print' for c in calls))
            self.assertFalse(old.exists())

    def test_plugin_install_uses_exact_revision_and_repeats_without_deletion(self):
        module = load(ROOT / 'scripts/provision.py')
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve()
            calls = []
            manifest = [{'repository': 'https://github.com/example/plugin.git',
                         'revision': 'a' * 40, 'destination': '.local/share/plugin'}]
            runner = lambda args: calls.append(args) or 0
            self.assertEqual(module.install_plugins(manifest, home, runner), 0)
            self.assertIn(['git', '-C', str(home / '.local/share/plugin'), 'checkout', '--detach', 'a' * 40], calls)
            self.assertFalse(any('pull' in c or '--force' in c for c in calls))
            (home / '.local/share/plugin/.git').mkdir(parents=True)
            calls.clear()
            self.assertEqual(module.install_plugins(manifest, home, runner), 0)
            self.assertFalse(any('init' in c for c in calls))

    def test_plugin_destination_cannot_escape_home(self):
        module = load(ROOT / 'scripts/provision.py')
        with tempfile.TemporaryDirectory() as folder:
            calls = []
            self.assertEqual(module.install_plugins([{'repository': 'https://github.com/a/b.git',
                'revision': 'a' * 40, 'destination': '../escape'}], Path(folder), lambda args: calls.append(args)), 2)
            self.assertEqual(calls, [])

    def test_existing_non_repository_is_not_overwritten(self):
        module = load(ROOT / 'scripts/provision.py')
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve(); (home / 'plugin').mkdir()
            (home / 'plugin/important').write_text('preserve')
            calls = []
            self.assertEqual(module.install_plugins([{'repository': 'https://github.com/a/b.git',
                'revision': 'a' * 40, 'destination': 'plugin'}], home, lambda args: calls.append(args)), 1)
            self.assertEqual((home / 'plugin/important').read_text(), 'preserve')
            self.assertEqual(calls, [])

    def test_maintenance_registration_stops_old_job_before_new_job(self):
        module = load(ROOT / 'scripts/provision.py')
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve(); calls = []
            old = home / 'Library/LaunchAgents/com.github.domt4.homebrew-autoupdate.plist'
            old.parent.mkdir(parents=True); old.write_text('old')
            new = old.parent / 'net.kurkin.dotfiles.maintenance.plist';new.write_text('new')
            self.assertEqual(module.register_maintenance(home, lambda args: calls.append(args) or 0), 0)
            self.assertEqual(calls[0][1], 'bootout')
            self.assertEqual(calls[-1][1], 'bootstrap')
            self.assertTrue((home / '.local/state/dotfiles/disabled-agents'/old.name).exists())
            self.assertFalse(old.exists())


class PreferencesTests(unittest.TestCase):
    def test_read_failure_skips_import_and_continues_other_domains(self):
        module = load(ROOT / 'scripts/preferences.py')
        calls = []
        def read(domain):
            if domain == 'a':
                raise OSError('export failed')
            return {}
        self.assertEqual(module.apply_preferences({'a': {'x': 1}, 'b': {'x': 2}}, read,
            lambda domain, values: calls.append(domain) or 0), 1)
        self.assertEqual(calls, ['b'])

    def test_export_failure_is_not_an_empty_domain(self):
        module = load(ROOT / 'scripts/preferences.py')
        from unittest.mock import patch
        from subprocess import CompletedProcess
        with patch.object(module.subprocess, 'run', return_value=CompletedProcess([], 1, b'', b'failed')):
            with self.assertRaises(OSError):
                module.read_domain('existing')
        with patch.object(module.subprocess, 'run', return_value=CompletedProcess([], 0,
                module.plistlib.dumps({}), b'')):
            self.assertEqual(module.read_domain('absent'), {})

    def test_selected_values_merge_without_deleting_other_preferences(self):
        module = load(ROOT / 'scripts/preferences.py')
        calls = []
        self.assertEqual(module.apply_preferences({'domain': {'enabled': False, 'repeat': 2}},
            lambda domain: {'unmanaged': 'preserve', 'enabled': True},
            lambda domain, values: calls.append((domain, values)) or 0), 0)
        self.assertEqual(calls, [('domain', {'unmanaged': 'preserve', 'enabled': False, 'repeat': 2})])

    def test_unchanged_preferences_are_not_written(self):
        module = load(ROOT / 'scripts/preferences.py')
        calls = []
        self.assertEqual(module.apply_preferences({'domain': {'enabled': False}},
            lambda domain: {'enabled': False}, lambda *args: calls.append(args)), 0)
        self.assertEqual(calls, [])

    def test_nested_view_changes_preserve_unmanaged_settings(self):
        module = load(ROOT / 'scripts/preferences.py')
        current = {'StandardViewSettings': {
            'IconViewSettings': {'iconSize': 80},
            'ListViewSettings': {'calculateAllSizes': False, 'textSize': 13,
                'columns': {'size': {'visible': True},
                    'dateModified': {'ascending': True, 'width': 179}}}}}
        selected = {'StandardViewSettings': {'ListViewSettings': {
            'calculateAllSizes': True, 'sortColumn': 'dateModified',
            'columns': {'dateModified': {'ascending': False}}}}}
        calls = []
        self.assertEqual(module.apply_preferences({'finder': selected}, lambda _: current,
            lambda _, values: calls.append(values) or 0), 0)
        views = calls[0]['StandardViewSettings']
        self.assertEqual(views['IconViewSettings'], {'iconSize': 80})
        self.assertEqual(views['ListViewSettings'], {'calculateAllSizes': True,
            'sortColumn': 'dateModified', 'textSize': 13,
            'columns': {'size': {'visible': True},
                'dateModified': {'ascending': False, 'width': 179}}})
        self.assertFalse(current['StandardViewSettings']['ListViewSettings']['calculateAllSizes'])

    def test_unchanged_nested_selection_skips_repeat_import(self):
        module = load(ROOT / 'scripts/preferences.py')
        current = {'view': {'calculateAllSizes': True, 'textSize': 13}}
        calls = []
        self.assertEqual(module.apply_preferences({'finder': {'view': {'calculateAllSizes': True}}},
            lambda _: current, lambda *args: calls.append(args) or 0), 0)
        self.assertEqual(calls, [])

    def test_preference_failure_reported_and_other_domains_continue(self):
        module = load(ROOT / 'scripts/preferences.py')
        calls = []
        self.assertEqual(module.apply_preferences({'a': {'x': 1}, 'b': {'x': 2}}, lambda domain: {},
            lambda domain, values: calls.append(domain) or (1 if domain == 'a' else 0)), 1)
        self.assertEqual(calls, ['a', 'b'])


if __name__ == '__main__':
    unittest.main()
