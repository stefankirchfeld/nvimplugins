local root = vim.env.AGENT_VIEW_ROOT
vim.opt.rtp:prepend(root)
vim.env.TMUX = '/tmp/routing-server,1,0'
vim.env.TMUX_PANE = '%9'
local entries = {
  { session_id = '$1', window_id = '@3', pane_id = '%10', tmux_socket = '/tmp/routing-server' },
  { session_id = '$2', window_id = '@3', pane_id = '%11', tmux_socket = '/tmp/routing-server' },
  { session_id = '$1', window_id = '@3', pane_id = '%12', tmux_socket = '/tmp/other-server' },
}
require('agent_view').records = function() return entries end
vim.system = function(args)
  return { wait = function()
    return { code = 0, stdout = args[#args] == '#{window_id}' and '@4\n' or '$1\t@3\n' }
  end }
end
local tmux = require('agent_view.tmux')
assert(tmux.target() == '%10', 'target leaked into another session/server')
assert(tmux.target('4') == nil, 'missing window selected an unrelated agent')
entries[#entries + 1] = { session_id = '$1', window_id = '@3', pane_id = '%13', tmux_socket = '/tmp/routing-server' }
assert(tmux.target() == nil, 'ambiguous agents should not be guessed')
print('PASS: prompt routing stays in the current session/server and rejects missing or ambiguous targets')
vim.cmd('qa!')
