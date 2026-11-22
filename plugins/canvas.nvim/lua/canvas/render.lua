local M = {}

-- 4-bit direction masks: Up=1, Right=2, Down=4, Left=8
local BIT = { U = 1, R = 2, D = 4, L = 8 }

-- Unicode box-drawing chars indexed by bitmask (0-15)
local CHARS = {
  [0]  = ' ',
  [1]  = '╵',  [2]  = '╶',  [3]  = '└',  [4]  = '╷',
  [5]  = '│',  [6]  = '┌',  [7]  = '├',  [8]  = '╴',
  [9]  = '┘',  [10] = '─',  [11] = '┴',  [12] = '┐',
  [13] = '┤',  [14] = '┬',  [15] = '┼',
}

-- Box variant table: keyed by sorted modifier string.
-- Each entry has TL/TR/BL/BR corners, H horizontal edge, V vertical edge.
-- Variants compose: 'rd' key covers rounded+double together.
local VARIANTS = {
  ['']   = { TL='┌', TR='┐', BL='└', BR='┘', H='─', V='│' },
  ['d']  = { TL='╔', TR='╗', BL='╚', BR='╝', H='═', V='║' },
  ['r']  = { TL='╭', TR='╮', BL='╰', BR='╯', H='─', V='│' },
  ['dr'] = { TL='╭', TR='╮', BL='╰', BR='╯', H='═', V='║' },
  ['t']  = { text_only = true },  -- free text: label only, no border
}
M.VARIANTS = VARIANTS

