local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local canvas = require('canvas.init')
local scene = require('canvas.scene')
local state = require('canvas.state')
local editor = require('canvas.form')
local outlines = require('canvas.outlines')
vim.cmd.edit(vim.fn.fnameescape(request.document))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = request.markdown and 'markdown' or ''
local s = state.for_buf(buf)
s.canvas_file = request.state
if request.markdown then
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find('canvas file=', 1, true) then vim.api.nvim_win_set_cursor(0, {row+1,0}); break end
  end
end
canvas.open()
local diamond = s.shapes[2]
assert(diamond.kind == 'decision' and diamond.parent_id == 1)
assert(not diamond:contains(diamond.top, diamond.left), 'diamond hit test includes empty bounding-box corner')
editor.open(buf, 2, 'box', canvas.rerender)
local draft = vim.api.nvim_get_current_buf()
local original = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
assert(vim.tbl_contains(original, 'shape: bx') and vim.tbl_contains(original, 'kind: decision'))
assert(vim.tbl_contains(original, 'size: '), 'legacy diamond editor must preserve custom dimensions')
vim.api.nvim_buf_set_lines(draft, 0, -1, false,
  { 'shape: bx', 'w: 11', 'h: 3', 'fg: #89b4fa', 'bg: #1e1e2e', 'text_color: #ff0000',
    'kind: approval', 'role: node', 'parent_id: 1', '', 'label:', 'Very long decision label', '', '  界 detail', 'More content' })
vim.cmd('write')
assert(s.shapes[2].width == 11 and s.shapes[2].height == 3, 'diamond unexpectedly fitted multiline label')
assert(s.shapes[2].kind == 'approval' and s.shapes[2].parent_id == 1)
assert(#s.shapes[2]:label_positions() == 4)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(table.concat(lines, string.char(10)):find('More content', 1, true), 'overflow rows were truncated')
local marks = vim.api.nvim_buf_get_extmarks(buf, state.ns_hl, 0, -1, {details=true})
local colored = 0
for _, mark in ipairs(marks) do if mark[4].hl_group == 'CanvasShapeLabel_2' then colored=colored+1 end end
assert(colored == 3, 'diamond multiline label highlights missing')
vim.cmd('quit')
local positions = s.shapes[2]:label_positions()
local tip = outlines.geometry(s.shapes[2]).points.left
vim.api.nvim_win_set_cursor(0, {s.row_start+tip[1]-1, tip[2]-1})
local function feed(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
  vim.wait(25, function() return false end)
end
feed('m'); feed('L'); feed('J'); feed('<Esc>')
for index, position in ipairs(s.shapes[2]:label_positions()) do
  assert(position.row == positions[index].row+3 and position.col == positions[index].col+3, 'diamond label did not move with its anchor')
end
vim.cmd('write')
local saved = vim.json.decode(table.concat(vim.fn.readfile(request.state), string.char(10)))
assert(saved.shapes['2'].outline == 'diamond' and saved.shapes['2'].kind == 'approval' and saved.shapes['2'].parent_id == 1)
local expected = scene.serialize(s)
canvas.open()
editor.open(buf, 2, 'box', canvas.rerender)
draft = vim.api.nvim_get_current_buf()
local scaled_lines = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
for index, line in ipairs(scaled_lines) do if line:match('^size:') then scaled_lines[index] = 'size: 1.5' end end
vim.api.nvim_buf_set_lines(draft, 0, -1, false, scaled_lines)
vim.cmd('write'); vim.cmd('quit')
assert(s.shapes[2].width == 19 and s.shapes[2].height == 10, 'editor scale did not resize both dimensions')
vim.cmd('write')
expected = scene.serialize(s)
require('canvas.commands').execute(buf, require('canvas.parser').parse('bx(9, 3, Not fitted at all)'), 20, 60)
assert(s.shapes[3].outline == 'diamond' and s.shapes[3].width == 9, 'native diamond token did not preserve fixed width')
require('canvas.commands').execute(buf, require('canvas.parser').parse('bx(1.5, Scaled)'), 20, 60)
assert(s.shapes[4].width == 19 and s.shapes[4].height == 10, 'native fractional size failed')
require('canvas.commands').execute(buf, require('canvas.parser').parse('bx(Default)'), 20, 60)
assert(s.shapes[5].width == 13 and s.shapes[5].height == 7, 'native default size failed')
require('canvas.commands').execute(buf, require('canvas.parser').parse('bx 2 Double'), 20, 60)
assert(s.shapes[6].width == 25 and s.shapes[6].height == 13, 'native space syntax scale failed')
vim.cmd('edit!')
vim.wait(25, function() return false end)
assert(vim.deep_equal(scene.serialize(s), expected), 'discard lost saved diamond metadata')
