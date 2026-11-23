local M = {}
local config = { keymaps = {} }
local mappings = require('canvas.mappings')
function M.setup(opts)
  config = opts or {}
  if config.keymaps == nil then config.keymaps = {} end
end
local function bind(buf, action, default, callback, opts)
  local name = action:sub(1,1):upper() .. action:sub(2):gsub('_(%l)', string.upper)
  mappings.set(buf, 'canvas', '<Plug>(Canvas' .. name .. ')', callback, opts)
  if config.keymaps == false then return end
  local key = config.keymaps[action]
  if key == nil then key = default end
  if key == false then return end
  mappings.set(buf, 'canvas', key, callback, opts)
end


local state   = require('canvas.state')
local parser  = require('canvas.parser')
local Grid    = require('canvas.grid')
local render  = require('canvas.render')
local persist = require('canvas.persist')
local editor  = require('canvas.form')
local indicator = require('canvas.indicator')
local scene = require('canvas.scene')
local session = require('canvas.session')
local markdown = require('canvas.markdown')
local outlines = require('canvas.outlines')

local refresh_all_extmarks
local highlight_canvas

local ALLOWED_FT = { [''] = true, txt = true, text = true, markdown = true }

-- ─── Highlight groups ────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, 'CanvasBox',       { fg = '#89b4fa' })
  vim.api.nvim_set_hl(0, 'CanvasLabel',     { fg = '#cdd6f4', bold = true })
  vim.api.nvim_set_hl(0, 'CanvasConn',      { fg = '#6c7086' })
  vim.api.nvim_set_hl(0, 'CanvasConnLabel', { fg = '#a6adc8' })
  vim.api.nvim_set_hl(0, 'CanvasId',        { fg = '#f9e2af', bold = true })
end

-- ─── Box-drawing highlight + label highlight ─────────────────────────────────

local BOX_CHARS = {
  ['┌']=true,['┐']=true,['└']=true,['┘']=true,
  ['─']=true,['│']=true,['├']=true,['┤']=true,
  ['┬']=true,['┴']=true,['┼']=true,
  ['╵']=true,['╶']=true,['╷']=true,['╴']=true,
  ['╱']=true,['╲']=true,['+']=true,
}

-- Convert a zero-based display column to a zero-based byte offset.
local function char_to_byte(line, char_col)
  return render.byte_col(line, char_col)
end

