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
│  MAIN orchestrator (fixed: subtask + notes + plan)           │
│  harness: break this goal into smaller tasks?                │
│  then run pending; after return: update the plan?            │
│        │                                                     │
│        ▼                                                     │
│   CODER / branch orch  (goal + TASK NOTES)                   │
│        │ text reply (no tool)                                │
│        ▼                                                     │
│   VALIDATOR (goal + result + task notes)                     │
│        │ ok / blocked → return                               │
│        │ missing → coder retries that action                 │
│        ▼                                                     │
│   orchestrator plan.update later items, then step=N+1        │
└──────────────────────────────────────────────────────────────┘
```

**Rules of the harness:**

1. Roles: **orchestrator** (plan and dispatch), **coder** (do one goal over
   as many tool turns as needed), **validator** (`ok`, `missing:`, or
   `blocked:`). Each has its own system prompt.
2. Orchestrator tools are fixed (`subtask`, `notes`, `plan`). The plan is a
   **tree**. A branch orchestrator edits only its children; the top one can
   change any node (`1.2`). Each item has `agent`, `status`, `goal`, `notes`.
   Dispatch with `subtask.step`. The child gets that item's goal and notes.
   When the branch is done, the orchestrator replies in text (same handoff
   as a coder).
3. Before a worker returns, the harness calls the validator. `missing`
   retries the coder (max 2) with that next action. `blocked` returns
   the step as a failure so the orchestrator can change later items.
   `ok` marks the plan item done.
4. After a return, the caller is asked again so it can `plan.update`
   later items, then send the next step. Answer only when the request is done.
5. Max depth is 8. Ungranted tools are denied. Validator has no tools.

### Subtask tool parameters

| Field | Required | Description |
|---|---|---|
| `step` | no | 1-based index into the caller's plan. Child gets that item's goal, agent, and notes |
| `goal` | yes* | One action if you are not using `step` / `goals` |
| `goals` | no | Granular goals. The harness runs and validates each in order |
| `role` | no | `orchestrator`, `coder`, or `validator`. Inferred from the plan item or tools |
| `tools` | no | Child tools. Coder default is `read`/`shell`/`notes`. Orchestrator default is `subtask`/`notes`/`plan` |
| `system_prompt` | no | Override the role prompt |

Examples:

```json
{
  "action": "write",
  "items": [
    { "agent": "coder", "goal": "List lua/tai and name session-load files.", "notes": "Project root is the cwd." },
    { "agent": "coder", "goal": "Read the load function.", "notes": "Fill this after step 1." }
  ]
}
```

```json
{ "step": 1, "tools": ["read", "shell"] }
```

```json
{ "action": "update", "index": 2, "goal": "Read lua/tai/context.lua 1:80", "notes": "load() is in context.lua" }
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
| `subtask` | Child agent (`step` into the plan, or `goal` / `goals`, optional `role` / `tools`) |
| `plan` | Structured plan: write / update / status (`agent`, `status`, `goal`, `notes`) |
| `notes` | Write/append the shared notepad (injected every turn for main and workers) |
| `mcp` | MCP status / connect / disconnect / list_tools / call |

Main is an orchestrator (`subtask` + `notes` + `plan`). Coders default to
`read` / `shell` / `notes`. A validator checks each return before the parent continues.

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
