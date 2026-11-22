local M = {}
local scene = require('canvas.scene')

-- Base command chars and their canonical names
local BASES = {
  b = 'box',
  c = 'conn',
  t = 'text',
  d = 'del',
}

-- Anchor semantics by base command
local ANCHORS = {
  box   = 'top-left',
  conn  = 'cursor',
  text  = 'cursor',
  del   = 'cursor',
  color = 'cursor',
}

-- Routing names come directly from the engine.
local CONN_STYLES = require('canvas.router').STYLES

-- ─── Command token parser ─────────────────────────────────────────────────────

-- Split an alpha token into {base, mods}.
-- Base is the first char if it's a known base, else the full token is a legacy name.
-- Mods are the remaining chars, each a flag.
-- e.g. "br" → {base="box", mods={r=true}}
--      "cbd" → {base="conn", mods={b=true, d=true}}
--      "box" → {base="box", mods={}}   (legacy full name, 'o'/'x' not valid mods so ignored)
local function parse_cmd_token(token)
  token = token:lower()

  -- Legacy full names still work
  local legacy = {
    box='box', cbox='box', rbox='box', ibox='box',
    conn='conn', aconn='conn', bconn='conn', dconn='conn',
    text='text', del='del',
    color='color',
  }
  if legacy[token] then
    local base = legacy[token]
    local mods = {}
    -- extract mods from legacy names
    if token == 'cbox'  then mods.c = true end
    if token == 'rbox'  then mods.r = true end
    if token == 'ibox'  then mods.i = true end
    if token == 'aconn' then mods.a = true end
    if token == 'bconn' then mods.b = true end
    if token == 'dconn' then mods.d = true end
    return base, mods
  end

  -- Bitmap mode: first char is base, rest are mods
  local base_char = token:sub(1, 1)
  local base = BASES[base_char]
  if not base then return nil, nil end

  if base == 'box' or base == 'conn' then
    local mods = scene.decode_token(token, base)
    if not mods then return nil, nil end
    return base, mods
  end
  return base, {}

end

-- ─── Bracket mode ────────────────────────────────────────────────────────────

local function parse_bracket(input)
  local name, args_str = input:match('^(%a+)%((.*)%)%s*$')
  if not name then return nil end
  local base, mods = parse_cmd_token(name)
  if not base then return nil end
  local anchor = ANCHORS[base]
  if mods.c then anchor = 'center' end
  if mods.r then anchor = 'top-left' end  -- rbox is top-left anchored
  return { cmd = base, mods = mods, params = M.parse_params(args_str), anchor = anchor }
end

-- ─── Space mode ──────────────────────────────────────────────────────────────

local function tokenise(input)
  local tokens = {}
  for tok in input:gmatch('%S+') do
    local n = tonumber(tok)
    table.insert(tokens, n ~= nil and n or tok:lower())
  end
  return tokens
end

local function merge_trailing_strings(tokens)
  local last_num = 0
  for i, t in ipairs(tokens) do
    if type(t) == 'number' then last_num = i end
  end
  if last_num == #tokens then return tokens end
  local result = {}
  for i = 1, last_num do result[i] = tokens[i] end
  local strs = {}
  for i = last_num + 1, #tokens do table.insert(strs, tokens[i]) end
  table.insert(result, table.concat(strs, ' '))
  return result
end

local function parse_space(input)
  if input:match('^%s*$') then return nil end
  local tokens = tokenise(input)
  if #tokens == 0 then return nil end

  local base, mods, params_start

  if type(tokens[1]) == 'number' then
    -- bare number alias: "1 2" → conn(1,2)
    base, mods = 'conn', {}
    params_start = 1
  else
    base, mods = parse_cmd_token(tokens[1])
    params_start = 2
  end

  if not base or not ANCHORS[base] then return nil end

  local raw = {}
  for i = params_start, #tokens do raw[#raw+1] = tokens[i] end
  local params = merge_trailing_strings(raw)

  local anchor = ANCHORS[base]
  if mods.c then anchor = 'center' end

  return { cmd = base, mods = mods, params = params, anchor = anchor }
end

-- ─── Public API ──────────────────────────────────────────────────────────────

function M.parse(input)
  return parse_bracket(input) or parse_space(input)
end

function M.is_partial(input)
  return input:match('^%a+%(') ~= nil and input:sub(-1) ~= ')'
end

function M.parse_params(args_str)
  if args_str:match('^%s*$') then return {} end
  local params = {}
  for token in (args_str .. ','):gmatch('([^,]*),') do
    token = token:match('^%s*(.-)%s*$')
    if token ~= '' then
      local n = tonumber(token)
      table.insert(params, n ~= nil and n or token)
    end
  end
  return params
end

function M.box_fields(params)
  local nums, strs = {}, {}
  for _, p in ipairs(params) do
    if type(p) == 'number' then table.insert(nums, p)
    else table.insert(strs, p) end
  end
  return nums[1], nums[2], strs[1]
end

function M.box_dimensions(params)
  local width, height, label = M.box_fields(params)
  local w, h = scene.box_dimensions(width, height, label)
  return w, h, label
end

function M.conn_params(params)
  local from_id = params[1]
  local to_id   = type(params[2]) == 'number' and params[2] or nil

  local strs = {}
  local start = to_id and 3 or 2
  for i = start, #params do
    if type(params[i]) == 'string' then table.insert(strs, params[i]) end
  end

  local style, label
  if #strs > 0 then
    local last = strs[#strs]
    if CONN_STYLES[last] then
      style = last
      if #strs > 1 then label = table.concat(strs, ' ', 1, #strs - 1) end
    else
      local body, tail = last:match('^(.-)%s+(%S+)$')
      if tail and CONN_STYLES[tail] then
        style = tail
        local parts = {}
        for i = 1, #strs - 1 do parts[#parts+1] = strs[i] end
        if body and body ~= '' then parts[#parts+1] = body end
        label = #parts > 0 and table.concat(parts, ' ') or nil
      else
        label = table.concat(strs, ' ')
      end
    end
  end

  return from_id, to_id, label, style
end

function M.color_params(params)
  local id  = type(params[1]) == 'number' and params[1] or nil
  local fg  = type(params[2]) == 'string' and params[2] ~= '-' and params[2] or nil
  local bg  = type(params[3]) == 'string' and params[3] ~= '-' and params[3] or nil
  local txt = type(params[4]) == 'string' and params[4] ~= '-' and params[4] or nil
  return id, fg, bg, txt
end

return M