highlight_canvas = function(buf)
  local s = state.for_buf(buf)
  if not s.row_start then return end
  vim.api.nvim_buf_clear_namespace(buf, state.ns_hl, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, s.row_start - 1, s.row_end, false)

  -- Build a set of zone {row, col} cells belonging to colored shape borders,
  -- so the BOX_CHARS scan can skip them (letting the color pass win).
  local colored_border = {}  -- key: "zrow,zcol" → true
  for _, shape in pairs(s.shapes) do
    if shape.fg or shape.bg then
      if shape.outline == 'diamond' then
        for _, cell in ipairs(outlines.geometry(shape).cells) do colored_border[cell.row .. ',' .. cell.col] = true end
      end
      local ztop    = shape.top
      local zbottom = shape.top + shape.height - 1
      local zleft   = shape.left
      local zright  = shape.left + shape.width - 1
      for zc = zleft, zright do
        colored_border[ztop    .. ',' .. zc] = true
        colored_border[zbottom .. ',' .. zc] = true
      end
      for zr = ztop + 1, zbottom - 1 do
        colored_border[zr .. ',' .. zleft]  = true
        colored_border[zr .. ',' .. zright] = true
      end
    end
  end

  for lnum, line in ipairs(lines) do
    local abs_lnum = lnum + s.row_start - 1
    local zrow = lnum  -- 1-indexed zone row
    local col = 0
    local zcol = 1
    local i = 1
    while i <= #line do
      local byte = line:byte(i)
      local clen = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or byte >= 0xC0 and 2 or 1
      local ch = line:sub(i, i + clen - 1)
      if BOX_CHARS[ch] and not colored_border[zrow .. ',' .. zcol] then
        vim.api.nvim_buf_add_highlight(buf, state.ns_hl, 'CanvasBox', abs_lnum - 1, col, col + clen)
      end
      col = col + clen
      zcol = zcol + 1
      i = i + clen
    end
  end

  -- Per-shape color highlights (border fg, interior bg, label text_color)
  for id, shape in pairs(s.shapes) do
    if shape.fg or shape.bg or shape.text_color then
      local hl_border = 'CanvasShapeBorder_' .. id
      local hl_fill   = 'CanvasShapeFill_'   .. id
      vim.api.nvim_set_hl(0, hl_border, { fg = shape.fg, bg = shape.bg })
      if shape.bg then
        vim.api.nvim_set_hl(0, hl_fill, { bg = shape.bg })
      end

      -- abs row indices (0-indexed for nvim API)
      local abs_top    = s.row_start + shape.top - 2
      local abs_bottom = s.row_start + shape.top + shape.height - 3

      if shape.outline == 'diamond' then
        local geometry = outlines.geometry(shape)
        if shape.bg then
          for zrow, bounds in pairs(geometry.rows) do
            local line = lines[zrow] or ''
            vim.api.nvim_buf_add_highlight(buf, state.ns_hl, hl_fill, s.row_start+zrow-2,
              render.byte_col(line, bounds[1]-1), render.byte_col(line, bounds[2]))
          end
        end
        for _, cell in ipairs(geometry.cells) do
          local line = lines[cell.row] or ''
          vim.api.nvim_buf_add_highlight(buf, state.ns_hl, hl_border, s.row_start+cell.row-2,
            render.byte_col(line, cell.col-1), render.byte_col(line, cell.col))
        end
      else
        for abs_row0 = abs_top, abs_bottom do
          local lnum = abs_row0 - (s.row_start - 1) + 1  -- 1-indexed into lines[]
          local line = lines[lnum] or ''
          local byte_left  = char_to_byte(line, shape.left - 1)
          local byte_right = char_to_byte(line, shape.left - 1 + shape.width)

          if abs_row0 == abs_top or abs_row0 == abs_bottom then
            -- full border row
            vim.api.nvim_buf_add_highlight(buf, state.ns_hl, hl_border,
              abs_row0, byte_left, byte_right)
          else
            -- left border char
            local byte_left1 = char_to_byte(line, shape.left)
            vim.api.nvim_buf_add_highlight(buf, state.ns_hl, hl_border,
              abs_row0, byte_left, byte_left1)
            -- interior fill
            if shape.bg then
              local byte_right1 = char_to_byte(line, shape.left - 1 + shape.width - 1)
              vim.api.nvim_buf_add_highlight(buf, state.ns_hl, hl_fill,
                abs_row0, byte_left1, byte_right1)
            end
            -- right border char
            local byte_right1 = char_to_byte(line, shape.left - 1 + shape.width - 1)
            vim.api.nvim_buf_add_highlight(buf, state.ns_hl, hl_border,
              abs_row0, byte_right1, byte_right)
          end
        end
      end
    end
  end

  -- Use the same block layout as rendering for every label line.
  for _, shape in pairs(s.shapes) do
    for _, label in ipairs(shape:label_positions()) do
      if label.text ~= '' and label.row >= 1 and label.row <= #lines then
        local row = s.row_start + label.row - 2
        local line = lines[label.row] or ''
        local first = render.byte_col(line, math.max(0,label.col-1))
        local last = render.byte_col(line, label.col-1 + vim.fn.strdisplaywidth(label.text))
        local group = 'CanvasLabel'
        if shape.text_color then
          group = 'CanvasShapeLabel_' .. shape.id
          vim.api.nvim_set_hl(0, group, { fg=shape.text_color, bg=shape.bg })
        end
        vim.api.nvim_buf_add_highlight(buf, state.ns_hl, group, row, first, last)
      end
    end
  end
end

-- ─── Virtual text IDs ─────────────────────────────────────────────────────────

local function place_id_extmark(buf, id, shape)
  if shape.variant == 't' then return nil end
  local s    = state.for_buf(buf)
  local row0 = s.row_start + shape.top - 2
  local lc   = vim.api.nvim_buf_line_count(buf)
  if row0 < 0 or row0 >= lc then return nil end
  local char_col = shape.left - 1
  local lines = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)
  local line = lines[1] or ''
  local byte_col = render.byte_col(line, char_col)
  return vim.api.nvim_buf_set_extmark(buf, state.ns_id, row0, byte_col, {
    virt_text     = { { '[' .. id .. ']', 'CanvasId' } },
    virt_text_pos = 'overlay',
    priority      = 200,
  })
