-- One saved document snapshot, with a saved scene for every visited canvas.
local M = {}
local state = require('canvas.state')
local scene = require('canvas.scene')
local persist = require('canvas.persist')
local snapshots = {}
local closers = {}

local function sequence(buf)
  return vim.api.nvim_buf_call(buf, function() return vim.fn.undotree().seq_cur end)
end

function M.changed(buf)
  if snapshots[buf] then snapshots[buf].working_sequence = sequence(buf) end
end

function M.pending(buf, selected)
  local saved = snapshots[buf]
  if not saved then return false end
  if selected then
    local entry = saved.scenes[selected]
    return entry ~= nil and not vim.deep_equal(entry.scene, scene.serialize(selected))
  end
  for s, entry in pairs(saved.scenes) do
    if not vim.deep_equal(entry.scene, scene.serialize(s)) then return true end
  end
  return false
end

local function capture(buf, baseline)
  local s = state.for_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local lines = baseline or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if baseline and vim.fn.filereadable(name) == 1 then lines = vim.fn.readfile(name) end
  local saved = snapshots[buf]
  if not saved then
    saved = { scenes={}, lines=lines }
    snapshots[buf] = saved
  end
  if baseline then
    -- Register a new block without replacing the document's saved baseline.
    saved.scenes[s] = { scene=vim.deepcopy(scene.serialize(s)), file=s.canvas_file }
  else
    saved.lines, saved.working_sequence = lines, nil
    for _, selected in pairs(state.scenes(buf)) do
      saved.scenes[selected] = { scene=vim.deepcopy(scene.serialize(selected)), file=selected.canvas_file }
    end
  end
end

local function restore(buf, close)
  local saved = snapshots[buf]
  if not saved then return end
  close(buf)
  for s, entry in pairs(saved.scenes) do
    local loaded = scene.deserialize(entry.scene)
    s.shapes, s.conns, s.next_id = loaded.shapes, loaded.conns, loaded.next_id
    s.canvas_file, s.grid_cache = entry.file, nil
  end
  saved.working_sequence = nil
end

local function check_saved(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local saved = snapshots[buf]
  local undo_to_saved = saved and saved.working_sequence and sequence(buf) < saved.working_sequence
  if saved and (not vim.bo[buf].modified or undo_to_saved) and M.pending(buf)
    and vim.deep_equal(saved.lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    restore(buf, closers[buf])
    vim.bo[buf].modified = false
  end
end

local function schedule_check(buf)
  vim.schedule(function() check_saved(buf) end)
end

function M.watch(buf, close, baseline)
  closers[buf] = close
  if baseline then capture(buf, baseline) end
  local group = vim.api.nvim_create_augroup('canvas_session_' .. buf, { clear=true })
  vim.api.nvim_create_autocmd('BufWritePre', { group=group, buffer=buf, callback=function() close(buf) end })
  vim.api.nvim_create_autocmd('BufWritePost', { group=group, buffer=buf, callback=function(event)
    -- A range write or :w other-file is not a commit of this buffer.
    if vim.bo[buf].modified then return end
    local destination = vim.fn.resolve(vim.fn.fnamemodify(event.file, ':p'))
    if destination ~= vim.fn.resolve(vim.api.nvim_buf_get_name(buf)) then return end
    local ok = true
    for _, selected in pairs(state.scenes(buf)) do
      if not persist.save(buf, selected) then ok = false end
    end
    if ok then capture(buf) else vim.bo[buf].modified = true end
  end })
  vim.api.nvim_create_autocmd('BufReadPost', { group=group, buffer=buf, callback=function()
    restore(buf, close)
    if snapshots[buf] then snapshots[buf].lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
  end })
  vim.api.nvim_create_autocmd({ 'BufModifiedSet', 'TextChanged', 'TextChangedI' }, {
    group=group, buffer=buf, callback=function()
      -- BufModifiedSet also fires during :w; let BufWritePost commit first.
      schedule_check(buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', { group=group, buffer=buf, callback=function()
    close(buf)
    snapshots[buf], closers[buf] = nil, nil
    state.clear_buf(buf)
    vim.api.nvim_del_augroup_by_id(group)
  end })
end

-- Identical-text undo may emit no TextChanged event. Observe, without replacing,
-- undo and command-enter keys and check only for a full return to the saved text.
local key_ns = vim.api.nvim_create_namespace('canvas_nvim_snapshot_keys')
vim.on_key(function(key)
  if key == 'u' or key == string.char(13) then
    local buf = vim.api.nvim_get_current_buf()
    if snapshots[buf] then schedule_check(buf) end
  end
end, key_ns)

return M
