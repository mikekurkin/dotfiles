#!/usr/bin/env python3
"""Explicit selected-preference restoration; never copy live preference plists."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def merge_selected(current, selected):
    """Preserve unselected keys inside nested preference dictionaries."""
    merged = dict(current)
    for key, value in selected.items():
        if isinstance(value, dict) and isinstance(current.get(key), dict):
            merged[key] = merge_selected(current[key], value)
        else:
            merged[key] = value
    return merged


def apply_preferences(preferences, read_domain, write_domain):
    failures = []
    for domain, selected in preferences.items():
        try:
            current = read_domain(domain)
        except (OSError, ValueError, plistlib.InvalidFileException):
            failures.append(domain + ' (read failed; import skipped)')
            continue
        merged = merge_selected(current, selected)
        if merged == current:
            continue
        if write_domain(domain, merged):
            failures.append(domain)
    if failures:
        print('Preference failures:', ', '.join(failures), file=sys.stderr)
    return int(bool(failures))


def read_domain(domain):
    result = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    # An absent domain exports successfully as an empty dictionary on macOS.
    if result.returncode:
        raise OSError('Preference export failed')
    values = plistlib.loads(result.stdout)
    if not isinstance(values, dict):
        raise ValueError('Invalid preference domain')
    return values


def clean(value):
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [clean(v) for v in value if v is not None]
    return value


def main():
    if sys.argv[1:] != ['--apply']:
        print('Usage: scripts/preferences.py --apply (close iTerm2 and IINA first)')
        return 2
    for app in ['iTerm2', 'IINA']:
        if subprocess.run(['pgrep', '-x', app], stdout=subprocess.DEVNULL).returncode == 0:
            print('Close ' + app + ' before importing settings; run this phase from Terminal.', file=sys.stderr)
            return 1
    config = Path.home() / '.config/dotfiles'
    preferences = json.loads((config / 'preferences.json').read_text())
    for p in sorted((config / 'app-preferences').glob('*.json')):
        preferences[p.stem] = clean(json.loads(p.read_text()))
    screenshots = preferences.get('com.apple.screencapture', {}).get('location')
    if screenshots:
        Path(screenshots).expanduser().mkdir(parents=True, exist_ok=True)
    def write_domain(domain, values):
        with tempfile.NamedTemporaryFile(suffix='.plist') as handle:
            handle.write(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
            handle.flush()
            return subprocess.run(['defaults', 'import', domain, handle.name]).returncode
    result = apply_preferences(preferences, read_domain, write_domain)
    print('Log out and back in to activate system settings; verify them on macOS 27.')
    return result


if __name__ == '__main__':
    raise SystemExit(main())
