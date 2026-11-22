# agent-view.nvim

Local Claude, Codex and Pi tracking, independent of any dashboard. Node.js built-ins write metadata; Neovim displays it. tmux is used only for navigation/session scope. No networking or transcript parsing.

## Install

Use this directory as a standalone Neovim runtime root. With lazy.nvim and a local checkout:

~~~lua
{ dir = vim.fn.expand('~/src/stefankirchfeld/nvimplugins/plugins/agent-view.nvim'),
  name = 'agent-view.nvim', lazy = false,
  config = function()
    require('agent_view').setup({ notification_timeout = 5000 })
  end }
~~~

Source scripts/agent-shell.zsh from your interactive zsh config. The claude/codex/pi functions launch in the current folder and preserve CLI arguments. Use command claude to bypass tracking deliberately.

Link bin/nvim-agent into your PATH for dashboard/other integrations. Usage:

~~~sh
nvim-agent codex --cwd "$PWD" -- resume
node scripts/install-agent-hooks.cjs
~~~

Claude loads per-launch settings, Pi loads its per-launch extension, and Codex uses guarded hooks in CODEX_HOME/hooks.json. Newly installed Codex command hooks may require native trust approval. The launcher uses --no-daemon --enable hooks to preserve per-agent environment.

## Neovim

:Agents or Space a a toggles the overview. Enter focuses the recorded pane, r refreshes, q closes. Two-line items show conversation title, status, starting folder and last edited project.

~~~lua
require('agent_view').setup({
  notification_timeout = 5000,
  keymap = '<leader>aa', -- false disables the mapping
  session_scope = true, -- false shows completion events across tmux sessions
  -- state_dir = '/your/shared/state',
})
~~~

Completion files are read independently by every editor in the same tmux socket/session. Quick next turns and agent exit cannot erase them. Notifications last five seconds; old events do not replay when an editor starts. Module reload keeps its cursor. An editor that isn't running cannot display notifications.

The optional agent_view.prompt module offers open(), open_visual(), and open_ref(). It sends only to a registered neighboring agent in the current tmux window/server. Missing or ambiguous targets preserve the prompt and report an error; it never falls back to another session. :Wai WINDOW selects a window within the current session.

## State and lifecycle

NVIM_AGENTS_DIR overrides the shared state directory. The compatibility default remains ~/.local/state/mesa/agents to preserve existing metadata during extraction; the directory name is historical and no Mesa code is required. Set state_dir and NVIM_AGENTS_DIR together when changing location.

- Live JSON files belong to launcher PIDs; normal exit removes them and editors ignore stale PIDs.
- conversations/ persists title and last-edit metadata under a hash of harness + native conversation ID. Resume restores details without restoring old status or tmux coordinates.
- notifications/ contains atomic completion events retained for seven days. Each editor deduplicates independently.

Claude/Codex hook session_id is recorded as conversation_id; live session_id remains the tmux ID. Pi uses sessionManager.getSessionId(). Write/Edit/apply_patch events capture creations and rename destinations. Arbitrary shell changes aren't inferred. Approval resolution has no separate hook: waiting resumes on the next tool event. Done means the agent turn finished, not guaranteed task success.

Existing Mesa environment variables are accepted by the writer solely for migration. To replace only old owned Codex hooks, use install-agent-hooks.cjs --migrate-from /old/scripts. To remove this plugin's hooks use --remove. Other hooks are preserved and hooks.json is backed up.

## Verification

~~~sh
node --test test/*.test.cjs
~~~

Tests use dummy harnesses and isolated state, including two real headless Neovim processes. Pi's adapter has not been exercised against a real Pi installation.
