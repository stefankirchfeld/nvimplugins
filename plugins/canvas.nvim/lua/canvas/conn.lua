local render = require('canvas.render')
local router = require('canvas.router')
local outlines = require('canvas.outlines')

local Conn = {}
Conn.__index = Conn

function Conn.new(id, fields)
  return setmetatable({
    id         = id,
    from_id    = fields.from_id,
    to_id      = fields.to_id,
    label      = fields.label,
    style      = fields.style,
    arrow      = fields.arrow      or false,
    arrow_both = fields.arrow_both or false,
    dashed     = fields.dashed     or false,
    cmd_str    = fields.cmd_str,
    target_row = fields.target_row,
    target_col = fields.target_col,
    waypoints  = fields.waypoints,
    forceConnectToSide = fields.forceConnectToSide,
    path       = nil,
  }, Conn)
end

-- Routing priority: direct/avoid claim attachment cells first.
function Conn:priority()
  return (self.style == 'direct' or self.style == 'avoid') and 1 or 2
end

-- Pure function: expand a waypoints list into a flat cell array.
-- Each segment must be orthogonal (same row or same col).
function Conn.interpolate(waypoints)
  if not waypoints or #waypoints < 2 then return {} end
  local path = {}
  for i = 1, #waypoints - 1 do
    local r1, c1 = waypoints[i][1],   waypoints[i][2]
    local r2, c2 = waypoints[i+1][1], waypoints[i+1][2]
    local start = i == 1 and 1 or 2
    if r1 == r2 then
      local step = c2 >= c1 and 1 or -1
      local ci = c1
      local idx = 0
      while (step > 0 and ci <= c2) or (step < 0 and ci >= c2) do
        if idx >= start - 1 then path[#path+1] = {r1, ci} end
        ci = ci + step; idx = idx + 1
      end
    else
      local step = r2 >= r1 and 1 or -1
      local ri = r1
      local idx = 0
      while (step > 0 and ri <= r2) or (step < 0 and ri >= r2) do
        if idx >= start - 1 then path[#path+1] = {ri, c1} end
        ri = ri + step; idx = idx + 1
      end
    end
  end
  return path
end

-- Compute and store self.path.
-- grid: current cell grid (for A* obstacle detection)
-- shapes: id → Shape table
function Conn:route(grid, shapes)
  if self.style == 'manual' then
    self.path = Conn.interpolate(self.waypoints)
    return
  end

  local from_shape = shapes[self.from_id]
  if not from_shape then return end

  local to_shape = self.to_id and shapes[self.to_id]
  local tr = self.target_row or 1
  local tc = self.target_col or 1
  if to_shape then
    tr = to_shape.top  + math.floor(to_shape.height / 2)
    tc = to_shape.left + math.floor(to_shape.width  / 2)
  end

  local sr, sc = router.nearest_edge(from_shape, tr, tc)
  local dr, dc
  if to_shape then
    dr, dc = router.nearest_edge(to_shape, sr, sc, self.forceConnectToSide)
  else
    dr, dc = tr, tc
  end

  -- Pass raw shape-field tables to router (it expects {top,left,width,height})
  local shape_tables = {}
  for id, sh in pairs(shapes) do shape_tables[id] = sh end

  local attachment = self.forceConnectToSide and { box=to_shape, side=self.forceConnectToSide } or nil
  self.path = router.astar(grid, sr, sc, dr, dc, shape_tables, self.style, attachment)
end

-- Stamp self.path onto grid. Appends to pending_arrows, dashed_gaps, conn_labels accumulators.
-- shapes: id → Shape (needed for arrow face-normal computation)
function Conn:draw(grid, shapes, pending_arrows, dashed_gaps, conn_labels)
  local path = self.path
  if not path or #path == 0 then return end

  -- Bitmask draw
  for i, cell in ipairs(path) do
    local bits = 0
    if i > 1 then
      local p = path[i-1]
      local ddr, ddc = cell[1]-p[1], cell[2]-p[2]
      if     ddr < 0 then bits = bits + 4
      elseif ddr > 0 then bits = bits + 1
      elseif ddc < 0 then bits = bits + 2
      elseif ddc > 0 then bits = bits + 8 end
    end
    if i < #path then
      local n = path[i+1]
      local ddr, ddc = n[1]-cell[1], n[2]-cell[2]
      if     ddr < 0 then bits = bits + 1
      elseif ddr > 0 then bits = bits + 4
      elseif ddc < 0 then bits = bits + 8
      elseif ddc > 0 then bits = bits + 2 end
    end
    render.smart_merge(grid, cell[1], cell[2], bits)
  end

  -- Dashed gaps
  if self.dashed then
    for i = 2, #path - 1, 2 do
      dashed_gaps[#dashed_gaps+1] = { path[i][1], path[i][2] }
    end
  end

  -- Arrows (face-normal from dest/source box geometry)
  local to_shape = self.to_id and shapes[self.to_id]
  if self.arrow and #path >= 2 then
    local last = path[#path]
    local akey
    if self.forceConnectToSide then
      local normal = router.SIDES[self.forceConnectToSide]
      akey = string.format('%2d%3d', -normal[1], -normal[2])
    elseif to_shape then
      local side = outlines.side_at(to_shape, last[1], last[2])
      local normal = side and router.SIDES[side]
      if normal then akey = string.format('%2d%3d', -normal[1], -normal[2]) end
    else
      local prev = path[#path - 1]
      akey = string.format('%2d%3d', last[1]-prev[1], last[2]-prev[2])
    end
    local ch = akey and render.ARROWS[akey]
    if ch then pending_arrows[#pending_arrows+1] = { row=last[1], col=last[2], ch=ch } end
  end

  local from_shape = shapes[self.from_id]
  if self.arrow_both and from_shape and #path >= 2 then
    local first = path[1]
    local akey
    local side = outlines.side_at(from_shape, first[1], first[2])
    local normal = side and router.SIDES[side]
    if normal then akey = string.format('%2d%3d', -normal[1], -normal[2]) end
    local ch = akey and render.ARROWS[akey]
    if ch then pending_arrows[#pending_arrows+1] = { row=first[1], col=first[2], ch=ch } end
  end

  -- Label centered on midpoint — collected for post-dashed application
  local label = self:label_position()
  if label then
    for _, cell in ipairs(render.text_cells(label.text)) do
      conn_labels[#conn_labels+1] = { label.row, label.col + cell.col, cell.text }
    end
  end
end

function Conn:label_position()
  if not self.label or not self.path or #self.path == 0 then return nil end
  local mid = self.path[math.floor(#self.path / 2) + 1]
  return { row=mid[1], col=mid[2] - math.floor(vim.fn.strdisplaywidth(self.label) / 2), text=self.label }
end

function Conn:serialize()
  return {
    from_id    = self.from_id,
    to_id      = self.to_id,
    label      = self.label,
    style      = self.style,
    arrow      = self.arrow,
    arrow_both = self.arrow_both,
    dashed     = self.dashed,
    cmd_str    = self.cmd_str,
    target_row = self.target_row,
    target_col = self.target_col,
    waypoints  = self.waypoints,
    forceConnectToSide = self.forceConnectToSide,
  }
end

function Conn.deserialize(id, t)
  return Conn.new(id, t)
end

return Conn
