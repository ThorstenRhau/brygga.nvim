-- :checkhealth brygga
local M = {}

local bit = require('bit')
local health = vim.health

--- True when a proxy is set but `no_proxy` does not cover loopback.
---@return boolean
local function proxy_blocks_loopback()
  local proxied = false
  for _, name in ipairs({ 'http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY' }) do
    if (vim.env[name] or '') ~= '' then
      proxied = true
    end
  end
  if not proxied then
    return false
  end
  local entries = vim.split((vim.env.no_proxy or '') .. ',' .. (vim.env.NO_PROXY or ''), '[,%s]+', { trimempty = true })
  return not vim.iter(entries):any(function(entry)
    return entry == '*' or entry == 'localhost' or entry == '127.0.0.1'
  end)
end

local function check_environment()
  health.start('brygga: environment')
  if vim.fn.has('nvim-0.12') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim 0.12 or newer is required', 'Upgrade Neovim.')
  end

  local claude = vim.fn.exepath('claude')
  if claude ~= '' then
    health.ok('claude command found: ' .. claude)
  else
    health.warn(
      'claude command not found in $PATH',
      'Install Claude Code, or start it from a shell that has it in $PATH.'
    )
  end

  if proxy_blocks_loopback() then
    health.warn(
      'An HTTP proxy variable is set without localhost in no_proxy',
      'Add "localhost,127.0.0.1" to no_proxy so Claude Code can reach brygga.'
    )
  else
    health.ok('Proxy settings do not intercept localhost')
  end
end

local function check_lock_dir()
  health.start('brygga: lock directory')
  local lockfile = require('brygga.lockfile')
  local dir = lockfile.dir()
  local stat = vim.uv.fs_stat(dir)
  if stat and stat.type ~= 'directory' then
    return health.error(dir .. ' is not a directory', 'Remove or rename it so brygga can create the directory.')
  end
  if stat then
    if vim.uv.fs_access(dir, 'W') then
      health.ok('Lock directory is writable: ' .. dir)
    else
      health.error('Lock directory is not writable: ' .. dir, 'Fix its permissions, or set CLAUDE_CONFIG_DIR.')
    end
    return
  end
  -- brygga creates the directory on start, so what matters is a writable parent.
  local parent = dir
  repeat
    parent = vim.fs.dirname(parent)
  until vim.uv.fs_stat(parent) or parent == vim.fs.dirname(parent)
  if vim.uv.fs_access(parent, 'W') then
    health.ok('Lock directory will be created on start: ' .. dir)
  else
    health.error(
      'Cannot create the lock directory ' .. dir,
      'Make ' .. parent .. ' writable, or set CLAUDE_CONFIG_DIR to a directory you own.'
    )
  end
end

local function check_server()
  health.start('brygga: server')
  local brygga = require('brygga')
  local port = brygga.port()
  if not port then
    return health.warn('Server is not running', 'Run :Brygga start, or call require("brygga").setup() at startup.')
  end
  health.ok(('Listening on 127.0.0.1:%d'):format(port))

  local clients = brygga.client_count()
  if clients > 0 then
    health.ok(('%d Claude Code client(s) connected'):format(clients))
  else
    health.info('No Claude Code client connected yet. Run /ide in Claude Code.')
  end

  if vim.env.CLAUDE_CODE_SSE_PORT == tostring(port) then
    health.ok('CLAUDE_CODE_SSE_PORT points at this server')
  else
    health.warn(
      'CLAUDE_CODE_SSE_PORT is ' .. (vim.env.CLAUDE_CODE_SSE_PORT or 'unset'),
      'Claude in a :terminal will not auto-connect. Run :Brygga stop, then :Brygga start.'
    )
  end

  local lockfile = require('brygga.lockfile')
  local path = lockfile.path(port)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return health.error('Lock file is missing: ' .. path, 'Run :Brygga stop, then :Brygga start.')
  end
  local ok, lock = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if not ok or type(lock) ~= 'table' then
    return health.error('Lock file is not valid JSON: ' .. path, 'Run :Brygga stop, then :Brygga start.')
  end
  health.ok('Lock file present: ' .. path)

  if bit.band(stat.mode, tonumber('077', 8)) ~= 0 then
    health.warn('Lock file is readable by other users (it holds the auth token)', 'Run: chmod 600 ' .. path)
  end
  if lock.pid ~= vim.fn.getpid() then
    health.error('Lock file belongs to another process', 'Run :Brygga stop, then :Brygga start.')
  end

  local cwd = vim.fs.normalize(vim.fn.getcwd())
  health.info('Workspace folders: ' .. table.concat(lock.workspaceFolders or {}, ', '))
  if not vim.tbl_contains(lock.workspaceFolders or {}, cwd) then
    health.warn(
      'Neovim working directory is not in the lock file',
      'Run :Brygga stop, then :Brygga start. Start claude from a directory inside a workspace folder.'
    )
  end
end

function M.check()
  check_environment()
  check_lock_dir()
  check_server()
end

return M
