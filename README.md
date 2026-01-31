# moltstream

Real-time bidirectional communication between Neovim and OpenClaw over Tailscale.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Neovim        │◄───►│   moltstream    │◄───►│   OpenClaw      │
│   (buffer)      │stdio│   (bridge)      │ WS  │   (gateway)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

## Features

- 📝 Edit messages in Neovim with full vim keybindings
- ⚡ Real-time streaming responses (appears as you receive)
- 🔒 E2E encrypted over Tailscale
- 📚 Persistent conversation history (markdown files)
- 🔄 Auto-archive at configurable size limit (default 1GB)
- 🎨 Syntax highlighting for conversation

## Requirements

- Neovim 0.9+
- Go 1.21+ (for building)
- OpenClaw gateway running
- Tailscale (for secure transport)

## Installation

### 1. Build moltstream

```bash
git clone https://github.com/albxllm/moltstream.git
cd moltstream
make build
make install  # Installs to ~/.local/bin
```

Or with Go directly:
```bash
go install github.com/albxllm/moltstream/cmd/moltstream@latest
```

### 2. Configure

```bash
mkdir -p ~/.config/moltstream
cp config.example.yaml ~/.config/moltstream/config.yaml
# Edit with your gateway URL and token
```

```yaml
# ~/.config/moltstream/config.yaml
gateway:
  url: "ws://<tailscale-ip>:3000/api/sessions/main/ws"
  token: "${OPENCLAW_TOKEN}"  # Or hardcode

session:
  directory: "~/.local/share/moltstream"
  max_size_bytes: 1073741824  # 1GB
  auto_archive: true

neovim:
  insert_mode_on_response: false
  scroll_on_response: true
```

### 3. Install Neovim Plugin

#### Using lazy.nvim

```lua
-- ~/.config/nvim/lua/plugins/moltstream.lua
return {
  "albxllm/moltstream",
  build = "make build",
  config = function()
    require("moltstream").setup({
      -- Optional overrides
      keymap = {
        send = "<leader>ms",      -- Send current message
        new_message = "<leader>mn", -- Start new message block
        open = "<leader>mo",      -- Open session file
        archive = "<leader>ma",   -- Archive and start fresh
      },
      auto_scroll = true,
      max_file_size = 1024 * 1024 * 1024,  -- 1GB
    })
  end,
  keys = {
    { "<leader>mo", desc = "Moltstream: Open" },
    { "<leader>ms", desc = "Moltstream: Send" },
  },
}
```

#### Manual Installation

```bash
# Clone to nvim packages
mkdir -p ~/.local/share/nvim/site/pack/moltstream/start
cd ~/.local/share/nvim/site/pack/moltstream/start
git clone https://github.com/albxllm/moltstream.git
cd moltstream && make build
```

Add to init.lua:
```lua
require("moltstream").setup()
```

### 4. Set Environment

```bash
export OPENCLAW_TOKEN="your-token-here"
# Or add to config.yaml
```

## Usage

### Quick Start

```vim
:MoltOpen          " Open/create session
```

Write your message:
```markdown
## User [18:40]

What's the status on the brain repo?
```

Send it:
```vim
<leader>ms         " Or :MoltSend
```

Watch the response stream in real-time:
```markdown
## User [18:40]

What's the status on the brain repo?

---

## Assistant [18:40]

The brain repo is running with Quartz serving at...
▌                  " Cursor shows streaming
```

### Commands

| Command | Keymap | Description |
|---------|--------|-------------|
| `:MoltOpen` | `<leader>mo` | Open session file |
| `:MoltSend` | `<leader>ms` | Send pending message |
| `:MoltNew` | `<leader>mn` | Insert new message template |
| `:MoltArchive` | `<leader>ma` | Archive session, start fresh |
| `:MoltStatus` | | Show connection status |
| `:MoltReconnect` | | Reconnect to gateway |

### Session File Format

```markdown
<!-- moltstream session -->
<!-- id: abc123 -->
<!-- created: 2026-01-31T18:40:00Z -->

---

## User [18:40]

Your message here.

---

## Assistant [18:40]

Response appears here, streaming in real-time.

---

## User [18:41]

Next message...
```

## Architecture

### Components

1. **moltstream binary** - Bridge daemon (Go)
   - Spawned by Neovim plugin as child process
   - Communicates via stdin/stdout (JSON-RPC)
   - Maintains WebSocket to OpenClaw gateway
   - Handles reconnection with exponential backoff

2. **Neovim plugin** - UI integration (Lua)
   - Manages session buffer
   - Parses markdown to extract messages
   - Streams responses into buffer
   - Handles archiving and rotation

### Protocol

Neovim ↔ moltstream (stdin/stdout, JSON-RPC 2.0):

```json
// Request (nvim → moltstream)
{"jsonrpc":"2.0","method":"send","params":{"content":"Hello"},"id":1}

// Streaming response (moltstream → nvim)
{"jsonrpc":"2.0","method":"stream","params":{"delta":"The","done":false}}
{"jsonrpc":"2.0","method":"stream","params":{"delta":" answer","done":false}}
{"jsonrpc":"2.0","method":"stream","params":{"delta":" is...","done":true}}

// Response complete
{"jsonrpc":"2.0","result":{"status":"ok"},"id":1}
```

### Security

- All traffic over Tailscale (WireGuard encrypted)
- Token stored in config with 600 permissions
- No data leaves the Tailscale network

## Development

```bash
# Run tests
make test

# Build for current platform
make build

# Build for all platforms
make build-all

# Lint
make lint
```

## Troubleshooting

### Connection refused
```
Error: dial tcp <tailscale-ip>:3000: connect: connection refused
```
→ Ensure OpenClaw gateway is running: `openclaw gateway status`

### Token invalid
```
Error: 401 Unauthorized
```
→ Check `OPENCLAW_TOKEN` or config.yaml token

### Buffer not updating
→ Check `:MoltStatus` for connection state
→ Try `:MoltReconnect`

## License

MIT
