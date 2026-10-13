# brygga

Brygga means "bridge" in Swedish. It makes Neovim an IDE that Claude Code can
connect to, the same way it connects to the VS Code and JetBrains extensions.
Start `claude`, type `/ide`, and Claude sees your selection, your diagnostics
and your open files. Edits it proposes open as a diff in Neovim.

It is pure Lua, has no dependencies, and needs Neovim 0.12+.

## Features

- Claude sees your current selection as you move
- A visual selection is kept after `<Esc>` until the cursor moves, so you can
  switch to Claude without losing it
- Proposed edits open as a side-by-side diff in a new tab
- Claude can read LSP diagnostics and is told when they change
- `:Brygga send` adds the current file or a range of lines to Claude's prompt
  as an @-mention
- Claude can open files, list open buffers and workspace folders, check for
  unsaved changes and save documents

## Install

With `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/ThorstenRhau/brygga.nvim' })
require('brygga').setup()
```

With lazy.nvim, `opts` makes lazy call `setup()`:

```lua
{ 'ThorstenRhau/brygga.nvim', opts = {} }
```

## Usage

`setup()` starts the server. It takes one option:

```lua
require('brygga').setup({
  -- Start the server when setup() runs.
  auto_start = true,
})
```

Setup is optional. Without it, run `:Brygga start` when you want the server.

### Connect Claude Code

- Run `claude` in a Neovim `:terminal`. It connects on its own, because brygga
  sets `CLAUDE_CODE_SSE_PORT` in Neovim's environment.
- Run `claude` in another terminal, in a directory inside Neovim's working
  directory or an LSP workspace root. Type `/ide` and pick Neovim, or start
  with `claude --ide`.

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
  first. Claude writes the file.
- `:q` rejects the change.

If the file has unsaved changes in Neovim, brygga refuses to open the diff.
Save the file and ask again.

## How it works

brygga runs a WebSocket server on `127.0.0.1` with a random port and a random
auth token. It writes a lock file to `~/.claude/ide/<port>.lock` (or
`$CLAUDE_CONFIG_DIR/ide`) with mode 0600. Claude Code reads that file to find
the server and the token. The file is removed when Neovim exits.

The lock file lists Neovim's working directory and the LSP workspace roots.
This is why `/ide` only offers Neovim when Claude's directory is inside one of
them.

Claude Code decides which tools it uses. Today the model sees diagnostics
directly, and the CLI uses the rest internally. Jupyter `executeCode` is not
supported.

## Troubleshooting

`/ide` does not list Neovim:

- Run `:Brygga status` and check that the server is running.
- Check that the directory you started `claude` in is inside Neovim's working
  directory or an LSP workspace root.
- Check that the lock file exists in `~/.claude/ide/`.
- If you use an HTTP proxy variable, add `localhost,127.0.0.1` to `no_proxy`.

Edits do not open as diffs: Claude shows a diff when it asks for permission to
edit. In a permission mode that accepts edits on its own, Claude writes files
directly and there is nothing to review.

## Development

```sh
make check   # stylua format check, selene lint, headless tests
make test    # headless tests only
```

## License

BSD 3-Clause

## Acknowledgments

The protocol notes in [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)
were a helpful reference.
