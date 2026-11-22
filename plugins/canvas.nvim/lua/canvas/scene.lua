local M = {}
local Shape = require('canvas.shape')
local Conn = require('canvas.conn')
local Grid = require('canvas.grid')
local router = require('canvas.router')
local render = require('canvas.render')
local outlines = require('canvas.outlines')
local islist = vim.islist or vim.tbl_islist

local function value(fields, key, fallback)
  if fields[key] ~= nil then return fields[key] end
  return fallback
end

local function fail(field, message)
  error(setmetatable({ field=field, message=message }, { __tostring=function(err) return err.message end }), 0)
end

local function integer(value, field, minimum)
  if type(value) ~= 'number' or value ~= math.floor(value) or value == math.huge or value < (minimum or 1) then
    fail(field, field .. ' must be an integer >= ' .. (minimum or 1))
  end
  return value
end

local function label(value, multiline)
  if value == nil then value = '' end
  if type(value) ~= 'string' then fail('label', 'label must be a string') end
  if not multiline and value:find('[\r\n]') then fail('label', 'connector labels must be one line') end
  return value
end

function M.decode_token(token, kind)
  local base = kind == 'box' and 'b' or 'c'
  if type(token) ~= 'string' or token:sub(1, 1) ~= base then return nil, 'expected ' .. base .. ' followed by modifiers' end
  local allowed = kind == 'box' and { r=true, d=true, c=true, i=true, x=true } or { a=true, b=true, d=true }
  local mods = {}
  for ch in token:sub(2):gmatch('.') do
    if not allowed[ch] or mods[ch] then return nil, 'invalid or repeated modifier: ' .. ch end
    mods[ch] = true
  end
  local description
  if kind == 'box' then
    if mods.x and (mods.r or mods.d) then return nil, 'diamond cannot use rounded or double borders' end
    description = mods.d and (mods.r and 'rounded double box' or 'double box') or (mods.r and 'rounded box' or 'box')
    if mods.x then description = 'diamond, multiline labels, fixed size' end
    if mods.c or mods.i then description = description .. ', centered anchor' end
  else
    description = 'connector' .. (mods.b and ', arrows both ends' or mods.a and ', arrow' or '') .. (mods.d and ', dashed' or '')
  end
  return mods, description
end

function M.token_for(object, kind)
  if kind == 'box' then
    return 'b' .. (object.outline == 'diamond' and 'x' or (object.variant or '')) .. (object.anchor == 'center' and 'c' or '')
  end
  return 'c' .. (object.arrow_both and 'b' or object.arrow and 'a' or '') .. (object.dashed and 'd' or '')
end