end

refresh_all_extmarks = function(buf)
  local s = state.for_buf(buf)
  if not s.row_start then return end
  vim.api.nvim_buf_clear_namespace(buf, state.ns_id, 0, -1)
  for id, shape in pairs(s.shapes) do
    shape.extmark_id = place_id_extmark(buf, id, shape)
  end
end

-- ─── Command execution ────────────────────────────────────────────────────────

function M.register_conn(buf, _id)
  refresh_all_extmarks(buf)
  highlight_canvas(buf)
end

local commands

local function execute_command(buf, cmd_str, zone_row, col, reuse_id)
  if not commands then commands = require('canvas.commands') end
  local parsed = parser.parse(cmd_str)
  if not parsed then
    vim.notify('canvas: invalid command: ' .. cmd_str, vim.log.levels.WARN)
    return
  end
  commands.execute(buf, parsed, zone_row, col, reuse_id)
end

local function to_zone_row(buf, buf_row)
  return buf_row - state.for_buf(buf).row_start + 1
end

-- ─── Floating command input ───────────────────────────────────────────────────

local function open_input_float(buf, prefill, on_commit)
  local s = state.for_buf(buf)
  if s.input_win and vim.api.nvim_win_is_valid(s.input_win) then
    vim.api.nvim_win_close(s.input_win, true)
  end

  local ibuf = vim.api.nvim_create_buf(false, true)
  -- Set before FileType/BufEnter so completion never starts in this prompt.
  vim.b[ibuf].completion = false -- blink.cmp's buffer-local opt-out
  vim.bo[ibuf].complete = ''
  vim.bo[ibuf].omnifunc = ''
  vim.bo[ibuf].completefunc = ''
  local cmp = package.loaded.cmp
  if cmp then
    vim.api.nvim_buf_call(ibuf, function() cmp.setup.buffer({ enabled=false }) end)
  end
  vim.bo[ibuf].buftype  = 'nofile'
  vim.bo[ibuf].filetype = 'canvas-input'
  if prefill and prefill ~= '' then
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { prefill })
  end

  local canvas_win = vim.fn.bufwinid(buf)
  if canvas_win == -1 then canvas_win = 0 end
  local cursor  = vim.api.nvim_win_get_cursor(canvas_win)
  local win_row = cursor[1] - vim.api.nvim_win_call(canvas_win, function() return vim.fn.line('w0') end)
  local win_col = vim.api.nvim_win_call(canvas_win, function() return vim.fn.virtcol('.') end) - 1

  local iwin = vim.api.nvim_open_win(ibuf, true, {
    relative = 'win', win = canvas_win,
    row = win_row, col = win_col,
    width = 40, height = 1,
    style = 'minimal', border = 'single',
    title = ' canvas ', title_pos = 'center',
  })

  s.input_win = iwin
  s.input_buf = ibuf
  vim.cmd('startinsert!')

  local function close_input()
    if vim.api.nvim_win_is_valid(iwin) then vim.api.nvim_win_close(iwin, true) end
    s.input_win = nil
    s.input_buf = nil
    vim.cmd('stopinsert')
  end

  local function try_commit()
    vim.schedule(function()
      local text = (vim.api.nvim_buf_get_lines(ibuf, 0, -1, false))[1] or ''
      if parser.parse(text) then close_input(); on_commit(text) end
    end)
  end

  vim.keymap.set('i', ')',           function() vim.api.nvim_feedkeys(')', 'n', false); try_commit() end, { buffer = ibuf, nowait = true })
  vim.keymap.set('i', '<CR>',        function() try_commit() end,   { buffer = ibuf, nowait = true })
  vim.keymap.set({'i','n'}, '<Esc>', function() close_input() end,  { buffer = ibuf, nowait = true })
end

-- ─── Move mode ───────────────────────────────────────────────────────────────

local move_state = {}

