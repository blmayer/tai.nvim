# Tai project (agent notes)

Tai is a Neovim plugin (Lua) that integrates an LLM assistant into your coding workflow.
This repo also includes a small static website under `www/`.

These notes are intended for **automated coding agents** working in this repository.

## Repository layout

- `lua/tai/` — Neovim plugin implementation (all core logic)
  - `init.lua` — plugin entrypoint (`setup`, `chat`, `stop`, …); connects MCPs
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
stack[2+] = isolated SUBTASK (clean history, goal, tools, steps)

each frame.steps = completed sibling steps at that level
  { text = child goal, response = child outcome }

each request (ephemeral):
  system = base_prompt
         + MCP Servers state
         + CURRENT STATE: Goal + Previous steps

if you can answer, do it; else subtask until you can answer.
a worker iterates only after `subtask` returns (work tools end the turn).
it does not see the user's chat; its final text is the step response.
```

- Main tools: `subtask` only
- Child tools: those listed in `subtask.tools` (default: read/edit/shell/subtask/…)
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
