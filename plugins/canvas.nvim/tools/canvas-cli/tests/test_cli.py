import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
CLI = ROOT / 'tools/canvas-cli/bin/canvas'


class CanvasCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.state = self.directory / 'diagram.canvas.json'
        self.call('create')

    def call(self, command, *args, success=True, env=None):
        result = subprocess.run([str(CLI), command, str(self.state), *map(str, args)],
                                capture_output=True, text=True, env=env, timeout=35)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
        return result

    def box(self, label='API', row=1, col=1, **extra):
        extra.setdefault('height', 5)
        args = ['--label', label, '--row', row, '--col', col]
        for key, value in extra.items():
            args.extend(['--' + key.replace('_', '-'), value])
        return json.loads(self.call('box', *args).stdout)['id']

    def test_configurable_keys_and_mapping_restoration(self):
        result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-l',
                                 str(ROOT / 'tools/canvas-cli/tests/check_config.lua')],
                                env={**os.environ, 'CANVAS_TEST_ROOT': str(ROOT)},
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:', result.stdout + result.stderr)

    def test_render_and_literal_labels(self):
        self.box('API, (Gateway)', shape='br', fg='#112233', bg='#334455')
        original = self.state.read_bytes()
        expected = ['╭──────────────────╮', '│                  │', '│  API, (Gateway)  │',
                    '│                  │', '╰──────────────────╯']
        rendered = json.loads(self.call('render', '--format', 'json').stdout)
        self.assertEqual(rendered['lines'], expected)
        self.assertEqual(rendered['rows'], 5)
        self.assertEqual(rendered['columns'], 20)
        self.assertEqual(rendered['paths'], {})
        self.assertEqual(self.call('render').stdout.splitlines(), expected)
        self.assertEqual(self.state.read_bytes(), original)

    def test_connections_moves_and_delete(self):
        first = self.box()
        second = self.box('Database', col=35)
        connection = json.loads(self.call('connect', '--from', first, '--to', second, '--label', 'requests', '--shape', 'cbd').stdout)['id']
        state = json.loads(self.call('inspect').stdout)
        self.assertTrue(state['conns'][str(connection)]['arrow_both'])
        self.assertTrue(state['conns'][str(connection)]['dashed'])
        rendered = json.loads(self.call('render', '--format', 'json').stdout)
        self.assertGreater(len(rendered['paths'][str(connection)]), 1)
        self.assertIn('requests', '\n'.join(rendered['lines']))
        self.call('move', second, '--row', 10, '--col', 35)
        moved = json.loads(self.call('render', '--format', 'json').stdout)
        self.assertNotEqual(moved['paths'], rendered['paths'])
        deleted = json.loads(self.call('delete', second).stdout)
        self.assertEqual(deleted['removed_connectors'], [connection])
        self.assertEqual(json.loads(self.call('inspect').stdout)['conns'], {})
        self.assertEqual(self.box('Next'), connection + 1)

    def test_multiline_text_and_free_endpoint(self):
        first = self.box()
        self.call('text', '--label', 'Title\nλ, details', '--row', 9, '--col', 3)
        connection = json.loads(self.call('connect', '--from', first, '--at', 7, 30).stdout)['id']
        rendered = json.loads(self.call('render', '--format', 'json').stdout)
        self.assertIn('Title', '\n'.join(rendered['lines']))
        self.assertIn('λ, details', '\n'.join(rendered['lines']))
        self.assertEqual(rendered['paths'][str(connection)][-1], [7, 30])

    def test_container_moves_enclosed_elements_once(self):
        outer = self.box('', row=2, col=2, width=60, height=20)
        nested = self.box('', row=4, col=4, width=30, height=12)
        child = self.box('Child', row=6, col=6, width=12, height=3)
        label = json.loads(self.call('text', '--label', '界 note', '--row', 12, '--col', 6).stdout)['id']
        partial = self.box('Partial', row=18, col=55, width=15, height=5)
        external = self.box('External', row=3, col=75, width=15, height=3)
        free = json.loads(self.call('connect', '--from', child, '--at', 10, 25).stdout)['id']
        outside = json.loads(self.call('connect', '--from', child, '--at', 25, 70).stdout)['id']
        internal = json.loads(self.call('connect', '--from', child, '--to', label).stdout)['id']
        # Manual routes are persisted geometry; translate only fully enclosed routes.
        data = json.loads(self.state.read_text())
        data['conns'][str(internal)].update(style='manual', waypoints=[[8, 11], [10, 11], [10, 8], [12, 8]])
        self.state.write_text(json.dumps(data))
        result = json.loads(self.call('move', outer, '--row', 5, '--col', 7).stdout)
        self.assertEqual(result['moved_shapes'], [outer, nested, child, label])
        moved = json.loads(self.call('inspect').stdout)
        for element in [outer, nested, child, label]:
            self.assertEqual(moved['shapes'][str(element)]['top'], data['shapes'][str(element)]['top']+3)
            self.assertEqual(moved['shapes'][str(element)]['left'], data['shapes'][str(element)]['left']+5)
        for element in [partial, external]:
            self.assertEqual(moved['shapes'][str(element)], data['shapes'][str(element)])
        self.assertEqual([moved['conns'][str(free)]['target_row'], moved['conns'][str(free)]['target_col']], [13, 30])
        self.assertEqual(moved['conns'][str(outside)], data['conns'][str(outside)])
        self.assertEqual(moved['conns'][str(internal)]['waypoints'], [[11, 16], [13, 16], [13, 13], [15, 13]])
        before = self.state.read_bytes()
        self.call('move', outer, '--row', 0, '--col', 1, success=False)
        self.assertEqual(self.state.read_bytes(), before)

    def test_overflow_validation_is_read_only_and_checks_unicode(self):
        box = self.box('Service', row=2, col=3, width=14, height=7)
        safe = json.loads(self.call('text', '--label', 'Safe', '--row', 3, '--col', 5).stdout)['id']
        self.assertTrue(json.loads(self.call('validate').stdout)['valid'])
        crossing = json.loads(self.call('text', '--label', '界界', '--row', 4, '--col', 14).stdout)['id']
        horizontal = json.loads(self.call('text', '--label', 'Top', '--row', 2, '--col', 5).stdout)['id']
        original = self.state.read_bytes()
        result = subprocess.run([str(CLI), 'validate', str(self.state)], capture_output=True, text=True, timeout=35)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report['valid'])
        self.assertEqual([issue['id'] for issue in report['issues']], [crossing, horizontal])
        self.assertTrue(all(issue['box_id'] == box for issue in report['issues']))
        self.assertEqual(report['issues'][0]['end_col'], 17)
        self.assertEqual(json.loads(self.call('render', '--format', 'json').stdout)['issues'], report['issues'])
        self.assertEqual(self.state.read_bytes(), original)
        self.call('move', crossing, '--row', 10, '--col', 3)
        self.call('move', horizontal, '--row', 11, '--col', 3)
        self.assertTrue(json.loads(self.call('validate').stdout)['valid'])

    def test_container_moves_in_both_buffer_modes(self):
        self.box('', id=1, row=2, col=2, width=30, height=12)
        self.box('Child', id=2, row=5, col=5, width=12, height=3)
        self.call('text', '--label', 'Note', '--row', 10, '--col', 5)
        for markdown in (False, True):
            with self.subTest(markdown=markdown):
                document = self.directory / ('container.md' if markdown else 'container.txt')
                if markdown:
                    self.call('document', '--output', document)
                else:
                    document.write_text(self.call('render').stdout)
                request = {'root': str(ROOT), 'state': str(self.state), 'document': str(document), 'markdown': markdown}
                env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
                result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l',
                                         str(Path(__file__).with_name('check_container.lua'))],
                                        input=json.dumps(request), text=True, capture_output=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_connector_label_border_overflow(self):
        first = self.box('A', row=2, col=2, width=7, height=3)
        second = self.box('B', row=2, col=18, width=7, height=3)
        conn = json.loads(self.call('connect', '--from', first, '--to', second, '--label', 'long label crosses borders').stdout)['id']
        issues = json.loads(self.call('render', '--format', 'json').stdout)['issues']
        self.assertTrue(any(issue['id'] == conn and issue['kind'] == 'connector' for issue in issues))

    def test_multiple_markdown_canvases_have_independent_working_states(self):
        first = self.state
        self.box('First', width=12, height=3, shape='br')
        first_lines = self.call('render').stdout
        second = self.directory / 'second canvas.canvas.json'
        self.state = second
        self.call('create')
        self.box('Second', width=12, height=3, shape='br')
        second_lines = self.call('render').stdout
        empty = self.directory / 'empty.canvas.json'
        self.state = empty
        self.call('create')
        document = self.directory / 'multiple.md'
        originals = {path: path.read_bytes() for path in (first, second, empty)}
        for implicit in (False, True):
            for fence in (chr(96)*3, '~~~', chr(96)*4, '  ~~~~'):
                with self.subTest(fence=fence, implicit=implicit):
                    for path, contents in originals.items():
                        path.write_bytes(contents)
                    selected = (first, second, empty)
                    default_base = None
                    if implicit:
                        selected = tuple(self.directory / ('defaults' + ('_'+str(i) if i > 1 else '') + '.canvas.json') for i in range(1,4))
                        for source, destination in zip((first,second,empty),selected): destination.write_bytes(originals[source])
                        default_base = str(selected[0])
                    tags = ['canvas' if implicit else 'canvas file='+json.dumps(path.name) for path in selected]
                    document.write_text('# Multiple canvases\n\n'
                                        + fence+tags[0]+'\n'+first_lines+fence+'\n\nBetween diagrams.\n\n'
                                        + fence+tags[1]+'\n'+second_lines+fence+'\n\n'
                                        + fence+tags[2]+'\n'+fence+'\n')
                    request = {'root': str(ROOT), 'document': str(document), 'first': str(selected[0]), 'second': str(selected[1]), 'empty': str(selected[2]), 'default_base': default_base, 'fence': fence}
                    env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
                    result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l',
                                             str(Path(__file__).with_name('check_multiple.lua'))],
                                            input=json.dumps(request), text=True, capture_output=True, env=env, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_mutations_leave_state_unchanged(self):
        first = self.box(id=7)
        original = self.state.read_bytes()
        for command, args in [
            ('create', []),
            ('box', ['--row', 1, '--col', 1, '--id', first]),
            ('connect', ['--from', first, '--to', 999]),
            ('box', ['--row', 1, '--col', 1, '--shape', 'ca']),
            ('connect', ['--from', first, '--to', first, '--label', 'two\nlines']),
            ('delete', [999]),
        ]:
            with self.subTest(command=command, args=args):
                self.call(command, *args, success=False)
                self.assertEqual(self.state.read_bytes(), original)

    def test_property_editor_follows_diagram_without_discarding_drafts(self):
        self.box('First',row=1,col=1,width=12,height=3)
        self.box('Second',row=1,col=30,width=12,height=3)
        self.call('text','--label','Note\n  detail','--row',8,'--col',2)
        self.call('box','--shape','bx','--label','Decision','--row',8,'--col',30)
        self.call('connect','--from',1,'--to',2)
        document=self.directory/'follow.md'
        self.call('document','--output',document)
        original=self.state.read_bytes()
        request={'root':str(ROOT),'document':str(document)}
        env=dict(os.environ,NVIM_LOG_FILE=os.devnull)
        result=subprocess.run([env.get('CANVAS_NVIM','nvim'),'--headless','-n','-u','NONE','-i','NONE','-l',
                               str(Path(__file__).with_name('check_follow.lua'))],
                              input=json.dumps(request),text=True,capture_output=True,env=env,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.state.read_bytes(),original)

    def test_diamond_labels_are_fixed_size_and_semantics_survive_moves(self):
        container = self.box('', row=1, col=1, width=70, height=25, kind='service', role='container')
        label = 'A long decision label that overflows\n  second line\n\n  last line'
        diamond = self.box(label, row=8, col=20, width=11, height=5, outline='diamond', kind='decision', role='node', parent_id=container)
        inspected = json.loads(self.call('inspect', '--id', diamond).stdout)
        self.assertEqual((inspected['width'], inspected['height']), (11, 5))
        self.assertEqual(inspected['kind'], 'decision')
        self.assertEqual(inspected['element_type'], 'box')
        self.assertEqual(inspected['capabilities'], {'multiline_labels': True, 'fit_to_labels': False})
        self.assertTrue(json.loads(self.call('validate').stdout)['valid'])
        rendered = self.call('render').stdout
        self.assertIn('A long decision label that overflows', rendered)
        self.assertIn('  second line', rendered)
        self.call('move', diamond, '--row', 11, '--col', 23)
        after = json.loads(self.call('inspect', '--id', diamond).stdout)
        for key in ('label', 'kind', 'role', 'parent_id', 'outline', 'width', 'height'):
            self.assertEqual(after[key], inspected[key])
        crossing = json.loads(self.call('text', '--label', 'tip', '--row', after['top']+after['height']//2, '--col', after['left']).stdout)['id']
        issues = json.loads(self.call('render', '--format', 'json').stdout)['issues']
        self.assertTrue(any(issue['id'] == crossing and issue['box_id'] == diamond for issue in issues))
        self.call('delete', container)
        after = json.loads(self.call('inspect', '--id', diamond).stdout)
        self.assertNotIn('parent_id', after)
        self.assertEqual(after['kind'], 'decision')

    def test_diamond_routes_attach_to_all_four_tips(self):
        diamond = self.box('Decision?', row=15, col=30, width=19, height=9, shape='bx', kind='decision')
        tips = {'left': (19,30,'→'), 'right': (19,48,'←'), 'top': (15,39,'↓'), 'bottom': (23,39,'↑')}
        positions = {'left':(18,1), 'right':(18,65), 'top':(1,36), 'bottom':(33,36)}
        for side, (row,col) in positions.items():
            source = self.box(side, row=row, col=col, width=10, height=3)
            conn = json.loads(self.call('connect', '--from', source, '--to', diamond, '--shape', 'cb', '--force-connect-to-side', side).stdout)['id']
            rendered = json.loads(self.call('render', '--format', 'json').stdout)
            row,col,arrow = tips[side]
            self.assertEqual(rendered['paths'][str(conn)][-1], [row,col])
            self.assertEqual(rendered['lines'][row-1][col-1], arrow)
            self.call('delete', conn)
            self.call('delete', source)

    def test_diamond_half_step_scales_and_legacy_dimensions(self):
        for size, expected in ((None,(13,7)), (1,(13,7)), (1.5,(19,10)), (2,(25,13)), (2.5,(31,16))):
            extra = {} if size is None else {'size':size}
            args = ['--shape','bx','--label','A label does not change the scale','--row',10,'--col',20]
            for key, val in extra.items(): args.extend(['--'+key,val])
            element = json.loads(self.call('box',*args).stdout)['id']
            inspected = json.loads(self.call('inspect','--id',element).stdout)
            self.assertEqual((inspected['width'],inspected['height']),expected)
            self.assertEqual(inspected['size'],1 if size is None else size)
            self.call('delete',element)
        original = self.state.read_bytes()
        for args in (['--size',1.3], ['--size',1.4], ['--size',0.5], ['--size',-1], ['--size',1,'--width',19]):
            self.call('box','--shape','bx','--row',1,'--col',1,*args,success=False)
            self.assertEqual(self.state.read_bytes(),original)
        self.call('box','--row',1,'--col',1,'--size',1,success=False)
        self.assertEqual(self.state.read_bytes(),original)
        legacy = self.box('Legacy',shape='bx',width=19,height=9)
        inspected = json.loads(self.call('inspect','--id',legacy).stdout)
        self.assertEqual((inspected['width'],inspected['height']),(19,9))
        self.assertNotIn('size',inspected)

    def test_semantic_validation_is_atomic(self):
        parent = self.box('', role='container', kind='service')
        child = self.box('Child', row=15, col=30, parent_id=parent, kind='database')
        original = self.state.read_bytes()
        for extra in ({'parent_id':child}, {'parent_id':999}, {'kind':'invalid kind'}, {'shape':'bxr'}, {'outline':'diamond','width':4}):
            args = ['--row',30,'--col',30]
            for key,val in extra.items(): args.extend(['--'+key.replace('_','-'),val])
            self.call('box', *args, success=False)
            self.assertEqual(self.state.read_bytes(), original)
        data = json.loads(original)
        data['shapes'][str(parent)]['parent_id'] = child
        data['shapes'][str(child)]['role'] = 'container'
        self.state.write_text(json.dumps(data))
        self.assertIn('cycles', self.call('inspect', success=False).stderr)

    def test_diamond_editor_and_metadata_in_both_buffer_modes(self):
        self.box('', row=1, col=1, width=100, height=30, kind='service', role='container')
        self.box('Decision?', row=12, col=30, width=11, height=5, shape='bx', kind='decision', role='node', parent_id=1)
        original = self.state.read_bytes()
        for markdown in (False, True):
            with self.subTest(markdown=markdown):
                self.state.write_bytes(original)
                document = self.directory / ('diamond.md' if markdown else 'diamond.txt')
                if markdown:
                    self.call('document', '--output', document)
                else:
                    document.write_text(self.call('render').stdout)
                request = {'root': str(ROOT), 'document': str(document), 'state': str(self.state), 'markdown': markdown}
                env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
                result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l',
                                         str(Path(__file__).with_name('check_diamond.lua'))],
                                        input=json.dumps(request), text=True, capture_output=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_empty_render_and_missing_engine(self):
        rendered = json.loads(self.call('render', '--format', 'json').stdout)
        self.assertEqual(rendered['lines'], [])
        self.assertEqual(rendered['rows'], 0)
        env = dict(os.environ, CANVAS_NVIM=str(self.directory / 'missing-nvim'))
        original = self.state.read_bytes()
        for command, args in [('render', []), ('inspect', []), ('create', ['--force'])]:
            failure = self.call(command, *args, success=False, env=env)
            self.assertIn('requires Neovim', json.loads(failure.stderr)['error'])
            self.assertEqual(self.state.read_bytes(), original)

    def test_malformed_state_and_renderer_error(self):
        self.box()
        state = json.loads(self.state.read_text())
        state['shapes']['1']['fg'] = 'not-a-color'
        self.state.write_text(json.dumps(state))
        original = self.state.read_bytes()
        failure = self.call('render', success=False)
        self.assertIn('invalid fg color', json.loads(failure.stderr)['error'])
        self.assertEqual(self.state.read_bytes(), original)
        del state['shapes']['1']['fg']
        state['next_id'] = False
        self.state.write_text(json.dumps(state))
        failure = self.call('inspect', success=False)
        self.assertIn('next_id', json.loads(failure.stderr)['error'])
        self.state.write_text('{malformed')
        self.call('inspect', success=False)
        self.assertEqual(self.state.read_text(), '{malformed')

    def test_document_loads_and_saves_in_vim(self):
        self.state = self.directory / 'state with "quotes".canvas.json'
        self.call('create')
        self.box('CLI → Vim', shape='br', fg='#89b4fa')
        output = self.directory / 'docs' / 'architecture.md'
        self.call('document', '--output', output, '--title', 'Architecture', '--description', 'High-level modules.')
        document = output.read_text()
        self.assertIn('# Architecture', document)
        self.assertIn('High-level modules.', document)
        self.call('document', '--output', output, success=False)
        self.assertEqual(output.read_text(), document)
        self.call('document', '--output', self.state, '--force', success=False)
        expected = json.loads(self.call('render', '--format', 'json').stdout)['lines']
        request = self.directory / 'request.json'
        request.write_text(json.dumps({'root': str(ROOT), 'document': str(output), 'sidecar': str(self.state), 'lines': expected}))
        script = self.directory / 'roundtrip.lua'
        script.write_text("""
local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].swapfile = false
vim.api.nvim_buf_set_name(buf, request.document)
vim.bo[buf].filetype = 'markdown'
local lines = vim.fn.readfile(request.document)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
for row, line in ipairs(lines) do
  if line:find('canvas file=', 1, true) then vim.api.nvim_win_set_cursor(0, {row+1, 0}); break end
end
require('canvas.init').open()
local s = require('canvas.state').for_buf(buf)
assert(vim.fn.resolve(s.canvas_file) == vim.fn.resolve(request.sidecar), s.canvas_file .. ' != ' .. request.sidecar)
local actual = vim.api.nvim_buf_get_lines(buf, s.row_start-1, s.row_end, false)
assert(vim.deep_equal(actual, request.lines))
assert(s.shapes[1].fg == '#89b4fa')
s.shapes[1].label = 'Edited in Vim'
require('canvas.persist').save(buf)
""")
        env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
        result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l', str(script)],
                                input=request.read_text(), capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.call('inspect', '--id', 1).stdout)['label'], 'Edited in Vim')
        self.assertIn('Edited in Vim', self.call('render').stdout)

    def test_vim_and_cli_share_scene_rules(self):
        self.call('box', '--shape', 'br', '--label', 'API', '--row', 2, '--col', 3)
        self.box('DB', row=2, col=40, shape='br')
        self.call('connect', '--from', 1, '--to', 2, '--shape', 'cad')
        request = {'root': str(ROOT), 'state': json.loads(self.state.read_text())}
        script = Path(__file__).with_name('check_vim.lua')
        env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
        result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l', str(script)],
                                input=json.dumps(request), text=True, capture_output=True, env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shared_color_validation_and_legacy_loading(self):
        self.box(fg='red')
        self.assertEqual(json.loads(self.call('inspect', '--id', 1).stdout)['fg'], 'red')
        original = self.state.read_bytes()
        self.call('box', '--row', 1, '--col', 30, '--fg', 'not-a-color', success=False)
        self.assertEqual(self.state.read_bytes(), original)
        self.state.write_text(json.dumps({'boxes': {'1': {'top': 1, 'left': 1, 'width': 20, 'height': 5, 'label': 'Legacy', 'variant': 'rd'}},
                                         'texts': {'2': {'text': 'Note', 'row': 8, 'col': 1}}}))
        imported = json.loads(self.call('inspect').stdout)
        self.assertEqual(imported['next_id'], 3)
        self.assertEqual(imported['shapes']['2']['variant'], 't')
        self.assertIn('Legacy', self.call('render').stdout)

    def test_saved_snapshot_and_discard_in_both_buffer_modes(self):
        for markdown in (False, True):
            with self.subTest(markdown=markdown):
                self.call('create', '--force')
                self.box('Saved', row=2, col=3, shape='br', fg='#89b4fa')
                document = self.directory / ('main.md' if markdown else 'main.txt')
                if markdown:
                    self.call('document', '--output', document, '--title', 'Snapshot test')
                else:
                    document.write_text(self.call('render').stdout)
                request = {'root': str(ROOT), 'state': str(self.state), 'document': str(document),
                           'markdown': markdown, 'missing': str(self.directory / 'missing' / 'failure.txt')}
                env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
                result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l', str(Path(__file__).with_name('check_session.lua'))],
                                        input=json.dumps(request), text=True, capture_output=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_forced_sides_route_and_draw_at_the_target(self):
        source = self.box('A', row=2, col=3)
        target = self.box('B', row=12, col=35)
        sides = {'left': ([14, 35], [14, 34], '→'), 'right': ([14, 54], [14, 55], '←'),
                 'top': ([12, 45], [11, 45], '↓'), 'bottom': ([16, 45], [17, 45], '↑')}
        for route in ('default', 'direct', 'lazy', 'avoid'):
            for side, (endpoint, approach, arrow) in sides.items():
                with self.subTest(route=route, side=side):
                    conn = json.loads(self.call('connect', '--from', source, '--to', target, '--route', route,
                                                '--force-connect-to-side', side).stdout)['id']
                    info = json.loads(self.call('inspect', '--id', conn).stdout)
                    self.assertEqual(info['forceConnectToSide'], side)
                    rendered = json.loads(self.call('render', '--format', 'json').stdout)
                    path = rendered['paths'][str(conn)]
                    self.assertEqual(path[-1], endpoint)
                    self.assertEqual(path[-2], approach)
                    self.assertTrue(all(not (12 <= row <= 16 and 35 <= col <= 54) for row, col in path[:-1]))
                    self.assertEqual(rendered['lines'][endpoint[0]-1][endpoint[1]-1], arrow)
                    self.assertGreaterEqual(rendered['rows'], max(row for row, col in path))
                    self.call('delete', conn)

    def test_forced_side_is_strict_and_invalid_values_are_atomic(self):
        source = self.box('A', row=2, col=35)
        target = self.box('B', row=12, col=1)
        original = self.state.read_bytes()
        for side in ('middle', 'LEFT'):
            self.call('connect', '--from', source, '--to', target, '--force-connect-to-side', side, success=False)
            self.assertEqual(self.state.read_bytes(), original)
        self.call('connect', '--from', source, '--at', 8, 30, '--force-connect-to-side', 'left', success=False)
        self.assertEqual(self.state.read_bytes(), original)

        self.call('connect', '--from', source, '--to', target, '--route', 'manual', '--force-connect-to-side', 'left', success=False)
        self.assertEqual(self.state.read_bytes(), original)
        self.call('connect', '--from', source, '--to', target, '--force-connect-to-side', 'left')
        original = self.state.read_bytes()
        failure = self.call('render', success=False)
        self.assertIn('no route found', json.loads(failure.stderr)['error'])
        self.assertEqual(self.state.read_bytes(), original)
    def test_multiline_box_labels_preserve_layout_and_auto_size(self):
        label = 'Title\n\n  - first item\n  - second item\n'
        self.box(label, shape='br', width=3, height=1)
        data = json.loads(self.call('inspect', '--id', 1).stdout)
        self.assertEqual(data['label'], label)
        self.assertEqual(data['height'], 7)
        self.assertEqual(data['width'], len('  - second item')+4)
        rendered = json.loads(self.call('render', '--format', 'json').stdout)
        self.assertEqual(len(rendered['lines']), 7)
        self.assertTrue(all(len(line) == data['width'] for line in rendered['lines']))
        self.assertIn('│ Title', rendered['lines'][1])
        self.assertIn('│   - first item', rendered['lines'][3])
        self.assertIn('│   - second item', rendered['lines'][4])
        self.assertEqual(rendered['lines'][2], '│'+' '*(data['width']-2)+'│')
        self.assertEqual(rendered['lines'][5], rendered['lines'][2])

    def test_multiline_unicode_box_editing_and_persistence(self):
        label = 'Initial\n  • item\n'
        self.box(label, shape='br', width=3, height=1)
        document = self.directory / 'multiline.md'
        self.call('document', '--output', document)
        request = {'root': str(ROOT), 'state': str(self.state), 'document': str(document), 'label': label}
        env = dict(os.environ, NVIM_LOG_FILE=os.devnull)
        result = subprocess.run([env.get('CANVAS_NVIM', 'nvim'), '--headless', '-n', '-u', 'NONE', '-i', 'NONE', '-l', str(Path(__file__).with_name('check_multiline.lua'))],
                                input=json.dumps(request), text=True, capture_output=True, env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)



if __name__ == '__main__':
    unittest.main()
