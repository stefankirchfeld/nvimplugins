vim.opt.rtp:prepend(vim.env.AGENT_VIEW_ROOT)
local entries = {
  { agent = 'codex', id = 'one', conversation_id = 'conversation-one' },
  { agent = 'claude', id = 'two', conversation_id = 'conversation-two' },
}
if vim.env.REVERSE_COLORS == '1' then entries = { entries[2], entries[1] } end
local groups = require('agent_view.colors').groups(entries, vim.env.COLOR_STATE_DIR)
io.stdout:write(vim.json.encode(groups))
vim.cmd('qa!')
