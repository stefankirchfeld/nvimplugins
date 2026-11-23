local M = {}
local uv = vim.uv or vim.loop
-- Dispose the previous monitor when this module is reloaded in a running editor.
if _G.agent_view_shutdown then _G.agent_view_shutdown() end
local config = {}
local global_keymap
local view
local icons = { idle = '', working = '󰔟', waiting = '󰋗', done = '󰄬', error = '󰅚' }

local function directory()
  return config.state_dir or vim.g.agent_view_dir or vim.env.NVIM_AGENTS_DIR or vim.env.MESA_AGENTS_DIR
    or ((vim.env.XDG_STATE_HOME or vim.fn.expand('~/.local/state')) .. '/mesa/agents')
end

function M.records()
  local entries = {}
  local scan = uv.fs_scandir(directory())
  if not scan then return entries end
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then break end
    if name:match('%.json$') then
      local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(directory() .. '/' .. name), '\n'))
      end)
      if ok and type(data) == 'table' and type(data.pid) == 'number' and data.pid > 0
        and type(data.folder) == 'string' and type(data.agent) == 'string' and icons[data.status] then
        local live, err = uv.kill(data.pid, 0)
        if live == 0 or (err and tostring(err):find('EPERM', 1, true)) then
          entries[#entries + 1] = data
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    local at = tonumber(a.updated_at) or tonumber(a.created_at) or 0
    local bt = tonumber(b.updated_at) or tonumber(b.created_at) or 0
    if at ~= bt then return at > bt end
    return tostring(a.id) < tostring(b.id)
  end)
  return entries
end

local function close()
  if not view then return end
  local previous = view
  view = nil
  previous.timer:stop()
  previous.timer:close()
  if vim.api.nvim_win_is_valid(previous.win) then vim.api.nvim_win_close(previous.win, true) end
end

