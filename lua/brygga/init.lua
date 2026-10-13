-- brygga: lets Claude Code connect to Neovim as its IDE (the `/ide` command).
-- mcp, tools and diff load on Claude's first message to keep them out of Neovim startup.
local lockfile = require('brygga.lockfile')
local selection = require('brygga.selection')
local websocket = require('brygga.websocket')

local M = {}

---@class brygga.Config
---@field auto_start boolean start the server when setup() runs

---@type brygga.Config
local defaults = { auto_start = true }

---@class brygga.State
---@field server brygga.ws.Server
---@field port integer
---@field token string
---@field clients table<integer, brygga.ws.Client>
---@field group integer
---@field diagnostics_timer uv.uv_timer_t

---@type brygga.State|nil
local state

local function notify(msg, level)
  vim.notify('brygga: ' .. msg, level or vim.log.levels.INFO)
end

--- Encodes a JSON-RPC notification.
---@param method string
---@param params table
---@return string
local function notification(method, params)
  return vim.json.encode({ jsonrpc = '2.0', method = method, params = params })
end

--- Closes open diffs, without loading the diff module when it never ran.
---@param client_id integer|nil
local function close_diffs(client_id)
  local diff = package.loaded['brygga.diff']
  if diff then
    diff.close_all(client_id)
  end
end

--- Sends a notification to every connected Claude Code client.
---@param method string
---@param params table
function M.broadcast(method, params)
  if not state then
    return
  end
  local message = notification(method, params)
  for _, client in pairs(state.clients) do
    client:send(message)
  end
end

local function refresh_lockfile()
  if not state then
    return
  end
  local ok, err = lockfile.write(state.port, state.token)
  if not ok then
    notify('could not update lock file: ' .. tostring(err), vim.log.levels.WARN)
  end
end

---@return boolean
function M.is_running()
  return state ~= nil
end

---@return integer
function M.client_count()
  return state and vim.tbl_count(state.clients) or 0
end

function M.start()
  if state then
    return notify('already running on port ' .. state.port)
  end
  local token = vim.uv.random(16):gsub('.', function(c)
    return string.format('%02x', c:byte())
  end)
  local clients = {}
  local server, listen_err = websocket.listen({
    authorize = function(headers)
      return headers['x-claude-code-ide-authorization'] == token
    end,
    on_open = function(client)
      clients[client.id] = client
      notify('Claude Code connected')
      -- Like VS Code, tell a new client what is selected once it has initialized.
      vim.defer_fn(function()
        local latest = selection.latest()
        if latest and clients[client.id] then
          client:send(notification('selection_changed', latest))
        end
      end, 500)
    end,
    on_message = function(client, text)
      require('brygga.mcp').handle(text, client.id, function(reply)
        client:send(reply)
      end)
    end,
    on_close = function(client)
      clients[client.id] = nil
      close_diffs(client.id)
      notify('Claude Code disconnected')
    end,
  })
  if not server then
    return notify('could not start server: ' .. tostring(listen_err), vim.log.levels.ERROR)
  end
  local port = server.port

  local ok, err = lockfile.write(port, token)
  if not ok then
    server:close()
    return notify('could not write lock file: ' .. tostring(err), vim.log.levels.ERROR)
  end

  local group = vim.api.nvim_create_augroup('brygga', { clear = true })
  local timer = assert(vim.uv.new_timer())
  state = { server = server, port = port, token = token, clients = clients, group = group, diagnostics_timer = timer }
  -- Claude started from a Neovim :terminal connects to this port automatically.
  vim.env.CLAUDE_CODE_SSE_PORT = tostring(port)

  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.stop })
  -- /ide only offers IDEs whose workspace folders contain Claude's cwd, so keep them current.
  vim.api.nvim_create_autocmd({ 'DirChanged', 'LspAttach', 'LspDetach' }, {
    group = group,
    callback = vim.schedule_wrap(refresh_lockfile),
  })
  local changed = {}
  local send_changed = vim.schedule_wrap(function()
    local uris = vim.tbl_keys(changed)
    changed = {}
    if #uris > 0 then
      M.broadcast('diagnostics_changed', { uris = uris })
    end
  end)
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = group,
    callback = function(ev)
      if vim.api.nvim_buf_get_name(ev.buf) ~= '' then
        changed[vim.uri_from_bufnr(ev.buf)] = true
      end
      timer:stop()
      timer:start(300, 0, send_changed)
    end,
  })
  selection.start(function(sel)
    M.broadcast('selection_changed', sel)
  end)
end

function M.stop()
  if not state then
    return
  end
  local current = state
  state = nil
  -- Release the port, lock file and env var first so a failure below cannot leave Claude
  -- pointed at a stopped server.
  lockfile.remove(current.port)
  if vim.env.CLAUDE_CODE_SSE_PORT == tostring(current.port) then
    vim.env.CLAUDE_CODE_SSE_PORT = nil
  end
  for _, client in pairs(current.clients) do
    client:close()
  end
  current.server.close()
  current.diagnostics_timer:close()
  vim.api.nvim_del_augroup_by_id(current.group)
  selection.stop()
  close_diffs()
end

function M.status()
  if not state then
    return notify('not running')
  end
  notify(
    ('listening on 127.0.0.1:%d, %d client(s) connected, lock file %s'):format(
      state.port,
      M.client_count(),
      lockfile.path(state.port)
    )
  )
end

--- Adds a file reference (and optional 1-based line range) to Claude's prompt.
---@param path string
---@param first integer|nil
---@param last integer|nil
function M.send(path, first, last)
  if M.client_count() == 0 then
    return notify('no Claude Code client connected', vim.log.levels.WARN)
  end
  M.broadcast('at_mentioned', {
    filePath = vim.fs.normalize(vim.fn.fnamemodify(path, ':p')),
    lineStart = first and first - 1 or nil,
    lineEnd = last and last - 1 or nil,
  })
end

---@param opts brygga.Config|nil
function M.setup(opts)
  local config = vim.tbl_extend('force', defaults, opts or {})
  if config.auto_start then
    M.start()
  end
end

return M
