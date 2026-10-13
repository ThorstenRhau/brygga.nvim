-- Dependency-free tests: nvim --headless -u NONE -l tests/headless.lua (see `make test`).
local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)
vim.cmd.runtime('plugin/brygga.lua')
assert(vim.env.CLAUDE_CONFIG_DIR, 'run through `make test` so lock files stay out of ~/.claude')

local bit = require('bit')
local brygga = require('brygga')
local lockfile = require('brygga.lockfile')
local mcp = require('brygga.mcp')
local selection = require('brygga.selection')
local sha1 = require('brygga.sha1')
local websocket = require('brygga.websocket')

-- The handshake nonce from the RFC 6455 section 1.3 example.
local RFC_NONCE = 'dGhlIHNhbXBsZSBub25jZQ=='

local failures, passed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failures = failures + 1
    print('FAIL ' .. name .. ': ' .. tostring(err))
  end
  -- Reset editor state between tests.
  pcall(vim.cmd, 'silent! tabonly! | silent! only! | enew!')
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or 'values differ') .. ': expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual), 2)
  end
end

local function hex(s)
  return (s:gsub('.', function(c)
    return string.format('%02x', c:byte())
  end))
end

local function tmpfile(content)
  local path = vim.fs.normalize(vim.fn.tempname() .. '.txt')
  vim.fn.writefile(vim.split(content, '\n', { plain = true }), path, 'b')
  return path
end

-- A masked client frame, as browsers and Claude Code send them.
local function client_frame(opcode, payload, fin)
  local key = { 0x12, 0x34, 0x56, 0x78 }
  local masked = payload:gsub('()(.)', function(i, c)
    return string.char(bit.bxor(c:byte(), key[(i - 1) % 4 + 1]))
  end)
  local len = #payload
  local first = string.char((fin == false and 0 or 0x80) + opcode)
  local header
  if len < 126 then
    header = first .. string.char(0x80 + len)
  elseif len < 0x10000 then
    header = first .. string.char(0x80 + 126, math.floor(len / 256), len % 256)
  else
    local bytes, n = {}, len
    for i = 8, 1, -1 do
      bytes[i] = n % 256
      n = math.floor(n / 256)
    end
    header = first .. string.char(0x80 + 127, unpack(bytes))
  end
  return header .. string.char(unpack(key)) .. masked
end

