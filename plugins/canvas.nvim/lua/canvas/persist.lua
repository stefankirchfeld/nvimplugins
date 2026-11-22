local M = {}

local state = require('canvas.state')
local scene = require('canvas.scene')

-- Legacy inline markers (used only for migration)
local LEGACY_MARKER     = '<!-- canvas-state:'
local LEGACY_MARKER_END = ' -->'

-- ─── Path resolution ─────────────────────────────────────────────────────────

local DEFAULT_DIR = vim.fn.expand('~/.canvas-nvim/canvases/')

local function dir_of(path)
  return path:match('(.+/)') or './'
end

local function resolve_path(rel, base_dir)
  if rel:sub(1, 1) == '/' or rel:sub(1, 1) == '~' then
    return vim.fn.expand(rel)
  end
  return vim.fn.simplify(base_dir .. rel)
end

local function slug_from_bufname(bufname)
  local slug = bufname:gsub('[/\\:%%]', '_')
  if #slug > 180 then slug = slug:sub(-180) end
  return slug
end

-- Returns the resolved absolute sidecar path for buf.
-- Also caches it in s.canvas_file if not already set.
local function sidecar_path(buf)
  local s = state.for_buf(buf)
  if s.canvas_file then return s.canvas_file end

  local bufname = vim.api.nvim_buf_get_name(buf)
  local ft      = vim.bo[buf].filetype
  local path

  -- 1. Plain file: shebang on line 1
  if ft ~= 'markdown' and bufname ~= '' then
    local line1 = (vim.api.nvim_buf_get_lines(buf, 0, 1, false))[1] or ''
    local override = line1:match('^#%s*canvas:%s*(.-)%s*$')
    if override and override ~= '' then
      path = resolve_path(override, dir_of(bufname))
    end
  end

  -- 2. Markdown: s.canvas_file already checked above; fence attr stored by init.lua
  -- (falls through to default if not set)

  -- 3. Default slug
  if not path then
    if bufname ~= '' then
      path = DEFAULT_DIR .. slug_from_bufname(bufname) .. '.canvas.json'
    else
      -- 4. Unnamed buffer
      path = DEFAULT_DIR .. 'unnamed_' .. buf .. '.canvas.json'
    end
  end

  s.canvas_file = path
  return path
end

-- Exported so init.lua can call it to build the fence tag attr before s.canvas_file is set.
function M.default_sidecar_path(buf, index)
  local bufname = vim.api.nvim_buf_get_name(buf)
  local suffix = index and index > 1 and '_' .. index or ''
  if bufname ~= '' then
    return DEFAULT_DIR .. slug_from_bufname(bufname) .. suffix .. '.canvas.json'
  end
  return DEFAULT_DIR .. 'unnamed_' .. buf .. suffix .. '.canvas.json'
end

-- ─── Pretty-print JSON ───────────────────────────────────────────────────────

local function is_array(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0
end

local function all_scalar(t)
  for _, v in ipairs(t) do
    if type(v) == 'table' then return false end
  end
  return true
end

local function json_scalar(v)
  if v == nil then return 'null'
  elseif v == true then return 'true'
  elseif v == false then return 'false'
  elseif type(v) == 'number' then return tostring(v)
  else
    -- string: escape special chars
    return '"' .. tostring(v)
      :gsub('\\', '\\\\')
      :gsub('"',  '\\"')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t')
      .. '"'
  end
end

local function pretty_json(val, depth)
  depth = depth or 0
  local indent  = string.rep('  ', depth)
  local indent1 = string.rep('  ', depth + 1)

  if type(val) ~= 'table' then
    return json_scalar(val)
  end

  if is_array(val) then
    if all_scalar(val) then
      local parts = {}
      for _, v in ipairs(val) do parts[#parts+1] = json_scalar(v) end
      return '[' .. table.concat(parts, ', ') .. ']'
    else
      local parts = {}
      for _, v in ipairs(val) do
        parts[#parts+1] = indent1 .. pretty_json(v, depth + 1)
      end
      return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end
  end

  -- Object: sort keys for stable output
  local keys = {}
  for k in pairs(val) do
    if val[k] ~= nil then keys[#keys+1] = k end
  end
  table.sort(keys, function(a, b)
    -- put id-like numeric string keys first, then alphabetical
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    if na then return true end
    if nb then return false end
    return a < b
  end)

  if #keys == 0 then return '{}' end

  local parts = {}
  for _, k in ipairs(keys) do
    local v = val[k]
    if v ~= nil then
      parts[#parts+1] = indent1 .. json_scalar(tostring(k)) .. ': ' .. pretty_json(v, depth + 1)
    end
  end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

-- ─── Serialisation helpers ───────────────────────────────────────────────────

local function populate_state(s, data)
  local loaded = scene.deserialize(data)
  s.shapes, s.conns, s.next_id = loaded.shapes, loaded.conns, loaded.next_id
end

-- ─── Public API ──────────────────────────────────────────────────────────────

function M.save(buf, selected)
  local s = selected or state.for_buf(buf)
  local path = s.canvas_file or sidecar_path(buf)
  local dir  = dir_of(path)
  local json = pretty_json(scene.serialize(s))
  local ok, err = pcall(function()
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.split(json, '\n'), path)
  end)
  if not ok then
    vim.notify('canvas: save failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

function M.load(buf)
  local s = state.for_buf(buf)
  if not s.row_start then return false end

  local path = sidecar_path(buf)

  -- Try sidecar file first
  if vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    local json  = table.concat(lines, '\n')
    local ok, data = pcall(vim.fn.json_decode, json)
    if not ok or type(data) ~= 'table' then
      vim.notify('canvas: failed to parse sidecar: ' .. path, vim.log.levels.WARN)
      return false
    end
    local valid, err = pcall(populate_state, s, data)
    if not valid then
      vim.notify('canvas: invalid sidecar: ' .. tostring(err), vim.log.levels.WARN)
      return false
    end
    return true
  end

  -- Migration: look for old inline comment
  local crow = s.row_end + 1
  local line  = (vim.api.nvim_buf_get_lines(buf, crow - 1, crow, false))[1] or ''
  local is_legacy = line:sub(1, #LEGACY_MARKER) == LEGACY_MARKER
                and line:sub(-#LEGACY_MARKER_END) == LEGACY_MARKER_END
  if is_legacy then
    local json_str = line:sub(#LEGACY_MARKER + 1, #line - #LEGACY_MARKER_END)
    local ok, data = pcall(vim.fn.json_decode, json_str)
    if ok and type(data) == 'table' then
      local valid, err = pcall(populate_state, s, data)
      if not valid then
        vim.notify('canvas: invalid legacy state: ' .. tostring(err), vim.log.levels.WARN)
        return false
      end
      -- Remove inline comment from buffer
      local was_mod = vim.bo[buf].modifiable
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, crow - 1, crow, false, {})
      vim.bo[buf].modifiable = was_mod
      vim.notify('canvas: inline state loaded; sidecar will be written on :w → ' .. path, vim.log.levels.INFO)
      return true
    end
  end

  return false
end

return M
