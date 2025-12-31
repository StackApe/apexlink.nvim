# apexlink.nvim

P2P collaborative editing for Neovim. Edit files together in real-time with CRDT-based conflict resolution.

## Features

- **Room-based collaboration** - Create/join rooms with 8-character codes
- **P2P communication** - Direct WebRTC connections between peers
- **CRDT buffer sync** - Conflict-free real-time editing via Yjs
- **Works anywhere** - Desktop, Termux, any Neovim instance

## Requirements

- Neovim 0.9+
- `apexlink-daemon` binary (see [Building the Daemon](#building-the-daemon))

## Installation

### lazy.nvim

```lua
{
  "StackApe/apexlink.nvim",
  cmd = "ApexLink",  -- Only load when you run :ApexLink
  keys = {
    { "<leader>ac", desc = "ApexLink: Create room" },
    { "<leader>aj", desc = "ApexLink: Join room" },
  },
  config = function()
    require("apexlink").setup({
      -- Optional: specify daemon path if not in PATH
      -- daemon_path = "/path/to/apexlink-daemon",

      -- Optional: signaling server URL (default: ws://localhost:8765)
      -- server_url = "ws://your-server:8765",

      -- Optional: your display name (default: $USER)
      -- username = "MyName",

      -- Optional: cursor color (default: #00ffff)
      -- color = "#ff00ff",
    })
  end,
}
```

### packer.nvim

```lua
use {
  "StackApe/apexlink.nvim",
  config = function()
    require("apexlink").setup()
  end
}
```

## Building the Daemon

The plugin requires the `apexlink-daemon` binary. Build it from the [apex-pde](https://github.com/StackApe/apex-pde) repo:

### Desktop (Linux/macOS)

```bash
git clone https://github.com/StackApe/apex-pde
cd apex-pde/apexlink/daemon
cargo build --release
# Binary at: target/release/apexlink-daemon
```

### Termux (Android)

```bash
pkg install rust
git clone https://github.com/StackApe/apex-pde
cd apex-pde/apexlink/daemon
cargo build --release
# Binary at: target/release/apexlink-daemon

# Add to PATH or specify in config:
cp target/release/apexlink-daemon ~/.local/bin/
```

## Usage

### Start a Signaling Server

One machine needs to run the signaling server (for WebRTC connection setup):

```bash
apexlink-daemon server --bind 0.0.0.0 --port 8765
```

### Commands

| Command | Description |
|---------|-------------|
| `:ApexLink create` | Create a new room (code copied to clipboard) |
| `:ApexLink join CODE` | Join a room by code |
| `:ApexLink rejoin` | Rejoin last room |
| `:ApexLink leave` | Leave current room |
| `:ApexLink status` | Show connection status |
| `:ApexLink sync` | Start syncing current buffer |
| `:ApexLink unsync` | Stop syncing current buffer |
| `:ApexLink buffers` | List synced buffers |
| `:ApexLink stop` | Stop daemon |

### Keybindings

All under `<leader>a` prefix:

| Key | Action |
|-----|--------|
| `<leader>ac` | Create room |
| `<leader>aj` | Join room |
| `<leader>ar` | Rejoin last room |
| `<leader>al` | Leave room |
| `<leader>as` | Show status |
| `<leader>ab` | Sync current buffer |
| `<leader>au` | Unsync current buffer |
| `<leader>aB` | List synced buffers |
| `<leader>ax` | Stop daemon |

## Quick Start

**Machine A (host):**
```vim
" Start signaling server in terminal first:
" apexlink-daemon server

:ApexLink create
" → Room: ABCD1234 (copied to clipboard)
:ApexLink sync
```

**Machine B (peer):**
```vim
:ApexLink join ABCD1234
:ApexLink sync
```

Now edits sync in real-time!

## Configuration

```lua
require("apexlink").setup({
  -- Path to daemon binary (auto-detected if in PATH)
  daemon_path = nil,

  -- Signaling server URL
  server_url = "ws://localhost:8765",

  -- Your display name
  username = nil,  -- defaults to $USER

  -- Your cursor color (hex)
  color = "#00ffff",

  -- Show notifications
  auto_notify = true,

  -- Auto-save when in a room
  auto_save = true,

  -- Auto-reload external changes
  auto_reload = true,

  -- Sync interval in ms
  sync_interval = 2000,
})
```

## Architecture

```
┌─────────────┐     WebSocket      ┌─────────────────┐
│   Neovim    │◄──────────────────►│ apexlink-daemon │
│  (plugin)   │    JSON-RPC        │   (per user)    │
└─────────────┘                    └────────┬────────┘
                                            │ WebRTC
                                            ▼
                                   ┌─────────────────┐
                                   │ Signaling Server│
                                   │  (one per LAN)  │
                                   └─────────────────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │  Other Peers    │
                                   │ (P2P via WebRTC)│
                                   └─────────────────┘
```

## License

MIT
