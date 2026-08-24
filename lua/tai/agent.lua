local M = {}

local config = require("tai.config")
local skills = require("tai.skills")

if not config.root then
	return M
end

M.MAX_DEPTH = 2

local tool_usage = [[
## Tool Usage

You can use tools to help on your task.

- Don't use `cat` for just reading files — use the `read` tool. Binary files
  are not supported; for images use `send_image`.
- Avoid repeating tool calls (e.g. reading the same file again is useless).
- Do NOT guess file paths — verify they exist before reading or editing.
- The shell tool already runs in the project root. ALWAYS use relative paths.
  Do NOT prefix commands with `cd` to the project (or any absolute path to it) —
  that is unnecessary and wasteful.
- Be EXTREMELY careful with destructive git commands (e.g. `git restore`).

### Progress Tracking (todos & notes)

Use `todos` and `notes` to stay organized. They are private to this agent and
their content is auto-injected every turn as Live Context (not stored in chat
history), so you always see current state without re-reading them.

1. **At the start**: `todos` add steps; `notes` write the overall goal/context.
2. **Before a step**: mark it `in_progress` (only one at a time).
3. **After a step**: mark it `done` immediately.
4. **After a discovery**: `notes` append (paths, decisions, errors).
5. **New work found**: `todos` add items rather than forgetting them.

### Subtasks

`subtask` delegates focused work with a clean history:

- The child cannot see your conversation — put all needed context in `goal`.
- Optionally seed the child with `notes` / `todos`.
- Optionally set `system_prompt` for a persona or constraints.
- Choose tools explicitly (minimal set):
  - Read-only: ["read", "shell", "send_image", "todos", "notes"]
  - Implementation: ["read", "shell", "send_image", "edit", "write", "todos", "notes"]
- The child's final text reply is returned as the tool result, plus its notes/todos.
- Subtasks cannot spawn further subtasks.

### MCP

Use the `mcp` tool for Model Context Protocol servers configured in `.tai`.
Actions: status, connect, disconnect, list_tools, call. Prefer `call` with the
server name, tool name, and arguments.
]]

M.system_prompt = [[
You are a software engineering agent. You have access to the project's
codebase in the current folder: ]] .. config.root .. [[

For general questions answer right away, else work by decomposing the goal into
smaller steps and work on them by following the instructions bellow:

1. Generate a first step towards the goal and write the todo as in_progress.
2. Call subtask to work on the todo item.
3. Upon receiving the response consider it carefully and plan the next step.
4. Update you notes if needed and add/update the todos with the next step toward the goal.
5. Goto 2 until the goal is reached.
6. Report to the user.

Keep in mind: NEVER work directly in tasks, always delegate the work to subtasks.
]]

M.subtask_system_prompt = [[
You are a focused agent working on a specific subtask. You have access to the
project's codebase in the current folder: ]] .. config.root .. [[

Current time is ]] .. os.date("%Y-%m-%d %H:%M:%S %Z") .. [[

## Guidelines

- Focus exclusively on the goal in the user message.
- Work systematically: explore → understand → act → verify.
- When done, respond with a clear report of what you found or accomplished.
  That report is returned to the calling agent (plus your notes/todos).
- Do NOT ask questions — you cannot talk to the user. Decide and document.
- Respect existing code style (tabs/spaces, indentation).
- If you have write tools, verify changes by reading them back.
- If blocked, report what you tried and what failed.
- Make sure you completed the goal. Only finish when you have nothing else to do.

]]

M.system_prompt = config.system_prompt or config.planner_system_prompt or M.system_prompt
if config.custom_prompt and config.custom_prompt ~= "" then
	M.system_prompt = M.system_prompt .. "\n" .. config.custom_prompt
end

-- Append skill catalog (compact listing) so the model knows what's available.
local catalog = skills.render_catalog()
if catalog ~= "" then
	M.system_prompt = M.system_prompt .. "\n\n" .. catalog
end

M.main_tools = {
	"read", "shell", "send_image", "edit", "write", "todos", "notes", "subtask", "skill", "mcp",
}

-- Allowed tools a parent may grant a subtask (never subtask itself).
M.subtask_tool_allowlist = {
	read = true,
	shell = true,
	send_image = true,
	edit = true,
	write = true,
	todos = true,
	notes = true,
	mcp = true,
}

function M.sanitize_subtask_tools(tools)
	local out = {}
	for _, name in ipairs(tools or {}) do
		if M.subtask_tool_allowlist[name] then
			table.insert(out, name)
		end
	end
	return out
end

--- Build a new agent frame.
--- opts: profile ("main"|"subtask"), system_prompt?, tools?, notes?, todos?, goal?, depth?, parent_call_id?
function M.new_frame(opts)
	opts = opts or {}

	local tool_list = opts.tools or M.main_tools

	local todos = {}
	local next_id = 1

	local frame = {
		system_prompt = opts.system_prompt,
		tools = tool_list,
		history = { { role = "system", content = opts.system_prompt } },
		notes = "",
		todos = todos,
		todos_next_id = next_id,
		depth = opts.depth or 0,
		parent_call_id = opts.parent_call_id,
	}
	if opts.goal and opts.goal ~= "" then
		table.insert(frame.history, { role = "user", content = opts.goal })
	end
	return frame
end

return M
