local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local state = require('canvas.state')
local scene = require('canvas.scene')
local render = require('canvas.render')
local canvas = require('canvas.init')
local editor = require('canvas.form')
vim.cmd.edit(vim.fn.fnameescape(request.document))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].swapfile = false
vim.bo[buf].filetype = 'markdown'
local document = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for row, line in ipairs(document) do
  if line:find('canvas file=', 1, true) then vim.api.nvim_win_set_cursor(0, {row+1, 0}); break end
end
canvas.open()
local s = state.for_buf(buf)
editor.open(buf, 1, 'box', canvas.rerender)
local draft = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
local label_at
for row, line in ipairs(lines) do if line == 'label:' then label_at = row; break end end
assert(vim.deep_equal(vim.list_slice(lines, label_at+1), render.label_lines(request.label)), 'editor lost multiline label content')
local content = { 'Heading', '', '  • item', string.char(9) .. '界 e' .. string.char(0xCC, 0x81), '' }
vim.api.nvim_buf_set_lines(draft, 0, -1, false,
  { 'shape: br', 'w: 3', 'h: 1', 'fg: #89b4fa', 'bg: #1e1e2e', 'text_color: #ff0000', '', 'label:', unpack(content) })
vim.cmd('write')
assert(s.shapes[1].label == table.concat(content, string.char(10)))
assert(s.shapes[1].height == #content+2)
assert(s.shapes[1].width == vim.fn.strdisplaywidth(content[4])+4)
local positions = s.shapes[1]:label_positions()
assert(#positions == #content and positions[1].col == positions[3].col)
assert(positions[3].row == positions[1].row+2)
local ns = state.ns_hl
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details=true })
local highlighted = 0
for _, mark in ipairs(marks) do
  if mark[4].hl_group == 'CanvasShapeLabel_1' then
    highlighted = highlighted+1
    local position = positions[highlighted == 1 and 1 or highlighted == 2 and 3 or 4]
    local row = s.row_start + position.row - 2
    assert(mark[2] == row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row+1, false)[1]
    assert(mark[3] == render.byte_col(line, position.col-1))
    assert(mark[4].end_col == render.byte_col(line, position.col-1+vim.fn.strdisplaywidth(position.text)))
  end
end
assert(highlighted == 3, 'multiline text color did not cover all nonempty lines')
local data = scene.serialize(s)
vim.cmd('quit')
vim.cmd('write')
local saved = vim.json.decode(table.concat(vim.fn.readfile(request.state), string.char(10)))
assert(saved.shapes['1'].label == data.shapes['1'].label, 'persisted label lost line breaks')
assert(saved.shapes['1'].width == data.shapes['1'].width and saved.shapes['1'].height == data.shapes['1'].height)
local again = scene.render(scene.deserialize(saved))
for _, line in ipairs(again.lines) do assert(vim.fn.strdisplaywidth(line) == s.shapes[1].left-1+s.shapes[1].width) end

-- Reverting the parent buffer restores the committed multiline label and size.
for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line:find('canvas file=', 1, true) then vim.api.nvim_win_set_cursor(0, {row+1, 0}); break end
end
canvas.open()
editor.open(buf, 1, 'box', canvas.rerender)
draft = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(draft, 0, -1, false,
  { 'shape: br', 'w: 3', 'h: 1', 'fg:', 'bg:', 'text_color:', '', 'label:', 'Temporary' })
vim.cmd('write')
assert(s.shapes[1].label == 'Temporary' and vim.bo[buf].modified)
vim.cmd('quit')
vim.cmd('edit!')
vim.wait(25, function() return false end)
assert(s.shapes[1].label == saved.shapes['1'].label, 'reload lost the saved multiline label')
assert(s.shapes[1].width == saved.shapes['1'].width and s.shapes[1].height == saved.shapes['1'].height)
assert(not vim.bo[buf].modified)
