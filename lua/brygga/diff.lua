-- openDiff: shows Claude's proposed change in a new tab and blocks until the user
-- accepts (:w in the proposed buffer) or rejects (closes it). Claude writes the file itself.
local util = require('brygga.util')

local M = {}

---@class brygga.Diff
---@field tab_name string
---@field client_id integer
---@field tab integer tabpage handle
---@field proposed integer|nil buffer with Claude's version
---@field original integer|nil scratch buffer used when the file does not exist yet
---@field file string
---@field filetype string
---@field had_buffer boolean whether the user had the file loaded before the diff
---@field reply fun(content: table[])|nil set while waiting for the user

---@type table<string, brygga.Diff>
local diffs = {}

local function text(value)
  return { type = 'text', text = value }
end

local function contents(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, '\n') .. (vim.bo[buf].eol and '\n' or '')
end

local function resolve(diff, content)
  local reply = diff.reply
  diff.reply = nil
  if reply then
    reply(content)
  end
end

local function reject(diff)
  resolve(diff, { text('DIFF_REJECTED'), text(diff.tab_name) })
end

--- Removes a diff's windows and scratch buffers, discarding unsaved edits to the proposal.
---@param diff brygga.Diff
local function teardown(diff)
  if diff.proposed and vim.api.nvim_buf_is_valid(diff.proposed) then
    vim.bo[diff.proposed].modified = false
  end
  if vim.api.nvim_tabpage_is_valid(diff.tab) and #vim.api.nvim_list_tabpages() > 1 then
    -- `!` hides rather than refuses a modified original file buffer; its changes are kept.
    vim.cmd('tabclose! ' .. vim.api.nvim_tabpage_get_number(diff.tab))
  end
  for _, buf in ipairs({ diff.proposed, diff.original }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

--- Closes a diff. Pending diffs count as rejected.
---@param diff brygga.Diff
local function close(diff)
  reject(diff)
  diffs[diff.tab_name] = nil
  teardown(diff)
  -- Claude writes the accepted file to disk: reload the buffer if the user had it open,
  -- otherwise drop the buffer the diff loaded so buffers do not pile up.
  vim.defer_fn(function()
    local buf = util.find_buffer(diff.file)
    if not buf or vim.bo[buf].modified then
      return
    end
    if diff.had_buffer or #vim.fn.win_findbuf(buf) > 0 then
      vim.cmd.checktime(buf)
    else
      vim.api.nvim_buf_delete(buf, {})
    end
  end, 100)
end

---@param diff brygga.Diff
---@param new_text string
local function build(diff, new_text)
  if vim.uv.fs_stat(diff.file) then
    vim.cmd.edit(vim.fn.fnameescape(diff.file))
  else
    diff.original = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(diff.original, 'brygga://new/' .. diff.file)
    vim.bo[diff.original].filetype = diff.filetype
    vim.api.nvim_win_set_buf(0, diff.original)
  end
  vim.cmd.diffthis()

  vim.cmd('rightbelow vnew')
  local proposed = vim.api.nvim_get_current_buf()
  diff.proposed = proposed
  local eol = new_text:sub(-1) == '\n'
  local lines = vim.split(eol and new_text:sub(1, -2) or new_text, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(proposed, 0, -1, false, lines)
  vim.bo[proposed].buftype = 'acwrite'
  vim.bo[proposed].bufhidden = 'wipe'
  vim.bo[proposed].swapfile = false
  vim.bo[proposed].eol = eol
  vim.bo[proposed].fixeol = false
  vim.bo[proposed].filetype = diff.filetype
  vim.bo[proposed].modified = false
  vim.api.nvim_buf_set_name(proposed, 'brygga://proposed/' .. diff.file)
  vim.cmd.diffthis()

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = proposed,
    callback = function()
      vim.bo[proposed].modified = false
      resolve(diff, { text('FILE_SAVED'), text(contents(proposed)) })
      vim.notify('brygga: change accepted', vim.log.levels.INFO)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = proposed,
    callback = function()
      reject(diff)
      -- Closing the proposal closes the whole diff, accepted or not. Windows cannot change
      -- inside BufWipeout, and a diff already closed or replaced is left alone.
      vim.schedule(function()
        if diffs[diff.tab_name] == diff then
          close(diff)
        end
      end)
    end,
  })
end

--- Opens a diff and calls `reply` once the user decides. Errors if the file has unsaved changes.
---@param args {old_file_path: string, new_file_path: string, new_file_contents: string, tab_name: string}
---@param client_id integer
---@param reply fun(content: table[])
function M.open(args, client_id, reply)
  local file = util.canonical(args.old_file_path)
  local existing = util.find_buffer(file)
  if existing and vim.bo[existing].modified then
    error('Cannot create diff: ' .. file .. ' has unsaved changes', 0)
  end
  local had_buffer = existing ~= nil
  -- A new proposal replaces any earlier one for the same tab or file.
  for name, diff in pairs(diffs) do
    if diff.file == file then
      -- `existing` may be the buffer that diff loaded, not one the user opened.
      had_buffer = diff.had_buffer
    end
    if name == args.tab_name or diff.file == file then
      close(diff)
    end
  end

  vim.cmd.tabnew()
  ---@type brygga.Diff
  local diff = {
    tab_name = args.tab_name,
    client_id = client_id,
    tab = vim.api.nvim_get_current_tabpage(),
    file = file,
    filetype = vim.filetype.match({ filename = file }) or '',
    had_buffer = had_buffer,
  }
  local placeholder = vim.api.nvim_get_current_buf()
  local ok, err = pcall(build, diff, args.new_file_contents)
  if vim.api.nvim_buf_is_valid(placeholder) and #vim.fn.win_findbuf(placeholder) == 0 then
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end
  if not ok then
    teardown(diff)
    error(err, 0)
  end
  diff.reply = reply
  diffs[args.tab_name] = diff
  vim.notify('brygga: :w to accept the change, :q to reject it', vim.log.levels.INFO)
end

--- Closes the diff called `tab_name`, if it is ours.
---@param tab_name string
---@return boolean closed
function M.close(tab_name)
  local diff = diffs[tab_name]
  if diff then
    close(diff)
  end
  return diff ~= nil
end

--- Closes every diff, or only those opened by one client. Returns how many were closed.
---@param client_id integer|nil
---@return integer
function M.close_all(client_id)
  local count = 0
  for _, diff in pairs(diffs) do
    if not client_id or diff.client_id == client_id then
      close(diff)
      count = count + 1
    end
  end
  return count
end

return M
