# brygga

Brygga means "bridge" in Swedish. It lets Claude Code use Neovim as its IDE,
the same way it uses the VS Code and JetBrains extensions. Start `claude`, type
`/ide`, and Claude can see your selection, your diagnostics and your open
files. Edits it proposes open as a diff in Neovim.

brygga is pure Lua, has no dependencies and needs Neovim 0.12 or newer.

brygga is built to stay out of your way. Its MCP, diff and SHA-1 code loads
only when Claude first needs it, so it adds little to Neovim's startup. The
server runs on `vim.uv`, so it does not block the editor. Selection and
diagnostic updates are debounced, which sends one message after a burst of
cursor moves or LSP changes.

## Features

- Claude sees your selection and follows it as the cursor moves.
- A visual selection stays after `<Esc>` until the cursor moves, so you can
  switch to Claude without losing it.
- Proposed edits open as a side-by-side diff in a new tab.
- Claude reads LSP diagnostics and is told when they change.
- `:Brygga send` adds the current file or a range of lines to Claude's prompt
  as an @-mention.
- Claude can open files, list open buffers and workspace folders, check for
  unsaved changes and save documents.

## Install

Both examples follow the tagged releases instead of the latest commit on
`main`.

With `vim.pack`:

```lua
vim.pack.add({
  { src = 'https://github.com/ThorstenRhau/brygga.nvim', version = vim.version.range('*') },
})
require('brygga').setup()
```

With lazy.nvim, `opts` makes lazy call `setup()`:

```lua
{ 'ThorstenRhau/brygga.nvim', version = '*', opts = {} }
```

## Usage

`setup()` starts the server. It has one option:

```lua
require('brygga').setup({
  -- Start the server when setup() runs.
  auto_start = true,
})
```

You can skip `setup()` and run `:Brygga start` when you want the server.

### Connect Claude Code

- In a Neovim `:terminal`, run `claude`. It connects on its own, because brygga
  sets `CLAUDE_CODE_SSE_PORT` in Neovim's environment.
- In another terminal, run `claude` from a directory inside Neovim's working
  directory or an LSP workspace root. Then type `/ide` and pick Neovim, or
  start with `claude --ide`.

### Commands

| Command | What it does |
| --- | --- |
| `:Brygga` or `:Brygga status` | Shows the port, the number of connected clients and the lock file |
| `:Brygga start` | Starts the server |
| `:Brygga stop` | Stops the server and removes the lock file |
| `:Brygga send` | Adds the current file to Claude's prompt as an @-mention |
| `:'<,'>Brygga send` | Adds only the selected lines |

A keymap for sending a visual selection:

```lua
vim.keymap.set('x', '<leader>cs', ':Brygga send<CR>', { desc = 'Send selection to Claude' })
```

Pressing `:` in visual mode fills in the range for you.

### Review edits

When Claude proposes a change, brygga opens a new tab with the file on the left
and the proposal on the right.

- `:w` in the proposed buffer accepts the change. You can edit the proposal
  first. Claude then writes the file.
- `:q` rejects the change.

If the file has unsaved changes in Neovim, brygga does not open the diff. Save
the file and ask Claude again.

## How it works

brygga runs a WebSocket server on `127.0.0.1` with a random port and a random
auth token. It writes a lock file to `~/.claude/ide/<port>.lock` (or
`$CLAUDE_CONFIG_DIR/ide`) with mode 0600. Claude Code reads that file to find
the server and the token. brygga removes the file when Neovim exits.

The lock file lists Neovim's working directory and the LSP workspace roots.
`/ide` offers Neovim only when Claude's directory is inside one of them.

Claude Code decides which tools to call. Today the model reads diagnostics
directly, and the CLI uses the other tools internally. brygga does not support
Jupyter `executeCode`.

## Troubleshooting

`/ide` does not list Neovim:

- Run `:checkhealth brygga`. It checks the Neovim version, the `claude`
  command, the lock file and the proxy settings, and says how to fix each
  problem.
- Run `:Brygga status` to see if the server is running.
- Start `claude` from a directory inside Neovim's working directory or an LSP
  workspace root.
- Look for the lock file in `~/.claude/ide/`.
- If you set an HTTP proxy variable, add `localhost,127.0.0.1` to `no_proxy`.

Edits do not open as diffs: Claude shows a diff only when it asks permission to
edit. In a permission mode that accepts edits automatically, Claude writes the
files directly and there is nothing to review.

## Development

```sh
make check   # stylua format check, selene lint, headless tests
make test    # headless tests only
```

## License

BSD 3-Clause

## Acknowledgments

The protocol notes in [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)
were a useful reference.