function M.box_dimensions(width, height, text)
  text = label(text, true)
  local lines, longest = render.label_lines(text), 0
  for _, line in ipairs(lines) do longest = math.max(longest, vim.fn.strdisplaywidth(line)) end
  local w = integer(width or 20, 'width')
  local h = integer(height or 10, 'height')
  return math.max(3, w, text ~= '' and longest + 4 or 3), math.max(h, text ~= '' and #lines + 2 or 1)
end

local function colors(object, fields)
  for _, key in ipairs({ 'fg', 'bg', 'text_color' }) do
    local value = fields[key]
    if value ~= nil then
      if value ~= '' then
        if type(value) ~= 'string' then fail(key, key .. ' must be a color string') end
        local ok, color = pcall(vim.api.nvim_get_color_by_name, value)
        if not ok or color < 0 then fail(key, 'invalid ' .. key .. ' color: ' .. value) end
      end
      object[key] = value ~= '' and value or nil
    end
  end
end

local function metadata(object, fields)
  for _, key in ipairs({ 'kind', 'role', 'parent_id' }) do
    local candidate = fields[key]
    if candidate ~= nil then
      if candidate == '' or (key == 'parent_id' and candidate == 0) then object[key] = nil
      else object[key] = candidate end
    end
  end
end

function M.diamond_dimensions(size)
  if type(size) ~= 'number' or size < 1 or size == math.huge or size*2 ~= math.floor(size*2) then
    fail('size', 'diamond size must be 1 or greater in half steps: 1, 1.5, 2, 2.5, ...')
  end
  return 12*size+1, 6*size+1
end

function M.diamond_size(object)
  local size = (object.width-1)/12
  if size >= 1 and size*2 == math.floor(size*2) and object.height == 6*size+1 then return size end
end

local function dimensions(object, width, height)
  local definition = outlines.definitions[object.outline or 'rectangle']
  if not definition then fail('outline', 'outline must be rectangle or diamond') end
  if definition.fit_to_labels then return M.box_dimensions(width, height, object.label) end
  return integer(width or 13, 'width', 5), integer(height or 7, 'height', 3)
end

local function box(id, fields, old, placement)
  local shape = value(fields, 'shape', old and M.token_for(old, 'box') or 'b')
  local mods, message = M.decode_token(shape, 'box')
  if not mods then fail('shape', message) end
  local object = old and vim.deepcopy(old) or Shape.new(id, {})
  object.outline = value(fields, 'outline', fields.shape and (mods.x and 'diamond' or 'rectangle') or object.outline or 'rectangle')
  if mods.x and object.outline ~= 'diamond' then fail('outline', 'bx requires a diamond outline') end
  if object.outline == 'diamond' and (mods.r or mods.d) then fail('shape', 'diamond cannot use rounded or double borders') end
  object.label = table.concat(render.label_lines(label(value(fields, 'label', object.label), true)), string.char(10))
  if fields.size ~= nil then
    if object.outline ~= 'diamond' then fail('size', 'size is only supported for diamonds') end
    if fields.width ~= nil or fields.height ~= nil then fail('size', 'use size or legacy width/height, not both') end
    object.width, object.height = M.diamond_dimensions(fields.size)
  else
    object.width, object.height = dimensions(object, value(fields, 'width', object.width), value(fields, 'height', object.height))
  end
  object.anchor = mods.i and 'center' or value(fields, 'anchor', mods.c and 'center' or 'top-left')
  object.variant = (mods.d and 'd' or '') .. (mods.r and 'r' or '')
  if object.outline == 'diamond' then object.variant = '' end
  object.cmd_str = fields.cmd_str or shape
  local top = integer(value(fields, 'row', object.top), 'row')
  local left = integer(value(fields, 'col', object.left), 'col')
  if placement == 'anchor' then
    if object.anchor == 'center' then
      top, left = top - math.floor(object.height/2), left - math.floor(object.width/2)
    elseif object.anchor == 'top-right' then left = left - object.width + 1 end
  end
  object.top, object.left = math.max(1, top), math.max(1, left)
  colors(object, fields)
  metadata(object, fields)
  return object
end

local function text(id, fields, old)
  local object = old and vim.deepcopy(old) or Shape.new(id, {})
  local lines = fields.lines
  if lines == nil then
    if fields.label ~= nil then lines = render.label_lines(label(fields.label, true))
    else lines = object.lines or render.label_lines(label(object.label, true)) end
  end
  if type(lines) ~= 'table' or not islist(lines) or #lines == 0 then fail('label', 'text requires an array of lines') end
  object.width = 1
  for _, line in ipairs(lines) do object.width = math.max(object.width, vim.fn.strdisplaywidth(label(line))) end
  object.lines, object.label, object.height = vim.deepcopy(lines), lines[1], #lines
  object.top, object.left = integer(value(fields, 'row', object.top), 'row'), integer(value(fields, 'col', object.left), 'col')
  object.anchor, object.variant, object.cmd_str = 'top-left', 't', fields.cmd_str or 't'
  colors(object, fields)
  metadata(object, fields)
  return object
end

local function connector(id, fields, old)
  local object = old and vim.deepcopy(old) or Conn.new(id, {})
  local shape = value(fields, 'shape', old and M.token_for(old, 'conn') or 'ca')
  local mods, message = M.decode_token(shape, 'conn')
  if not mods then fail('shape', message) end
  object.from_id = value(fields, 'from_id', object.from_id)
  if fields.to_id ~= nil then
    if fields.to_id == 0 then object.to_id = nil else object.to_id = fields.to_id end
  end
  if not object.to_id then
    object.target_row, object.target_col = value(fields, 'row', object.target_row), value(fields, 'col', object.target_col)
  end
  object.style = value(fields, 'route', object.style or 'default')
  local side = value(fields, 'forceConnectToSide', object.forceConnectToSide)
  if side == '' then object.forceConnectToSide = nil else object.forceConnectToSide = side end
  object.label = label(value(fields, 'label', object.label))
  object.arrow, object.arrow_both, object.dashed = mods.a or mods.b or false, mods.b or false, mods.d or false
  object.path, object.cmd_str = nil, fields.cmd_str or shape
  return object
end

function M.new()
  return { shapes={}, conns={}, next_id=1 }
end

function M.validate(s)
  local ids, maximum = {}, 0
  for _, collection in ipairs({ 'shapes', 'conns' }) do
    if type(s[collection]) ~= 'table' then fail(collection, 'expected ' .. collection .. ' object') end
    for id, object in pairs(s[collection]) do
      integer(id, 'id')
      if ids[id] then fail('id', 'shape and connector IDs must be unique') end
      ids[id], maximum = true, math.max(maximum, id)
      if type(object) ~= 'table' then fail('id', 'element ' .. id .. ' must be an object') end
      if collection == 'shapes' then
        for _, key in ipairs({ 'top', 'left', 'width', 'height' }) do integer(object[key], key) end
        if object.outline ~= nil and not outlines.definitions[object.outline] then fail('outline', 'outline must be rectangle or diamond') end
        if object.outline == 'diamond' then
          integer(object.width, 'width', 5); integer(object.height, 'height', 3)
          if object.variant == 't' then fail('outline', 'free text cannot have a diamond outline') end
          if object.variant and object.variant ~= '' then fail('shape', 'diamond cannot use rounded or double borders') end
        end
        if object.kind ~= nil and (type(object.kind) ~= 'string' or not object.kind:match('^[%a][%w_-]*$')) then
          fail('kind', 'kind must be an identifier such as decision, service, database, or queue')
        end
        if object.role ~= nil and not ({node=true,container=true,annotation=true})[object.role] then fail('role', 'role must be node, container, or annotation') end
        if object.parent_id then
          integer(object.parent_id, 'parent_id')
          local parent = s.shapes[object.parent_id]
          if not parent or parent.role ~= 'container' then fail('parent_id', 'parent_id must refer to a container') end
          local seen, current = {[id]=true}, object.parent_id
          while current do
            if seen[current] then fail('parent_id', 'semantic containment must not contain cycles') end
            seen[current] = true
            current = s.shapes[current] and s.shapes[current].parent_id
          end
        end
        if object.variant ~= nil and type(object.variant) ~= 'string' then fail('shape', 'variant must be a string') end
        if not render.VARIANTS[render.variant_key(object.variant)] then fail('shape', 'unsupported box variant') end
        if object.anchor ~= nil and not ({ ['top-left']=true, ['top-right']=true, center=true })[object.anchor] then fail('anchor', 'invalid anchor') end
        label(object.label, true)
        if object.lines then
          if not islist(object.lines) then fail('label', 'lines must be an array') end
          for _, line in ipairs(object.lines) do label(line) end
        end
        colors({}, object)
      else
        integer(object.from_id, 'from_id')
        if not s.shapes[object.from_id] then fail('from_id', 'source shape ' .. object.from_id .. ' not found') end
        if object.to_id then
          integer(object.to_id, 'to_id')
          if not s.shapes[object.to_id] then fail('to_id', 'target shape ' .. object.to_id .. ' not found') end
        else
          integer(object.target_row, 'row')
          integer(object.target_col, 'col')
        end
        label(object.label)
        if object.style ~= nil and type(object.style) ~= 'string' then fail('route', 'route must be a string') end
        local route = object.style or 'default'
        if route ~= 'manual' and not router.STYLES[route] then fail('route', 'invalid route: ' .. tostring(route)) end
        local side = object.forceConnectToSide
        if side ~= nil then
          if not router.SIDES[side] then fail('forceConnectToSide', 'target side must be left, right, top, or bottom') end
          if not object.to_id then fail('forceConnectToSide', 'target side requires a target shape') end
          if route == 'manual' then fail('forceConnectToSide', 'target side requires automatic routing') end
        end
        if route == 'manual' then
          local points = object.waypoints
          if type(points) ~= 'table' or not islist(points) or #points < 2 then fail('route', 'manual routing requires waypoints') end
          for i, point in ipairs(points) do
            if type(point) ~= 'table' or #point ~= 2 then fail('route', 'invalid waypoint') end
            integer(point[1], 'row'); integer(point[2], 'col')
            if i > 1 and point[1] ~= points[i-1][1] and point[2] ~= points[i-1][2] then fail('route', 'waypoint segments must be orthogonal') end
          end
        end
        for _, key in ipairs({ 'arrow', 'arrow_both', 'dashed' }) do
          if object[key] ~= nil and type(object[key]) ~= 'boolean' then fail(key, key .. ' must be boolean') end
        end
      end
    end
  end
  integer(s.next_id, 'next_id')
  if s.next_id <= maximum then fail('next_id', 'next_id must be greater than all element IDs') end
end

function M.serialize(s)
  local shapes, conns = vim.empty_dict(), vim.empty_dict()
  for id, shape in pairs(s.shapes) do shapes[tostring(id)] = shape:serialize() end
  for id, conn in pairs(s.conns) do conns[tostring(id)] = conn:serialize() end
  return { shapes=shapes, conns=conns, next_id=s.next_id }
end

function M.deserialize(data)
  if type(data) ~= 'table' then fail('state', 'expected a canvas sidecar object') end
  local s = M.new()
  local legacy = data.boxes or data.texts
  local shape_data = data.shapes or data.boxes or (data.texts and {})
  local conn_data = data.conns or (legacy and {})
  if type(shape_data) ~= 'table' or type(conn_data) ~= 'table' then fail('state', 'expected shapes and conns objects') end
  local function load(collection, source, class)
    for key, fields in pairs(source) do
      if type(key) ~= 'string' or not key:match('^[1-9]%d*$') then fail('id', 'IDs must be positive integer strings') end
      if type(fields) ~= 'table' or islist(fields) and next(fields) ~= nil then fail('id', 'element must be an object') end
      local cleaned = {}
      for field, value in pairs(fields) do if value ~= vim.NIL then cleaned[field] = value end end
      collection[tonumber(key)] = class.deserialize(tonumber(key), cleaned)
      if class == Shape then
        local object = collection[tonumber(key)]
        for _, field in ipairs({ 'top', 'left', 'width', 'height' }) do integer(object[field], field) end
        colors(object, cleaned)
        if object.variant ~= 't' then
          if object.label ~= nil then object.label = table.concat(render.label_lines(label(object.label, true)), string.char(10)) end
          object.width, object.height = dimensions(object, object.width, object.height)
        end
      end
    end
  end
  load(s.shapes, shape_data, Shape)
  load(s.conns, conn_data, Conn)
  -- Legacy free text is migrated at the same boundary as legacy boxes.
  for key, fields in pairs(data.texts or {}) do
    local id = tonumber(key)
    if not id or s.shapes[id] then fail('id', 'invalid legacy text ID') end
    s.shapes[id] = text(id, { label=fields.text, row=fields.row, col=fields.col })
  end
  s.next_id = value(data, 'next_id', 1)
  if legacy and not data.next_id then
    for _, collection in ipairs({ s.shapes, s.conns }) do
      for id in pairs(collection) do s.next_id = math.max(s.next_id, id + 1) end
    end
  end
  M.validate(s)
  return s
end

local function encloses(outer, inner)
  local bottom, right = inner.top+inner.height-1, inner.left+inner.width-1
  return outer:contains(inner.top, inner.left) and outer:contains(inner.top,right)
    and outer:contains(bottom,inner.left) and outer:contains(bottom,right)
end

local function inside(shape, point)
  return shape:contains(point[1], point[2])
end

function M.apply(s, request)
  -- Work in shallow copies; constructors clone edited elements before changing them.
  local draft = { shapes=vim.tbl_extend('force', {}, s.shapes), conns=vim.tbl_extend('force', {}, s.conns), next_id=s.next_id }
  local op, fields = request.op, request.fields or request
  local id, result = request.id, {}
  if op == 'box' or op == 'text' or op == 'connect' then
    id = integer(id or draft.next_id, 'id')
    if draft.shapes[id] or draft.conns[id] then fail('id', 'ID ' .. id .. ' already exists') end
    draft.next_id = math.max(draft.next_id, id + 1)
    if op == 'connect' then draft.conns[id] = connector(id, fields)
    elseif op == 'box' then draft.shapes[id] = box(id, fields, nil, request.placement)
    else draft.shapes[id] = text(id, fields) end
    result.kind = op == 'connect' and 'connector' or op
  elseif op == 'update' then
    integer(id, 'id')
    local shape, conn = draft.shapes[id], draft.conns[id]
    if shape then
      draft.shapes[id] = shape.variant == 't' and text(id, fields, shape) or box(id, fields, shape, request.placement)
    elseif conn then draft.conns[id] = connector(id, fields, conn)
    else fail('id', 'element ' .. id .. ' not found') end
  elseif op == 'move' then
    integer(id, 'id')
    local shape = draft.shapes[id]
    if not shape then fail('id', 'shape ' .. id .. ' not found') end
    local row, col = fields.row, fields.col
    if fields.dr or fields.dc then row, col = math.max(1, shape.top + (fields.dr or 0)), math.max(1, shape.left + (fields.dc or 0)) end
    row, col = integer(row, 'row'), integer(col, 'col')
    local dr, dc = row - shape.top, col - shape.left
    local moved_ids = {}
    result.moved_shapes = {}
    for child_id, child in pairs(draft.shapes) do
      if child_id == id or (shape.variant ~= 't' and encloses(shape, child)) then
        local moved = vim.deepcopy(child)
        moved.top, moved.left = child.top + dr, child.left + dc
        draft.shapes[child_id], moved_ids[child_id] = moved, true
        result.moved_shapes[#result.moved_shapes+1] = child_id
      end
    end
    table.sort(result.moved_shapes)
    for conn_id, conn in pairs(draft.conns) do
      local move_endpoint = shape.variant ~= 't' and not conn.to_id and moved_ids[conn.from_id]
        and inside(shape, { conn.target_row, conn.target_col })
      local move_route = shape.variant ~= 't' and conn.style == 'manual' and #conn.waypoints > 0
      if move_route then
        for _, point in ipairs(conn.waypoints) do if not inside(shape, point) then move_route = false; break end end
      end
      if move_endpoint or move_route then
        local moved = vim.deepcopy(conn)
        if move_endpoint then moved.target_row, moved.target_col = conn.target_row + dr, conn.target_col + dc end
        if move_route then
          for _, point in ipairs(moved.waypoints) do point[1], point[2] = point[1] + dr, point[2] + dc end
        end
        moved.path = nil
        draft.conns[conn_id] = moved
      end
    end
  elseif op == 'delete' then
    integer(id, 'id')
    local removed = {}
    if draft.shapes[id] then
      draft.shapes[id] = nil
      for child_id, child in pairs(draft.shapes) do
        if child.parent_id == id then
          draft.shapes[child_id] = vim.deepcopy(child)
          draft.shapes[child_id].parent_id = nil
        end
      end
      for conn_id, conn in pairs(draft.conns) do
        if conn.from_id == id or conn.to_id == id then draft.conns[conn_id] = nil; removed[#removed+1] = conn_id end
      end
    elseif draft.conns[id] then draft.conns[id] = nil
    else fail('id', 'element ' .. id .. ' not found') end
    table.sort(removed)
    result.removed_connectors = removed
  else fail('op', 'unknown scene operation: ' .. tostring(op)) end
  M.validate(draft)
  for _, key in ipairs({ 'shapes', 'conns' }) do
    for old_id in pairs(s[key]) do if not draft[key][old_id] then s[key][old_id] = nil end end
    for new_id, object in pairs(draft[key]) do s[key][new_id] = object end
  end
  s.next_id, s.grid_cache = draft.next_id, nil
  result.id = id
  return result
end

-- Text spans are checked against geometry, before overlapping draws can hide them.
function M.layout_issues(s)
  local issues = {}
  local function check(id, kind, lines)
    for index, line in ipairs(lines) do
      local width = vim.fn.strdisplaywidth(line.text)
      local last = line.col + width - 1
      if width > 0 then
        for box_id, box in pairs(s.shapes) do
          if box.variant ~= 't' and not (box_id == id and kind == 'box' and box.outline == 'diamond') then
            local bottom, right = box.top + box.height - 1, box.left + box.width - 1
            local on_horizontal = (line.row == box.top or line.row == bottom)
              and line.col <= right and last >= box.left
            local on_vertical = line.row >= box.top and line.row <= bottom
              and ((line.col <= box.left and last >= box.left) or (line.col <= right and last >= right))
            if box.outline == 'diamond' then
              on_horizontal, on_vertical = false, false
              for _, cell in ipairs(outlines.geometry(box).cells) do
                if cell.row == line.row and cell.col >= line.col and cell.col <= last then on_vertical = true; break end
              end
            end
            if on_horizontal or on_vertical then
              issues[#issues+1] = { code='text_crosses_border', id=id, kind=kind, box_id=box_id,
                line=index, row=line.row, col=line.col, end_col=last,
                message=kind .. ' ' .. id .. ' text crosses box ' .. box_id .. ' border' }
            end
          end
        end
      end
    end
  end
  for id, shape in pairs(s.shapes) do check(id, shape.variant == 't' and 'text' or 'box', shape:label_positions()) end
  for id, conn in pairs(s.conns) do
    local position = conn:label_position()
    if position then check(id, 'connector', { position }) end
  end
  table.sort(issues, function(a, b)
    if a.id ~= b.id then return a.id < b.id end
    if a.line ~= b.line then return a.line < b.line end
    return a.box_id < b.box_id
  end)
  return issues
end

function M.render(s)
  M.validate(s)
  local grid = Grid.new()
  grid:build(s.shapes, s.conns)
  local paths = vim.empty_dict()
  for id, conn in pairs(s.conns) do
    if not conn.path or #conn.path == 0 then fail('route', 'connector ' .. id .. ': no route found') end
    paths[tostring(id)] = conn.path
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local last = grid:flush(buf, 1, 1, 0)
  local lines = last > 0 and vim.api.nvim_buf_get_lines(buf, 0, last, false) or {}
  vim.api.nvim_buf_delete(buf, { force=true })
  local columns = 0
  for _, line in ipairs(lines) do columns = math.max(columns, vim.fn.strdisplaywidth(line)) end
  return { lines=lines, rows=#lines, columns=columns, paths=paths, issues=M.layout_issues(s) }
end

return M
