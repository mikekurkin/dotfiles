import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    spec = importlib.util.spec_from_file_location("workflow", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MaintenanceTests(unittest.TestCase):
    def test_binary_casks_require_installed_executable(self):
        binary = self.home / 'bin/codex'; binary.parent.mkdir()
        binary.write_text('#!/bin/sh\n'); binary.chmod(0o755)
        policy = {'formulae': [], 'installed_formulae': [], 'installed_casks': ['codex', 'missing'],
                  'casks': [{'token': 'codex', 'apps': [], 'binaries': [str(binary)], 'unattended': True},
                            {'token': 'missing', 'apps': [], 'binaries': [str(self.home / 'absent')], 'unattended': True}]}
        self.assertEqual(self.run_job(policy), 0)
        self.assertIn(['brew', 'upgrade', '--cask', '--greedy', 'codex'], self.calls)
        self.assertFalse(any('missing' in c for c in self.calls))

    def test_policy_read_failure_still_cleans_cache(self):
        module = load(ROOT / 'home/dot_local/share/dotfiles/executable_maintenance.py')
        def read():
            raise OSError('metadata unavailable')
        self.assertEqual(module.maintain(None, self.home, lambda args: self.calls.append(args) or 0,
                                        load_policy=read), 1)
        self.assertEqual(self.calls, [['brew', 'cleanup', '--prune=7']])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.calls = []

    def tearDown(self):
        self.temp.cleanup()

    def run_job(self, policy, failures=()):
        module = load(ROOT / "home/dot_local/share/dotfiles/executable_maintenance.py")
        def runner(args):
            self.calls.append(args)
            return 1 if any(x in failures for x in args) else 0
        return module.maintain(policy, self.home, runner)

    def test_only_declared_installed_packages_and_present_apps_upgrade(self):
        (self.home / "Demo.app").mkdir()
        policy = {"formulae": ["git"], "casks": [
            {"token": "demo", "apps": [str(self.home / "Demo.app")], "unattended": True},
            {"token": "missing", "apps": [str(self.home / "Missing.app")], "unattended": True},
            {"token": "privileged", "apps": [], "unattended": False}],
            "installed_formulae": ["git", "unrelated"], "installed_casks": ["demo", "missing", "privileged"]}
        self.assertEqual(self.run_job(policy), 0)
        self.assertIn(["brew", "upgrade", "--formula", "git"], self.calls)
        self.assertIn(["brew", "upgrade", "--cask", "--greedy", "demo"], self.calls)
        upgrades = [x for x in self.calls if "upgrade" in x]
        self.assertEqual(len(upgrades), 2)

    def test_failure_continues_and_cleanup_always_runs(self):
        policy = {"formulae": ["git", "jq"], "casks": [],
                  "installed_formulae": ["git", "jq"], "installed_casks": []}
        self.assertEqual(self.run_job(policy, failures=("git",)), 1)
        self.assertIn(["brew", "upgrade", "--formula", "jq"], self.calls)
        self.assertEqual(self.calls[-1], ["brew", "cleanup", "--prune=7"])

    def test_overlapping_job_does_not_run_brew(self):
        policy = {"formulae": [], "casks": [], "installed_formulae": [], "installed_casks": []}
        module = load(ROOT / "home/dot_local/share/dotfiles/executable_maintenance.py")
        import fcntl
        lock = self.home / ".local/state/dotfiles/maintenance.lock"
        lock.parent.mkdir(parents=True)
        with lock.open("w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(module.maintain(policy, self.home, lambda args: self.calls.append(args) or 0), 0)
        self.assertEqual(self.calls, [])

    def test_update_failure_still_cleans_cache(self):
        policy = {"formulae": ["git"], "casks": [], "installed_formulae": ["git"], "installed_casks": []}
        self.assertEqual(self.run_job(policy, failures=("update",)), 1)
        self.assertEqual(self.calls[-1], ["brew", "cleanup", "--prune=7"])
        self.assertFalse(any("upgrade" in x for x in self.calls))


class BootstrapTests(unittest.TestCase):
    def test_plan_invokes_no_mutating_commands(self):
        module = load(ROOT / "scripts/bootstrap.py")
        calls = []
        self.assertEqual(module.execute(ROOT, "plan", [], runner=lambda args: calls.append(args) or 0), 0)
        self.assertEqual(calls, [])

    def test_failed_phase_stops_and_can_be_repeated(self):
        module = load(ROOT / "scripts/bootstrap.py")
        calls = []
        self.assertEqual(module.execute(ROOT, "apply", ["configuration", "runtimes"],
                                       runner=lambda args: calls.append(args) or 1), 1)
        self.assertEqual(len(calls), 1)
        calls.clear()
        self.assertEqual(module.execute(ROOT, "apply", ["configuration"],
                                       runner=lambda args: calls.append(args) or 0), 0)
        self.assertEqual(len(calls), 1)

    def test_unknown_phase_rejected_before_side_effects(self):
        module = load(ROOT / "scripts/bootstrap.py")
        calls = []
        self.assertEqual(module.execute(ROOT, "apply", ["unknown"], runner=lambda args: calls.append(args)), 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
