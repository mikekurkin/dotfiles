#!/usr/bin/env python3
"""Weekly maintenance of the declared, already installed package set."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys


def maintain(policy, home, runner, load_policy=None):
    state = home / ".local/state/dotfiles"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    failures = []
    with (state / "maintenance.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Maintenance already running; skipped.")
            return 0
        try:
            if load_policy is not None:
                policy = load_policy()
            if runner(["brew", "update"]):
                failures.append("brew update")
            else:
                formulae = set(policy["installed_formulae"])
                casks = set(policy["installed_casks"])
                for token in policy["formulae"]:
                    if token in formulae and runner(["brew", "upgrade", "--formula", token]):
                        failures.append(token)
                for cask in policy["casks"]:
                    token = cask["token"]
                    if token not in casks or not cask["unattended"]:
                        continue
                    paths = [Path(p.replace("$HOME", str(home))) for p in cask["apps"]]
                    binaries = [Path(p.replace("$HOME", str(home))) for p in cask.get("binaries", [])]
                    if (not paths and not binaries or not all(p.exists() for p in paths) or
                            not all(p.is_file() and os.access(p, os.X_OK) for p in binaries)):
                        print("Missing installed artifact; skipped:", token)
                        continue
                    if runner(["brew", "upgrade", "--cask", "--greedy", token]):
                        failures.append(token)
        except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            failures.append(type(error).__name__)
        finally:
            try:
                if runner(["brew", "cleanup", "--prune=7"]):
                    failures.append("cleanup")
            except OSError:
                failures.append("cleanup unavailable")
        print("Failures:" if failures else "Maintenance complete.", ", ".join(failures))
        return int(bool(failures))


def main():
    home = Path.home()
    env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_CLEANUP_MAX_AGE_DAYS="7",
               HOMEBREW_CLEANUP_PERIODIC_FULL_DAYS="1", HOMEBREW_NO_ANALYTICS="1",
               PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin")
    state = home / ".local/state/dotfiles"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    logfile = state / "maintenance.log"
    if logfile.exists() and logfile.stat().st_size > 2 * 1024 * 1024:
        for n in range(4, 0, -1):
            old = state / ("maintenance.log" if n == 1 else "maintenance.log." + str(n - 1))
            if old.exists():
                old.replace(state / ("maintenance.log." + str(n)))
    with logfile.open("a", buffering=1) as log:
        sys.stdout = sys.stderr = log
        print("Started:", datetime.datetime.now().isoformat())
        try:
            def load_policy():
                policy = json.loads((home / ".config/dotfiles/packages.json").read_text())
                for key, flag in [("installed_formulae", "--formula"), ("installed_casks", "--cask")]:
                    result = subprocess.run(["brew", "list", flag, "--full-name"], env=env,
                                            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
                    policy[key] = result.stdout.splitlines()
                return policy
            def runner(args):
                print("Running:", " ".join(args))
                return subprocess.run(args, env=env, stdin=subprocess.DEVNULL,
                                      stdout=log, stderr=log).returncode
            return maintain(None, home, runner, load_policy=load_policy)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print("Maintenance failed:", type(error).__name__)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
