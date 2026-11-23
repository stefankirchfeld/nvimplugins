vim.opt.rtp:prepend(vim.env.AGENT_VIEW_ROOT)
vim.g.agent_view_dir = vim.fn.tempname()
vim.env.TMUX = nil
local agents = require('agent_view')
local attached = 0
agents.setup({ keymap = '<leader>x', buffer_keymaps = { close = 'x', refresh = false, focus = 'o' },
  on_attach = function(buf) assert(vim.bo[buf].filetype == 'agent-view'); attached = attached + 1 end })
agents.toggle()
assert(attached == 1)
assert(vim.fn.maparg('x', 'n') ~= '')
assert(vim.fn.maparg('q', 'n') == '')
assert(vim.fn.maparg('r', 'n') == '')
assert(vim.fn.maparg('o', 'n') ~= '')
agents.close()
agents.setup({ keymap = false })
assert(vim.fn.maparg('<leader>x', 'n') == '', 'old global binding remained after reconfiguration')
print('PASS: Agent view custom keys, disabled mappings, on_attach and global-key cleanup')
vim.cmd('qa!')
