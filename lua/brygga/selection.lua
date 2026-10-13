-- Tracks the editor selection and reports it to Claude as `selection_changed`.
local util = require('brygga.util')

local M = {}

local DEBOUNCE_MS = 100

---@class brygga.Selection
---@field text string
---@field filePath string
---@field fileUrl string
---@field selection {start: {line: integer, character: integer}, ['end']: {line: integer, character: integer}, isEmpty: boolean}

---@type brygga.Selection|nil
local latest
local timer
local group

local function is_visual(mode)
  return mode == 'v' or mode == 'V' or mode == '\22'
end

local function pos(buf, line0, byte)
  local text = vim.api.nvim_buf_get_lines(buf, line0, line0 + 1, false)[1] or ''
  return { line = line0, character = util.utf16_col(text, byte) }
end

---@param buf integer
---@param a integer[] getpos() result
---@param b integer[] getpos() result
---@param mode string 'v', 'V' or CTRL-V
---@return brygga.Selection
local function region(buf, a, b, mode)
  if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then
    a, b = b, a
  end
  local text = table.concat(vim.fn.getregion(a, b, { type = mode }), '\n')
  local start_line, end_line = a[2] - 1, b[2] - 1
  local last = vim.api.nvim_buf_get_lines(buf, end_line, end_line + 1, false)[1] or ''
  local start_byte, end_byte
  if mode == 'V' then
    start_byte, end_byte = 0, #last
  else
    -- getpos() columns are 1-based byte starts; the end is exclusive, so include the whole last character.
    start_byte = a[3] - 1
    end_byte = math.min(b[3], #last)
    if end_byte > 0 then
      end_byte = end_byte + vim.str_utf_end(last, end_byte)
    end
  end
  local path = vim.api.nvim_buf_get_name(buf)
  return {
    text = text,
    filePath = path,
    fileUrl = vim.uri_from_fname(path),
    selection = {
      start = pos(buf, start_line, start_byte),
      ['end'] = pos(buf, end_line, end_byte),
      isEmpty = text == '',
    },
  }
end

--- Selection in the current window: the visual region, or the cursor position when not in visual mode.
---@return brygga.Selection|nil
function M.current()
  local buf = vim.api.nvim_get_current_buf()
  if not util.is_file_buffer(buf) then
    return nil
  end
  local mode = vim.fn.mode()
  if is_visual(mode) then
    return region(buf, vim.fn.getpos('v'), vim.fn.getpos('.'), mode)
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local p = pos(buf, cursor[1] - 1, cursor[2])
  return {
    text = '',
    filePath = path,
    fileUrl = vim.uri_from_fname(path),
    selection = { start = p, ['end'] = p, isEmpty = true },
  }
end

--- The most recent visual selection in the current buffer, from the '< and '> marks.
---@return brygga.Selection|nil
function M.last_visual()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.visualmode()
  if not util.is_file_buffer(buf) or mode == '' then
    return nil
  end
  return region(buf, vim.fn.getpos("'<"), vim.fn.getpos("'>"), mode)
end

--- The last selection seen in a file buffer, which survives moving focus to Claude's terminal.
---@return brygga.Selection|nil
function M.latest()
  return latest
end

---@param notify fun(selection: brygga.Selection)
---@param selection brygga.Selection|nil
local function update(notify, selection)
  if selection and not vim.deep_equal(selection, latest) then
    latest = selection
    notify(selection)
  end
end

--- Starts tracking. `notify` is called with each new selection, debounced.
---@param notify fun(selection: brygga.Selection)
function M.start(notify)
  M.stop()
  local own = assert(vim.uv.new_timer())
  timer = own
  group = vim.api.nvim_create_augroup('brygga.selection', { clear = true })
  local function schedule()
    timer:stop()
    timer:start(
      DEBOUNCE_MS,
      0,
      vim.schedule_wrap(function()
        -- A callback queued before stop() must not revive the old state.
        if timer == own then
          update(notify, M.current())
        end
      end)
    )
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'TextChanged' }, {
    group = group,
    callback = schedule,
  })
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    callback = function()
      -- Send a just-finished visual selection right away and keep it until the cursor
      -- moves, so pressing <Esc> and switching to Claude does not erase it.
      if is_visual(vim.v.event.old_mode) and not is_visual(vim.v.event.new_mode) then
        timer:stop()
        return update(notify, M.last_visual())
      end
      schedule()
    end,
  })
  update(notify, M.current())
end

function M.stop()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  latest = nil
end

return M
