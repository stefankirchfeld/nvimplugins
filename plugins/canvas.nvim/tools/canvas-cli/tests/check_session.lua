local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local state = require('canvas.state')
local canvas = require('canvas.init')
local commands = require('canvas.commands')
local parser = require('canvas.parser')
local editor = require('canvas.form')
local function wait() vim.wait(25, function() return false end) end
local function read() return table.concat(vim.fn.readfile(request.state), string.char(10)) end
vim.cmd.edit(vim.fn.fnameescape(request.document))
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.bo[buf].filetype = request.markdown and 'markdown' or ''
local s = state.for_buf(buf)
s.canvas_file = request.state
local original = read()
local function open()
  if request.markdown then
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find('canvas file=', 1, true) then vim.api.nvim_win_set_cursor(win, {row+1, 0}); break end
    end
  end
  canvas.open()
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  wait()
end
local function reload() vim.cmd('edit!'); wait() end
open()
assert(not vim.bo[buf].modified, 'opening an unchanged canvas made it dirty')
commands.execute(buf, parser.parse('br(20, 5, Pending)'), 10, 3)
assert(s.shapes[2] and vim.bo[buf].modified)
feed('q')
assert(read() == original, 'exiting canvas mode wrote the sidecar')
open()
assert(s.shapes[2], 'reopening lost the pending scene')
reload()
assert(not s.shapes[2] and not vim.bo[buf].modified, 'reload did not restore saved state')
assert(read() == original)

-- Color-only edits still dirty the main buffer and can be fully discarded.
open()
local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
vim.cmd('let &undolevels = &undolevels')
commands.execute(buf, { cmd='color', params={1, '#ff00ff'} }, 1, 1)
assert(vim.bo[buf].modified and s.shapes[1].fg == '#ff00ff')
assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
feed('u')
assert(not vim.bo[buf].modified and s.shapes[1].fg == '#89b4fa', 'full text revert did not restore the saved scene')
assert(read() == original)

-- Saving a property buffer only applies to working state, not to disk.
open()
editor.open(buf, 1, 'box', canvas.rerender)
local draft = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(draft, 0, -1, false,
  { 'shape: br', 'w: 20', 'h: 5', 'fg: #aabbcc', 'bg:', 'text_color:', '', 'label:', 'Saved version' })
vim.cmd('write')
assert(read() == original and vim.bo[buf].modified)
vim.cmd('quit')
feed('q')
vim.cmd('write'); wait()
assert(not vim.bo[buf].modified)
local saved = read()
assert(saved ~= original and vim.json.decode(saved).shapes['1'].label == 'Saved version')

open()
vim.api.nvim_win_set_cursor(win, {s.row_start + s.shapes[1].top-1, s.shapes[1].left-1})
feed('m'); feed('L'); feed('<Esc>')
assert(s.shapes[1].left == 6)
reload()
assert(s.shapes[1].left == 3 and s.shapes[1].label == 'Saved version', 'snapshot did not advance on successful save')

open()
commands.execute(buf, parser.parse('b(20, 5, Failed)'), 10, 3)
assert(not pcall(vim.cmd, 'write ' .. vim.fn.fnameescape(request.missing)))
assert(read() == saved, 'failed document write committed the sidecar')
assert(s.shapes[2])
reload()
assert(not s.shapes[2])

-- A property editor opened before a discard must not overwrite restored state.
open()
editor.open(buf, 1, 'box', canvas.rerender)
draft = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_win(win)
reload()
local draftwin = vim.fn.bufwinid(draft)
vim.api.nvim_set_current_win(draftwin)
assert(not pcall(vim.cmd, 'write'), 'stale property editor overwrote the restored scene')
vim.cmd('quit')

open()
commands.execute(buf, { cmd='del', params={1} }, 1, 1)
assert(next(s.shapes) == nil and read() == saved)
vim.cmd('write'); wait()
local empty = vim.json.decode(read())
assert(next(empty.shapes) == nil and next(empty.conns) == nil, 'deleting the last shape was not persisted')
assert(not vim.bo[buf].modified)
