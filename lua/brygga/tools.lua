-- The MCP tools Claude Code calls on the IDE. Names, inputs and outputs follow the
-- VS Code extension, which is the reference implementation of this protocol.
local diff = require('brygga.diff')
local lockfile = require('brygga.lockfile')
local selection = require('brygga.selection')
local util = require('brygga.util')

local M = {}

---@class brygga.ToolContext
---@field client_id integer
---@field reply fun(content: table[]) for tools that answer later

---@class brygga.Tool
---@field name string
---@field description string
---@field inputSchema table
---@field handler fun(args: table, ctx: brygga.ToolContext): table[]|nil nil means the tool replies later through ctx.reply

local function text(value)
  return { { type = 'text', text = value } }
end

local function json(value)
  return text(vim.json.encode(value))
end

local function schema(properties, required)
  return {
    type = 'object',
    properties = next(properties) and properties or vim.empty_dict(),
    required = required,
    additionalProperties = false,
  }
end

local STRING = { type = 'string' }
local BOOLEAN = { type = 'boolean' }

--- Resolves a path from Claude: absolute, or relative to the working directory.
local function resolve(path)
  if not vim.startswith(path, '/') and not path:match('^~') then
    path = vim.fs.joinpath(vim.fn.getcwd(), path)
  end
  return vim.fs.normalize(path)
end

local SEVERITY = { 'Error', 'Warning', 'Information', 'Hint' }

local function diagnostics_for(buf)
  local items = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local function position(line, col)
      local content = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ''
      return { line = line, character = util.utf16_col(content, col) }
    end
    items[#items + 1] = {
      message = d.message,
      severity = SEVERITY[d.severity] or 'Error',
      range = { start = position(d.lnum, d.col), ['end'] = position(d.end_lnum or d.lnum, d.end_col or d.col) },
      source = d.source,
      code = d.code,
    }
  end
  return {
    uri = vim.uri_from_bufnr(buf),
    linesInFile = vim.api.nvim_buf_line_count(buf),
    diagnostics = items,
  }
end

--- Finds `needle` from 0-based `from_line` and byte column `from_col` onward.
--- Returns 0-based line and byte column.
local function find_text(buf, needle, from_line, from_col)
  local lines = vim.api.nvim_buf_get_lines(buf, from_line, -1, false)
  for i, line in ipairs(lines) do
    local col = line:find(needle, i == 1 and (from_col or 0) + 1 or 1, true)
    if col then
      return from_line + i - 1, col - 1
    end
  end
end

