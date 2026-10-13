local M = {}

--- True for buffers that hold a real file (not terminals, prompts or plugin UIs).
---@param buf integer
---@return boolean
function M.is_file_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= ''
end

--- Absolute path with symlinks resolved, as Neovim names buffers (/var/x is /private/var/x on macOS).
--- Relative paths are taken from the working directory. For a path that does not exist yet,
--- the nearest existing parent is resolved.
---@param path string
---@return string
function M.canonical(path)
  path = vim.fs.normalize(path)
  if not vim.startswith(path, '/') then
    path = vim.fs.joinpath(vim.fn.getcwd(), path)
  end
  local real = vim.uv.fs_realpath(path)
  if real then
    return real
  end
  local parent = vim.fs.dirname(path)
  if parent == path then
    return path
  end
  return vim.fs.joinpath(M.canonical(parent), vim.fs.basename(path))
end

--- Finds the loaded buffer for an absolute path. `bufnr()` is avoided because it pattern-matches.
---@param path string
---@return integer|nil
function M.find_buffer(path)
  path = M.canonical(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == path then
      return buf
    end
  end
end

--- Converts a 0-based byte column to the UTF-16 offset editors report.
---@param line string
---@param byte integer
---@return integer
function M.utf16_col(line, byte)
  byte = math.min(byte, #line)
  if byte <= 0 then
    return 0
  end
  local ok, col = pcall(vim.str_utfindex, line, 'utf-16', byte, false)
  return ok and col or byte
end

--- Converts a UTF-16 column back to a 0-based byte column.
---@param line string
---@param col integer
---@return integer
function M.byte_col(line, col)
  local ok, byte = pcall(vim.str_byteindex, line, 'utf-16', col, false)
  return ok and byte or math.min(col, #line)
end

--- A window to show files in: the current one unless it is a terminal or other special buffer.
---@return integer
function M.editor_window()
  local current = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(current)].buftype == '' then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative == '' and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then
      return win
    end
  end
  vim.cmd('aboveleft vnew')
  return vim.api.nvim_get_current_win()
end

return M
