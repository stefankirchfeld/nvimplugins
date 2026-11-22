local M = {}
local scene = require('canvas.scene')

-- Namespaces are global (one per Neovim session), not per-buffer
M.ns_id = vim.api.nvim_create_namespace('canvas_nvim')
M.ns_hl = vim.api.nvim_create_namespace('canvas_nvim_hl')
M.ns_fence = vim.api.nvim_create_namespace('canvas_nvim_fences')

-- Per-buffer state tables
local buf_states = {}
local buf_scenes = {}

local function new_state()
  return vim.tbl_extend('force', scene.new(), { active=false, row_start=1, row_end=1 })
end

-- Returns the state table for a given buffer, creating it if needed.
function M.for_buf(bufnr)
  if not buf_states[bufnr] then
    buf_states[bufnr] = new_state()
  end
  return buf_states[bufnr]
end

-- Select a Markdown sidecar without discarding another block's working scene.
function M.select(bufnr, path)
  local first = buf_scenes[bufnr] == nil
  buf_scenes[bufnr] = buf_scenes[bufnr] or {}
  local scenes = buf_scenes[bufnr]
  local fresh = scenes[path] == nil
  if fresh then
    local previous = buf_states[bufnr]
    scenes[path] = first and previous or new_state()
    scenes[path].canvas_file = path
  end
  buf_states[bufnr] = scenes[path]
  return scenes[path], fresh
end

function M.scenes(bufnr)
  if buf_scenes[bufnr] then return buf_scenes[bufnr] end
  return { state=M.for_buf(bufnr) }
end

-- Remove state for a buffer (e.g. on BufDelete).
function M.clear_buf(bufnr)
  buf_states[bufnr] = nil
  buf_scenes[bufnr] = nil
end

return M
