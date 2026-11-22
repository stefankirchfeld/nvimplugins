-- Structured CLI requests on stdin; shared Lua scene results on stdout.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.runtimepath:prepend(root)

local function run()
  local request = vim.json.decode(io.read('*a'))
  local scene = require('canvas.scene')
  if request.op == 'create' then return { state=scene.serialize(scene.new()) } end
  local s = scene.deserialize(request.state)
  if request.op == 'render' then return { rendered=scene.render(s) } end
  if request.op == 'validate' then
    local issues = scene.render(s).issues
    return { result={ valid=#issues == 0, issues=issues } }
  end
  if request.op == 'inspect' then
    if not request.id then return { result=scene.serialize(s) } end
    local shape, conn = s.shapes[request.id], s.conns[request.id]
    local object = shape or conn
    if not object then error('element ' .. request.id .. ' not found', 0) end
    local result = object:serialize()
    result.id = request.id
    result.element_type = conn and 'connector' or (shape.variant == 't' and 'text' or 'box')
    if shape then result.capabilities = require('canvas.outlines').definitions[shape.outline or 'rectangle'] end
    if shape and shape.outline == 'diamond' then result.size = scene.diamond_size(shape) end
    return { result=result }
  end
  local result = scene.apply(s, request)
  return { state=scene.serialize(s), result=result }
end

local ok, result = pcall(run)
if ok then io.stdout:write(vim.json.encode(result), string.char(10))
else
  io.stderr:write(vim.json.encode({ error=tostring(result) }), string.char(10))
  vim.cmd('cquit 1')
end
