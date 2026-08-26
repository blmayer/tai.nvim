local M = {}

local config = require("tai.config")
local skills = require("tai.skills")

if not config.root then
	return M
end

M.MAX_DEPTH = 8

local guide = [[
Coding guidelines

- Do the work. Do not stop at a plan or a promise.
- Do not assume what exists. List the project, then open what you find.
- Decide only from tool results, notes, and previous steps. Never guess paths.
- NOTES is the only shared memory. Write short facts others need (paths, names, findings). No plans or dumps.
- A child starts empty: it sees only its goal, NOTES, and previous steps at its level.
- Put every path, name, and constraint in the child's goal. Write durable facts to notes before you spawn.
- Grep to search (use -A/-B). Do not read a whole file to search.
- Read only a range; edit needs the previous content, not line numbers.
- Be efficient. Completely address the goal. No markdown, use ASCII.
- Use only tools you may call. If you need a tool you cannot call, subtask and grant that tool to the child.
]]

M.system_prompt = [[
You are the orchestrator for this project: ]] .. config.root .. [[

You cannot read, edit, or run commands. Your agents do the work.
You only reply to the user or call subtask.
- A child starts empty. It cannot see this chat. Put every path, name, and constraint in the goal. Write durable facts to notes before you spawn.
- Answer only when the request is fully addressed from notes or step reports. Do not invent.
- Otherwise subtask one concrete next step. Grant the child the tools that step needs (read/shell/edit), even if you cannot call them.
- If that step still needs more than one shot, also grant subtask.
- Notes is shared. No markdown, use ASCII.

]]

M.subtask_system_prompt = [[
You are an agent for this project: ]] .. config.root .. [[

Answer or call subtask:
- Do the goal. Answer only when it is fully done from notes, previous steps, or this turn.
- A child starts empty. Put every path, name, and constraint in its goal. Write durable facts to notes before you spawn.
- Use only tools you may call. Grant a child the tools it needs, even ones you cannot call.
- If you have read/shell/edit and the task is one shot, do the work. Do not subtask it.
- If the goal is simple but you cannot do it, say what is missing. Do not copy or rephrase it as a subtask.
- Otherwise subtask one smaller step. Give it the tools for that goal, not a copy of yours.
- If that step still needs more than one shot, also grant subtask.

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

-- Names a child may be granted.
M.subtask_tools = {
	"read", "shell", "send_image", "edit", "write", "notes", "subtask", "skill", "mcp",
}

-- Default child is a coordinator, like main. Work tools only if the parent lists them.
M.default_child_tools = {
	"subtask",
	"notes",
}

-- One-liners for the prompt. Schema text stays on the tool defs.
M.tool_blurb = {
	subtask = "spawn one smaller step; grant the child the tools that step needs",
	notes = "shared pad; write facts a child will need before you spawn",
	read = "open a file or line range",
	shell = "run a command in the project root",
	edit = "replace text in a file",
	write = "create a file",
	send_image = "send an image for the model to see",
	skill = "list/load/unload Agent Skills",
	mcp = "status/connect/call MCP tools",
}

local subtask_tool_set = {}
for _, name in ipairs(M.subtask_tools) do
	subtask_tool_set[name] = true
end

function M.tool_granted(tools, name)
	if type(name) ~= "string" or name == "" or type(tools) ~= "table" then
		return false
	end
	for _, t in ipairs(tools) do
		if t == name then
			return true
		end
	end
	return false
end

local function tool_line(name)
	local blurb = M.tool_blurb[name]
	if blurb then
		return "- " .. name .. ": " .. blurb
	end
	return "- " .. name
end

--- Compact catalog for the system prompt: granted tools, plus grantable
--- names when this frame has `subtask`.
function M.render_tools(tools)
	if type(tools) ~= "table" or #tools == 0 then
		return ""
	end
	local lines = { "You may call only:" }
	local granted = {}
	for _, name in ipairs(tools) do
		granted[name] = true
		table.insert(lines, tool_line(name))
	end
	if granted.subtask then
		table.insert(lines, "A child can be given any of these, including ones you cannot call:")
		for _, name in ipairs(M.subtask_tools) do
			table.insert(lines, tool_line(name))
		end
	end
	return table.concat(lines, "\n")
end

-- Keep known names; if none survive, use the coordinator default.
function M.sanitize_subtask_tools(tools)
	local out = {}
	if type(tools) == "table" then
		for _, name in ipairs(tools) do
			if subtask_tool_set[name] then
				table.insert(out, name)
			end
		end
	end
	if #out == 0 then
		return vim.deepcopy(M.default_child_tools)
	end
	return out
end

--- Build a new agent frame.
--- opts: profile ("main"|"subtask"), system_prompt?, tools?, goal?,
---       steps?, depth?, parent_call_id?
function M.new_frame(opts)
	opts = opts or {}

	local is_sub = opts.profile == "subtask"
	local system = opts.system_prompt
		or (is_sub and M.subtask_system_prompt or M.system_prompt)

	local tool_list = is_sub
		and M.sanitize_subtask_tools(opts.tools)
		or (opts.tools or M.main_tools)

	local frame = {
		label = is_sub and "SUBTASK" or "MAIN",
		system_prompt = system,
		tools = tool_list,
		history = { { role = "system", content = system } },
		goal = opts.goal,
		steps = vim.deepcopy(opts.steps or {}),
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
