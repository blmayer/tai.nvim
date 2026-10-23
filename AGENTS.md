# Tai project (agent notes)

Tai is a Neovim plugin (Lua) that integrates an LLM assistant into your coding workflow.
This repo also includes a small static website under `www/`.

These notes are intended for **automated coding agents** working in this repository.

## Repository layout

- `lua/tai/` — Neovim plugin implementation (all core logic)
  - `init.lua` — plugin entrypoint (`setup`, `chat`, `stop`, …); connects MCPs
  - `inline.lua` — visual selection, insert complete, and insert-at-cursor (own prompts, no planner)
  - `config.lua` — defaults + `.tai` project config (`mcps`, …)
  - `agent.lua` — main/subtask system prompts, `new_frame`, tool allowlists
  - `mcp.lua` — MCP client (stdio + HTTP); status/connect/call
  - `providers.lua` / `provider_common.lua` — provider adapters
  - `tools.lua` — tool **schemas** + re-exports
  - `tools/` — implementation modules (`io`, `shell`, `edit`, `subtask`, `skill`, `mcp`)
  - `ui.lua` — thin facade over `ui/core.lua`
  - `ui/core.lua` — stack, continue loop, tool runner, chat UI
  - `context.lua` — session file load/save
  - `log.lua` — logging
- `plugin/tai.lua` — optional autoload + `:Tai` user command
- `www/` — static website assets
- `README.md` — user documentation
- `TODO.md` — rough roadmap / scratchpad

## Agent harness (runtime)

```
stack[1] = MAIN frame (history + goal + steps; multi-turn; tool: subtask)
stack[2+] = isolated SUBTASK (history = goal only; steps in system prompt)

each frame.steps = completed sibling steps at that level
  { text = child goal, response = child outcome }

each request (ephemeral):
  system = base_prompt
         + granted / grantable tools
         + NOTES (shared pad)
         + LIVE CONTEXT (previous steps at this level; isolated only)
         + MCP Servers state

answer if the goal is fully addressed, else subtask one step.
notes is the shared channel between agents.
when a child returns, the parent is asked again.
it does not see the user's chat; its final text is the step response.
```

- Main tools: `subtask`, `notes`
- Child tools: those listed in `subtask.tools` (default: `subtask`, `notes`)
- Pass read/shell/edit for a one-shot leaf. Omit `tools` to make a coordinator.
- `run_tools` rejects names not on the frame allowlist (models can still hallucinate tools).
- Notes are global (one pad for the stack) and injected every turn for main and workers
- `notes` does not end a worker (briefing); work tools still end a leaf
- Isolated workers see sibling step reports via Live Context, not chat history
- Skills (Agent Skills spec): dirs under `~/.config/tai/skills/` and `<project>/.tai-skills/`, each with `SKILL.md`
  - Required frontmatter: `name` (1–64, `[a-z0-9-]+`, match dir name) + `description` (1–1024, non-empty)
  - Invalid skills are skipped; catalog = name+description; `skill` load injects markdown body only
- Max depth: 8
- No `todos` tool — progress is Goal + Previous steps in Live Context
- No `complete` tool — final assistant text or tool output is the handoff

## MCP

- Config: `.tai` → `mcps` map
- Local: `command` + `args` + optional `env`/`cwd`/`denylist`
- Remote: `url` + auth (`api_key` | `user`/`pass` | `oauthURL`+`oauth_token`) + `denylist`
- No Tool List Changed notifications, Roots, or Sampling
- Connected at startup; `mcp` tool for status/connect/disconnect/list_tools/call

## How to orient quickly (when debugging)

1. Entrypoint: `lua/tai/init.lua` → mcp connect, `ui.init` / `ui.continue`.
2. Config: `config.lua` (needs `.tai` walking up from cwd).
3. Request path:
   - prompts/frames: `agent.lua`
   - Live Context + MCP sections: `ui/core.lua` `prepare_messages`
   - tool execution: `ui/core.lua` `run_tools`
   - provider: `providers.lua`

## Common tasks

- **Add a new provider**
  - Extend `providers.lua`.
  - Update `README.md` and `www/index.html`.

- **Add/adjust a tool**
  - Schema in `lua/tai/tools.lua`.
  - Implementation under `lua/tai/tools/` (or inline).
  - Wire in `ui/core.lua` `run_tools`.
  - Update allowlists in `agent.lua` if subtasks may use it.
  - Update README / www.

- **Change system prompts**
  - `lua/tai/agent.lua` (`system_prompt`, `subtask_system_prompt`).
  - Inline editor actions: `lua/tai/inline.lua`.

- **Inline editor actions**
  - Keymaps live in the user's Neovim `init.lua`. The plugin does not bind keys.
  - `<leader>tv` sends a visual selection or a motion. `gP` asks for an instruction first.
  - Map `<C-X>` to `tai.ctrl_x` (`expr`). `<C-T>` completes at the cursor. `<C-A>` asks, then inserts the reply. Other `<C-X>` keys stay normal completion.
  - These calls set `no_tools` and `stateless` and do not enter planner history.

- **Provider-side tools (e.g. web_search)**
  - `.tai` field `provider_tools`.
  - Document in README / www.

## Development notes

- Prefer small, explicit Lua. Avoid new dependencies.
- Keep system prompts compact (small models).
- Live Context / MCP prompt sections must stay request-ephemeral (never append into history).
- Requires Neovim 0.10+ (`vim.uv`).
- No external HTTP/MCP libraries — use `vim.fn.jobstart` + curl + JSON-RPC.

(Agent reminder) You are editing the Tai plugin’s own code—double-check changes for regressions.
