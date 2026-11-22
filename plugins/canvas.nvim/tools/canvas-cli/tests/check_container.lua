local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local state = require('canvas.state')
local canvas = require('canvas.init')
local scene = require('canvas.scene')
vim.cmd.edit(vim.fn.fnameescape(request.document))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = request.markdown and 'markdown' or ''
local s = state.for_buf(buf)
s.canvas_file = request.state
if request.markdown then
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find('canvas file=', 1, true) then vim.api.nvim_win_set_cursor(0, {row+1, 0}); break end
  end
end
canvas.open()
local saved = scene.serialize(s)
local original = table.concat(vim.fn.readfile(request.state), string.char(10))
local outer = s.shapes[1]
vim.api.nvim_win_set_cursor(0, {s.row_start + outer.top - 1, outer.left - 1})
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  vim.wait(25, function() return false end)
end
feed('m'); feed('L'); feed('J'); feed('<Esc>')
for id, shape in pairs(s.shapes) do
  assert(shape.top == saved.shapes[tostring(id)].top+3, 'Vim container move lost vertical offset')
  assert(shape.left == saved.shapes[tostring(id)].left+3, 'Vim container move lost horizontal offset')
end
assert(vim.bo[buf].modified)
assert(table.concat(vim.fn.readfile(request.state), string.char(10)) == original)
vim.cmd('edit!')
vim.wait(25, function() return false end)
assert(vim.deep_equal(scene.serialize(s), saved), 'discard did not restore the container and its contents')
assert(not vim.bo[buf].modified)