local function render()
  if not view or not vim.api.nvim_buf_is_valid(view.buf) then return end
  local cursor = vim.api.nvim_win_get_cursor(view.win)[1]
  local old = view.rows and view.rows[cursor]
  view.entries = M.records()
  local colors = require('agent_view.colors').groups(view.entries, directory(), config.colors)
  local width = vim.api.nvim_win_get_width(view.win)
  local lines, rows, spans = require('agent_view.table').layout(view.entries, width, os.time(), colors, config)
  view.rows = rows
  local selected = #view.entries > 0 and 5 or 1
  for row, entry in pairs(rows) do if old and entry.id == old.id then selected = row end end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.buf, view.ns, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_add_highlight(view.buf, view.ns, span.group, span.row, span.first, span.last)
  end
  local function hint(action, default)
    local key = config.buffer_keymaps and config.buffer_keymaps[action]
    if key == nil then key = default end
    if key == false then return nil end
    if type(key) == 'table' then key = table.concat(key, '/') end
    return key:gsub('<CR>', 'Enter'):gsub('<Esc>', 'Esc')
  end
  local hints = {}
  for _, action in ipairs({ { 'focus', '<CR>', 'focus' }, { 'refresh', 'r', 'refresh' }, { 'close', 'q', 'close' } }) do
    local key = hint(action[1], action[2])
    if key then hints[#hints + 1] = key .. ' ' .. action[3] end
  end
  local text = table.concat(hints, '  ·  ')
  local available = math.max(0, width - vim.fn.strdisplaywidth(lines[1]) - 3)
  if available > 0 then
    text = require('agent_view.table').fit(text, available):gsub('%s+$', '')
    vim.api.nvim_buf_set_extmark(view.buf, view.ns, 0, 0, { virt_text = { { text, 'Comment' } }, virt_text_pos = 'right_align' })
  end
  vim.api.nvim_win_set_cursor(view.win, { math.min(selected, #lines), 0 })
end

function M.jump(entry)
  if not entry or type(entry.tmux_socket) ~= 'string' or not tostring(entry.pane_id):match('^%%%d+$') then
    vim.notify('This agent has no tmux pane to focus.', vim.log.levels.WARN)
    return
  end
  local socket, pane = entry.tmux_socket, entry.pane_id
  vim.system({ 'tmux', '-S', socket, 'display-message', '-p', '-t', pane, '#{window_id}\t#{session_id}' }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify('The agent pane is no longer available.', vim.log.levels.WARN)
        return
      end
      local window, session = vim.trim(result.stdout):match('^(@%d+)\t(%$%d+)$')
      if not window then return end
      close()
      local selected = vim.system({ 'tmux', '-S', socket, 'select-window', '-t', window }):wait()
      if selected.code ~= 0 then return end
      vim.system({ 'tmux', '-S', socket, 'select-pane', '-t', pane }):wait()
      local current_socket = vim.env.TMUX and vim.env.TMUX:match('^(.-),')
      if current_socket and (uv.fs_realpath(current_socket) or current_socket) == (uv.fs_realpath(socket) or socket) then
        local switched = vim.system({ 'tmux', '-S', socket, 'switch-client', '-t', session }):wait()
        if switched.code ~= 0 then vim.notify('Pane selected; switch tmux sessions to view it.', vim.log.levels.INFO) end
      else
        vim.cmd('botright 15new')
        vim.fn.jobstart({ 'tmux', '-S', socket, 'attach-session', '-t', session }, {
          term = true, env = { TMUX = '', TMUX_PANE = '' },
        })
        vim.cmd('startinsert')
      end
    end)
  end)
end

function M.toggle()
  if view then close(); return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'agent-view'
  local width = math.max(1, math.min(config.width or 120, vim.o.columns - 4))
  local height = math.max(1, math.min(#M.records() + 4, config.max_height or 20, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1), col = math.max(0, math.floor((vim.o.columns - width) / 2)), border = 'rounded' })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  view = { buf = buf, win = win, entries = {}, ns = vim.api.nvim_create_namespace('AgentView'), timer = uv.new_timer() }
  local function bind(action, defaults, callback, desc)
    local configured = config.buffer_keymaps and config.buffer_keymaps[action]
    local keys = configured == nil and defaults or configured
    if keys == false then return end
    if type(keys) == 'string' then keys = { keys } end
    for _, key in ipairs(keys) do vim.keymap.set('n', key, callback, { buffer = buf, desc = desc }) end
  end
  bind('close', { 'q', '<Esc>' }, close, 'Close agent overview')
  bind('refresh', { 'r' }, render, 'Refresh agents')
  bind('focus', { '<CR>' }, function()
    if view then M.jump(view.rows[vim.api.nvim_win_get_cursor(win)[1]]) end
  end, 'Focus selected agent')
  if config.on_attach then config.on_attach(buf) end
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = close })
  view.timer:start(0, 1000, vim.schedule_wrap(function()
    if not view or not vim.api.nvim_win_is_valid(view.win) then close(); return end
    render()
  end))
  render()
end

function M.setup(opts)
config = opts or {}
if _G.agent_view_shutdown then _G.agent_view_shutdown() end
if global_keymap then pcall(vim.keymap.del, 'n', global_keymap); global_keymap = nil end
if config.keymap ~= false then
  global_keymap = config.keymap or '<leader>aa'
  vim.keymap.set('n', global_keymap, M.toggle, { desc = 'Agent overview' })
end
M.close = close
vim.api.nvim_create_user_command('Agents', M.toggle, { desc = 'Show running coding agents', force = true })

-- Independent cursors: no editor deletes an event another editor still needs.
_G.agent_view_notifications = _G.agent_view_notifications or { since = os.time() * 1000, seen = {} }
local notifications = _G.agent_view_notifications
local scope
local function refresh_scope()
  if not vim.env.TMUX or not vim.env.TMUX_PANE then scope = false; return end
  vim.system({ 'tmux', 'display-message', '-p', '-t', vim.env.TMUX_PANE,
    '#{socket_path}\t#{session_id}' }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then scope = nil; return end
      local socket, session = vim.trim(result.stdout):match('^(.-)\t(%$%d+)$')
      if socket then scope = { socket = uv.fs_realpath(socket) or socket, session = session } end
    end)
  end)
end
refresh_scope()
function M.check_notifications()
  if scope == nil then return end
  local scan = uv.fs_scandir(directory() .. '/notifications')
  if not scan then return end
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then break end
    if name:match('%.json$') and not notifications.seen[name] then
      local ok, entry = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(directory() .. '/notifications/' .. name), '\n'))
      end)
      if ok and type(entry) == 'table' and type(entry.completed_at) == 'number' then
        notifications.seen[name] = true
        local same_session = config.session_scope == false or scope == false or (entry.session_id == scope.session
          and type(entry.tmux_socket) == 'string'
          and (uv.fs_realpath(entry.tmux_socket) or entry.tmux_socket) == scope.socket)
        if entry.completed_at >= notifications.since and same_session
          and type(entry.agent) == 'string' and type(entry.folder) == 'string' then
          local label = entry.agent:sub(1, 1):upper() .. entry.agent:sub(2)
          local title = type(entry.title) == 'string' and entry.title:gsub('[\r\n]', ' ') or 'Untitled session'
          local project = vim.fn.fnamemodify(entry.last_project or entry.folder, ':t')
          vim.notify(label .. ': ' .. title .. '\n' .. project .. ' · turn finished', vim.log.levels.INFO,
            { title = 'Agent finished', icon = icons.done, timeout = config.notification_timeout or 5000 })
        end
      end
    end
  end
end
local monitor = uv.new_timer()
local ticks = 0
monitor:start(1000, 1000, vim.schedule_wrap(function()
  if monitor:is_closing() then return end
  ticks = ticks + 1
  if ticks % 10 == 0 then refresh_scope() end
  M.check_notifications()
end))
local function shutdown()
  close()
  if global_keymap then pcall(vim.keymap.del, 'n', global_keymap); global_keymap = nil end
  if not monitor:is_closing() then monitor:stop(); monitor:close() end
end
_G.agent_view_shutdown = shutdown
local group = vim.api.nvim_create_augroup('AgentViewNotifications', { clear = true })
vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = shutdown })
vim.api.nvim_create_autocmd('FocusGained', { group = group, callback = M.check_notifications })
end
return M
