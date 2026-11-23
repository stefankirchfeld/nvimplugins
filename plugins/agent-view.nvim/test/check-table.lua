vim.opt.rtp:prepend(vim.env.AGENT_VIEW_ROOT)
vim.o.columns, vim.o.lines = 150, 40
vim.env.TMUX = nil
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function entry(id, status, time)
  return { id = id, conversation_id = 'conversation-' .. id, agent = 'codex', pid = vim.fn.getpid(),
    folder = '/workspace/projects', last_project = '/workspace/service', status = status,
    title = id .. ' · 漢字 conversation with a long title', updated_at = time }
end
local a, b, c = entry('a', 'done', 100), entry('b', 'idle', 200), entry('c', 'working', 300)
local function save(e) vim.fn.writefile({ vim.json.encode(e) }, dir .. '/' .. e.id .. '.json') end
save(a); save(b); save(c)
local agents = require('agent_view')
agents.setup({ state_dir = dir, keymap = false })
local records = agents.records()
assert(records[1].id == 'c' and records[2].id == 'b' and records[3].id == 'a', 'activity ordering is wrong')
local colors = require('agent_view.colors')
local first = colors.groups(records, dir)
assert(first[colors.identity(a)] ~= first[colors.identity(b)], 'pool reused a color too soon')
package.loaded['agent_view.colors'] = nil
local second = require('agent_view.colors').groups({ b, c, a }, dir)
assert(vim.deep_equal(first, second), 'colors changed after reload/reorder')
local different_launch = vim.deepcopy(c); different_launch.id = 'resumed-launch'
local resumed = require('agent_view.colors').groups({ different_launch }, dir)
assert(resumed[colors.identity(c)] == first[colors.identity(c)], 'conversation resume changed its color')
agents.toggle()
local buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(#lines == 7, 'table should use one row per agent')
assert(lines[3]:find('Conversation', 1, true) and lines[3]:find('Status', 1, true))
assert(lines[5]:find('c ·', 1, true) and lines[6]:find('idle', 1, true) and lines[7]:find('done', 1, true))
assert(not lines[6]:find('', 1, true) and not lines[7]:find('󰄬', 1, true), 'idle/done icons should be absent')
for _, line in ipairs(lines) do assert(vim.fn.strdisplaywidth(line) <= 120, 'table overflows') end
local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('AgentView'), 0, -1, { details = true })
local ghost = false
for _, mark in ipairs(marks) do if mark[4].virt_text then ghost = mark[4].virt_text[1][2] == 'Comment' end end
assert(ghost, 'key hints should be ghost text')
vim.api.nvim_win_set_cursor(0, { 6, 0 }) -- b is selected.
a.updated_at = 400; save(a)
vim.fn.maparg('r', 'n', false, true).callback()
assert(vim.api.nvim_win_get_cursor(0)[1] == 7, 'selection did not follow its agent after reorder')
local table_view = require('agent_view.table')
for _, width in ipairs({ 20, 45, 65, 90, 120 }) do
  local rendered = table_view.layout(records, width, 500, first, {})
  for _, line in ipairs(rendered) do assert(vim.fn.strdisplaywidth(line) <= width, 'narrow table overflows') end
end
agents.close()
vim.fn.delete(dir, 'rf')
print('PASS: activity table, ghost hints, sticky colors, selection and narrow layouts')
vim.cmd('qa!')
