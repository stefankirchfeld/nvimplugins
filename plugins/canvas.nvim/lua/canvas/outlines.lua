local M = {}

M.definitions = {
  rectangle = { multiline_labels=true, fit_to_labels=true },
  diamond = { multiline_labels=true, fit_to_labels=false },
}

-- Shared raster geometry for drawing, hit tests, routing and validation.
function M.geometry(shape)
  local key = table.concat({shape.top, shape.left, shape.width, shape.height, shape.outline or 'rectangle'}, ':')
  if shape._outline_geometry and shape._outline_geometry.key == key then return shape._outline_geometry end
  local top, left = shape.top, shape.left
  local bottom, right = top+shape.height-1, left+shape.width-1
  local mr, mc = top+math.floor(shape.height/2), left+math.floor(shape.width/2)
  local geometry = { key=key, cells={}, rows={}, points={top={top,mc}, right={mr,right}, bottom={bottom,mc}, left={mr,left}} }
  local function cell(row, col, char)
    geometry.cells[#geometry.cells+1] = {row=row, col=col, char=char}
    local bounds = geometry.rows[row] or {col,col}
    bounds[1], bounds[2] = math.min(bounds[1],col), math.max(bounds[2],col)
    geometry.rows[row] = bounds
  end
  if shape.outline == 'diamond' then
    for row=top,bottom do
      local fraction = row <= mr and (row-top)/(mr-top) or (bottom-row)/(bottom-mr)
      local l = math.floor(mc+(left-mc)*fraction+0.5)
      local r = math.floor(mc+(right-mc)*fraction+0.5)
      local tip = row == top or row == mr or row == bottom
      cell(row, l, tip and '+' or row < mr and '╱' or '╲')
      if r ~= l then cell(row, r, tip and '+' or row < mr and '╲' or '╱') end
    end
  else
    for row=top,bottom do
      geometry.rows[row] = {left,right}
      for col=left,right do
        if row == top or row == bottom or col == left or col == right then cell(row,col) end
      end
    end
  end
  shape._outline_geometry = geometry
  return geometry
end

function M.contains(shape, row, col)
  local bounds = M.geometry(shape).rows[row]
  return bounds ~= nil and col >= bounds[1] and col <= bounds[2]
end

function M.side_at(shape, row, col)
  local points = M.geometry(shape).points
  for _, side in ipairs({ 'top', 'bottom', 'left', 'right' }) do
    local point = points[side]
    if point[1] == row and point[2] == col then return side end
  end
  if shape.outline ~= 'diamond' then
    if row == shape.top then return 'top' end
    if row == shape.top+shape.height-1 then return 'bottom' end
    if col == shape.left then return 'left' end
    if col == shape.left+shape.width-1 then return 'right' end
  end
end

function M.is_border(shape, row, col)
  if shape.outline == 'diamond' then
    for _, cell in ipairs(M.geometry(shape).cells) do if cell.row == row and cell.col == col then return true end end
    return false
  end
  return row == shape.top or row == shape.top+shape.height-1 or col == shape.left or col == shape.left+shape.width-1
end

return M
