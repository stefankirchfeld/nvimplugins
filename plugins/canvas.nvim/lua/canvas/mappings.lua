-- Temporary buffer mappings must not discard the user's existing mappings.
local M = {}
local saved = {}
function M.set(buf, layer, key, callback, opts)
  saved[buf] = saved[buf] or {}
  saved[buf][layer] = saved[buf][layer] or {}
  local bindings = saved[buf][layer]
  if bindings[key] == nil then
    local prior = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, 'n', false, true) end)
    bindings[key] = prior.buffer == 1 and prior or false
  end
  vim.keymap.set('n', key, callback, opts)
end
function M.clear(buf, layer)
  local bindings = saved[buf] and saved[buf][layer]
  if not bindings then return end
  if vim.api.nvim_buf_is_valid(buf) then
    for key, prior in pairs(bindings) do
      pcall(vim.keymap.del, 'n', key, { buffer = buf })
      if prior then vim.api.nvim_buf_call(buf, function() vim.fn.mapset('n', false, prior) end) end
    end
  end
  saved[buf][layer] = nil
  if not next(saved[buf]) then saved[buf] = nil end
end
return M
