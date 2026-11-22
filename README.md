# nvimplugins

Independent Neovim plugins maintained in one repository. Each plugin directory is a standalone runtime root; install either or both.

- [Canvas](plugins/canvas.nvim/README.md): editable text diagrams, a local CLI and diagram skill.
- [Agent view](plugins/agent-view.nvim/README.md): Claude/Codex/Pi status, conversation metadata and tmux navigation.

No SAP plugins or credentials are included.

## Installing from the monorepo

Local plugin managers can point directly at plugins/canvas.nvim or plugins/agent-view.nvim. For lazy.nvim with a GitHub checkout, give each selected plugin its own name and add only its runtime root:

~~~lua
{
  'stefankirchfeld/nvimplugins', name = 'canvas.nvim',
  config = function(plugin)
    local root = plugin.dir .. '/plugins/canvas.nvim'
    vim.opt.rtp:prepend(root)
    vim.cmd.source(root .. '/plugin/canvas.lua')
  end,
},
{
  'stefankirchfeld/nvimplugins', name = 'agent-view.nvim',
  config = function(plugin)
    vim.opt.rtp:prepend(plugin.dir .. '/plugins/agent-view.nvim')
    require('agent_view').setup({ notification_timeout = 5000 })
  end,
},
~~~

These GitHub examples are for future publication; this repository is currently local only. Select either entry independently. Additional plugins can have their own runtime roots under plugins/. No root-level loader enables all plugins implicitly.
