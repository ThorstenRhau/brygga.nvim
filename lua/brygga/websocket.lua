-- Minimal RFC 6455 WebSocket server on top of vim.uv TCP. Text messages only;
-- it handles fragmentation, ping/pong and close, which is all Claude Code uses.
local bit = require('bit')

local M = {}

local GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
local MAX_MESSAGE = 64 * 1024 * 1024
local MAX_HANDSHAKE = 16 * 1024

local OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

--- Encodes one unmasked, final server frame.
---@param opcode integer
---@param payload string
---@return string
function M.frame(opcode, payload)
  local len = #payload
  local header
  if len < 126 then
    header = string.char(0x80 + opcode, len)
  elseif len < 0x10000 then
    header = string.char(0x80 + opcode, 126, math.floor(len / 256), len % 256)
  else
    local bytes = {}
    local n = len
    for i = 8, 1, -1 do
      bytes[i] = n % 256
      n = math.floor(n / 256)
    end
    header = string.char(0x80 + opcode, 127, unpack(bytes))
  end
  return header .. payload
end

local function unmask(payload, key)
  local k = { key:byte(1, 4) }
  local out = {}
  local CHUNK = 4096
  for start = 1, #payload, CHUNK do
    local bytes = { payload:byte(start, math.min(start + CHUNK - 1, #payload)) }
    for i = 1, #bytes do
      bytes[i] = bit.bxor(bytes[i], k[(start + i - 2) % 4 + 1])
    end
    out[#out + 1] = string.char(unpack(bytes))
  end
  return table.concat(out)
end

--- Parses one frame from the start of `buf`.
--- Returns nil when more data is needed, or an error string for a protocol violation.
---@param buf string
---@return {fin: boolean, opcode: integer, payload: string}|nil frame
---@return integer|string|nil consumed_or_err
function M.parse(buf)
  if #buf < 2 then
    return nil
  end
  local b1, b2 = buf:byte(1, 2)
  local fin = bit.band(b1, 0x80) ~= 0
  local opcode = bit.band(b1, 0x0F)
  local masked = bit.band(b2, 0x80) ~= 0
  local len = bit.band(b2, 0x7F)
  local pos = 3
  if len == 126 then
    if #buf < 4 then
      return nil
    end
    local h, l = buf:byte(3, 4)
    len = h * 256 + l
    pos = 5
  elseif len == 127 then
    if #buf < 10 then
      return nil
    end
    len = 0
    for _, byte in ipairs({ buf:byte(3, 10) }) do
      len = len * 256 + byte
    end
    pos = 11
  end
  if not masked then
    return nil, 'client frames must be masked'
  end
  if len > MAX_MESSAGE then
    return nil, 'frame too large'
  end
  if #buf < pos + 3 + len then
    return nil
  end
  local key = buf:sub(pos, pos + 3)
  local payload = unmask(buf:sub(pos + 4, pos + 3 + len), key)
  return { fin = fin, opcode = opcode, payload = payload }, pos + 3 + len
end

local function parse_request(head)
  local lines = vim.split(head, '\r\n', { plain = true })
  local method, path = lines[1]:match('^(%u+) (%S+) HTTP/1%.1$')
  local headers = {}
  for i = 2, #lines do
    local name, value = lines[i]:match('^([^:]+):%s*(.-)%s*$')
    if name then
      headers[name:lower()] = value
    end
  end
  return method, path, headers
end

---@class brygga.ws.Client
---@field id integer
---@field send fun(self: brygga.ws.Client, text: string)
---@field close fun(self: brygga.ws.Client)

---@class brygga.ws.Handlers
---@field authorize fun(headers: table<string, string>): boolean
---@field on_open fun(client: brygga.ws.Client)
---@field on_message fun(client: brygga.ws.Client, text: string)
---@field on_close fun(client: brygga.ws.Client)

---@class brygga.ws.Server
---@field port integer
---@field close fun() stops listening and drops every connection, including unfinished handshakes

--- Starts listening on 127.0.0.1. `on_open`, `on_message` and `on_close` run on the main loop
--- (scheduled). `authorize` runs in the uv read callback, a fast context: it must not call the
--- Neovim API.
---@param handlers brygga.ws.Handlers
---@return brygga.ws.Server|nil server
---@return string|nil err
function M.listen(handlers)
  local server = assert(vim.uv.new_tcp())
  local ok, err = server:bind('127.0.0.1', 0)
  if not ok then
    server:close()
    return nil, err
  end
  local next_id = 0
  ---@type table<uv.uv_tcp_t, true>
  local sockets = {}

  ok, err = server:listen(16, function(listen_err)
    if listen_err then
      return
    end
    local sock = assert(vim.uv.new_tcp())
    if not server:accept(sock) then
      sock:close()
      return
    end
    next_id = next_id + 1
    sockets[sock] = true
    local buf, open, closed = '', false, false
    local fragments, frag_op, frag_size = nil, nil, 0

    local client = { id = next_id }
    local function write(data)
      if not closed and not sock:is_closing() then
        sock:write(data)
      end
    end
    function client.send(_, text)
      write(M.frame(OP_TEXT, text))
    end
    --- Stops reading and closes the socket, after sending `final` if given.
    ---@param final string|nil
    local function shutdown(final)
      if closed then
        return
      end
      if final then
        write(final)
      end
      closed = true
      sockets[sock] = nil
      if not sock:is_closing() then
        -- Without this, data arriving before the close could re-run the handshake.
        sock:read_stop()
        -- uv shutdown waits for pending writes; closing right away would cancel `final`.
        local function close_sock()
          if not sock:is_closing() then
            sock:close()
          end
        end
        if not sock:shutdown(close_sock) then
          close_sock()
        end
      end
      if open then
        vim.schedule(function()
          handlers.on_close(client)
        end)
      end
    end
    local function fail(code)
      shutdown(M.frame(OP_CLOSE, string.char(math.floor(code / 256), code % 256)))
    end
    function client.close()
      fail(1000)
    end

    local function handshake()
      local head_end = buf:find('\r\n\r\n', 1, true)
      if not head_end then
        if #buf > MAX_HANDSHAKE then
          shutdown()
        end
        return false
      end
      local method, _, headers = parse_request(buf:sub(1, head_end - 1))
      buf = buf:sub(head_end + 4)
      local key = headers['sec-websocket-key']
      if method ~= 'GET' or not key or (headers['upgrade'] or ''):lower() ~= 'websocket' then
        shutdown('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
        return false
      end
      if not handlers.authorize(headers) then
        shutdown('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
        return false
      end
      -- Loaded on the first handshake to keep it out of Neovim startup.
      local accept = vim.base64.encode(require('brygga.sha1').binary(key .. GUID))
      local response = {
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Accept: ' .. accept,
      }
      -- Echo the first offered subprotocol (Claude Code offers "mcp"); clients reject unexpected ones.
      local protocol = headers['sec-websocket-protocol']
      if protocol then
        response[#response + 1] = 'Sec-WebSocket-Protocol: ' .. vim.trim(vim.split(protocol, ',', { plain = true })[1])
      end
      write(table.concat(response, '\r\n') .. '\r\n\r\n')
      open = true
      vim.schedule(function()
        handlers.on_open(client)
      end)
      return true
    end

    local function frames()
      while not closed do
        local frame, consumed = M.parse(buf)
        if not frame then
          if consumed then
            fail(1002)
          end
          return
        end
        buf = buf:sub(consumed + 1)
        local op = frame.opcode
        if op >= OP_CLOSE and (not frame.fin or #frame.payload > 125) then
          return fail(1002)
        end
        if op == OP_PING then
          write(M.frame(OP_PONG, frame.payload))
        elseif op == OP_CLOSE then
          shutdown(M.frame(OP_CLOSE, frame.payload:sub(1, 2)))
        elseif op == OP_TEXT or op == OP_BINARY or op == OP_CONT then
          -- A new message may only start once the previous fragmented one is finished.
          if (op == OP_CONT) ~= (fragments ~= nil) then
            return fail(1002)
          end
          if op ~= OP_CONT then
            fragments, frag_op, frag_size = {}, op, 0
          end
          frag_size = frag_size + #frame.payload
          if frag_size > MAX_MESSAGE then
            return fail(1009)
          end
          fragments[#fragments + 1] = frame.payload
          if frame.fin then
            local text = table.concat(fragments)
            local was_text = frag_op == OP_TEXT
            fragments, frag_op = nil, nil
            if was_text then
              vim.schedule(function()
                if not closed then
                  handlers.on_message(client, text)
                end
              end)
            end
          end
        elseif op ~= OP_PONG then
          return fail(1002)
        end
      end
    end

    sock:read_start(function(read_err, data)
      if read_err or not data then
        return shutdown()
      end
      buf = buf .. data
      if not open and not handshake() then
        return
      end
      frames()
    end)
  end)
  if not ok then
    server:close()
    return nil, err
  end
  return {
    port = server:getsockname().port,
    close = function()
      server:close()
      for sock in pairs(sockets) do
        if not sock:is_closing() then
          sock:close()
        end
      end
      sockets = {}
    end,
  }
end

return M
