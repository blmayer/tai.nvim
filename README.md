# 泰.nvim

![tai.nvim in action](www/screenshot.png)

> A minimal, dependency-free Neovim plugin that brings AI coding agents directly
> into your editor. It uses a **subtask harness**, Live Context (goal + previous
> steps), session persistence, and many LLM providers.

<a href="https://dotfyle.com/plugins/blmayer/tai">
	<img src="https://dotfyle.com/plugins/blmayer/tai/shield?style=flat" />
</a>

## Features

- **Subtask harness** — if you can answer, do it; else `subtask` until you
  can. Children start with a clean history and iterate only after a
  subtask returns. Their final text is the result.
- **Current state** — Goal + Previous steps at this level, shown as data
  (not mixed into the instructions).
- **Flexible subtasks** — pass `goal`, optional `tools` / `system_prompt`.
- **Session persistence** — conversations auto-save/restore (`.tai-session.json`
  in the project root).
- **Tool use** — read/write files, shell, edit, images, subtask, MCP.
- **MCP** — local stdio and remote HTTP servers from `.tai` (`mcps`).
- **Rate limiting** — configurable `rpm` / `tpm`.
- **Streaming and non-streaming** for all providers.
- **Code folding** — tool output and whole subtasks fold in the chat buffer.
- **Provider-side tools** — pass-through for e.g. `web_search`.
- **Configurable shell safety** — allowlist of commands without confirmation.

## Agent harness

```
┌──────────────────────────────────────────────────────────────┐
│  MAIN (multi-turn, subtask + notes)                          │
│  Live Context: shared notes                                  │
│                                                              │
│   reply if done, else subtask(one concrete next step)        │
│        │                                                     │
│        ▼                                                     │
│   ┌──────────────────────────────────────────────────────┐   │
│   │  SUBTASK (clean history)  fold                       │   │
│   │  Goal + Previous steps at this level                 │   │
│   │  work, or subtask, then next step or reply           │   │
│   └──────────────────────┬───────────────────────────────┘   │
│                          │ step recorded as previous step    │
│                          ▼                                   │
│   next subtask, or answer the user                           │
└──────────────────────────────────────────────────────────────┘
```

**Rules of the harness:**

1. No `todos` tool. Agents **answer** or call **`subtask`** (one step).
2. Answer only if it fully addresses the goal. A subtask is one step
   toward that goal.
3. When a child returns, its report is injected into the parent’s system
   prompt and the parent is asked again. The child’s final text is the result.
4. Max depth is 8. A child may nest only if granted `subtask`. Pass a
   `read`/`shell`/`edit` for a leaf; omit `tools` for a coordinator.
   Ungranted tools are denied.
5. Main is the orchestrator (`subtask` + shared `notes`). Work happens in subagents.

### Subtask tool parameters

| Field | Required | Description |
|---|---|---|
| `goal` | yes | The next step (paths, action). Must not copy the current Goal |
| `tools` | no | Child tools. Default is `subtask` + `notes`. Pass `read`/`shell`/`edit` for a leaf. |
| `system_prompt` | no | Override the default worker prompt |

Examples:

```json
{
  "goal": "List lua/tai and report which file defines main_tools.",
  "tools": ["read", "shell"]
}
```

```json
{
  "goal": "In lua/tai/agent.lua, change main_tools to only subtask. Minimal diff.",
  "tools": ["read", "edit"],
  "system_prompt": "You are a careful implementer. Do not freestyle architecture."
}
```

## Providers

| Provider | Environment Variable | Notes |
|---|---|---|
| Gemini | `GEMINI_API_KEY` | |
| Groq | `GROQ_API_KEY` | |
| Minimax | `MINIMAX_API_KEY` | |
| Mistral | `MISTRAL_API_KEY` | |
| Ollama | *(none)* | Local, `localhost:11434` |
| llama.cpp | *(none)* | Local, `localhost:8080` |
| OpenAI | `OPENAI_API_KEY` | Chat Completions API |
| OpenAI Responses | `OPENAI_API_KEY` | Responses API |
| OpenRouter | `OPENROUTER_API_KEY` | |
| StepFun | `STEPFUN_API_KEY` | |
| xAI | `XAI_API_KEY` | |
| Z.AI | `Z_AI_API_KEY` | |
| Zyphra | `ZYPHRA_API_KEY` | |
| Custom | *(via `options.url`)* | Any OpenAI-compatible endpoint |

## Installation

### Requirements

- Neovim 0.10+ (`vim.uv`)
- curl (for API calls)
- An API key for your chosen provider

### Plugin Managers

#### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  "blmayer/tai",
  opts = {},
  keys = {
    { "<leader>tt", "<cmd>Tai chat<cr>", desc = "Open Tai chat" },
    { "<leader>tc", "<cmd>Tai reload<cr>", desc = "Reload Tai config" },
    { "<leader>tr", "<cmd>Tai clear<cr>", desc = "Clear Tai history" },
    { "<leader>ts", "<cmd>Tai stop<cr>", desc = "Stop Tai" },
  },
}
```

#### [Packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use("blmayer/tai")
```

#### [vim-plug](https://junegunn.github.io/vim-plug/)

```vim
Plug "blmayer/tai"
```

#### Native / Manual Installation

Place or symlink the plugin (include `lua/` and `plugin/` if you want `:Tai`
commands). Example keymaps:

