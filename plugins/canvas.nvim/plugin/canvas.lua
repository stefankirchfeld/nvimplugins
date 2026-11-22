if vim.g.loaded_personal_canvas then return end
vim.g.loaded_personal_canvas = true
vim.api.nvim_create_user_command('Canvas', function() require('canvas').open() end, { desc = 'Open editable text canvas' })