local function exit_move_mode(buf)
  local ms = move_state[buf]
  if not ms then return end
  local was_id = ms.id
  move_state[buf] = nil
  if state.for_buf(buf).active then indicator.show(buf) end
  vim.notify('canvas: move mode off (box ' .. tostring(was_id) .. ')', vim.log.levels.INFO)
  mappings.clear(buf, 'move')
end

local function enter_move_mode(buf, id)
  move_state[buf] = { id = id, busy = false }
  indicator.show(buf, id)
  vim.notify('canvas: move mode — hjkl to move, <CR>/<Esc> to finish', vim.log.levels.INFO)

  local function move(dr, dc)
    local ms = move_state[buf]
    if not ms or ms.busy then return end
    ms.busy = true
    local s     = state.for_buf(buf)
    local shape = s.shapes[ms.id]
    if not shape then exit_move_mode(buf); return end
    scene.apply(s, { op='move', id=ms.id, fields={ dr=dr, dc=dc } })
    shape = s.shapes[ms.id]
    M.rerender(buf)
    local abs_row = s.row_start + shape.top - 1
    vim.schedule(function()
      if move_state[buf] then
        pcall(vim.api.nvim_win_set_cursor, 0, { abs_row, shape.left - 1 })
      end
      if move_state[buf] then move_state[buf].busy = false end
    end)
  end

  local mopts = { buffer = buf, nowait = true, silent = true }
  mappings.set(buf, 'move', 'h',        function() move( 0,-1) end, mopts)
  mappings.set(buf, 'move', 'l',        function() move( 0, 1) end, mopts)
  mappings.set(buf, 'move', 'k',        function() move(-1, 0) end, mopts)
  mappings.set(buf, 'move', 'j',        function() move( 1, 0) end, mopts)
  mappings.set(buf, 'move', 'H',        function() move( 0,-3) end, mopts)
  mappings.set(buf, 'move', 'L',        function() move( 0, 3) end, mopts)
  mappings.set(buf, 'move', 'K',        function() move(-3, 0) end, mopts)
  mappings.set(buf, 'move', 'J',        function() move( 3, 0) end, mopts)
  mappings.set(buf, 'move', '<Left>',   function() move( 0,-1) end, mopts)
  mappings.set(buf, 'move', '<Right>',  function() move( 0, 1) end, mopts)
  mappings.set(buf, 'move', '<Up>',     function() move(-1, 0) end, mopts)
  mappings.set(buf, 'move', '<Down>',   function() move( 1, 0) end, mopts)
  mappings.set(buf, 'move', '<S-Left>',  function() move( 0,-3) end, mopts)
  mappings.set(buf, 'move', '<S-Right>', function() move( 0, 3) end, mopts)
  mappings.set(buf, 'move', '<S-Up>',    function() move(-3, 0) end, mopts)
  mappings.set(buf, 'move', '<S-Down>',  function() move( 3, 0) end, mopts)
  mappings.set(buf, 'move', '<CR>',     function() exit_move_mode(buf) end, mopts)
  mappings.set(buf, 'move', '<Esc>',    function() exit_move_mode(buf) end, mopts)
end

-- ─── Re-render (zone-scoped) ──────────────────────────────────────────────────

-- overlay: optional list of {row, col, char} stamped after scene build (for previews)
function M.rerender(buf, overlay)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local s = state.for_buf(buf)
  if not s.row_start then return end

  -- Markdown: re-scan fence bounds in case fence grew/shifted
  local ft = vim.bo[buf].filetype
  if ft == 'markdown' then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local anchor = s.fence_mark and vim.api.nvim_buf_get_extmark_by_id(buf, state.ns_fence, s.fence_mark, {}) or {}
    local opener = anchor[1] and anchor[1]+1 or s.row_start-1
    for _, fence in ipairs(markdown.fences(lines)) do
      if fence.opener == opener then
        s.row_start = fence.row_start
        s.row_end = math.max(fence.row_start, fence.row_end)
        break
      end
    end
  end

  local zone_lines = vim.api.nvim_buf_get_lines(buf, s.row_start - 1, s.row_end, false)
  local is_md = ft == 'markdown'

  local g = Grid.new()
  g:build(s.shapes, s.conns)
  g:apply_overlay(overlay)
  -- markdown: preserve zone height so fence bounds stay stable
  -- Full buffers keep the one empty line required by Neovim.
  local height = is_md and #zone_lines or 1
  local new_lines = g:lines(height)
  if not vim.deep_equal(zone_lines, new_lines) or session.pending(buf) then
    local last = is_md and s.row_end or vim.api.nvim_buf_line_count(buf)
    s.row_end = g:flush(buf, s.row_start, last, height)
    session.changed(buf)
  end

  refresh_all_extmarks(buf)
  highlight_canvas(buf)
  indicator.refresh(buf)