local function open_file(args)
  local path = resolve(args.filePath)
  if not vim.uv.fs_stat(path) then
    error('File not found: ' .. path, 0)
  end

  if args.makeFrontmost == false then
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    return json({
      success = true,
      filePath = path,
      fileUrl = vim.uri_from_fname(path),
      message = 'Opened file: ' .. path,
      languageId = vim.bo[buf].filetype ~= '' and vim.bo[buf].filetype or 'plaintext',
      lineCount = vim.api.nvim_buf_line_count(buf),
      isDirty = vim.bo[buf].modified,
      isUntitled = false,
      isClosed = false,
    })
  end

  local win = util.editor_window()
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  if not args.startText or args.startText == '' then
    return text('Opened file: ' .. path)
  end

  local start_line, start_col = find_text(buf, args.startText, 0)
  if not start_line then
    return text('Opened file, but text "' .. args.startText .. '" not found')
  end
  local end_line, end_col = start_line, start_col + #args.startText - 1
  if args.endText and args.endText ~= '' then
    local line, col = find_text(buf, args.endText, start_line, start_col + #args.startText)
    if line then
      end_line, end_col = line, col + #args.endText - 1
    end
  end
  if args.selectToEndOfLine then
    local last = vim.api.nvim_buf_get_lines(buf, end_line, end_line + 1, false)[1] or ''
    end_col = math.max(#last - 1, 0)
  end
  vim.cmd('normal! \27')
  vim.api.nvim_win_set_cursor(win, { start_line + 1, start_col })
  vim.cmd('normal! v')
  vim.api.nvim_win_set_cursor(win, { end_line + 1, end_col })
  return text('Opened file and selected text "' .. args.startText .. '"')
end

local function document_not_open(path)
  return json({ success = false, message = 'Document not open: ' .. path })
end

---@type brygga.Tool[]
M.list = {
  {
    name = 'openFile',
    description = 'Open a file in the editor and optionally select a range of text',
    inputSchema = schema({
      filePath = vim.tbl_extend('force', STRING, { description = 'Path to the file to open' }),
      preview = vim.tbl_extend('force', BOOLEAN, { default = false }),
      startText = vim.tbl_extend('force', STRING, { description = 'Text pattern to find the start of the selection' }),
      endText = vim.tbl_extend('force', STRING, { description = 'Text pattern to find the end of the selection' }),
      selectToEndOfLine = vim.tbl_extend('force', BOOLEAN, { default = false }),
      makeFrontmost = vim.tbl_extend('force', BOOLEAN, { default = true }),
    }, { 'filePath' }),
    handler = open_file,
  },
  {
    name = 'openDiff',
    description = 'Open a diff view comparing a file with proposed contents and wait for the user to accept or reject it',
    inputSchema = schema({
      old_file_path = STRING,
      new_file_path = STRING,
      new_file_contents = STRING,
      tab_name = STRING,
    }, { 'old_file_path', 'new_file_path', 'new_file_contents', 'tab_name' }),
    handler = function(args, ctx)
      diff.open(args, ctx.client_id, ctx.reply)
    end,
  },
  {
    name = 'getCurrentSelection',
    description = 'Get the current text selection in the editor',
    inputSchema = schema({}),
    handler = function()
      local current = selection.current() or selection.latest()
      if not current then
        return json({ success = false, message = 'No active editor found' })
      end
      return json(vim.tbl_extend('force', { success = true }, current))
    end,
  },
  {
    name = 'getLatestSelection',
    description = 'Get the most recent text selection, even if the editor is no longer focused',
    inputSchema = schema({}),
    handler = function()
      local latest = selection.latest()
      if not latest then
        return json({ success = false, message = 'No selection available' })
      end
      return json(vim.tbl_extend('force', { success = true }, latest))
    end,
  },
  {
    name = 'getOpenEditors',
    description = 'Get the files currently open in the editor',
    inputSchema = schema({}),
    handler = function()
      local current = vim.api.nvim_get_current_buf()
      local tabs = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buflisted and vim.api.nvim_buf_is_loaded(buf) and util.is_file_buffer(buf) then
          local path = vim.api.nvim_buf_get_name(buf)
          tabs[#tabs + 1] = {
            uri = vim.uri_from_fname(path),
            isActive = buf == current,
            isPinned = false,
            isPreview = false,
            isDirty = vim.bo[buf].modified,
            label = vim.fs.basename(path),
            groupIndex = 0,
            viewColumn = 1,
            isGroupActive = true,
            fileName = path,
            languageId = vim.bo[buf].filetype ~= '' and vim.bo[buf].filetype or 'plaintext',
            lineCount = vim.api.nvim_buf_line_count(buf),
            isUntitled = false,
          }
        end
      end
      return json({ tabs = tabs })
    end,
  },
  {
    name = 'getWorkspaceFolders',
    description = 'Get the workspace folders open in the editor',
    inputSchema = schema({}),
    handler = function()
      local folders = {}
      for i, path in ipairs(lockfile.workspace_folders()) do
        folders[i] = { name = vim.fs.basename(path), uri = vim.uri_from_fname(path), path = path, index = i - 1 }
      end
      return json({
        success = true,
        folders = folders,
        rootPath = folders[1] and folders[1].path,
        workspaceFile = vim.NIL,
      })
    end,
  },
  {
    name = 'getDiagnostics',
    description = 'Get language diagnostics (errors, warnings) from the editor. Pass a file URI for one file, or omit it for all open files.',
    inputSchema = schema({
      uri = vim.tbl_extend('force', STRING, { description = 'Optional file URI to get diagnostics for' }),
    }),
    handler = function(args)
      local result = {}
      if args.uri and args.uri ~= '' then
        local path = args.uri:match('^file://') and vim.uri_to_fname(args.uri) or resolve(args.uri)
        local buf = util.find_buffer(path)
        result[1] = buf and diagnostics_for(buf) or { uri = vim.uri_from_fname(path), diagnostics = {} }
      else
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and util.is_file_buffer(buf) and #vim.diagnostic.get(buf) > 0 then
            result[#result + 1] = diagnostics_for(buf)
          end
        end
      end
      return json(result)
    end,
  },
  {
    name = 'checkDocumentDirty',
    description = 'Check whether a document has unsaved changes',
    inputSchema = schema({ filePath = STRING }, { 'filePath' }),
    handler = function(args)
      local path = resolve(args.filePath)
      local buf = util.find_buffer(path)
      if not buf then
        return document_not_open(path)
      end
      return json({ success = true, filePath = path, isDirty = vim.bo[buf].modified, isUntitled = false })
    end,
  },
  {
    name = 'saveDocument',
    description = 'Save a document with unsaved changes',
    inputSchema = schema({ filePath = STRING }, { 'filePath' }),
    handler = function(args)
      local path = resolve(args.filePath)
      local buf = util.find_buffer(path)
      if not buf then
        return document_not_open(path)
      end
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd.write()
      end)
      if not ok then
        return json({ success = false, filePath = path, saved = false, message = 'Failed to save file: ' .. err })
      end
      return json({ success = true, filePath = path, saved = true, message = 'Document saved successfully' })
    end,
  },
  {
    name = 'close_tab',
    description = 'Close a diff tab by name',
    inputSchema = schema({ tab_name = STRING }, { 'tab_name' }),
    handler = function(args)
      diff.close(args.tab_name)
      return text('TAB_CLOSED')
    end,
  },
  {
    name = 'closeAllDiffTabs',
    description = 'Close all diff tabs opened by Claude',
    inputSchema = schema({}),
    handler = function(_, ctx)
      return text('CLOSED_' .. diff.close_all(ctx.client_id) .. '_DIFF_TABS')
    end,
  },
}

---@type table<string, brygga.Tool>
M.by_name = {}
for _, tool in ipairs(M.list) do
  M.by_name[tool.name] = tool
end

return M
