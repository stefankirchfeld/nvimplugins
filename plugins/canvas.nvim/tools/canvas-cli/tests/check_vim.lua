local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local scene = require('canvas.scene')
local state = require('canvas.state')
local parser = require('canvas.parser')
local commands = require('canvas.commands')
local canvas = require('canvas.init')
local editor = require('canvas.form')
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].swapfile = false
local s = state.for_buf(buf)

commands.execute(buf, parser.parse('br(API)'), 2, 3)
commands.execute(buf, parser.parse('br(20, 5, DB)'), 2, 40)
commands.execute(buf, parser.parse('cad(1, 2)'), 1, 1)
local native, cli = scene.serialize(s), request.state
for _, collection in ipairs({ 'shapes', 'conns' }) do
  for _, object in pairs(native[collection]) do object.cmd_str = nil end
  for _, object in pairs(cli[collection]) do object.cmd_str = nil end
end
assert(vim.deep_equal(native, cli), 'Vim commands and CLI produced different state')
assert(s.shapes[1].height == 10, 'default height drifted')

local original = s.shapes[1]
local next_id = s.next_id
local ok = pcall(scene.apply, s, { op='connect', fields={ from_id=1, to_id=999 } })
assert(not ok and s.shapes[1] == original and s.next_id == next_id, 'failed operation mutated state')
assert(not parser.parse('bz(API)'), 'invalid modifier was accepted')

editor.open(buf, 3, 'conn', canvas.rerender)
local connbuf = vim.api.nvim_get_current_buf()
local function side(value)
  vim.api.nvim_buf_set_lines(connbuf, 0, -1, false,
    { 'shape: cad', 'from: 1', 'to: 2', 'route: direct', 'to_side: ' .. value, '', 'label:', '' })
end
side('left'); vim.cmd('write')
assert(s.conns[3].forceConnectToSide == 'left')
local oldconn = s.conns[3]
side('bad')
assert(not pcall(vim.cmd, 'write') and s.conns[3] == oldconn)
side(''); vim.cmd('wq')
assert(s.conns[3].forceConnectToSide == nil)
assert(not pcall(scene.apply, s, { op='update', id=3, fields={ forceConnectToSide=false } }))

editor.open(buf, 1, 'box', canvas.rerender)
local editbuf = vim.api.nvim_get_current_buf()
local function put(label, shape, fg)
  vim.api.nvim_buf_set_lines(editbuf, 0, -1, false,
    { 'shape: ' .. shape, 'w: 20', 'h: 5', 'fg: ' .. fg, 'bg:', 'text_color:', '', 'label:', label })
end
local literal = 'Long label, with (punctuation)'
put(literal, 'bd', 'red')
vim.cmd('write')
assert(vim.api.nvim_get_current_buf() == editbuf)
assert(s.shapes[1].label == literal and s.shapes[1].width >= #literal+4 and s.shapes[1].fg == 'red')
put('Second apply', 'br', '#89b4fa')
vim.cmd('write')
assert(s.shapes[1].label == 'Second apply')
local saved = s.shapes[1]
put('Invalid color', 'br', 'not-a-color')
assert(not pcall(vim.cmd, 'write') and s.shapes[1] == saved)
local ns = vim.api.nvim_create_namespace('canvas_nvim_editor')
local marks = vim.api.nvim_buf_get_extmarks(editbuf, ns, 0, -1, {})
assert(marks[1][2] == 3, 'validation diagnostic was not on the color row')
assert(not pcall(vim.cmd, 'wq') and vim.api.nvim_buf_is_valid(editbuf), 'invalid write-and-quit closed the editor')
vim.cmd('quit')
assert(s.shapes[1] == saved and not vim.api.nvim_buf_is_valid(editbuf))

local text = scene.apply(s, { op='text', fields={ row=12, col=3, label='First' .. string.char(10) .. 'Second' } }).id
commands.execute(buf, { cmd='color', params={ text, '#aabbcc' } }, 1, 1)
assert(#s.shapes[text].lines == 2 and s.shapes[text].fg == '#aabbcc', 'color update lost multiline text')
editor.open(buf, text, 'text', canvas.rerender, true)
local textbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(textbuf, 0, -1, false, { '', 'New second line' })
vim.cmd('write')
assert(s.shapes[text].lines[1] == '' and s.shapes[text].height == 2)
vim.cmd('wq')
assert(not vim.api.nvim_buf_is_valid(textbuf))

-- Existing move controls still move and highlight the chosen shape.
require('canvas.persist').load = function() return false end
require('canvas.persist').save = function() end
canvas.open()
vim.api.nvim_win_set_cursor(0, { s.row_start + s.shapes[1].top-1, s.shapes[1].left-1 })
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  vim.wait(20, function() return false end)
end
feed('m')
assert(vim.wo.winbar:find('MOVE', 1, true))
local left = s.shapes[1].left
feed('L')
assert(s.shapes[1].left == left+3)
feed('<Esc>')
assert(not vim.wo.winbar:find('MOVE', 1, true))
commands.execute(buf, { cmd='del', params={ 2 } }, 1, 1)
assert(s.conns[3] == nil, 'deleting a box did not remove its connector')
canvas.open()
