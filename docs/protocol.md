# Claude Code IDE protocol

What brygga implements and what Claude Code actually does on the wire. Verified
on 2026-10-13 against Claude Code 2.1.296: live sessions of the `claude` CLI
against brygga, plus the code of the VS Code extension 2.1.296, which is the
reference implementation. Anthropic does not document this protocol, so
re-verify when Claude Code changes behavior.

## Discovery

- Lock file: `<config>/ide/<port>.lock`, where `<config>` is
  `$CLAUDE_CONFIG_DIR` or `~/.claude`. The CLI reads the port from the
  filename. Contents: `pid`, `workspaceFolders`, `ideName`, `transport: "ws"`,
  `authToken` ([`lua/brygga/lockfile.lua`](../lua/brygga/lockfile.lua)).
- `/ide` and `claude --ide` offer a lock file when the CLI's working directory
  is inside one of its `workspaceFolders`, or when its port equals
  `CLAUDE_CODE_SSE_PORT`. With that variable set, plain `claude` connects on
  its own (verified live). The CLI deletes lock files whose `pid` is dead.
- `ENABLE_IDE_INTEGRATION`, still set by older plugins, is not read by the CLI.

## Transport

- WebSocket on `127.0.0.1`. The CLI requests subprotocol `mcp` and expects it
  echoed. It also offers `permessage-deflate`, which brygga declines.
- Auth header `x-claude-code-ide-authorization` carries the lock file token.
- MCP over JSON-RPC 2.0, one message per text frame. The CLI sends
  `protocolVersion` `2025-11-25` and also supports older versions. brygga
  echoes the client's version ([`lua/brygga/mcp.lua`](../lua/brygga/mcp.lua)).

## Observed call sequence

1. `initialize`, `notifications/initialized`, the notification
   `ide_connected` `{pid}`, then `tools/list`.
2. At the start of every turn: `closeAllDiffTabs`.
3. Around an edit: `getDiagnostics`, then `openDiff`, which blocks until the
   user decides. `close_tab` follows twice with the same `tab_name`, then
   `getDiagnostics` for the file and for all files.

`tab_name` looks like `✻ [Claude Code] app.lua (5da2a1) ⧉`.

## Notifications from Neovim

brygga sends these JSON-RPC notifications, shaped like the VS Code extension's
([`lua/brygga/init.lua`](../lua/brygga/init.lua)):

- `selection_changed`: the selection, debounced, and the latest one again
  500 ms after a client connects. A visual selection is sent as soon as visual
  mode ends. When the operator edited the buffer (`d`, `c`, `p`), the cursor
  position is sent instead.
- `diagnostics_changed` `{uris}`: debounced 300 ms.
- `at_mentioned` `{filePath, lineStart, lineEnd}`: from `:Brygga send`, with
  0-based lines.

Their shapes are verified against the extension code and unit tests. A live
session on 2026-10-13 showed the CLI using `selection_changed`: the prompt
shows `⧉ 1 line selected` and the model reported the selected text. A manual
test on 2026-10-14 confirmed that the CLI acts on `at_mentioned`: `:Brygga
send` adds the file reference to the prompt.

## openDiff replies

- Accepted: `[{text: "FILE_SAVED"}, {text: <final contents>}]`. The CLI writes
  the file from the second item, so the user's edits to the proposal count.
- Rejected: `[{text: "DIFF_REJECTED"}, {text: <tab_name>}]`.
- Any other first item, such as `DIFF_ACCEPTED`, makes the CLI fail the edit.

## Tool visibility

The CLI only exposes `getDiagnostics` and `executeCode` (Jupyter, not
implemented) to the model as `mcp__ide__*`. The other tools are for the CLI
itself or currently unused, and tools must be listed in `tools/list` to be
called. Names and result shapes follow the VS Code extension
([`lua/brygga/tools.lua`](../lua/brygga/tools.lua)).

Before a tool runs, `mcp.lua` checks its arguments against its `inputSchema`:
required names and the types of known ones. A mismatch returns an `isError`
result such as `Missing argument: tab_name`, so a malformed `openDiff` never
opens a tab. Unknown arguments are ignored.

## Positions and paths

- Lines are 0-based in selections, diagnostics and `at_mentioned`. Columns
  are UTF-16 offsets, as in VS Code.
- Neovim resolves symlinks in buffer names (on macOS, `/var` becomes
  `/private/var`). Incoming paths are resolved with `fs_realpath` before
  matching buffers (`util.canonical` in
  [`lua/brygga/util.lua`](../lua/brygga/util.lua)). Tools return these
  canonical paths.

## Testing against the real CLI

- A `claude` started from inside another Claude Code session inherits
  `CLAUDECODE` and `CLAUDE_CODE_CHILD_SESSION` and never connects to an IDE.
  Start it with a clean environment (`env -i HOME=… PATH=… TERM=…`).
- `claude -p` does not connect to an IDE. Use an interactive session in a
  pseudo-terminal (`script -q /dev/null claude`), with an idle stdin; a stream
  such as `/dev/zero` stalls the TUI.
- Run from a trusted directory, or the trust dialog consumes typed input.
- In the default permission mode the CLI asks before `mcp__ide__getDiagnostics`;
  pass `--allowedTools=mcp__ide__getDiagnostics` (the `=` form, because the
  flag is variadic and swallows the prompt otherwise).