--- Calls mcp.handle and returns decoded replies sent so far (a function returns later ones).
local function rpc(method, params, id)
  local replies = {}
  mcp.handle(vim.json.encode({ jsonrpc = '2.0', id = id or 1, method = method, params = params }), 1, function(text)
    replies[#replies + 1] = vim.json.decode(text)
  end)
  return replies
end

local function call(name, args)
  return rpc('tools/call', { name = name, arguments = args or {} })
end

local function result_text(reply, index)
  return reply.result.content[index or 1].text
end

test('sha1 matches known digests', function()
  equal(hex(sha1.binary('')), 'da39a3ee5e6b4b0d3255bfef95601890afd80709')
  equal(hex(sha1.binary('abc')), 'a9993e364706816aba3e25717850c26c9cd0d89d')
  equal(hex(sha1.binary(string.rep('a', 1000))), '291e9a6c66994949b57ba5e650361e98fc36b1ba')
  -- RFC 6455 section 1.3 handshake example
  equal(
    vim.base64.encode(sha1.binary(RFC_NONCE .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')),
    's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
  )
end)

test('websocket parses masked frames of every length encoding', function()
  for _, size in ipairs({ 0, 5, 125, 126, 300, 70000 }) do
    local payload = string.rep('x', size)
    local raw = client_frame(0x1, payload)
    local frame, consumed = websocket.parse(raw .. 'next')
    equal(frame and frame.payload, payload, 'payload of size ' .. size)
    equal(consumed, #raw)
    equal(websocket.parse(raw:sub(1, -2)), nil, 'incomplete frame of size ' .. size)
  end
  local _, err = websocket.parse(websocket.frame(0x1, 'unmasked'))
  equal(err, 'client frames must be masked')
end)

test('mcp initialize echoes the client protocol version', function()
  local reply = rpc('initialize', { protocolVersion = '2025-06-18' })[1]
  equal(reply.result.protocolVersion, '2025-06-18')
  equal(reply.result.serverInfo.name, 'brygga')
  equal(rpc('initialize', {})[1].result.protocolVersion, '2025-11-25')
end)

test('mcp reports errors and ignores notifications', function()
  equal(rpc('resources/list', {})[1].error.code, -32601)
  equal(call('nope')[1].error.code, -32602)
  local replies = {}
  mcp.handle('{not json', 1, function(text)
    replies[#replies + 1] = vim.json.decode(text)
  end)
  mcp.handle(vim.json.encode({ jsonrpc = '2.0', method = 'notifications/initialized' }), 1, function(text)
    replies[#replies + 1] = vim.json.decode(text)
  end)
  equal(#replies, 1)
  equal(replies[1].error.code, -32700)
  equal(replies[1].id, vim.NIL)
end)

test('tools/list has the VS Code tool set', function()
  local names = vim.tbl_map(function(tool)
    return tool.name
  end, rpc('tools/list', {})[1].result.tools)
  table.sort(names)
  equal(names, {
    'checkDocumentDirty',
    'closeAllDiffTabs',
    'close_tab',
    'getCurrentSelection',
    'getDiagnostics',
    'getLatestSelection',
    'getOpenEditors',
    'getWorkspaceFolders',
    'openDiff',
    'openFile',
    'saveDocument',
  })
end)

test('openDiff waits for :w and returns the edited proposal', function()
  local path = tmpfile('one\ntwo\n')
  local replies = call('openDiff', {
    old_file_path = path,
    new_file_path = path,
    new_file_contents = 'one\nTWO\n',
    tab_name = 'diff-a',
  })
  equal(#replies, 0, 'no reply before the user decides')
  equal(#vim.api.nvim_list_tabpages(), 2)
  local proposed = vim.api.nvim_get_current_buf()
  equal(vim.api.nvim_buf_get_lines(proposed, 0, -1, false), { 'one', 'TWO' })
  vim.api.nvim_buf_set_lines(proposed, 2, 2, false, { 'three' })
  vim.cmd.write()
  equal(result_text(replies[1]), 'FILE_SAVED')
  equal(result_text(replies[1], 2), 'one\nTWO\nthree\n')
  equal(vim.fn.readfile(path), { 'one', 'two' }, 'the plugin itself does not write the file')

  equal(result_text(call('close_tab', { tab_name = 'diff-a' })[1]), 'TAB_CLOSED')
  equal(#vim.api.nvim_list_tabpages(), 1)
  equal(vim.api.nvim_buf_is_valid(proposed), false)
end)

test('openDiff rejects when the proposal is closed', function()
  local path = tmpfile('a')
  local replies = call('openDiff', {
    old_file_path = path,
    new_file_path = path,
    new_file_contents = 'b',
    tab_name = 'diff-b',
  })
  vim.cmd.quit()
  equal(result_text(replies[1]), 'DIFF_REJECTED')
  equal(result_text(replies[1], 2), 'diff-b')
  vim.wait(500, function()
    return #vim.api.nvim_list_tabpages() == 1
  end)
  equal(#vim.api.nvim_list_tabpages(), 1, 'closing the proposal closes the diff tab')
  equal(result_text(call('closeAllDiffTabs')[1]), 'CLOSED_0_DIFF_TABS')
end)

test('closing an accepted diff forgets it', function()
  local path = tmpfile('a')
  call('openDiff', { old_file_path = path, new_file_path = path, new_file_contents = 'b', tab_name = 'f' })
  vim.cmd.write()
  vim.cmd.quit()
  vim.wait(500, function()
    return #vim.api.nvim_list_tabpages() == 1
  end)
  equal(result_text(call('closeAllDiffTabs')[1]), 'CLOSED_0_DIFF_TABS')
end)

test('a second diff for the same file does not keep the buffer the first one loaded', function()
  local path = tmpfile('a')
  local util = require('brygga.util')
  call('openDiff', { old_file_path = path, new_file_path = path, new_file_contents = 'b', tab_name = 'g1' })
  call('openDiff', { old_file_path = path, new_file_path = path, new_file_contents = 'c', tab_name = 'g2' })
  equal(result_text(call('closeAllDiffTabs')[1]), 'CLOSED_1_DIFF_TABS')
  vim.wait(500, function()
    return util.find_buffer(path) == nil
  end)
  equal(util.find_buffer(path), nil)
end)

test('canonical resolves relative paths and symlinked parents of new files', function()
  local util = require('brygga.util')
  local dir = vim.fs.dirname(vim.fn.tempname())
  local real = assert(vim.uv.fs_realpath(dir))
  equal(util.canonical(dir .. '/missing/new.lua'), real .. '/missing/new.lua')
  equal(util.canonical('lua/brygga'), assert(vim.uv.fs_realpath(root .. '/lua/brygga')))
end)

test('lockfile.write reports a directory it cannot create', function()
  local config = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = tmpfile('not a directory')
  local ok, err = lockfile.write(1, 'token')
  vim.env.CLAUDE_CONFIG_DIR = config
  equal(ok, false)
  equal(type(err), 'string')
end)

test('lockfile.write skips unchanged content but recreates a deleted file', function()
  local path = lockfile.path(2)
  assert(lockfile.write(2, 'token'))
  local inode = assert(vim.uv.fs_stat(path)).ino
  assert(lockfile.write(2, 'token'))
  equal(assert(vim.uv.fs_stat(path)).ino, inode, 'same content is not rewritten')
  assert(lockfile.write(2, 'other'))
  equal(assert(vim.uv.fs_stat(path)).ino ~= inode, true, 'new content is written')
  vim.uv.fs_unlink(path)
  assert(lockfile.write(2, 'other'))
  equal(vim.uv.fs_stat(path) ~= nil, true, 'a deleted file is written again')
  lockfile.remove(2)
end)

test('tools return canonical paths', function()
  local path = tmpfile('a')
  vim.cmd.edit(path)
  local reply = vim.json.decode(result_text(call('checkDocumentDirty', { filePath = path })[1]))
  equal(reply.filePath, assert(vim.uv.fs_realpath(path)))
end)

test(':Brygga send refuses buffers that are not files', function()
  vim.api.nvim_buf_set_name(0, 'term://~//1234:claude')
  vim.bo.buftype = 'nofile'
  local messages = {}
  local notify = vim.notify
  vim.notify = function(msg)
    messages[#messages + 1] = msg
  end
  vim.cmd('Brygga send')
  vim.notify = notify
  equal(messages, { 'brygga: current buffer is not a file' })
end)

test('openDiff handles new files and keeps a missing trailing newline', function()
  local path = vim.fn.tempname() .. '/new.lua'
  local replies = call('openDiff', {
    old_file_path = path,
    new_file_path = path,
    new_file_contents = 'return 1',
    tab_name = 'diff-c',
  })
  vim.cmd.write()
  equal(result_text(replies[1], 2), 'return 1')
  call('closeAllDiffTabs')
end)

test('closing a diff with unsaved edits to the proposal still closes it', function()
  local path = tmpfile('a')
  local replies =
    call('openDiff', { old_file_path = path, new_file_path = path, new_file_contents = 'b', tab_name = 'e' })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited but not saved' })
  equal(result_text(call('close_tab', { tab_name = 'e' })[1]), 'TAB_CLOSED')
  equal(result_text(replies[1]), 'DIFF_REJECTED')
  equal(#vim.api.nvim_list_tabpages(), 1)
  -- The diff loaded a file the user did not have open; it must not linger.
  vim.wait(500, function()
    return require('brygga.util').find_buffer(path) == nil
  end)
  equal(require('brygga.util').find_buffer(path), nil)
end)

test('openDiff refuses a file with unsaved changes', function()
  local path = tmpfile('a')
  vim.cmd.edit(path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
  local reply =
    call('openDiff', { old_file_path = path, new_file_path = path, new_file_contents = 'b', tab_name = 'd' })[1]
  equal(reply.result.isError, true)
  equal(#vim.api.nvim_list_tabpages(), 1)
  vim.bo.modified = false
end)

test('selection reports UTF-16 columns with an exclusive end', function()
  local path = tmpfile('local s = "héllo"\nnext line')
  vim.cmd.edit(path)
  vim.api.nvim_win_set_cursor(0, { 1, 11 })
  vim.cmd('normal! v4l\27')
  local sel = selection.last_visual()
  equal(sel.text, 'héllo')
  equal(sel.selection.start, { line = 0, character = 11 })
  equal(sel.selection['end'], { line = 0, character = 16 })

  vim.cmd('normal! ggVj\27')
  sel = selection.last_visual()
  equal(sel.text, 'local s = "héllo"\nnext line')
  equal(sel.selection['end'], { line = 1, character = 9 })

  equal(selection.current().selection.isEmpty, true)
end)

test('a visual edit does not report the text left at the old marks', function()
  local path = tmpfile('one\ntwo\nthree\nfour')
  vim.cmd.edit(path)
  selection.start(function() end)
  vim.cmd('normal! Vj\27')
  equal(selection.latest().text, 'one\ntwo', 'a plain exit keeps the selection')
  -- The cursor is on "two": delete "two" and "three", leaving the cursor on "four".
  vim.cmd('normal! Vjd')
  vim.wait(500, function()
    return selection.latest().text == ''
  end)
  local latest = selection.latest()
  selection.stop()
  equal(latest.text, '')
  equal(latest.selection.start, { line = 1, character = 0 })
end)

test('openFile selects text between startText and endText', function()
  local path = tmpfile('alpha\nbeta gamma\ndelta')
  local reply = call('openFile', { filePath = path, startText = 'gamma', endText = 'del' })[1]
  equal(result_text(reply), 'Opened file and selected text "gamma"')
  local sel = selection.current()
  equal(sel.text, 'gamma\ndel')
  vim.cmd('normal! \27')
  equal(call('openFile', { filePath = path .. '.missing' })[1].result.isError, true)

  -- endText is searched after startText, even on the same line.
  path = tmpfile('end start middle end')
  call('openFile', { filePath = path, startText = 'start', endText = 'end' })
  equal(selection.current().text, 'start middle end')
  vim.cmd('normal! \27')
end)

test('tools reject missing and mistyped arguments before running', function()
  local path = tmpfile('a')
  local reply = call('openDiff', { old_file_path = path, new_file_path = path, new_file_contents = 'b' })[1]
  equal(reply.result.isError, true)
  equal(result_text(reply), 'Missing argument: tab_name')
  equal(#vim.api.nvim_list_tabpages(), 1, 'no diff tab is left behind')
  reply = call('checkDocumentDirty', { filePath = 5 })[1]
  equal(reply.result.isError, true)
  equal(result_text(reply), 'Argument filePath must be a string')
end)

test('mcp rejects non-object params', function()
  local replies = {}
  mcp.handle(vim.json.encode({ jsonrpc = '2.0', id = 3, method = 'tools/call', params = 5 }), 1, function(text)
    replies[#replies + 1] = vim.json.decode(text)
  end)
  equal(replies[1].error.code, -32602)
end)

test('getDiagnostics, checkDocumentDirty and saveDocument', function()
  local path = tmpfile('x = 1')
  vim.cmd.edit(path)
  local ns = vim.api.nvim_create_namespace('brygga-test')
  vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, end_col = 1, message = 'oops', severity = 2, source = 't' } })
  local diagnostics = vim.json.decode(result_text(call('getDiagnostics', { uri = vim.uri_from_fname(path) })[1]))
  equal(diagnostics[1].diagnostics[1].severity, 'Warning')
  equal(diagnostics[1].diagnostics[1].range['end'], { line = 0, character = 1 })
  vim.diagnostic.reset(ns)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'x = 2' })
  equal(vim.json.decode(result_text(call('checkDocumentDirty', { filePath = path })[1])).isDirty, true)
  equal(vim.json.decode(result_text(call('saveDocument', { filePath = path })[1])).saved, true)
  equal(vim.fn.readfile(path), { 'x = 2' })
  equal(vim.json.decode(result_text(call('checkDocumentDirty', { filePath = '/not/open' })[1])).success, false)
end)

test('server writes a private lock file and accepts only the right token', function()
  brygga.start()
  local port = tonumber(vim.env.CLAUDE_CODE_SSE_PORT)
  local lock_path = lockfile.path(port)
  local stat = assert(vim.uv.fs_stat(lock_path))
  equal(bit.band(stat.mode, tonumber('777', 8)), tonumber('600', 8))
  local lock = vim.json.decode(table.concat(vim.fn.readfile(lock_path), '\n'))
  equal(lock.transport, 'ws')
  equal(lock.pid, vim.fn.getpid())
  equal(lock.workspaceFolders[1], vim.fs.normalize(vim.fn.getcwd()))

  local function connect(token, frames)
    local sock = assert(vim.uv.new_tcp())
    local received = ''
    sock:connect('127.0.0.1', port, function()
      sock:read_start(function(_, data)
        received = received .. (data or '')
      end)
      sock:write(table.concat({
        'GET / HTTP/1.1',
        'Host: 127.0.0.1',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: ' .. RFC_NONCE,
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Protocol: mcp',
        'x-claude-code-ide-authorization: ' .. token,
      }, '\r\n') .. '\r\n\r\n' .. (frames or ''))
    end)
    return sock, function()
      return received
    end
  end

  local bad, bad_received = connect('wrong')
  vim.wait(1000, function()
    return bad_received() ~= ''
  end)
  equal(bad_received():match('^HTTP/1.1 (%d+)'), '401')
  bad:close()

  -- The request arrives in two fragments to exercise reassembly.
  local request =
    vim.json.encode({ jsonrpc = '2.0', id = 7, method = 'tools/call', params = { name = 'closeAllDiffTabs' } })
  local half = math.floor(#request / 2)
  local frames = client_frame(0x1, request:sub(1, half), false) .. client_frame(0x0, request:sub(half + 1))
  local good, good_received = connect(lock.authToken, frames)
  vim.wait(2000, function()
    return good_received():find('CLOSED_0_DIFF_TABS', 1, true) ~= nil
  end)
  local response = good_received()
  equal(response:match('^HTTP/1.1 (%d+)'), '101')
  equal(response:match('Sec%-WebSocket%-Accept: (%S+)'), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
  equal(response:match('Sec%-WebSocket%-Protocol: (%S+)'), 'mcp')
  equal(response:find('CLOSED_0_DIFF_TABS', 1, true) ~= nil, true, 'tool reply over the socket')
  equal(brygga.client_count(), 1)
  good:close()

  -- A new message before a fragmented one finishes is a protocol error, answered with close 1002.
  local broken, broken_received = connect(lock.authToken, client_frame(0x1, 'a', false) .. client_frame(0x1, 'b'))
  vim.wait(1000, function()
    return broken_received():find('\136\2\3\234', 1, true) ~= nil
  end)
  equal(broken_received():find('\136\2\3\234', 1, true) ~= nil, true, 'close frame with 1002')
  broken:close()

  -- A handshake still in progress when the server stops must not complete afterwards.
  local pending = assert(vim.uv.new_tcp())
  local pending_received, connected = '', false
  pending:connect('127.0.0.1', port, function()
    connected = true
    pending:read_start(function(_, data)
      pending_received = pending_received .. (data or '')
    end)
    pending:write('GET / HTTP/1.1\r\nUpgrade: websocket\r\n')
  end)
  vim.wait(1000, function()
    return connected
  end)
  vim.wait(100)
  brygga.stop()
  pending:write(
    'Sec-WebSocket-Key: ' .. RFC_NONCE .. '\r\nx-claude-code-ide-authorization: ' .. lock.authToken .. '\r\n\r\n'
  )
  vim.wait(300)
  equal(pending_received, '', 'no handshake response after stop')
  pending:close()

  equal(vim.uv.fs_stat(lock_path), nil, 'lock file removed on stop')
  equal(vim.env.CLAUDE_CODE_SSE_PORT, nil)
end)

print(('%d passed, %d failed'):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
