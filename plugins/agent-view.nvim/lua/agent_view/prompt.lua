local M = {}

local CONTEXT_LINES   = 20
local VISUAL_MAX_LINES = 40

local assistant_target = require('agent_view.tmux').target

-- Shared scratch-buffer + send infrastructure.
-- opts.header_lines : lines shown above the prompt (commented out with "# ")
-- opts.message_fn   : function(prompt_text) → string to send to the assistant
-- opts.split_height : height of the split (default 20)
local function open_prompt(opts)
  local header_lines = opts.header_lines
  local message_fn   = opts.message_fn
  local split_height = opts.split_height or 20

  local prompt_buf = vim.api.nvim_create_buf(false, true)
  local buf_lines  = {}
  for _, l in ipairs(header_lines) do table.insert(buf_lines, l) end
  table.insert(buf_lines, "")
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, buf_lines)
  vim.bo[prompt_buf].buftype   = "acwrite"
  vim.bo[prompt_buf].filetype  = "markdown"
  vim.bo[prompt_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(prompt_buf, "assistant://prompt")

  vim.cmd("botright " .. split_height .. "split")
  vim.api.nvim_win_set_buf(0, prompt_buf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(prompt_buf), 0 })
  vim.cmd("startinsert")

  local pending_target = nil

  vim.api.nvim_buf_create_user_command(prompt_buf, "Wai", function(cmd_opts)
    if cmd_opts.args ~= "" then
      pending_target = cmd_opts.args:match("^(%d+)")
    end
    vim.cmd("w")
  end, {
    nargs = "?",
    complete = function()
      local scope = require('agent_view.tmux').scope()
      if not scope then return {} end
      local result = vim.system({ 'tmux', '-S', scope.socket, 'list-windows', '-t', scope.session, '-F', '#{window_index}:#{window_name}' }, { text = true }):wait(1500)
      local windows = result.code == 0 and vim.split(vim.trim(result.stdout), '\n') or {}
      return windows
    end,
    desc = "Send to an assistant tmux window",
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = prompt_buf,
    once   = false,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)

      local prompt_start = 1
      for i = #lines, 1, -1 do
        if lines[i]:match("^# ──") then
          prompt_start = i + 1
          break
        end
      end

      local prompt_lines = {}
      for i = prompt_start, #lines do table.insert(prompt_lines, lines[i]) end
      while #prompt_lines > 0 and prompt_lines[1]             == "" do table.remove(prompt_lines, 1)  end
      while #prompt_lines > 0 and prompt_lines[#prompt_lines] == "" do table.remove(prompt_lines)     end

      if #prompt_lines == 0 then
        vim.notify("agent-prompt: empty prompt, not sending", vim.log.levels.WARN)
        vim.cmd("bwipeout!")
        return
      end

      local message = message_fn(table.concat(prompt_lines, "\n"))
      local target, target_error = assistant_target(pending_target)
      if not target then vim.notify(target_error, vim.log.levels.WARN); return end
      pending_target = nil
      local buffer_name = 'agent_prompt_' .. vim.fn.getpid() .. '_' .. tostring(vim.uv.hrtime())
      local tmpfile = os.tmpname()
      local fh = io.open(tmpfile, "w")
      if fh then
        fh:write(message)
        fh:close()
        vim.fn.system("tmux load-buffer -b " .. buffer_name .. " " .. vim.fn.shellescape(tmpfile))
        -- Use paste-buffer with -p (no trailing newline) then send Enter separately.
        -- The sleep ensures the paste completes before Enter is sent.
        vim.fn.system("tmux paste-buffer -d -p -b " .. buffer_name .. " -t " .. vim.fn.shellescape(target) .. " && sleep 0.3 && tmux send-keys -t " .. vim.fn.shellescape(target) .. " Enter")
        os.remove(tmpfile)
      else
        vim.notify("agent-prompt: failed to write temp file", vim.log.levels.ERROR)
        return
      end
      vim.notify("agent-prompt: sent to " .. target, vim.log.levels.INFO)
      vim.cmd("bwipeout!")
    end,
  })
end

-- Full snippet context (±CONTEXT_LINES around cursor, or explicit from/to)
function M.open(opts)
  opts = opts or {}
  local bufnr       = vim.api.nvim_get_current_buf()
  local filepath    = vim.api.nvim_buf_get_name(bufnr)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local cursor_line = opts.cursor_line or vim.api.nvim_win_get_cursor(0)[1]
  local from        = opts.from or math.max(1, cursor_line - CONTEXT_LINES)
  local to          = opts.to   or math.min(total_lines, cursor_line + CONTEXT_LINES)
  local code_lines  = vim.api.nvim_buf_get_lines(bufnr, from - 1, to, false)
  local ext         = filepath:match("%.([^%.]+)$") or ""

  local header = {
    "# " .. filepath .. ":" .. from .. "-" .. to,
    "# cursor at line " .. cursor_line,
    "# ──────────────────────────────────────────────",
  }
  for i, line in ipairs(code_lines) do
    local abs_line = from + i - 1
    local marker   = abs_line == cursor_line and ">" or " "
    table.insert(header, string.format("# %s %4d  %s", marker, abs_line, line))
  end
  table.insert(header, "# ──────────────────────────────────────────────")

  open_prompt({
    header_lines = header,
    split_height = 20,
    message_fn   = function(prompt_text)
      local context_block = "```" .. ext .. "\n"
      for i, line in ipairs(code_lines) do
        local abs_line = from + i - 1
        local marker   = abs_line == cursor_line and ">" or " "
        context_block  = context_block .. string.format("%s %4d  %s\n", marker, abs_line, line)
      end
      context_block = context_block .. "```"
      return "You are being called from inside Vim. The user wants to discuss or get assistance with the file excerpt below. File path and line range are provided for context and if needed, read the full file given the users permission. Respond to the user's prompt at the end.\n\n"
        .. filepath .. ":" .. from .. "-" .. to
        .. "\n" .. context_block
        .. "\n\n" .. prompt_text
    end,
  })
end

-- Visual mode: uses selected lines if <= VISUAL_MAX_LINES, else cursor context
function M.open_visual()
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)
  local v_start  = vim.fn.line("'<")
  local v_end    = vim.fn.line("'>")
  local sel_lines = v_end - v_start + 1
  if sel_lines <= VISUAL_MAX_LINES then
    M.open({ from = v_start, to = v_end, cursor_line = v_start })
  else
    vim.notify(
      string.format("agent-prompt: selection too large (%d lines), using cursor context instead", sel_lines),
      vim.log.levels.INFO
    )
    M.open({ cursor_line = v_start })
  end
end

-- Lightweight reference: just filepath:line, no snippet
function M.open_ref()
  local filepath    = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local ref         = filepath .. ":" .. cursor_line

  open_prompt({
    header_lines = {
      "# " .. ref,
      "# ──────────────────────────────────────────────",
    },
    split_height = 10,
    message_fn   = function(prompt_text)
      return "You are being called from inside Vim. The user is referencing a specific location in the codebase. File path and line number are provided — read the file if needed (with the user's permission).\n\n"
        .. ref .. "\n\n" .. prompt_text
    end,
  })
end

return M
