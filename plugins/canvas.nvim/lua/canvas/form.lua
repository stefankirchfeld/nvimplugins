local M = {}
local state = require('canvas.state')
local scene = require('canvas.scene')
local render = require('canvas.render')
local ns = vim.api.nvim_create_namespace('canvas_nvim_editor')

local function serialize(object, kind)
  local lines
  if kind == 'box' then
    lines = { 'shape: ' .. scene.token_for(object, kind), 'w: ' .. object.width, 'h: ' .. object.height,
      'fg: ' .. (object.fg or ''), 'bg: ' .. (object.bg or ''), 'text_color: ' .. (object.text_color or '') }
    if object.outline == 'diamond' then
      table.remove(lines, 3)
      lines[2] = 'size: ' .. (scene.diamond_size(object) or '')
    end
    lines[#lines+1] = 'kind: ' .. (object.kind or '')
    lines[#lines+1] = 'role: ' .. (object.role or '')
    lines[#lines+1] = 'parent_id: ' .. (object.parent_id or '')
  else
    lines = { 'shape: ' .. scene.token_for(object, kind), 'from: ' .. object.from_id,
      'to: ' .. (object.to_id or ''), 'route: ' .. (object.style or 'default'),
      'to_side: ' .. (object.forceConnectToSide or '') }
    if not object.to_id then
      lines[#lines+1] = 'row: ' .. (object.target_row or 1)
      lines[#lines+1] = 'col: ' .. (object.target_col or 1)
    end
  end
  lines[#lines+1] = ''
  lines[#lines+1] = 'label:'
  for _, line in ipairs(render.label_lines(object.label)) do lines[#lines+1] = line end
  return lines
end

local function parse(lines, kind)
  local fields, rows, label_at = {}, {}, nil
  local allowed = kind == 'box' and { shape=true, w=true, h=true, size=true, fg=true, bg=true, text_color=true, kind=true, role=true, parent_id=true }
    or { shape=true, from=true, to=true, route=true, row=true, col=true, to_side=true }
  for row, line in ipairs(lines) do
    if line == 'label:' then label_at = row; break end
    if line:match('%S') then
      local key, value = line:match('^([%w_]+):%s*(.-)%s*$')
      if not key or not allowed[key] then return nil, row, 'unknown field' end
      if fields[key] ~= nil then return nil, row, 'duplicate field: ' .. key end
      fields[key], rows[key] = value, row
    end
  end
  if not label_at then return nil, #lines, 'missing label: section' end
  local last = #lines
  if kind ~= 'box' then
    while last > label_at + 1 and not lines[last]:match('%S') do last = last - 1 end
  end
  local function number(key)
    return fields[key] ~= nil and (tonumber(fields[key]) or fields[key]) or nil
  end
  local text = table.concat(vim.list_slice(lines, label_at+1, last), string.char(10))
  local values = { shape=fields.shape, label=text }
  if kind == 'box' then
    values.width, values.height = number('w'), number('h')
    values.size = fields.size ~= '' and number('size') or nil
    for _, key in ipairs({ 'fg', 'bg', 'text_color' }) do values[key] = fields[key] end
    values.kind, values.role = fields.kind, fields.role
    values.parent_id = fields.parent_id == '' and 0 or number('parent_id')
    rows.width, rows.height = rows.w, rows.h
  else
    values.from_id = number('from')
    values.to_id = fields.to == '' and 0 or number('to')
    values.route, values.row, values.col = fields.route, number('row'), number('col')
    values.forceConnectToSide = fields.to_side
    rows.forceConnectToSide = rows.to_side
    rows.from_id, rows.to_id = rows.from, rows.to
  end
  rows.label = label_at + 1
  return values, rows
end

function M.open(source_buf, id, kind, rerender, vertical)
  local s = state.for_buf(source_buf)
  local source_was_active = s.active
  local objects = kind == 'conn' and s.conns or s.shapes
  local object = objects[id]
  local scope = vim.fn.sha256(s.canvas_file or ''):sub(1, 12)
  local name = 'canvas-edit://' .. source_buf .. '/' .. scope .. '/' .. kind .. '/' .. id
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    local win = vim.fn.bufwinid(existing)
    if win ~= -1 then vim.api.nvim_set_current_win(win); return end
  end
  local buf = existing ~= -1 and existing or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  local lines = kind == 'text' and (object.lines or { object.label or '' }) or serialize(object, kind)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = kind == 'text' and 'text' or 'canvas-edit'
  vim.cmd(vertical and 'botright vsplit' or 'botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = true
  local group = vim.api.nvim_create_augroup('canvas_editor_' .. buf, { clear=true })
  vim.b[buf].canvas_target_id = id
  vim.b[buf].canvas_target_kind = kind

  local function preview()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if kind == 'text' then return end
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line == 'label:' then break end
      local token = line:match('^shape:%s*(.-)%s*$')
      if token then
        local mods, description = scene.decode_token(token, kind)
        vim.api.nvim_buf_set_extmark(buf, ns, row-1, 0, {
          virt_text={ { '  ' .. description, mods and 'Comment' or 'DiagnosticError' } }, virt_text_pos='eol',
        })
      end
      if line:match('^size:%s*$') and object.outline == 'diamond' then
        vim.api.nvim_buf_set_extmark(buf, ns, row-1, 0, {
          virt_text={{'  custom ' .. object.width .. '×' .. object.height .. '; enter size to resize', 'Comment'}}, virt_text_pos='eol',
        })
      end
      local help
      if line:match('^kind:') then
        help = 'meaning: service, database, queue, decision (custom names allowed)'
      elseif line:match('^role:') then
        help = 'structure: node = element; container = boundary; annotation = note'
      end
      if help then
        vim.api.nvim_buf_set_extmark(buf, ns, row-1, 0, {
          virt_text={{'  ' .. help, 'Comment'}}, virt_text_pos='eol',
        })
      end
    end
  end
  preview()
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group=group, buffer=buf, callback=preview })
  -- QuitPre runs before Vim's modified-buffer check, so :q can discard this draft.
  vim.api.nvim_create_autocmd('QuitPre', { group=group, buffer=buf, callback=function() vim.bo[buf].modified = false end })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group=group, buffer=buf, callback=function()
    local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local current_state = state.for_buf(source_buf)
    local current_objects = kind == 'conn' and current_state.conns or current_state.shapes
    if not vim.api.nvim_buf_is_loaded(source_buf) or current_state ~= s or current_objects ~= objects
      or objects[id] ~= object or (source_was_active and not current_state.active) then
      error('canvas: source canvas was closed or changed')
    end
    local fields, rows, message
    if kind == 'text' then fields, rows = { lines=current }, { label=1 }
    else fields, rows, message = parse(current, kind) end
    local valid, result
    if fields then valid, result = pcall(scene.apply, s, { op='update', id=id, fields=fields }) end
    if not valid then
      local row
      if fields then
        row = type(result) == 'table' and rows[result.field] or 1
        message = tostring(result)
      else row = rows end
      vim.bo[buf].modified = true
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.api.nvim_buf_set_extmark(buf, ns, (row or 1)-1, 0, {
        virt_text={ { '  ' .. message, 'DiagnosticError' } }, virt_text_pos='eol',
      })
      error('canvas: ' .. message)
    end
    s.grid_cache = nil
    local ok, err = pcall(rerender, source_buf)
    if not ok then objects[id] = object; s.grid_cache = nil; error(err) end
    object = objects[id]
    vim.bo[buf].modified = false
    preview()
  end })

  -- Follow the diagram cursor without taking focus or replacing an edited draft.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinEnter' }, { group=group, buffer=source_buf, callback=function()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= buf or vim.bo[buf].modified
      or vim.api.nvim_get_current_buf() ~= source_buf then return end
    local current = state.for_buf(source_buf)
    if current ~= s or not s.active or not s.row_start
      or (kind == 'conn' and s.conns or s.shapes) ~= objects then return end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row < s.row_start or row > s.row_end then return end
    local commands = require('canvas.commands')
    local target_id, target = commands.shape_at_cursor(source_buf, row-s.row_start+1, vim.fn.virtcol('.'))
    local target_kind = target and (target.variant == 't' and 'text' or 'box') or nil
    if not target then
      target_id, target = commands.conn_at_cursor(source_buf, row-s.row_start+1, vim.fn.virtcol('.'))
      target_kind = 'conn'
    end
    if not target or (target_id == id and target_kind == kind and target == object) then return end
    local target_name = 'canvas-edit://' .. source_buf .. '/' .. scope .. '/' .. target_kind .. '/' .. target_id
    local other = vim.fn.bufnr(target_name)
    if other ~= -1 and other ~= buf then
      -- Renaming creates an unloaded alternate-name buffer in Neovim.
      if vim.api.nvim_buf_is_loaded(other) then return end
      vim.api.nvim_buf_delete(other, {force=true})
    end
    id, kind, object = target_id, target_kind, target
    objects = kind == 'conn' and s.conns or s.shapes
    vim.api.nvim_buf_set_name(buf, target_name)
    local content = kind == 'text' and (object.lines or {object.label or ''}) or serialize(object, kind)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.bo[buf].filetype = kind == 'text' and 'text' or 'canvas-edit'
    vim.bo[buf].modified = false
    vim.b[buf].canvas_target_id, vim.b[buf].canvas_target_kind = id, kind
    vim.api.nvim_win_set_cursor(win, {1,0})
    preview()
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group=group, buffer=buf, callback=function()
    vim.api.nvim_del_augroup_by_id(group)
  end })
end

return M
