import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / 'bin/canvas'


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.doc = self.root / 'my document.md'
        self.env = dict(os.environ, HOME=str(self.root / 'home'))
        self.state = json.dumps({'shapes': {}, 'conns': {}, 'next_id': 1})

    def call(self, *args, success=True):
        result = subprocess.run([str(CLI), 'change-persistence', str(self.doc), *args],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def test_round_trip_preserves_content_and_fence_order(self):
        first, second = self.root / 'first state.json', self.root / 'second.json'
        for path in (first, second):
            path.write_text(self.state)
        tick = chr(96)
        prefix = tick*4+'text\n~~~canvas file=missing.json\n~~~\n'+tick*4+'\nProse.\n'
        tag = 'canvas file='+json.dumps(first.name)
        original = prefix+'  ~~~~'+tag+'\r\nA → B\r\n  ~~~~\r\n'+tick*3+'canvas file=second.json\nC → D\n'+tick*3+'\n'
        self.doc.write_bytes(original.encode())
        result = json.loads(self.call().stdout)
        self.assertEqual(len(result['canvases']), 2)
        expected = original.replace(tag, 'canvas').replace('canvas file=second.json', 'canvas')
        self.assertEqual(self.doc.read_bytes(), expected.encode())
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())
        for index, move in enumerate(result['canvases'], 1):
            dst = Path(move['destination'])
            self.assertEqual(dst.read_text(), self.state)
            suffix = '' if index == 1 else '_2'
            self.assertEqual(dst.name, str(self.doc.resolve()).replace('/', '_') + suffix + '.canvas.json')
        self.call()
        reverse = json.loads(self.call('--mode', 'colocated').stdout)
        self.assertIn('canvas file='+json.dumps('my document.canvas.json'), self.doc.read_text())
        for move in reverse['canvases']:
            self.assertFalse(Path(move['source']).exists())
            self.assertEqual(Path(move['destination']).read_text(), self.state)

    def test_conflict_preflight_and_force_keep_source(self):
        source = self.root / 'old.json'
        source.write_text(self.state)
        original = '~~~canvas file=old.json\nunchanged\n~~~\n'
        self.doc.write_text(original)
        result = json.loads(self.call('--keep-source').stdout)
        destination = Path(result['canvases'][0]['destination'])
        conflict = json.dumps({'shapes': {}, 'conns': {}, 'next_id': 99})
        destination.write_text(conflict)
        self.doc.write_text(original)
        self.call(success=False)
        self.assertEqual(self.doc.read_text(), original)
        self.assertEqual(destination.read_text(), conflict)
        self.assertTrue(source.exists())
        self.call('--force')
        self.assertEqual(destination.read_text(), self.state)
        self.assertFalse(source.exists())

    def test_missing_later_state_does_not_move_first(self):
        source = self.root / 'old.json'
        source.write_text(self.state)
        original = '~~~canvas file=old.json\n~~~\n~~~canvas file=missing.json\n~~~\n'
        self.doc.write_text(original)
        self.call(success=False)
        self.assertEqual(self.doc.read_text(), original)
        self.assertTrue(source.exists())
        self.assertFalse((self.root / 'home').exists())
