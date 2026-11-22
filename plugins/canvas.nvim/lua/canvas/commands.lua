local M = {}

local state  = require('canvas.state')
local parser = require('canvas.parser')
local scene  = require('canvas.scene')

local function canvas_init() return require('canvas.init') end

-- ─── Bounds checks ───────────────────────────────────────────────────────────

function M.shape_at_cursor(buf, row, col)
  local s = state.for_buf(buf)
  local best_id, best_shape, best_area = nil, nil, math.huge
  for id, shape in pairs(s.shapes) do
    if shape:contains(row, col) then
      local area = shape.width * shape.height
      if area < best_area then
        best_id, best_shape, best_area = id, shape, area
      end
    end
  end
  return best_id, best_shape
end

-- Backwards-compat alias used by init.lua hit tests
function M.box_at_cursor(buf, row, col)
  return M.shape_at_cursor(buf, row, col)
end

function M.conn_at_cursor(buf, row, col)
  local s = state.for_buf(buf)
  for id, conn in pairs(s.conns) do
    if conn.path then
      for _, cell in ipairs(conn.path) do
        if cell[1] == row and cell[2] == col then return id, conn end
      end
    end
  end
  return nil, nil
end

-- Translate Vim's command syntax into the same requests used by the CLI.
local function command_token(base, mods)
  local chars = {}
  for key in pairs(mods or {}) do chars[#chars+1] = key end
  table.sort(chars)
  return base .. table.concat(chars)
end

function M.execute(buf, parsed, cursor_row, cursor_col, reuse_id)
  local fields, op = {}, parsed.cmd
  if op == 'box' then
    fields.width, fields.height, fields.label = parser.box_fields(parsed.params)
    if parsed.mods.x and fields.height == nil then
      fields.size, fields.width = fields.width, nil
    end
    fields.shape = command_token('b', parsed.mods)
    fields.anchor, fields.row, fields.col = parsed.anchor, cursor_row, cursor_col
    fields.cmd_str = fields.shape .. '(' .. table.concat(vim.tbl_map(tostring, parsed.params), ', ') .. ')'
  elseif op == 'conn' then
    fields.from_id, fields.to_id, fields.label, fields.route = parser.conn_params(parsed.params)
    fields.shape = command_token('c', parsed.mods)
    fields.row, fields.col = cursor_row, cursor_col
    op = 'connect'
  elseif op == 'text' then
    fields.label = table.concat(vim.tbl_map(tostring, parsed.params), ' ')
    if fields.label == '' then return end
    fields.row, fields.col = cursor_row, cursor_col
  elseif op == 'del' then
    op = 'delete'
    reuse_id = parsed.params[1]
  elseif op == 'color' then
    reuse_id, fields.fg, fields.bg, fields.text_color = parser.color_params(parsed.params)
    op = 'update'
  end
  local request = { op=op, id=reuse_id, fields=fields, placement=parsed.cmd == 'box' and 'anchor' or nil }
  local s = state.for_buf(buf)
  if reuse_id and (op == 'box' or op == 'text') and s.shapes[reuse_id] then request.op = 'update' end
  local ok, err = pcall(scene.apply, s, request)
  if not ok then vim.notify('canvas: ' .. tostring(err), vim.log.levels.WARN); return end
  canvas_init().rerender(buf)
end

return M