end

-- ─── Markdown fence helpers ───────────────────────────────────────────────────

local function fresh_markdown_path(buf)
  local base = persist.default_sidecar_path(buf)
  local path, suffix = base, 1
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local function used(candidate)
    if vim.fn.filereadable(candidate) == 1 or state.scenes(buf)[candidate] then return true end
    for _, line in ipairs(lines) do if line:find(candidate, 1, true) then return true end end
    return false
  end
  while used(path) do
    suffix = suffix + 1
    path = base:gsub('%.canvas%.json$', '_' .. suffix .. '.canvas.json')
  end
  return path
end

local function find_canvas_fence(buf)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, fence in ipairs(markdown.fences(lines)) do
    if cursor_row >= fence.opener and cursor_row <= fence.row_end+1 then
      local file_attr = fence.info:match('^canvas%s+file=(%S+)')
      if file_attr and file_attr:sub(1, 1) == '"' then
        local ok, decoded = pcall(vim.json.decode, fence.info:match('file=(.+)%s*$'))
        file_attr = ok and type(decoded) == 'string' and decoded or nil
      end
      local path
      if file_attr then
        local base_dir = vim.api.nvim_buf_get_name(buf):match('(.+/)') or './'
        path = (file_attr:sub(1,1) == '/' or file_attr:sub(1,1) == '~')
          and vim.fn.expand(file_attr) or vim.fn.simplify(base_dir .. file_attr)
        path = vim.fn.fnamemodify(path, ':p')
      else
        path = persist.default_sidecar_path(buf, index)
      end
      if fence.row_end < fence.row_start then
        vim.api.nvim_buf_set_lines(buf, fence.row_start-1, fence.row_start-1, false, { '' })
        fence.row_end = fence.row_start
      end
      return fence.row_start, fence.row_end, path, fence.opener
    end
  end
end

