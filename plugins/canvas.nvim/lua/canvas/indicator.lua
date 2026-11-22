local M = {}
local state = require('canvas.state')
local render = require('canvas.render')
local outlines = require('canvas.outlines')
local ns = vim.api.nvim_create_namespace('canvas_nvim_indicator')
local active = {}
local windows = {}

vim.api.nvim_set_hl(0, 'CanvasMode', { link='StatusLine', default=true })
vim.api.nvim_set_hl(0, 'CanvasMoveMode', { link='WarningMsg', default=true })
vim.api.nvim_set_hl(0, 'CanvasMoveTarget', { link='IncSearch', default=true })

local function restore(win)
  local saved = windows[win]
  if saved and vim.api.nvim_win_is_valid(win) and vim.wo[win].winbar == saved.applied then
    vim.wo[win].winbar = saved.original
  end
  windows[win] = nil
end

local function refresh_windows()
  for win in pairs(windows) do
    if not vim.api.nvim_win_is_valid(win) then windows[win] = nil end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local mode = active[buf]
    if mode and vim.api.nvim_win_get_config(win).relative == '' then
      local current = vim.wo[win].winbar
      local saved = windows[win]
      if not saved or current ~= saved.applied then
        saved = { original=current }
        windows[win] = saved
      end
      local original = saved.original
      -- Preserve expression-based winbars as an evaluated statusline fragment.
      if original:sub(1, 2) == '%!' then original = '%{%' .. original:sub(3) .. '%}' end
      local badge = mode.id and '%#CanvasMoveMode# CANVAS · MOVE %*' or '%#CanvasMode# CANVAS %*'
      saved.applied = badge .. (original ~= '' and ' ' .. original or '')
      vim.wo[win].winbar = saved.applied
    else
      restore(win)
    end
  end
  vim.cmd('redrawstatus')
end

local function highlight_target(buf, id)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not id then return end
  local s = state.for_buf(buf)
  local shape = s.shapes[id]
  if not shape or not s.row_start then return end
  local top = s.row_start + shape.top - 2
  local count = vim.api.nvim_buf_line_count(buf)
  local bottom = math.min(top + shape.height - 1, count - 1)
  if top < 0 or top >= count then return end
  local lines = vim.api.nvim_buf_get_lines(buf, top, bottom + 1, false)
  local function mark(row, line, first, last)
    local start_col = render.byte_col(line, first)
    local end_col = render.byte_col(line, last)
    if start_col < 0 then return end
    if end_col < 0 then end_col = #line end
    if start_col >= end_col then return end
    -- nvim_buf_add_highlight uses priority 4096 for the shape's own colors.
    vim.api.nvim_buf_set_extmark(buf, ns, row, start_col, {
      end_col=end_col, hl_group='CanvasMoveTarget', priority=5000,
    })
  end
  for offset, line in ipairs(lines) do
    local row = top + offset - 1
    local left, right = shape.left - 1, shape.left + shape.width - 1
    if shape.outline == 'diamond' then
      for _, cell in ipairs(outlines.geometry(shape).cells) do
        if cell.row == shape.top+offset-1 then mark(row, line, cell.col-1, cell.col) end
      end
    elseif shape.variant == 't' or row == top or row == top + shape.height - 1 then
      mark(row, line, left, right)
    else
      mark(row, line, left, left + 1)
      mark(row, line, right - 1, right)
    end
  end
end

function M.show(buf, moving_id)
  active[buf] = { id=moving_id }
  highlight_target(buf, moving_id)
  refresh_windows()
end

function M.refresh(buf)
  if active[buf] then
    highlight_target(buf, active[buf].id)
    refresh_windows()
  end
end

function M.hide(buf)
  active[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  refresh_windows()
end

local group = vim.api.nvim_create_augroup('canvas_nvim_indicator', { clear=true })
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, { group=group, callback=refresh_windows })
vim.api.nvim_create_autocmd('BufWinLeave', { group=group, callback=function()
  vim.schedule(refresh_windows)
end })
vim.api.nvim_create_autocmd('BufWipeout', { group=group, callback=function(event) M.hide(event.buf) end })

return M
