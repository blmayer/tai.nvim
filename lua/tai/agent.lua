local M = {}

local config = require("tai.config")
local skills = require("tai.skills")

if not config.root then
	return M
end

M.MAX_DEPTH = 8

local guide = [[
Follow this guide for working on tasks:

1. Decompose the task into smaller chunks that altogether solve the task.
2. Write a detailed plan to reach the goal in your notes.
3. Orchestrate with sub agents to perform and return what you want in a direct
   way in order to accomplish the user's request by calling `subtask`.
4. After each response analyze the info, the state and the goal then plan the
   next step towards the goal and update your notes.
5. Call `subtask` with the next step or answer the user if finished.

Coding guidelines

- Start by reading README.md and AGENTS.md files if present.
- Explore the codebase to find your way to the needed files, use find, ls etc.
- Use grep to search for code in files, use -A and -B to show surrounding lines.
- Be efficient, use commands well to reach your goal quickly without waste.
- To inspect files use the read tool and to edit use only the edit tool.
- Verify your changes are correct by re-reading the affected areas.
- Make sure you completely address the goal given.
]]

M.system_prompt = [[
You are the orchestrator for this project: ]] .. config.root .. [[

You cannot read, edit, or run commands. Your agents do the work.
You only reply to the user or call `subtask`.

Reply in text when no repo work is needed (greetings, simple Q&A).

]] .. guide

M.subtask_system_prompt = [[
You are an agent for this project: ]] .. config.root .. [[

Only finish after addressing the task completely or by being blocked. If your
task has more than one operation use subtasks. When you subtask you get a new
turn, else your turn ends with your text response or the tool call output.

]] .. guide

M.system_prompt = config.system_prompt or M.system_prompt
if config.custom_prompt and config.custom_prompt ~= "" then
	M.system_prompt = M.system_prompt .. "\n" .. config.custom_prompt
end

-- Append skill catalog (compact listing) so the model knows what's available.
local catalog = skills.render_catalog()
if catalog ~= "" then
	M.system_prompt = M.system_prompt .. "\n\n" .. catalog
end

M.main_tools = {
	"subtask",
	"notes",
}

M.subtask_tools = {
	"read", "shell", "send_image", "edit", "write", "notes", "subtask", "skill", "mcp",
}

function M.sanitize_subtask_tools(tools)
	local out = {}
	for _, name in ipairs(tools or {}) do
		if M.subtask_tools[name] then
			table.insert(out, name)
		end
	end
	return out
end

--- Build a new agent frame.
--- opts: profile ("main"|"subtask"), system_prompt?, tools?, goal?,
---       depth?, parent_call_id?
function M.new_frame(opts)
	opts = opts or {}

	local is_sub = opts.profile == "subtask"
	local system = opts.system_prompt
		or (is_sub and M.subtask_system_prompt or M.system_prompt)

	local tool_list
	if is_sub then
		tool_list = M.sanitize_subtask_tools(opts.tools)
		if #tool_list == 0 then
			tool_list = vim.deepcopy(M.subtask_tools)
		end
	else
		tool_list = opts.tools or M.main_tools
	end

	local frame = {
		label = is_sub and "SUBTASK" or "MAIN",
		system_prompt = system,
		tools = tool_list,
		history = { { role = "system", content = system } },
		notes = "",
		goal = opts.goal,
		steps = {},
		isolated = is_sub,
		depth = opts.depth or 0,
		parent_call_id = opts.parent_call_id,
		tool_outputs = {},
	}
	if opts.goal and opts.goal ~= "" then
		table.insert(frame.history, { role = "user", content = opts.goal })
	end
	return frame
end

return M
