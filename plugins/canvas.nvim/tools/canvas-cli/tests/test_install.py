import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
INSTALLER = ROOT / 'tools/canvas-cli/install.py'
SKILL = ROOT / 'skills/canvas-diagrams'


class InstallCanvas(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.prefix = self.directory / 'local'
        self.codex = self.directory / 'agents' / 'skills'
        self.claude = self.directory / 'claude' / 'skills'

    def install(self, *args):
        return subprocess.run([sys.executable, str(INSTALLER), '--prefix', str(self.prefix),
                               '--codex-skills-dir', str(self.codex), '--claude-skills-dir', str(self.claude), *args],
                              capture_output=True, text=True, timeout=30)

    def test_dry_run_does_not_create_directories(self):
        result = self.install('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)['links']), 3)
        self.assertFalse(self.prefix.exists())
        self.assertFalse(self.codex.exists())
        self.assertFalse(self.claude.exists())

    def test_shared_skill_and_installed_cli_work(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        for directory in (self.codex, self.claude):
            installed = directory / 'canvas-diagrams'
            self.assertEqual(installed.resolve(), SKILL.resolve())
            self.assertEqual((installed / 'SKILL.md').read_bytes(), (SKILL / 'SKILL.md').read_bytes())
        cli = self.prefix / 'bin' / 'canvas'
        sidecar = self.directory / 'diagram.json'
        for command in [('create', str(sidecar)), ('box', str(sidecar), '--label', 'Installed', '--row', '1', '--col', '1', '--height', '3')]:
            result = subprocess.run([str(cli), *command], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        rendered = subprocess.run([str(cli), 'render', str(sidecar)], capture_output=True, text=True)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn('Installed', rendered.stdout)
        again = self.install()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertTrue(all(link['action'] == 'unchanged' for link in json.loads(again.stdout)['links']))

    def test_conflict_prevents_any_installation(self):
        conflict = self.claude / 'canvas-diagrams'
        conflict.mkdir(parents=True)
        (conflict / 'SKILL.md').write_text('Existing skill')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('refusing to replace', result.stderr)
        self.assertFalse(self.prefix.exists())
        self.assertFalse(self.codex.exists())
        self.assertEqual((conflict / 'SKILL.md').read_text(), 'Existing skill')

    def test_single_target_and_shared_directory(self):
        result = self.install('--targets', 'codex')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.claude.exists())
        self.claude.parent.mkdir(parents=True)
        self.claude.symlink_to(self.codex, target_is_directory=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.claude / 'canvas-diagrams').resolve(), SKILL.resolve())


if __name__ == '__main__':
    unittest.main()
