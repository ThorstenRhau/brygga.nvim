# AGENTS.md - brygga

brygga is a Neovim 0.12+ plugin, pure Lua with no dependencies, that lets
Claude Code connect to Neovim as its IDE. `README.md` is the public contract.
Read [`docs/index.md`](docs/index.md) and [`docs/protocol.md`](docs/protocol.md)
before changing protocol behavior.

## Architecture

- `lua/brygga/init.lua`: public API (`setup`, `start`, `stop`, `send`),
  server state, broadcasts and autocmds.
- `lua/brygga/websocket.lua` and `sha1.lua`: the RFC 6455 server on `vim.uv`.
- `lua/brygga/lockfile.lua`: the discovery file Claude Code reads.
- `lua/brygga/mcp.lua`: JSON-RPC and MCP dispatch.
- `lua/brygga/tools.lua`: one entry per MCP tool. `diff.lua` owns the
  blocking `openDiff` lifecycle, `selection.lua` owns selection tracking.
- `plugin/brygga.lua`: the `:Brygga` command.

## Change conventions

- Match tool names, inputs and result shapes to the VS Code extension; the CLI
  rejects anything else. Record verified protocol changes in
  `docs/protocol.md`.
- uv callbacks run in a fast context: schedule before calling the Neovim API.
- To close a socket after a final write (close frame, HTTP error), use
  `shutdown` and close in its callback. Closing right away cancels the write.
- Keep handshake nonces in tests in `RFC_NONCE`. Gitleaks reports a literal
  `Sec-WebSocket-Key: <value>` as a generic API key and blocks the commit.
- Tests must never write to `~/.claude`: `make test` sets a temporary
  `CLAUDE_CONFIG_DIR`, and `tests/headless.lua` refuses to run without one.

## Validation

- `make check` is the read-only gate: stylua format check, selene lint and the
  headless tests.
- `make format` rewrites files.
- For protocol changes, also test against the real CLI as described in
  `docs/protocol.md`. That writes a short-lived lock file to `~/.claude/ide`.

## Commits

Use `type(scope): description`, where type is `feat`, `fix`, `chore`,
`refactor`, `style`, or `docs`, and scope is a filename or feature area without
an extension.
