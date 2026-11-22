local M = {}

local render = require('canvas.render')
local outlines = require('canvas.outlines')

-- Outward normals also define the required approach cell for a forced side.
M.SIDES = { left={0, -1}, right={0, 1}, top={-1, 0}, bottom={1, 0} }

-- ─── Nearest edge cell ───────────────────────────────────────────────────────

-- Returns the row, col of the edge cell of `box` nearest to (target_row, target_col).
-- Uses the face whose outward normal best aligns with the vector from box center to target,
-- breaking ties by Manhattan distance.
function M.nearest_edge(box, target_row, target_col, side)
  local top    = box.top
  local left   = box.left
  local w      = box.width
  local h      = box.height
  local bottom = top + h - 1
  local right  = left + w - 1
  local mid_r  = top + math.floor(h / 2)
  local mid_c  = left + math.floor(w / 2)

  -- Vector from box centre to target; scale cols by 0.5 to approximate terminal aspect ratio
  local drow = target_row - mid_r
  local dcol = (target_col - mid_c) * 0.5

  local points = outlines.geometry(box).points
  local faces = {}
  for _, name in ipairs({ 'left', 'right', 'top', 'bottom' }) do
    faces[#faces+1] = { points[name][1], points[name][2], name }
  end
  if side then
    for _, face in ipairs(faces) do
      if face[3] == side then return face[1], face[2] end
    end
    error('invalid target side: ' .. tostring(side), 0)
  end

  local best_dot  = -math.huge
  local best_dist = math.huge
  local best_r, best_c = mid_r, left

  for _, f in ipairs(faces) do
    local fr, fc = f[1], f[2]
    local normal = M.SIDES[f[3]]
    local nr, nc = normal[1], normal[2]
    local dot  = nr * drow + nc * dcol
    local dist = math.abs(fr - target_row) + math.abs(fc - target_col)
    if dot > best_dot or (dot == best_dot and dist < best_dist) then
      best_dot  = dot
      best_dist = dist
      best_r, best_c = fr, fc
    end
  end

  return best_r, best_c
end

-- ─── A* routing ──────────────────────────────────────────────────────────────

local BIT = { U=1, R=2, D=4, L=8 }
local DIRS = {
  { -1,  0, BIT.U },
  {  1,  0, BIT.D },
  {  0, -1, BIT.L },
  {  0,  1, BIT.R },
}

local BOX_CHARS = {
  -- single border
  ['┌']=true, ['┐']=true, ['└']=true, ['┘']=true,
  ['─']=true, ['│']=true, ['├']=true, ['┤']=true,
  ['┬']=true, ['┴']=true, ['┼']=true,
  ['╵']=true, ['╶']=true, ['╷']=true, ['╴']=true,
  -- rounded corners (same singles, already covered, but explicit)
  ['╭']=true, ['╮']=true, ['╰']=true, ['╯']=true,
  -- double border
  ['╔']=true, ['╗']=true, ['╚']=true, ['╝']=true,
  ['═']=true, ['║']=true, ['╠']=true, ['╣']=true,
  ['╦']=true, ['╩']=true, ['╬']=true,
  -- mixed single/double joins (used at conn attachment points on double boxes)
  ['╒']=true, ['╓']=true, ['╕']=true, ['╖']=true,
  ['╘']=true, ['╙']=true, ['╛']=true, ['╜']=true,
  ['╞']=true, ['╟']=true, ['╡']=true, ['╢']=true,
  ['╤']=true, ['╥']=true, ['╧']=true, ['╨']=true,
  ['╫']=true, ['╪']=true,
  -- arrow heads also count as occupied for routing purposes
  ['↑']=true, ['↓']=true, ['←']=true, ['→']=true,
}

-- Named routing style presets.
-- turn_cost:    penalty for changing direction
-- cross_cost:   penalty for crossing an existing connector
-- max_iters:    base iteration budget (scaled up with path distance at runtime)
-- heuristic:    multiplier on Manhattan distance — >1 makes search greedier/faster,
--               trading optimality for speed. 1.0 = exact A*, 2.0 = twice as fast.
local STYLES = {
  default = { turn_cost = 20, cross_cost = 10,  max_iters = 10000, heuristic = 1.5 },
  direct  = { turn_cost = 20, cross_cost = 999, max_iters = 10000, heuristic = 2.0 },
  lazy    = { turn_cost = 1,  cross_cost = 10,  max_iters = 10000, heuristic = 1.5 },
  avoid   = { turn_cost = 20, cross_cost = 999, max_iters = 10000, heuristic = 2.0 },
}
M.STYLES = STYLES

local function manhattan(r1, c1, r2, c2)
  return math.abs(r1 - r2) + math.abs(c1 - c2)
end

local function key(r, c) return r .. ',' .. c end

-- Returns true if (row, col) is on the border of a box (not interior).
local function is_border(box, row, col)
  return outlines.is_border(box, row, col)
end

-- Cost penalty for attaching to a border cell, based on distance from edge midpoint.
-- Midpoint = 0, corner = 100, linear in between.
local function edge_attach_cost(box, row, col)
  local bottom = box.top  + box.height - 1
  local right  = box.left + box.width  - 1
  local mid_r  = box.top  + math.floor(box.height / 2)
  local mid_c  = box.left + math.floor(box.width  / 2)

  if row == box.top or row == bottom then
    local half = math.max(1, math.floor(box.width / 2))
    local dist = math.abs(col - mid_c)
    return math.floor(dist / half * 100)
  else
    local half = math.max(1, math.floor(box.height / 2))
    local dist = math.abs(row - mid_r)
    return math.floor(dist / half * 100)
  end
end

-- Proximity penalty for passing near a foreign box (one the path doesn't connect).
-- Tapers from PROX_PEAK at the box border down to 0 at PROX_RADIUS cells away.
local PROX_RADIUS = 0
local PROX_PEAK   = 0

local function box_border_dist(box, row, col)
  local bottom = box.top  + box.height - 1
  local right  = box.left + box.width  - 1
  local cr = math.max(box.top,  math.min(bottom, row))
  local cc = math.max(box.left, math.min(right,  col))
  return math.abs(row - cr) + math.abs(col - cc)
end

local function proximity_cost(row, col, boxes, exclude_border, exclude_full)
  local cost = 0
  for id, box in pairs(boxes) do
    if not exclude_border[id] and not exclude_full[id] then
      local dist = box_border_dist(box, row, col)
      if dist < PROX_RADIUS then
        cost = cost + math.floor((PROX_RADIUS - dist) / PROX_RADIUS * PROX_PEAK)
      end
    end
  end
  return cost
end

-- Returns true if (row, col) is blocked for routing.
-- exclude_border: boxes where only border is passable (source/dest boxes)
-- exclude_full:   boxes that are fully passable (container boxes)
local function is_blocked(row, col, boxes, exclude_border, exclude_full)
  for id, box in pairs(boxes) do
    if outlines.contains(box, row, col) then
      if exclude_full and exclude_full[id] then
        -- container box — fully passable
      elseif exclude_border and exclude_border[id] then
        -- source/dest box — interior blocked, border passable
        if not is_border(box, row, col) then return true end
      else
        return true
      end
    end
  end
  return false
end

-- Minimal priority queue (min-heap by f score)
local function make_heap()
  return { data = {} }
end

local function heap_push(h, item)
  table.insert(h.data, item)
  local i = #h.data
  while i > 1 do
    local parent = math.floor(i / 2)
    if h.data[parent].f > h.data[i].f then
      h.data[parent], h.data[i] = h.data[i], h.data[parent]
      i = parent
    else break end
  end
end

local function heap_pop(h)
  if #h.data == 0 then return nil end
  local top = h.data[1]
  local last = table.remove(h.data)
  if #h.data > 0 then
    h.data[1] = last
    local i = 1
    while true do
      local smallest = i
      local l, r = 2*i, 2*i+1
      if l <= #h.data and h.data[l].f < h.data[smallest].f then smallest = l end
      if r <= #h.data and h.data[r].f < h.data[smallest].f then smallest = r end
      if smallest == i then break end
      h.data[i], h.data[smallest] = h.data[smallest], h.data[i]
      i = smallest
    end
  end
  return top
end

-- A* from (sr, sc) to (dr, dc). Returns list of {row, col} cells or nil.
-- boxes: the state.boxes table. Cells inside boxes are blocked except for
-- the source and destination boxes (identified by their edge cells sr/sc, dr/dc).
-- style: optional string key into STYLES (defaults to 'default').
function M.astar(grid, sr, sc, dr, dc, boxes, style, attachment)
  local st = STYLES[style] or STYLES.default
  local target, approach_row, approach_col
  if attachment then
    target = attachment.box
    local normal = M.SIDES[attachment.side]
    approach_row, approach_col = dr + normal[1], dc + normal[2]
    if approach_row < 1 or approach_col < 1 then return nil end
  end

  -- Classify boxes:
  -- - contains only start or only dest → source/dest box (border passable, interior blocked)
  -- - contains both start and dest → container box (fully passable)
  local exclude_border = {}
  local exclude_full   = {}
  for id, box in pairs(boxes) do
    local has_start = outlines.contains(box, sr, sc)
    local has_dest = outlines.contains(box, dr, dc)
    if has_start and has_dest then
      exclude_full[id] = true
    elseif has_start or has_dest then
      exclude_border[id] = true
    end
  end

  local open   = make_heap()
  local g_cost = {}
  local parent = {}
  local closed = {}

  local start_key = key(sr, sc)
  g_cost[start_key] = 0

  local dist0 = manhattan(sr, sc, dr, dc)
  -- Expand the bounding box to include any box that intersects the routing rectangle,
  -- since obstacles force detours that explore well outside the straight-line bbox.
  local min_r = math.min(sr, dr)
  local max_r = math.max(sr, dr)
  local min_c = math.min(sc, dc)
  local max_c = math.max(sc, dc)
  for _, box in pairs(boxes) do
    local bb = box.top + box.height - 1
    local br = box.left + box.width - 1
    if box.top <= max_r and bb >= min_r and box.left <= max_c and br >= min_c then
      min_r = math.min(min_r, box.top  - 2)
      max_r = math.max(max_r, bb       + 2)
      min_c = math.min(min_c, box.left - 2)
      max_c = math.max(max_c, br       + 2)
    end
  end
  local rows = max_r - min_r + 1
  local cols = max_c - min_c + 1
  local area_budget = rows * cols * 4
  local max_iters = math.max(st.max_iters, area_budget)
  local h_weight  = st.heuristic or 1.0

  heap_push(open, { r=sr, c=sc, f=dist0 * h_weight, g=0, dir=nil })

  local iters = 0

  while #open.data > 0 and iters < max_iters do
    iters = iters + 1
    local cur = heap_pop(open)
    local ck = key(cur.r, cur.c)

    if closed[ck] then goto continue end
    closed[ck] = true

    if cur.r == dr and cur.c == dc then
      local path = {}
      local k = ck
      while k do
        local p = parent[k]
        local r, c = k:match('(%d+),(%d+)')
        table.insert(path, 1, { tonumber(r), tonumber(c) })
        k = p and key(p[1], p[2]) or nil
      end
      return path
    end

    for _, d in ipairs(DIRS) do
      local nr = cur.r + d[1]
      local nc = cur.c + d[2]
      local nk = key(nr, nc)

      if nr >= 1 and nc >= 1 and not closed[nk] then
        if target and nr >= target.top and nr <= target.top + target.height - 1
          and nc >= target.left and nc <= target.left + target.width - 1 then
          -- Only the chosen attachment cell is passable, from its outward neighbor.
          -- This prevents walking along other target edges before reaching the tip.
          if nr ~= dr or nc ~= dc or cur.r ~= approach_row or cur.c ~= approach_col then goto next_dir end
        end
        local extra = 0
        if cur.dir and cur.dir ~= d[3] then extra = extra + st.turn_cost end
        -- cross_cost penalises cells that carry existing connector chars,
        -- but not cells inside the source/dest boxes
        local ch = render.get(grid, nr, nc)
        if BOX_CHARS[ch] then
          local on_endpoint_box = false
          for id in pairs(exclude_border) do
            local b = boxes[id]
            if nr >= b.top and nr <= b.top + b.height - 1
            and nc >= b.left and nc <= b.left + b.width - 1 then
              on_endpoint_box = true; break
            end
          end
          for id in pairs(exclude_full) do
            local b = boxes[id]
            if nr >= b.top and nr <= b.top + b.height - 1
            and nc >= b.left and nc <= b.left + b.width - 1 then
              on_endpoint_box = true; break
            end
          end
          if not on_endpoint_box then extra = extra + st.cross_cost end
        end

        -- Edge attachment cost: penalise border cells far from midpoint,
        -- and add a heavy occupancy penalty if already used by another connector.
        for id in pairs(exclude_border) do
          local b = boxes[id]
          if nr >= b.top and nr <= b.top + b.height - 1
          and nc >= b.left and nc <= b.left + b.width - 1
          and is_border(b, nr, nc) then
            extra = extra + edge_attach_cost(b, nr, nc)
          end
        end

        -- Proximity cost: penalise passing close to foreign boxes
        extra = extra + proximity_cost(nr, nc, boxes, exclude_border, exclude_full)

        if is_blocked(nr, nc, boxes, exclude_border, exclude_full) then
          goto next_dir
        end

        local new_g = cur.g + 1 + extra
        if not g_cost[nk] or new_g < g_cost[nk] then
          g_cost[nk] = new_g
          parent[nk] = { cur.r, cur.c }
          local f = new_g + manhattan(nr, nc, dr, dc) * h_weight
          heap_push(open, { r=nr, c=nc, f=f, g=new_g, dir=d[3] })
        end
      end
      ::next_dir::
    end

    ::continue::
  end

  return nil
end

return M
