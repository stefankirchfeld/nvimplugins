local render = require('canvas.render')

local Grid = {}
Grid.__index = Grid

function Grid.new()
  return setmetatable({ cells = {}, total_rows = 0 }, Grid)
end

-- Build committed scene onto the grid.
-- shapes: id → Shape, conns: id → Conn
function Grid:build(shapes, conns)
  local cells = self.cells
  local total  = self.total_rows

  -- Draw all shapes
  for _, shape in pairs(shapes) do
    local need = shape.top + shape.height - 1
    for _, line in ipairs(shape:label_positions()) do need = math.max(need, line.row) end
    if need > total then
      for r = total + 1, need do cells[r] = {} end
      total = need
    end
    shape:draw(cells)
  end

  -- Sort conns: priority 1 (direct/avoid) first, then by id for determinism
  local order = {}
  for id, conn in pairs(conns) do
    order[#order+1] = { id = id, conn = conn }
  end
  table.sort(order, function(a, b)
    local pa, pb = a.conn:priority(), b.conn:priority()
    if pa ~= pb then return pa < pb end
    return a.id < b.id
  end)

  local pending_arrows = {}
  local dashed_gaps    = {}
  local conn_labels    = {}

  for _, entry in ipairs(order) do
    local conn = entry.conn

    -- Expand grid if the conn target is below current total
    local tr = conn.target_row or 1
    local tc = conn.target_col or 1  -- luacheck: ignore (tc used by route internally)
    if conn.to_id and shapes[conn.to_id] then
      tr = shapes[conn.to_id].top + shapes[conn.to_id].height - 1
    end
    if tr > total then
      for r = total + 1, tr do cells[r] = {} end
      total = tr
    end

    conn:route(cells, shapes)
    -- Detours and forced bottom attachments can extend below every shape.
    for _, cell in ipairs(conn.path or {}) do
      if cell[1] > total then
        for row = total + 1, cell[1] do cells[row] = cells[row] or {} end
        total = cell[1]
      end
    end
    conn:draw(cells, shapes, pending_arrows, dashed_gaps, conn_labels)
  end

  -- Apply dashed gaps after all routing (routing always sees solid chars)
  for _, cell in ipairs(dashed_gaps) do
    render.set(cells, cell[1], cell[2], ' ')
  end

  -- Apply arrows last so no path draw can overwrite them
  for _, a in ipairs(pending_arrows) do
    render.set(cells, a.row, a.col, a.ch)
  end

  -- Apply conn labels after dashed gaps and arrows so they're never blanked
  for _, lbl in ipairs(conn_labels) do
    render.set(cells, lbl[1], lbl[2], lbl[3])
  end

  self.total_rows = total
end

-- Stamp ephemeral overlay cells on top of committed content.
-- overlay: list of {row, col, char}
function Grid:apply_overlay(overlay)
  if not overlay then return end
  for _, cell in ipairs(overlay) do
    render.set(self.cells, cell[1], cell[2], cell[3])
  end
end

-- Text projection shared by the buffer writer and its no-change check.
function Grid:lines(zone_height)
  local cells = self.cells
  local total = self.total_rows

  local new_lines = {}
  for r = 1, total do
    local row = cells[r]
    if not row then
      new_lines[r] = ''
    else
      local max_col = 0
      for c in pairs(row) do if c > max_col then max_col = c end end
      local chars = {}
      for c = 1, max_col do chars[c] = row[c] or ' ' end
      new_lines[r] = table.concat(chars)
    end
  end
  for r = #new_lines + 1, zone_height do new_lines[r] = '' end
  return new_lines
end

-- Flush grid to buffer zone rows [row_start, row_end].
function Grid:flush(buf, row_start, row_end, zone_height)
  local new_lines = self:lines(zone_height)

  local was_mod = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, row_start - 1, row_end, false, new_lines)
  vim.bo[buf].modifiable = was_mod

  return row_start + #new_lines - 1  -- new row_end
end

return Grid
