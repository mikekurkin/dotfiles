#!/usr/bin/env python3
"""Explicit, repeatable provisioning. Importing this module has no side effects."""
from pathlib import Path
import argparse
import os
import subprocess
import sys

PHASES = ("packages", "configuration", "runtimes", "plugins", "editors", "preferences", "maintenance")


def execute(root, mode, phases, runner=None):
    runner = runner or (lambda args: subprocess.run(args, cwd=root, check=False).returncode)
    phases = phases or list(PHASES)
    if any(p not in PHASES and p not in ("app-store", "agents") for p in phases):
        print("Unknown phase", file=sys.stderr)
        return 2
    if mode == "plan":
        print("Target: macOS 27 on Apple Silicon. No changes made.")
        print("Phases:", ", ".join(phases))
        print("Prerequisites: Command Line Tools, Homebrew. Optional: App Store sign-in and private files.")
        print("Excluded: Fish, Ghostty, Cursor, Alfred, Raycast, TextMate, Sublime Text, Typora. Review docs/migration-report.md before applying.")
        return 0
    if mode != "apply":
        return 2
    commands = {
        "packages": ["brew", "bundle", "install", "--no-upgrade", "--file=" + str(root / "Brewfile")],
        "app-store": ["brew", "bundle", "install", "--no-upgrade", "--file=" + str(root / "Brewfile.mas")],
        "configuration": ["chezmoi", "--source", str(root), "apply"],
        "runtimes": ["mise", "install", "--cd", str(Path.home())],
        "plugins": [sys.executable, str(root / "scripts/provision.py"), "plugins"],
        "editors": [sys.executable, str(root / "scripts/provision.py"), "editors"],
        "preferences": [sys.executable, str(root / "scripts/preferences.py"), "--apply"],
        "agents": [sys.executable, str(root / "scripts/provision.py"), "agents"],
        "maintenance": [sys.executable, str(root / "scripts/provision.py"), "maintenance"],
    }
    for phase in phases:
        print("Phase:", phase, flush=True)
        code = runner(commands[phase])
        if code:
            print("Phase failed; rerun after resolving:", phase, file=sys.stderr)
            return code
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["plan", "apply"])
    parser.add_argument("phases", nargs="*")
    args = parser.parse_args()
    return execute(Path(__file__).resolve().parents[1], args.mode, args.phases)


if __name__ == "__main__":
    raise SystemExit(main())
