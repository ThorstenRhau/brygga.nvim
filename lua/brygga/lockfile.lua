-- Discovery file Claude Code reads from ~/.claude/ide/<port>.lock to find this server.
local M = {}

--- Returns the lock directory, honoring CLAUDE_CONFIG_DIR like Claude Code does.
---@return string
function M.dir()
  local config = vim.env.CLAUDE_CONFIG_DIR
  if config and config ~= '' then
    return vim.fs.joinpath(vim.fs.normalize(config), 'ide')
  end
  return vim.fs.joinpath(vim.fs.normalize('~/.claude'), 'ide')
end

---@param port integer
---@return string
function M.path(port)
  return vim.fs.joinpath(M.dir(), port .. '.lock')
end

--- Current working directory plus LSP workspace roots, without duplicates.
--- `/ide` only offers this server when Claude's cwd is inside one of these.
---@return string[]
function M.workspace_folders()
  local folders, seen = {}, {}
  local function add(path)
    path = vim.fs.normalize(path)
    if path ~= '' and not seen[path] then
      seen[path] = true
      folders[#folders + 1] = path
    end
  end
  add(vim.fn.getcwd())
  for _, client in ipairs(vim.lsp.get_clients()) do
    for _, folder in ipairs(client.workspace_folders or {}) do
      add(vim.uri_to_fname(folder.uri))
    end
  end
  return folders
end

--- Writes the lock file atomically with owner-only permissions.
---@param port integer
---@param token string
---@return boolean ok
---@return string|nil err
function M.write(port, token)
  local dir = M.dir()
  local made, mkdir_err = pcall(vim.fn.mkdir, dir, 'p', tonumber('700', 8))
  if not made then
    return false, mkdir_err
  end
  local content = vim.json.encode({
    pid = vim.fn.getpid(),
    workspaceFolders = M.workspace_folders(),
    ideName = 'Neovim',
    transport = 'ws',
    authToken = token,
  })
  local final = M.path(port)
  local tmp = final .. '.tmp'
  local fd, err = vim.uv.fs_open(tmp, 'w', tonumber('600', 8))
  if not fd then
    return false, err
  end
  local _, write_err = vim.uv.fs_write(fd, content)
  vim.uv.fs_close(fd)
  if write_err then
    vim.uv.fs_unlink(tmp)
    return false, write_err
  end
  local ok, rename_err = vim.uv.fs_rename(tmp, final)
  if not ok then
    vim.uv.fs_unlink(tmp)
    return false, rename_err
  end
  return true
end

---@param port integer
function M.remove(port)
  vim.uv.fs_unlink(M.path(port))
end

return M
