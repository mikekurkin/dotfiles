#!/usr/bin/env python3
"""Install pinned plugins and register the declared maintenance job."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def install_plugins(manifest, home, runner):
    home = home.resolve()
    for item in manifest:
        destination = (home / item['destination']).resolve()
        if (home not in destination.parents or
                not re.fullmatch(r'https://github\.com/[\w.-]+/[\w.-]+\.git', item['repository']) or
                not re.fullmatch(r'[a-f0-9]{40}', item['revision'])):
            print('Unsafe plugin declaration', file=sys.stderr)
            return 2
    for item in manifest:
        destination = home / item['destination']
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() and not (destination / '.git').exists():
            print('Existing non-repository preserved:', destination, file=sys.stderr)
            return 1
        if not destination.exists() and runner(['git', 'init', str(destination)]):
            return 1
        commands = [
            ['git', '-C', str(destination), 'fetch', '--depth=1', item['repository'], item['revision']],
            ['git', '-C', str(destination), 'checkout', '--detach', item['revision']],
        ]
        for command in commands:
            if runner(command):
                return 1
    return 0


def register_maintenance(home, runner):
    domain = 'gui/' + str(os.getuid())
    old = home / 'Library/LaunchAgents/com.github.domt4.homebrew-autoupdate.plist'
    if old.exists():
        if runner(['launchctl', 'bootout', domain, str(old)]):
            if (runner(['launchctl', 'print', domain]) or
                    not runner(['launchctl', 'print', domain + '/com.github.domt4.homebrew-autoupdate'])):
                print('Could not confirm old maintenance job is unloaded; registration preserved.', file=sys.stderr)
                return 1
        backup = home / '.local/state/dotfiles/disabled-agents'
        backup.mkdir(parents=True, exist_ok=True, mode=0o700)
        old.replace(backup / old.name)
    new = home / 'Library/LaunchAgents/net.kurkin.dotfiles.maintenance.plist'
    if not new.exists():
        print('Apply configuration before registering maintenance.', file=sys.stderr)
        return 1
    if runner(['launchctl', 'bootout', domain, str(new)]):
        if (runner(['launchctl', 'print', domain]) or
                not runner(['launchctl', 'print', domain + '/net.kurkin.dotfiles.maintenance'])):
            print('Could not unload existing maintenance job.', file=sys.stderr)
            return 1
    return runner(['launchctl', 'bootstrap', domain, str(new)])


def main():
    root = Path(__file__).resolve().parents[1]
    home = Path.home()
    runner = lambda args: subprocess.run(args, check=False).returncode
    if len(sys.argv) != 2:
        return 2
    if sys.argv[1] == 'plugins':
        if install_plugins(json.loads((root / 'plugins.lock.json').read_text()), home, runner):
            return 1
        for tool in (home / '.config/dotfiles/uv-tools.txt').read_text().splitlines():
            if tool and not tool.startswith('#') and runner(['uv', 'tool', 'install', '--python', '3.14', tool]):
                return 1
        return 0
    if sys.argv[1] == 'editors':
        for extension in (home / '.config/dotfiles/vscode-extensions.txt').read_text().splitlines():
            if extension and runner(['code', '--install-extension', extension]):
                return 1
        print('VS Code extensions installed. Optional Zed extensions are listed in ~/.config/dotfiles/zed-extensions.txt.')
        return 0
    if sys.argv[1] == 'maintenance':
        return register_maintenance(home, runner)
    if sys.argv[1] == 'agents':
        for repo in ['anthropics/claude-plugins-official', 'mattpocock/skills', 'nextlevelbuilder/ui-ux-pro-max-skill']:
            if runner(['claude', 'plugin', 'marketplace', 'add', repo]):
                return 1
        for name in ['superpowers@claude-plugins-official', 'mattpocock-skills@mattpocock', 'ui-ux-pro-max@ui-ux-pro-max-skill']:
            if runner(['claude', 'plugin', 'install', name]):
                return 1
        print('Codex plugin sources are declared in ~/.codex/config.toml.')
        return 0
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