```lua
local tai = require("tai")
tai.setup({})

vim.keymap.set("n", "<leader>tt", tai.chat, { noremap = true })
vim.keymap.set("n", "<leader>tc", tai.reload, { noremap = true })
vim.keymap.set("n", "<leader>tr", tai.clear_history, { noremap = true })
vim.keymap.set("n", "<leader>ts", tai.stop, { noremap = true })
vim.keymap.set("n", "<C-W><C-T>", tai.toggle_chat_window, { noremap = true })
```

Tai only fully activates when a **`.tai`** file is found walking up from the
current working directory.

## Project Configuration

tai reads configuration from a `.tai` JSON file in your project root:

| Key | Type | Default | Description |
|---|---|---|---|
| `provider` | string | — | Provider name (see table above) |
| `model` | string | — | Model identifier (e.g. `"gemini-2.0-flash"`) |
| `options` | object | `{}` | Provider-specific options |
| `stream` | boolean | `false` | Enable streaming responses |
| `use_tools` | boolean | `true` | Enable/disable agent tools |
| `think` | string | — | Reasoning effort for supporting models |
| `rpm` | number | `60` | Max requests per minute |
| `tpm` | number | — | Max tokens per minute |
| `provider_tools` | array | — | Provider-side tools (e.g. `["web_search"]`) |
| `system_prompt` | string | — | Override the default main system prompt |
| `custom_prompt` | string | — | Extra instructions appended to the main prompt |
| `allowed_commands` | object | *(defaults)* | Map of allowed shell commands |
| `auto_approve` | boolean | `false` | Auto-approve shell commands outside the allowlist |
| `mcps` | object | `{}` | MCP server definitions (local and remote) |

Default allowed commands: `cat`, `grep`, `ag`, `rg`, `ls`, `head`, `tail`,
`wc`, `diff`, `sort`, `uniq`, `find`, `file`, `stat`, `date`, `echo`, `tree`,
`pwd`, `which`, `type`.

### MCP servers (`mcps`)

Map of name → server config. Connected at startup.

**Local (stdio):**

```json
"my-server": {
  "command": "python3",
  "args": ["path/to/server.py"],
  "env": { "FOO": "bar" },
  "cwd": ".",
  "denylist": ["dangerous_tool"]
}
```

**Remote (HTTP JSON-RPC):**

```json
"remote": {
  "url": "http://127.0.0.1:3000/mcp",
  "api_key": "…",
  "denylist": []
}
```

Auth fields (use one style):

| Fields | Auth |
|---|---|
| `api_key` | Bearer + `X-Api-Key` headers |
| `user` + `pass` | HTTP Basic |
| `oauthURL` + `oauth_token` | OAuth: set URL for discovery; put the access token in `oauth_token` |
| `headers` | Extra static headers |

Client features **not** supported: Tool List Change Notifications, Roots, Sampling.

Example `.tai` file:

```json
{
	"provider": "groq",
	"model": "llama-3.1-70b-versatile",
	"stream": true,
	"rpm": 30,
	"options": {
		"temperature": 0.7,
		"max_tokens": 4096
	},
	"use_tools": true,
	"custom_prompt": "Prefer using rust over python for performance-critical code.",
	"allowed_commands": {
		"git": true,
		"npm": true,
		"make": true
	},
	"mcps": {
		"dummy": {
			"command": "python3",
			"args": ["lua/tai/tests/fixtures/dummy_mcp_server.py"],
			"denylist": ["secret_tool"]
		}
	}
}
```

## Agent Tools

| Tool | Description |
|---|---|
| `read` | Read file contents (optional line range) |
| `shell` | Run shell commands in the project root |
| `send_image` | Send images for visual analysis |
| `edit` | Search-and-replace edit (`multi` flag supported) |
| `write` | Create new files |
| `subtask` | One-shot child for the next step (`goal`, optional `tools` / `system_prompt`) |
| `notes` | Write/append the shared notepad (injected every turn for main and workers) |
| `mcp` | MCP status / connect / disconnect / list_tools / call |

Main and default children get `subtask` + `notes`. Pass `read`/`shell`/`edit`
in `tools` for a one-shot leaf.

### `mcp` tool

| Action | Args | Description |
|---|---|---|
| `status` | `server?` | Connection state and tools |
| `connect` | `server` | Connect a configured server |
| `disconnect` | `server` | Disconnect |
| `list_tools` | `server?` | Available tools (with schemas) |
| `call` | `server`, `tool`, `arguments` | Invoke an MCP tool |

## Commands

If `plugin/tai.lua` is on the runtimepath:

| Command | Action |
|---|---|
| `:Tai chat` | Open chat and focus input |
| `:Tai toggle` | Toggle chat window |
| `:Tai reload` | Reload `.tai` config |
| `:Tai clear` | Clear history and session |

## Running Tests

```sh
nvim --headless -u NONE -c "set rtp+=." -c "luafile lua/tai/tests/edit_test.lua" -c "qa!"
nvim --headless -u NONE -c "set rtp+=." -c "luafile lua/tai/tests/subtask_test.lua" -c "qa!"
nvim --headless -u NONE -c "set rtp+=." -c "luafile lua/tai/tests/mcp_test.lua" -c "qa!"
```

## Screenshots

- ![tai.nvim in action](www/screenshot.png)
- ![side panel](www/2025-08-05-174307_1372x1415_scrot.png)
- ![side panel with folding](www/folding.png)

## License

This project is licensed under the MIT License.