local function insert_canvas_fence(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local path = fresh_markdown_path(buf)
  vim.api.nvim_buf_set_lines(buf, row-1, row-1, false,
    { '```canvas file=' .. vim.json.encode(path), '', '```' })
  return row+1, row+1, path, row
end

-- ─── Activate / deactivate ───────────────────────────────────────────────────

-- ─── Activate / deactivate ───────────────────────────────────────────────────

local function deactivate(buf)
  local s = state.for_buf(buf)
  if not s.active then return end
  s.active    = false
  s.row_start = nil
  s.row_end   = nil
  vim.api.nvim_buf_clear_namespace(buf, state.ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, state.ns_hl, 0, -1)
  exit_move_mode(buf)
  indicator.hide(buf)
  mappings.clear(buf, 'canvas')
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then vim.wo[win].virtualedit = '' end
  end
  vim.notify('canvas: off', vim.log.levels.INFO)
end

local function activate(buf, row_start, row_end)
  setup_highlights()
  local s = state.for_buf(buf)
  s.active    = true
  s.row_start = row_start
  s.row_end   = row_end

  local opts = { buffer = buf, nowait = true, silent = true }

  bind(buf, 'draw', '<leader>dc', function()
    local buf_row = vim.fn.line('.')
    local col     = vim.fn.virtcol('.')
    local zrow    = to_zone_row(buf, buf_row)
    open_input_float(buf, '', function(cmd_str)
      execute_command(buf, cmd_str, zrow, col)
    end)
  end, opts)

  local function edit_at_cursor(vertical)
    if not commands then commands = require('canvas.commands') end
    local zrow = to_zone_row(buf, vim.fn.line('.'))
    local col  = vim.fn.virtcol('.')
    local id, shape = commands.shape_at_cursor(buf, zrow, col)
    if id then
      editor.open(buf, id, shape.variant == 't' and 'text' or 'box', M.rerender, vertical)
      return
    end
    local conn_id = commands.conn_at_cursor(buf, zrow, col)
    if conn_id then
      editor.open(buf, conn_id, 'conn', M.rerender, vertical)
      return
    end
    if not vertical then vim.api.nvim_feedkeys('e', 'n', true) end
  end

  -- e must wait for a possible v so the longer mapping can match.
  local edit_opts = vim.tbl_extend('force', opts, { nowait = false })
  bind(buf, 'edit', 'e', function() edit_at_cursor(false) end, edit_opts)
  bind(buf, 'edit_vertical', 'ev', function() edit_at_cursor(true) end, edit_opts)

  bind(buf, 'delete', 'd', function()
    if not commands then commands = require('canvas.commands') end
    local zrow = to_zone_row(buf, vim.fn.line('.'))
    local col  = vim.fn.virtcol('.')
    local id   = commands.shape_at_cursor(buf, zrow, col)
    if id then
      scene.apply(s, { op='delete', id=id })
      M.rerender(buf)
      return
    end
    local conn_id = commands.conn_at_cursor(buf, zrow, col)
    if conn_id then scene.apply(s, { op='delete', id=conn_id }); M.rerender(buf); return end
    vim.api.nvim_feedkeys('d', 'n', true)
  end, opts)

  bind(buf, 'move', 'm', function()
    if not commands then commands = require('canvas.commands') end
    local zrow = to_zone_row(buf, vim.fn.line('.'))
    local col  = vim.fn.virtcol('.')
    local id   = commands.shape_at_cursor(buf, zrow, col)
    if not id then vim.api.nvim_feedkeys('m', 'n', true); return end
    enter_move_mode(buf, id)
  end, opts)

  bind(buf, 'rerender', '<leader>dr', function() M.rerender(buf) end, opts)
  bind(buf, 'quit', 'q',          function() deactivate(buf) end, opts)

  vim.wo.virtualedit = 'all'
  M.rerender(buf)
  indicator.show(buf)
  if config.on_attach then config.on_attach(buf) end
  vim.notify('canvas: on  — <leader>dc draw  e/ev edit  d delete  m move  q exit', vim.log.levels.INFO)
end

-- ─── Entry point ─────────────────────────────────────────────────────────────

function M.open()
  local buf = vim.api.nvim_get_current_buf()
  local s = state.for_buf(buf)
  local ft = vim.bo[buf].filetype
  if not ALLOWED_FT[ft] then
    vim.notify('canvas: only supported in txt, markdown, or unnamed buffers', vim.log.levels.WARN)
    return
  end

  local baseline = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.api.nvim_buf_get_name(buf) == '' and vim.bo[buf].modified then baseline = { '' } end
  local row_start, row_end, path, fence_start
  if ft == 'markdown' then
    row_start, row_end, path, fence_start = find_canvas_fence(buf)
    if s.active and (not row_start or path == s.canvas_file) then deactivate(buf); return end
    if s.active then deactivate(buf) end
    if not row_start then row_start, row_end, path, fence_start = insert_canvas_fence(buf) end
    s = state.select(buf, path)
    s.fence_mark = vim.api.nvim_buf_set_extmark(buf, state.ns_fence, fence_start-1, 0,
      { id=s.fence_mark, right_gravity=true })
  else
    if s.active then deactivate(buf); return end
    row_start, row_end = 1, math.max(vim.api.nvim_buf_line_count(buf), 1)
  end

  local keep_working = session.pending(buf, s) and vim.bo[buf].modified
  s.row_start, s.row_end = row_start, row_end
  if not keep_working then
    persist.load(buf)
    session.watch(buf, deactivate, baseline)
  end
  activate(buf, row_start, row_end)
end

-- Called by commands module after drawing a box (kept for API compat)
function M.register_box(buf, _id, _shape)
  local s = state.for_buf(buf)
  refresh_all_extmarks(buf)
  highlight_canvas(buf)
  s.grid_cache = nil
end

return M
