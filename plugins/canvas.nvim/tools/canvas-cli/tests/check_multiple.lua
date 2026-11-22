local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local canvas = require('canvas.init')
local state = require('canvas.state')
local scene = require('canvas.scene')
local editor = require('canvas.form')
if request.default_base then
  require('canvas.persist').default_sidecar_path = function(_, index)
    return request.default_base:gsub('%.canvas%.json$', (index and index > 1 and '_' .. index or '') .. '.canvas.json')
  end
end
local function is_canvas(line)
  return line:sub(1,#request.fence) == request.fence and line:sub(#request.fence+1):match('^canvas') ~= nil
end
vim.cmd.edit(vim.fn.fnameescape(request.document))
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.bo[buf].filetype = 'markdown'
local function wait() vim.wait(25, function() return false end) end
local function select(index, at_tag)
  vim.api.nvim_set_current_win(win)
  local count = 0
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if is_canvas(line) then
      count = count+1
      if count == index then vim.api.nvim_win_set_cursor(win, {row+(at_tag and 0 or 1), 0}); break end
    end
  end
  canvas.open()
  return state.for_buf(buf)
end
local function body(index)
  local count, start = 0, nil
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    if is_canvas(line) then count=count+1; if count == index then start=row end
    elseif start and line == request.fence then return vim.list_slice(lines, start+1, row-1) end
  end
end
local function edit(label)
  editor.open(buf, 1, 'box', canvas.rerender)
  local draft = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(draft, 0, -1, false,
    { 'shape: br', 'w: 12', 'h: 3', 'fg:', 'bg:', 'text_color:', '', 'label:', unpack(label) })
  vim.cmd('write'); vim.cmd('quit'); wait()
end
local function disk(path) return vim.json.decode(table.concat(vim.fn.readfile(path), string.char(10))) end
local first_original, second_original = disk(request.first), disk(request.second)
local second_body = body(2)
local a = select(1, true)
assert(a.shapes[1].label == 'First' and not vim.bo[buf].modified)
edit({ 'First changed', '', '  More detail', '  Extra line' })
assert(vim.deep_equal(body(2), second_body), 'resizing first canvas changed second canvas')
local first_body = body(1)
local b = select(2)
assert(b ~= a and b.shapes[1].label == 'Second' and not a.active)
edit({ 'Second changed' })
assert(vim.deep_equal(body(1), first_body), 'editing second canvas changed first canvas')
assert(vim.deep_equal(disk(request.first), first_original) and vim.deep_equal(disk(request.second), second_original))
assert(select(1) == a and a.shapes[1].label:find('First changed', 1, true), 'switching lost first working scene')
assert(select(2) == b and b.shapes[1].label == 'Second changed', 'switching lost second working scene')
vim.cmd('write'); wait()
assert(disk(request.first).shapes['1'].label == a.shapes[1].label)
assert(disk(request.second).shapes['1'].label == b.shapes[1].label)
assert(not vim.bo[buf].modified and not b.active)
local saved_a, saved_b = scene.serialize(a), scene.serialize(b)
select(1); edit({ 'Discard first' })
select(2); edit({ 'Discard second' })
local pending_first, pending_second = body(1), body(2)
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'Inserted prose.', '' })
canvas.rerender(buf)
assert(vim.deep_equal(body(1), pending_first) and vim.deep_equal(body(2), pending_second), 'shifted fence rendered into the wrong block')
vim.cmd('edit!'); wait()
assert(vim.deep_equal(scene.serialize(a), saved_a) and vim.deep_equal(scene.serialize(b), saved_b), 'reload did not restore both scenes')
assert(not vim.bo[buf].modified)

-- Editors for the same ID in different blocks must remain distinct and scoped.
select(1)
editor.open(buf, 1, 'box', canvas.rerender)
local draft_a = vim.api.nvim_get_current_buf()
select(2)
editor.open(buf, 1, 'box', canvas.rerender)
local draft_b = vim.api.nvim_get_current_buf()
assert(draft_a ~= draft_b, 'property editor reused another canvas draft')
vim.cmd('quit')
vim.api.nvim_set_current_win(vim.fn.bufwinid(draft_a))
assert(not pcall(vim.cmd, 'write'), 'inactive canvas editor applied to another block')
vim.cmd('quit')

-- Opening a zero-line block on its fence tag creates one editable row.
local empty = select(3, true)
assert(empty.active and next(empty.shapes) == nil and vim.fn.resolve(empty.canvas_file) == vim.fn.resolve(request.empty))
assert(#body(3) == 1, 'empty canvas swallowed its closing fence')
local count = 0
for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do if is_canvas(line) then count=count+1 end end
assert(count == 3, 'opening existing canvas inserted another fence')
