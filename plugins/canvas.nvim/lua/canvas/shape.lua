local render = require('canvas.render')
local outlines = require('canvas.outlines')

local Shape = {}
Shape.__index = Shape

function Shape.new(id, fields)
  return setmetatable({
    id         = id,
    top        = fields.top,
    left       = fields.left,
    width      = fields.width,
    height     = fields.height,
    label      = fields.label,
    lines      = fields.lines,
    variant    = fields.variant,
    anchor     = fields.anchor,
    cmd_str    = fields.cmd_str,
    fg         = fields.fg,
    bg         = fields.bg,
    text_color = fields.text_color,
    outline    = fields.outline,
    kind       = fields.kind,
    role       = fields.role,
    parent_id  = fields.parent_id,
  }, Shape)
end

function Shape:draw(grid)
  if self.outline == 'diamond' then
    for _, cell in ipairs(outlines.geometry(self).cells) do render.set(grid, cell.row, cell.col, cell.char) end
    for _, line in ipairs(self:label_positions()) do
      for _, cell in ipairs(render.text_cells(line.text)) do
        if line.row >= 1 and line.col+cell.col >= 1 then render.set(grid, line.row, line.col+cell.col, cell.text) end
      end
    end
    return
  end
  local label = (self.variant == 't' and self.lines) and self.lines or self.label
  render.draw_box(grid, self.top, self.left, self.width, self.height, label, self.variant)
end

function Shape:contains(r, c)
  return outlines.contains(self, r, c)
end

-- Returns zone-relative {row, col} of the label's first character.
-- Used by highlight_canvas. row/col are 1-indexed zone coords.
function Shape:label_pos()
  local positions = self:label_positions()
  if not positions[1] then return nil, nil end
  return positions[1].row, positions[1].col
end

function Shape:label_positions()
  if not self.label and not self.lines then return {} end
  local label = self.variant == 't' and self.lines or self.label
  if self.outline == 'diamond' then
    local lines, longest = render.label_lines(label), 0
    for _, line in ipairs(lines) do longest = math.max(longest, vim.fn.strdisplaywidth(line)) end
    local top = self.top+math.floor((self.height-#lines+1)/2)
    local left = self.left+math.floor((self.width-longest)/2)
    local positions = {}
    for index, line in ipairs(lines) do positions[#positions+1] = {row=top+index-1,col=left,text=line} end
    return positions
  end
  return render.label_layout(self.top, self.left, self.width, self.height, label, self.variant)
end

function Shape:serialize()
  return {
    top        = self.top,
    left       = self.left,
    width      = self.width,
    height     = self.height,
    label      = self.label,
    lines      = self.lines,
    variant    = self.variant,
    anchor     = self.anchor,
    cmd_str    = self.cmd_str,
    fg         = self.fg,
    bg         = self.bg,
    text_color = self.text_color,
    outline    = self.outline,
    kind       = self.kind,
    role       = self.role,
    parent_id  = self.parent_id,
  }
end

function Shape.deserialize(id, t)
  return Shape.new(id, t)
end

return Shape
