import tempfile
from pathlib import Path
import unittest
from test_workflow import ROOT, load


class VerificationTests(unittest.TestCase):
    def test_jsonc_preserves_urls_and_comment_text_inside_strings(self):
        verify = load(ROOT / 'scripts/verify.py')
        self.assertEqual(verify.parse_jsonc('''{
          // outside comment
          "url": "https://example.com/a//b", /* block comment */
          "text": "/* literal */", "list": [1, 2,],
        }'''), {'url': 'https://example.com/a//b', 'text': '/* literal */', 'list': [1, 2]})

    def test_retired_tools_are_rejected_from_package_manifest(self):
        verify = load(ROOT / 'scripts/verify.py')
        self.assertIn('Retired package: cursor', verify.check_packages(
            {'formulae': ['git'], 'casks': [{'token': 'cursor'}]}))

    def test_plaintext_private_key_reports_path_without_value(self):
        verify = load(ROOT / 'scripts/verify.py')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'private.txt'
            path.write_text('-----BEGIN OPENSSH PRIVATE KEY-----\nsensitive-value\n')
            issues = verify.check_secrets(Path(folder))
            self.assertEqual(len(issues), 1)
            self.assertIn('private.txt', issues[0])
            self.assertNotIn('sensitive-value', str(issues))


if __name__ == '__main__':
    unittest.main()
