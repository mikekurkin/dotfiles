#!/usr/bin/env python3
"""Validate repository and render into a disposable home; never provision the live Mac."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


def parse_jsonc(text):
    # Tokenize strings first so URL slashes and literal comments are preserved.
    token = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)
    text = token.sub(lambda m: m[0] if m[0].startswith('"') else '', text)
    token = re.compile(r'"(?:\\.|[^"\\])*"|,(\s*[}\]])', re.S)
    text = token.sub(lambda m: m[0] if m[0].startswith('"') else m[1], text)
    return json.loads(text)


def check_packages(policy):
    retired = {'fish', 'fisher', 'ghostty', 'cursor', 'alfred',
               'raycast', 'textmate', 'sublime-text', 'typora'}
    names = policy['formulae'] + [x['token'] for x in policy['casks']]
    return ['Retired package: ' + name for name in names if name.split('/')[-1] in retired]


def check_secrets(root):
    pattern = re.compile(r'(?:-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,})')
    issues = []
    for p in root.rglob('*'):
        if p.is_file() and not p.is_symlink() and pattern.search(p.read_text(errors='ignore')):
            issues.append('Potential credential in ' + str(p.relative_to(root)))
    return issues


def validate_rendered(destination):
    import tomllib
    issues = []
    for p in destination.rglob('*'):
        if not p.is_file():
            continue
        try:
            text = p.read_text()
        except UnicodeDecodeError:
            continue
        try:
            if p.suffix in ['.json', '.code-snippets', '.sublime-settings', '.sublime-keymap']:
                parse_jsonc(text)
            elif p.suffix == '.toml':
                tomllib.loads(text)
            elif p.suffix == '.plist':
                plistlib.loads(p.read_bytes())
        except Exception as error:
            issues.append('Invalid ' + str(p.relative_to(destination)) + ': ' + type(error).__name__)
        if '/Users/mk' in text:
            issues.append('Unrendered home path: ' + str(p.relative_to(destination)))
    for p in destination.rglob('*'):
        if p.is_symlink() and not p.exists():
            issues.append('Broken symlink: ' + str(p.relative_to(destination)))
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chezmoi', default='chezmoi')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    issues = check_secrets(root / 'home')
    policy = json.loads((root / 'home/dot_config/dotfiles/packages.json').read_text())
    issues += check_packages(policy)
    brewfile = (root / 'Brewfile').read_text()
    formulae = re.findall(r'^brew "([^"]+)"', brewfile, re.M)
    casks = re.findall(r'^cask "([^"]+)"', brewfile, re.M)
    if formulae != policy['formulae'] or casks != [x['token'] for x in policy['casks']]:
        issues.append('Brewfile and maintenance manifest differ')
    for p in (root / 'scripts').glob('*.py'):
        try:
            compile(p.read_text(), str(p), 'exec')
        except SyntaxError:
            issues.append('Python syntax: ' + p.name)
    if subprocess.run(['bash', '-n', str(root / 'install')]).returncode:
        issues.append('Installer syntax')
    tests = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(root / 'tests')],
                           cwd=root, capture_output=True, text=True)
    if tests.returncode:
        print(tests.stderr)
        issues.append('Behavioral tests failed')
    with tempfile.TemporaryDirectory(prefix='dotfiles-verify-') as folder:
        temp = Path(folder); destination = temp / 'home'; destination.mkdir()
        config = temp / 'chezmoi.toml'; config.write_text('[data]\n')
        env = dict(os.environ, HOME=str(destination), XDG_CONFIG_HOME=str(destination / '.config'),
                   XDG_CACHE_HOME=str(temp / 'cache'), XDG_DATA_HOME=str(destination / '.local/share'))
        command = [args.chezmoi, '--config', str(config), '--source', str(root),
                   '--destination', str(destination), '--cache', str(temp / 'cache'),
                   '--persistent-state', str(temp / 'state.boltdb')]
        for operation in ['apply', 'apply', 'verify']:
            result = subprocess.run(command + [operation], env=env, capture_output=True, text=True)
            if result.returncode:
                issues.append('chezmoi ' + operation + ': ' + result.stderr.strip())
                break
        else:
            issues += validate_rendered(destination)
            for name in ['.zprofile', '.zshrc', '.aliases', '.functions', '.environment', '.homebrewrc', '.p10k.zsh']:
                if subprocess.run(['zsh', '-n', str(destination / name)]).returncode:
                    issues.append('Zsh syntax: ' + name)
            safe_env = dict(env, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
            shell = subprocess.run(['zsh', '-d', '-i', '-c', 'print shell-startup-ok'],
                                   cwd=destination, env=safe_env, capture_output=True, text=True, timeout=15)
            if shell.returncode or 'shell-startup-ok' not in shell.stdout:
                issues.append('Offline shell startup failed')
            for name in ['.secret', '.ssh/id_rsa', '.ssh/id_ed25519', '.codex/auth.json']:
                if (destination / name).exists():
                    issues.append('Private file unexpectedly managed: ' + name)
            for name in ['.codex/config.toml', '.claude/settings.json', '.config/karabiner/karabiner.json']:
                if (destination / name).stat().st_mode & 0o077:
                    issues.append('Private configuration permissions: ' + name)
    if issues:
        print('\n'.join(issues), file=sys.stderr)
        return 1
    print('PASS: behavioral tests, manifest parity, secret scan, syntax/formats, isolated chezmoi apply twice + verify, offline Zsh startup and private-file exclusions.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
