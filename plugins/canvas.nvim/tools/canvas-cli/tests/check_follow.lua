local request = vim.json.decode(io.read('*a'))
vim.opt.runtimepath:prepend(request.root)
local canvas = require('canvas.init')
local state = require('canvas.state')
local editor = require('canvas.form')
vim.cmd.edit(vim.fn.fnameescape(request.document))
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.bo[source].filetype = 'markdown'
for row,line in ipairs(vim.api.nvim_buf_get_lines(source,0,-1,false)) do
  if line:find('canvas file=',1,true) then vim.api.nvim_win_set_cursor(0,{row+1,0});break end
end
canvas.open()
local s = state.for_buf(source)
local function hover(id)
  vim.api.nvim_set_current_win(source_win)
  local shape = s.shapes[id]
  local row = shape.top + (shape.outline == 'diamond' and math.floor(shape.height/2) or 0)
  local absolute = s.row_start+row-1
  local line = vim.api.nvim_buf_get_lines(source,absolute-1,absolute,false)[1]
  vim.api.nvim_win_set_cursor(source_win,{absolute,require('canvas.render').byte_col(line,shape.left-1)})
  vim.api.nvim_exec_autocmds('CursorMoved',{buffer=source})
end
hover(1)
editor.open(source,1,'box',canvas.rerender,true)
local draft, draft_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
hover(2)
assert(vim.api.nvim_get_current_win()==source_win, 'following stole diagram focus')
assert(vim.api.nvim_win_get_buf(draft_win)==draft and vim.b[draft].canvas_target_id==2)
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(draft,0,-1,false),'Second'))
vim.api.nvim_set_current_win(draft_win)
local lines=vim.api.nvim_buf_get_lines(draft,0,-1,false)
lines[#lines]='Second edited'
vim.api.nvim_buf_set_lines(draft,0,-1,false,lines)
hover(1)
assert(vim.b[draft].canvas_target_id==2 and vim.bo[draft].modified,'hover discarded pending draft')
vim.api.nvim_set_current_win(draft_win)
vim.cmd('write')
assert(s.shapes[2].label=='Second edited' and s.shapes[1].label=='First','write changed wrong target')
hover(1)
assert(vim.b[draft].canvas_target_id==1,'following did not resume after apply')
hover(3)
assert(vim.b[draft].canvas_target_kind=='text' and vim.bo[draft].filetype=='text')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(draft,0,-1,false),{'Note','  detail'}))
vim.api.nvim_set_current_win(draft_win)
vim.api.nvim_buf_set_lines(draft,0,-1,false,{'New note','  detail'})
vim.cmd('write')
assert(s.shapes[3].lines[1]=='New note')
hover(4)
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(draft,0,-1,false),'shape: bx'))
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(draft,0,-1,false),'size: 1'))
local path=s.conns[5].path
local point=path[math.floor(#path/2)+1]
local absolute=s.row_start+point[1]-1
local line=vim.api.nvim_buf_get_lines(source,absolute-1,absolute,false)[1]
vim.api.nvim_win_set_cursor(source_win,{absolute,require('canvas.render').byte_col(line,point[2]-1)})
vim.api.nvim_exec_autocmds('CursorMoved',{buffer=source})
assert(vim.b[draft].canvas_target_kind=='conn' and vim.b[draft].canvas_target_id==5)
vim.api.nvim_set_current_win(draft_win)
local connector_lines=vim.api.nvim_buf_get_lines(draft,0,-1,false)
connector_lines[#connector_lines]='link'
vim.api.nvim_buf_set_lines(draft,0,-1,false,connector_lines)
vim.cmd('write')
assert(s.conns[5].label=='link','following connector wrote to the wrong collection')
hover(4)
local before=vim.api.nvim_buf_get_lines(draft,0,-1,false)
vim.api.nvim_win_set_cursor(source_win,{s.row_end+1,0})
vim.api.nvim_exec_autocmds('CursorMoved',{buffer=source})
assert(vim.deep_equal(before,vim.api.nvim_buf_get_lines(draft,0,-1,false)),'prose cursor changed draft')
vim.api.nvim_set_current_win(draft_win)
vim.cmd('quit')
assert(not vim.api.nvim_buf_is_valid(draft))
hover(1)
