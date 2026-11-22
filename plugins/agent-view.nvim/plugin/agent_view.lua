vim.api.nvim_create_user_command('Agents', function() require('agent_view').toggle() end, { desc = 'Show coding agents', force = true })
