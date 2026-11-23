local M = {}
local uv = vim.uv or vim.loop
M.pool = { '#7ec8e3', '#f4a261', '#52b788', '#c77dff', '#e9c46a', '#f15bb5',
  '#4cc9f0', '#b7e4c7', '#e76f51', '#a8c5da', '#e2b4bd', '#00f5d4' }
function M.identity(entry)
  return entry.agent .. ':' .. tostring(entry.conversation_id or entry.id)
end
local function read(file)
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(file), '\n')) end)
  return ok and type(data) == 'table' and type(data.assignments) == 'table' and data.assignments or {}
end
function M.groups(entries, directory, pool)
  pool = type(pool) == 'table' and #pool > 0 and pool or M.pool
  local folder = directory .. '/appearance'
  local file, lock = folder .. '/colors.json', folder .. '/colors.lock'
  local assignments = read(file)
  local missing = false
  for _, entry in ipairs(entries) do if not assignments[M.identity(entry)] then missing = true end end
  local ok = pcall(vim.fn.mkdir, folder, 'p')
  local fd = missing and ok and uv.fs_open(lock, 'wx', 384) or nil
  if missing and not fd then
    -- Recover a lock left by an editor that exited unexpectedly.
    local owner_ok, owner = pcall(function() return tonumber(vim.fn.readfile(lock)[1]) end)
    if not owner_ok then owner = nil end
    local live, err
    if owner then live, err = uv.kill(owner, 0) end
    local stat = uv.fs_stat(lock)
    if stat and ((owner and live ~= 0 and not tostring(err):find('EPERM', 1, true))
      or (not owner and os.time() - stat.mtime.sec > 5)) then
      uv.fs_unlink(lock)
      fd = uv.fs_open(lock, 'wx', 384)
    end
  end
  if fd then
    uv.fs_write(fd, tostring(vim.fn.getpid()), 0)
    local saved_ok = pcall(function()
      assignments = read(file)
      local used = {}
      for _, index in pairs(assignments) do if type(index) == 'number' then used[index] = true end end
      for _, entry in ipairs(entries) do
        local key = M.identity(entry)
        if not assignments[key] then
          local index = tonumber(vim.fn.sha256(key):sub(1, 8), 16) % #pool + 1
          for offset = 0, #pool - 1 do
            local candidate = (index - 1 + offset) % #pool + 1
            if not used[candidate] then index = candidate; break end
          end
          assignments[key], used[index] = index, true
        end
      end
      local temp = file .. '.' .. vim.fn.getpid() .. '.tmp'
      vim.fn.writefile({ vim.json.encode({ version = 1, assignments = assignments }) }, temp)
      uv.fs_chmod(temp, 384)
      assert(uv.fs_rename(temp, file))
    end)
    uv.fs_close(fd)
    uv.fs_unlink(lock)
    if not saved_ok then assignments = read(file) end
  end
  local groups = {}
  for _, entry in ipairs(entries) do
    local key = M.identity(entry)
    local index = tonumber(assignments[key]) or (tonumber(vim.fn.sha256(key):sub(1, 8), 16) % #pool + 1)
    index = (index - 1) % #pool + 1
    local group = 'AgentViewConversation' .. index
    vim.api.nvim_set_hl(0, group, { fg = pool[index] })
    groups[key] = group
  end
  return groups
end
return M
