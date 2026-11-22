local M = {}
local uv = vim.uv or vim.loop
function M.scope()
  if not vim.env.TMUX or not vim.env.TMUX_PANE then return nil end
  local socket = vim.env.TMUX:match('^(.-),')
  if not socket then return nil end
  local result = vim.system({ 'tmux', '-S', socket, 'display-message', '-p', '-t', vim.env.TMUX_PANE,
    '#{session_id}\t#{window_id}' }, { text = true }):wait(1500)
  if result.code ~= 0 then return nil end
  local session, window = vim.trim(result.stdout):match('^(%$%d+)\t(@%d+)$')
  if not session then return nil end
  return { socket = socket, session = session, window = window }
end
function M.target(window_index)
  local scope = M.scope()
  if not scope then return nil, 'No tmux session is available.' end
  if window_index then
    local result = vim.system({ 'tmux', '-S', scope.socket, 'display-message', '-p', '-t',
      scope.session .. ':' .. window_index, '#{window_id}' }, { text = true }):wait(1500)
    if result.code ~= 0 then return nil, 'That window is not available.' end
    scope.window = vim.trim(result.stdout)
  end
  local matches = {}
  for _, entry in ipairs(require('agent_view').records()) do
    if entry.session_id == scope.session and entry.window_id == scope.window
      and entry.pane_id ~= vim.env.TMUX_PANE and type(entry.tmux_socket) == 'string'
      and (uv.fs_realpath(entry.tmux_socket) or entry.tmux_socket) == (uv.fs_realpath(scope.socket) or scope.socket) then
      matches[#matches + 1] = entry
    end
  end
  if #matches == 1 then return matches[1].pane_id end
  return nil, #matches == 0 and 'No registered agent in this window.'
    or 'Multiple agents in this window; use :Agents to choose one.'
end
return M
