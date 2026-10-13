-- JSON-RPC 2.0 / MCP request handling for one WebSocket message.
local tools = require('brygga.tools')

local M = {}

M.VERSION = '0.1.0'
-- Used only when the client does not say which version it speaks; otherwise we echo its version.
local DEFAULT_PROTOCOL = '2025-11-25'

local function encode(id, key, value)
  return vim.json.encode({ jsonrpc = '2.0', id = id == nil and vim.NIL or id, [key] = value })
end

local function err(id, code, message)
  return encode(id, 'error', { code = code, message = message })
end

local function tool_list()
  local list = {}
  for i, tool in ipairs(tools.list) do
    list[i] = { name = tool.name, description = tool.description, inputSchema = tool.inputSchema }
  end
  return { tools = list }
end

--- Checks required arguments and the types of known ones against the tool's input schema.
---@return string|nil err
local function check_args(schema, args)
  for _, name in ipairs(schema.required or {}) do
    if args[name] == nil then
      return 'Missing argument: ' .. name
    end
  end
  for name, value in pairs(args) do
    local property = schema.properties[name]
    -- The schemas only use JSON types whose names match Lua's (string, boolean).
    if property and type(value) ~= property.type then
      return ('Argument %s must be a %s'):format(name, property.type)
    end
  end
end

--- Handles one incoming message. `send` may be called later for tools that wait on the user.
---@param text string
---@param client_id integer
---@param send fun(text: string)
function M.handle(text, client_id, send)
  local ok, msg = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    return send(err(nil, -32700, 'Parse error'))
  end
  if type(msg) ~= 'table' or msg.jsonrpc ~= '2.0' then
    return send(err(type(msg) == 'table' and msg.id or nil, -32600, 'Invalid Request'))
  end
  -- Notifications (ide_connected, notifications/initialized) and responses need no reply.
  if msg.id == nil or msg.method == nil then
    return
  end
  local id, params = msg.id, msg.params or {}
  if type(params) ~= 'table' then
    return send(err(id, -32602, 'Invalid params'))
  end

  if msg.method == 'initialize' then
    return send(encode(id, 'result', {
      protocolVersion = params.protocolVersion or DEFAULT_PROTOCOL,
      capabilities = { tools = { listChanged = false } },
      serverInfo = { name = 'brygga', version = M.VERSION },
    }))
  elseif msg.method == 'ping' then
    return send(encode(id, 'result', vim.empty_dict()))
  elseif msg.method == 'tools/list' then
    return send(encode(id, 'result', tool_list()))
  elseif msg.method ~= 'tools/call' then
    return send(err(id, -32601, 'Method not found: ' .. tostring(msg.method)))
  end

  local tool = tools.by_name[params.name]
  if not tool then
    return send(err(id, -32602, 'Unknown tool: ' .. tostring(params.name)))
  end
  local replied = false
  local function reply(content, is_error)
    if not replied then
      replied = true
      send(encode(id, 'result', { content = content, isError = is_error or nil }))
    end
  end
  local args = params.arguments or {}
  if type(args) ~= 'table' then
    return send(err(id, -32602, 'Invalid arguments'))
  end
  local invalid = check_args(tool.inputSchema, args)
  if invalid then
    return reply({ { type = 'text', text = invalid } }, true)
  end
  local call_ok, content = pcall(tool.handler, args, { client_id = client_id, reply = reply })
  if not call_ok then
    reply({ { type = 'text', text = tostring(content) } }, true)
  elseif content then
    reply(content)
  end
end

return M
