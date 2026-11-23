local M = {}
local function clean(value) return tostring(value or ''):gsub('[\r\n\t]', ' ') end
function M.fit(value, width)
  local text = clean(value)
  if width <= 0 then return '' end
  if vim.fn.strdisplaywidth(text) > width then
    local count = vim.fn.strchars(text)
    repeat count = count - 1; text = vim.fn.strcharpart(text, 0, count)
    until vim.fn.strdisplaywidth(text) <= width - 1
    text = text .. '…'
  end
  return text .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(text)))
end
function M.age(entry, now)
  local seconds = math.max(0, now - (tonumber(entry.updated_at) or tonumber(entry.created_at) or now))
  if seconds < 60 then return seconds .. 's ago' end
  if seconds < 3600 then return math.floor(seconds / 60) .. 'm ago' end
  if seconds < 86400 then return math.floor(seconds / 3600) .. 'h ago' end
  return math.floor(seconds / 86400) .. 'd ago'
end
function M.layout(entries, width, now, identity_groups, options)
  local content = math.max(1, width - 4)
  local columns = { { key = 'title', label = 'Conversation', width = content } }
  if content >= 42 then
    columns[#columns + 1] = { key = 'status', label = 'Status', width = 10 }
    columns[#columns + 1] = { key = 'age', label = 'Activity', width = 8 }
  end
  if content >= 60 then table.insert(columns, 1, { key = 'agent', label = 'Agent', width = 7 }) end
  if content >= 86 then table.insert(columns, #columns - 1, { key = 'scope', label = 'Scope → last edit', width = 23 }) end
  local fixed = 3 * (#columns - 1)
  for _, col in ipairs(columns) do if col.key ~= 'title' then fixed = fixed + col.width end end
  for _, col in ipairs(columns) do if col.key == 'title' then col.width = math.max(1, content - fixed) end end
  local header = {}
  for _, col in ipairs(columns) do header[#header + 1] = M.fit(col.label, col.width) end
  local lines = { '  Agents  · ' .. #entries, '', '  ' .. table.concat(header, ' │ '), '  ' .. string.rep('─', content) }
  local rows, spans = {}, { { row = 0, first = 2, last = 8, group = 'Title' },
    { row = 2, first = 0, last = -1, group = 'Comment' }, { row = 3, first = 0, last = -1, group = 'Comment' } }
  for _, entry in ipairs(entries) do
    local status = entry.status
    local glyph = { working = '󰔟', waiting = '󰋗', error = '󰅚' }
    local name = vim.fn.fnamemodify(entry.folder, ':t')
    local project = entry.last_project and vim.fn.fnamemodify(entry.last_project, ':t')
    local values = { agent = entry.agent:sub(1, 1):upper() .. entry.agent:sub(2),
      title = entry.title or 'Untitled session', scope = name .. (project and (' → ' .. project) or ''),
      status = (options.status_icons ~= false and glyph[status] and (glyph[status] .. ' ') or '') .. status,
      age = M.age(entry, now) }
    local parts, offset = {}, 2
    local row = #lines
    for index, col in ipairs(columns) do
      local part = M.fit(values[col.key], col.width)
      local group = col.key == 'title' and identity_groups[require('agent_view.colors').identity(entry)]
        or col.key == 'status' and ({ working = 'DiagnosticInfo', waiting = 'DiagnosticWarn', error = 'DiagnosticError', done = 'DiagnosticOk', idle = 'Comment' })[status]
        or (col.key == 'scope' or col.key == 'age') and 'Comment' or 'Normal'
      spans[#spans + 1] = { row = row, first = offset, last = offset + #part, group = group }
      parts[#parts + 1] = part
      offset = offset + #part + (index < #columns and #' │ ' or 0)
    end
    lines[#lines + 1] = '  ' .. table.concat(parts, ' │ ')
    rows[#lines] = entry
  end
  if #entries == 0 then lines[#lines + 1] = M.fit('  No agents registered.', width) end
  return lines, rows, spans
end
return M