-- Normalise a variant key: sort mod chars so 'rd'=='dr'.
local function variant_key(variant)
  if not variant or variant == '' then return '' end
  local chars = {}
  for c in variant:gmatch('.') do chars[#chars+1] = c end
  table.sort(chars)
  return table.concat(chars)
end
M.variant_key = variant_key

function M.label_lines(label)
  if type(label) == 'table' then return label end
  local text = (label or ''):gsub(string.char(13, 10), string.char(10)):gsub(string.char(13), string.char(10))
  return vim.split(text, string.char(10), { plain=true })
end

-- Reserve display columns for wide glyphs and attach combining marks to their base.
function M.text_cells(text)
  local cells, byte, column, previous = {}, 1, 0, nil
  while byte <= #text do
    local lead = text:byte(byte)
    local length = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    local char = text:sub(byte, byte+length-1)
    local next_column = vim.fn.strdisplaywidth(text:sub(1, byte+length-1))
    local width = next_column - column
    if width == 0 and previous then
      cells[previous].text = cells[previous].text .. char
    elseif char == string.char(9) then
      for offset = 0, width-1 do cells[#cells+1] = { col=column+offset, text=' ' } end
      previous = #cells
    else
      cells[#cells+1] = { col=column, text=char }
      previous = #cells
      for offset = 1, width-1 do cells[#cells+1] = { col=column+offset, text='' } end
    end
    column, byte = next_column, byte + length
  end
  return cells
end

function M.byte_col(line, column)
  local byte, display = 1, 0
  while byte <= #line do
    local lead = line:byte(byte)
    local length = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    local next_display = vim.fn.strdisplaywidth(line:sub(1, byte+length-1))
    if next_display > display and (display >= column or next_display > column) then break end
    byte, display = byte + length, next_display
  end
  return byte-1
end

function M.label_layout(top, left, width, height, label, variant)
  local lines = M.label_lines(label)
  local text_only = variant == 't'
  local longest = 0
  for _, line in ipairs(lines) do longest = math.max(longest, vim.fn.strdisplaywidth(line)) end
  local row = text_only and top or top + math.max(1, math.floor((height - #lines + 1) / 2))
  local col = text_only and left or left + 1 + math.max(0, math.floor((width - 2 - longest) / 2))
  local result = {}
  for index, line in ipairs(lines) do result[#result+1] = { row=row+index-1, col=col, text=line } end
  return result
end

-- Arrow heads by incoming direction (dr, dc encoded as string).
M.ARROWS = {
  [' 1  0'] = '↓',
  ['-1  0'] = '↑',
  [' 0  1'] = '→',
  [' 0 -1'] = '←',
}

-- Reverse lookup: char → bitmask
local CHAR_TO_MASK = {}
for mask, ch in pairs(CHARS) do CHAR_TO_MASK[ch] = mask end

-- A grid is a table of rows: grid[row][col] = char string.
-- Rows are 1-indexed, cols are 1-indexed.

-- Read the current buffer into a grid table.
-- Expands tab characters to single spaces for simplicity.
function M.read_grid(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local grid = {}
  for r, line in ipairs(lines) do
    grid[r] = {}
    -- iterate over utf8 chars
    local col = 1
    for _, c in utf8 and utf8.codes(line) or ipairs({}) do
      local ch = type(c) == 'number' and utf8.char(c) or c
      grid[r][col] = ch
      col = col + 1
    end
    -- fallback: byte iteration for non-multibyte
    if col == 1 then
      for i = 1, #line do
        grid[r][i] = line:sub(i, i)
      end
    end
  end
  return grid, #lines
end

-- Read the current buffer into a grid, handling utf8 properly.
function M.buf_to_grid(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local grid = {}
  for r, line in ipairs(lines) do
    grid[r] = {}
    if #line == 0 then
      -- empty row, leave sparse
    else
      -- Use vim.fn.split on each char via a helper
      local col = 1
      local i = 1
      while i <= #line do
        local byte = line:byte(i)
        local char_len
        if byte >= 0xF0 then char_len = 4
        elseif byte >= 0xE0 then char_len = 3
        elseif byte >= 0xC0 then char_len = 2
        else char_len = 1 end
        grid[r][col] = line:sub(i, i + char_len - 1)
        col = col + 1
        i = i + char_len
      end
    end
  end
  return grid, #lines
end

-- Get char at (row, col) in grid (1-indexed). Returns ' ' if out of bounds.
function M.get(grid, row, col)
  return (grid[row] and grid[row][col]) or ' '
end

-- Set char at (row, col) in grid, extending as needed.
function M.set(grid, row, col, ch)
  if not grid[row] then grid[row] = {} end
  grid[row][col] = ch
end

-- Merge add_bits into the cell at (row, col) in grid.
-- Reads current char, ORs in bits, writes resolved char back.
function M.smart_merge(grid, row, col, add_bits)
  local current = M.get(grid, row, col)
  local mask = CHAR_TO_MASK[current] or 0
  mask = bit.bor(mask, add_bits)
  M.set(grid, row, col, CHARS[mask] or current)
end

-- Draw a box into grid at (top, left) with dimensions w×h, optional label and variant.
-- variant: normalized sorted mod string, e.g. '', 'r', 'd', 'dr', 't'
function M.draw_box(grid, top, left, w, h, label, variant)
  local key = variant_key(variant)
  local V   = VARIANTS[key] or VARIANTS['']

  -- Text-only: place each line at anchor, no border
  if V.text_only then
    for _, line in ipairs(M.label_layout(top, left, w, h, label, 't')) do
      for _, cell in ipairs(M.text_cells(line.text)) do M.set(grid, line.row, line.col+cell.col, cell.text) end
    end
    return
  end

  local bottom = top + h - 1
  local right  = left + w - 1
  local has_double_edge = key:find('d') ~= nil

  if has_double_edge then
    -- Double edges: set all border chars directly (no bitmask — double chars don't bitmask)
    M.set(grid, top,    left,  V.TL)
    M.set(grid, top,    right, V.TR)
    M.set(grid, bottom, left,  V.BL)
    M.set(grid, bottom, right, V.BR)
    for col = left + 1, right - 1 do
      M.set(grid, top,    col, V.H)
      M.set(grid, bottom, col, V.H)
    end
    for row = top + 1, bottom - 1 do
      M.set(grid, row, left,  V.V)
      M.set(grid, row, right, V.V)
    end
  else
    -- Plain or rounded: bitmask merge for edges/joins, then set corners from variant
    M.smart_merge(grid, top,    left,  BIT.R + BIT.D)
    M.smart_merge(grid, top,    right, BIT.L + BIT.D)
    M.smart_merge(grid, bottom, left,  BIT.R + BIT.U)
    M.smart_merge(grid, bottom, right, BIT.L + BIT.U)
    -- Override corners with variant-specific chars (rounded or plain)
    M.set(grid, top,    left,  V.TL)
    M.set(grid, top,    right, V.TR)
    M.set(grid, bottom, left,  V.BL)
    M.set(grid, bottom, right, V.BR)
    for col = left + 1, right - 1 do
      M.smart_merge(grid, top,    col, BIT.R + BIT.L)
      M.smart_merge(grid, bottom, col, BIT.R + BIT.L)
    end
    for row = top + 1, bottom - 1 do
      M.smart_merge(grid, row, left,  BIT.U + BIT.D)
      M.smart_merge(grid, row, right, BIT.U + BIT.D)
    end
  end

  -- Fill interior with spaces
  for row = top + 1, bottom - 1 do
    for col = left + 1, right - 1 do
      if not (grid[row] and grid[row][col] and grid[row][col] ~= ' ') then
        M.set(grid, row, col, ' ')
      end
    end
  end

  -- Center the label block while preserving relative indentation and blank lines.
  if label and h >= 3 then
    for _, line in ipairs(M.label_layout(top, left, w, h, label, key)) do
      for _, cell in ipairs(M.text_cells(line.text)) do M.set(grid, line.row, line.col+cell.col, cell.text) end
    end
  end
end

-- Erase a box from grid at (top, left) with dimensions w×h.
-- Replaces all border chars with spaces, removes interior content.
function M.erase_box(grid, top, left, w, h)
  local bottom = top + h - 1
  local right  = left + w - 1
  for row = top, bottom do
    for col = left, right do
      M.set(grid, row, col, ' ')
    end
  end
end

-- Flush grid back to the buffer.
-- Ensures the buffer has enough lines and each row is written correctly.
function M.flush(buf, grid, total_rows)
  -- Find the highest row used in the grid
  local max_row = total_rows
  for r, _ in pairs(grid) do
    if r > max_row then max_row = r end
  end

  -- Build lines array
  local lines = {}
  for r = 1, max_row do
    local row = grid[r]
    if not row then
      table.insert(lines, '')
    else
      -- Find max col in this row
      local max_col = 0
      for c, _ in pairs(row) do
        if c > max_col then max_col = c end
      end
      local chars = {}
      for c = 1, max_col do
        chars[c] = row[c] or ' '
      end
      table.insert(lines, table.concat(chars))
    end
  end

  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = was_modifiable
  vim.bo[buf].modified   = false
end

return M
