vim.opt.rtp:prepend(vim.env.AGENT_VIEW_ROOT)
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. '/notifications', 'p')
vim.env.TMUX, vim.env.TMUX_PANE = '/tmp/notification-server,1,0', '%1'
local session = '$1'
vim.system = function(_, _, callback) callback({ code = 0, stdout = '/tmp/notification-server\t' .. session .. '\n' }) end
local agents = require('agent_view')
agents.setup({ state_dir = dir, keymap = false })
vim.wait(30, function() return false end)
local attempts, delivered = 0, 0
vim.notify = function(_, level, opts)
  attempts = attempts + 1
  assert(level == vim.log.levels.WARN and opts.title == 'Agent needs input')
  if attempts == 1 then error('temporary notifier failure') end
  delivered = delivered + 1
end
local event = { type = 'waiting', occurred_at = os.time() * 1000, session_id = '$2',
  tmux_socket = '/tmp/notification-server', agent = 'codex', folder = '/workspace', title = 'Needs input' }
vim.fn.writefile({ vim.json.encode(event) }, dir .. '/notifications/input.json')
agents.check_notifications()
assert(attempts == 0 and not _G.agent_view_notifications.seen['input.json'], 'another session consumed the event')
session = '$2'
agents.setup({ state_dir = dir, keymap = false })
vim.wait(30, function() return false end)
agents.check_notifications()
assert(attempts == 1 and not _G.agent_view_notifications.seen['input.json'], 'failed notification consumed the event')
agents.check_notifications()
agents.check_notifications()
assert(attempts == 2 and delivered == 1, 'notification failed to retry or repeated')
vim.fn.delete(dir, 'rf')
print('PASS: waiting alerts survive session mismatch and retry after notifier failure')
vim.cmd('qa!')
