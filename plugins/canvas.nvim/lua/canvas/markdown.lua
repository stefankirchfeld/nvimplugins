local M = {}

-- Markdown fences may use three or more backticks or tildes, with up to
-- three leading spaces. Track other fenced languages too, so examples inside
-- a larger code fence cannot become editable canvases.
function M.fences(lines)
  local result, opened = {}, nil
  for row, line in ipairs(lines) do
    local indent, marker, info = line:match('^( *)([`~]+)(.*)$')
    if marker and #indent <= 3 and #marker >= 3
      and marker == string.rep(marker:sub(1,1), #marker) then
      info = vim.trim(info)
      if opened then
        if marker:sub(1,1) == opened.marker:sub(1,1) and #marker >= #opened.marker and info == '' then
          if opened.canvas then
            opened.row_start, opened.row_end = opened.opener+1, row-1
            result[#result+1] = opened
          end
          opened = nil
        end
      else
        opened = { opener=row, marker=marker, indent=indent, info=info,
          canvas=info == 'canvas' or info:match('^canvas%s') ~= nil }
      end
    end
  end
  return result
end

return M
