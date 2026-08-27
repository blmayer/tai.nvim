local M = {}

local config = require("tai.config")
local skills = require("tai.skills")
local plan = require("tai.tools.plan")
local changes = require("tai.tools.changes")

if not config.root then
	return M
end

M.MAX_DEPTH = 8
M.MAX_VALIDATE_RETRIES = 2
M.MAX_CODER_TURNS = 12

M.ROLES = {
	orchestrator = true,
	coder = true,
	validator = true,
}

local guide = [[
Coding guidelines

- Do the work. Do not stop at a plan or a promise.
- Do not assume what exists. List the project, then open what you find.
- Decide only from tool results, notes, and previous steps. Never guess paths.
- Shared NOTES is for facts every agent needs. Each plan item has its own notes for that task only.
- A child starts empty: it sees its current goal, TASK NOTES, shared NOTES, and previous steps at its level.
- Grep to search (use -A/-B). Do not read a whole file to search.
- Read only a range; edit needs the previous content, not line numbers.
- Be efficient. Completely address the goal. No markdown, use ASCII.
- Use only tools you were given. Do not call subtask unless it is listed.
]]

M.system_prompt = [[
You are the orchestrator for this project: ]] .. config.root .. [[

You cannot read, edit, or run commands. Your tools are only subtask, notes, and plan.
You will receive a goal or a plan. Analyse it and decide the next step.
When the work is done, reply in text with no tool call.
No markdown, use ASCII.

]]

M.decompose_prompt = [[
You are the orchestrator for this project: ]] .. config.root .. [[

You cannot do the work. Tools: plan, notes.
You will receive a goal. Analyse it and answer if you should split it into smaller tasks.
- If it is already one action, say it is a leaf. Do not invent extra steps.
- If it needs several actions, write a plan of children.
  Each item: agent (coder or orchestrator), goal, notes, optional tools for a coder.
- Coders do one concrete action. Orchestrators own a subtree that still needs splitting.
- Then stop. Pending work will be run for you.

]]

M.revise_prompt = [[
You are the orchestrator for this project: ]] .. config.root .. [[

You cannot do the work. Tools: plan, notes.
You will receive a plan and the last task's output. Analyse them and answer if you need to update later items (goal, notes, agent, tools).
- Copy useful discoveries from the output into notes (shared NOTES, or later items' notes).
- Do not repeat a finished step. If something was blocked, change what comes next.
- If the plan is fine, say so.
- If nothing is left to run, reply with the result of your goal. Include short discoveries from the reports.

]]

M.coder_prompt = [[
You are a coder for this project: ]] .. config.root .. [[

Do this one goal. Do not plan the whole request. A validator will check your result.
- You get this task's goal and TASK NOTES. Use them. You do not see later plan items.
- You may take several turns (read, then grep, then edit). Keep going until the goal is done.
- When it is done, reply in text with no tool call. That reply is the handoff to the caller.
- The handoff is: what you did, then short discoveries later steps need (paths, names, facts). No file dumps.
- Use only tools you were given. Do not call subtask unless it is listed.
- If a path, file, or name in the goal does not exist, say so in the handoff (invalid premise). Do not invent other files or a different task.
- If the goal cannot be done, say why. Do not invent.

]] .. guide

M.validator_prompt = [[
You are the validator for this project: ]] .. config.root .. [[

Judge only. You have no tools. Do not solve the Goal. Do not invent work.
You will receive a Goal, a Result, Tools this agent called (no output), and Changes (this agent's edits only).
Decide only against that Goal. Do not invent new tool calls.
Reply with exactly one of:
ok
missing: <the undone part of the Goal, in the Goal's own words>
blocked: <a premise in the Goal is false>
- missing must quote or restate a piece of the Goal. No new commands, files, or tasks.
- If the Result says a path or name from the Goal does not exist, that is blocked, not missing.
- A plan or a promise is not ok.

]]

M.subtask_system_prompt = M.coder_prompt

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
	"plan",
}

-- Names a child may be granted.
M.subtask_tools = {
	"read", "shell", "send_image", "edit", "write", "notes", "plan", "subtask", "skill", "mcp",
}

-- Default child is a coordinator, like main. Work tools only if the parent lists them.
M.default_child_tools = {
	"subtask",
	"notes",
	"plan",
}

-- Coder with no tools listed can still inspect the repo.
M.coder_tools = {
	"read",
	"shell",
	"edit",
	"notes",
}

M.role_label = {
	orchestrator = "ORCHESTRATOR",
	coder = "CODER",
	validator = "VALIDATOR",
}

local work_tool = {
	read = true,
	shell = true,
	edit = true,
	write = true,
	send_image = true,
}

-- One-liners for the prompt. Schema text stays on the tool defs.
M.tool_blurb = {
	subtask = "spawn a plan step (step=N) or a one-off goal; grant the tools that step needs",
	notes = "shared pad for facts every agent needs",
	plan = "write or update the structured plan (agent, status, goal, notes per item)",
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

function M.parse_role(role, opts)
	opts = opts or {}
	if type(role) == "string" then
		role = role:lower():match("^%s*(.-)%s*$") or role
		if role == "manager" then
			role = "orchestrator"
		end
		if M.ROLES[role] then
			return role
		end
	end
	if opts.profile == "subtask" and type(opts.tools) == "table" then
		for _, name in ipairs(opts.tools) do
			if work_tool[name] then
				return "coder"
			end
		end
		return "orchestrator"
	end
	return "orchestrator"
end

function M.parse_goals(goal, goals)
	local out = {}
	local function add(g)
		if type(g) == "number" then
			g = tostring(g)
		end
		if type(g) == "string" then
			g = g:match("^%s*(.-)%s*$") or g
			if g ~= "" then
				table.insert(out, g)
			end
		end
	end
	if type(goals) == "table" then
		for _, g in ipairs(goals) do
			add(g)
		end
	end
	if #out == 0 then
		add(goal)
	end
	return out
end

function M.tools_for_role(role, tools)
	if role == "validator" then
		return {}
	end
	if role == "orchestrator" then
		return vim.deepcopy(M.main_tools)
	end
	local out = {}
	if type(tools) == "table" then
		for _, name in ipairs(tools) do
			if subtask_tool_set[name] then
				table.insert(out, name)
			end
		end
	end
	if #out > 0 then
		return out
	end
	if role == "coder" then
		return vim.deepcopy(M.coder_tools)
	end
	return vim.deepcopy(M.main_tools)
end

function M.iterates(frame)
	if not frame then
		return false
	end
	if frame.role == "coder" then
		return true
	end
	return frame.role == "orchestrator" and frame.isolated == true
end

function M.prompt_for(role, phase)
	if role == "coder" then
		return M.coder_prompt
	end
	if role == "validator" then
		return M.validator_prompt
	end
	if phase == "decompose" then
		return M.decompose_prompt
	end
	if phase == "revise" then
		return M.revise_prompt
	end
	return M.system_prompt
end

function M.weak_phase_reply(text)
	if type(text) ~= "string" then
		return true
	end
	local s = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return true
	end
	if s == "no" or s == "ok" or s == "yes" or s == "leaf" then
		return true
	end
	if s:match("^no[,%.]") or s:match("^ok[,%.]") then
		return true
	end
	if s:match("^it is a leaf") or s:match("^this is a leaf") or s:match("^looks good") then
		return true
	end
	if s:match("^do not update") or s:match("^no update") or s:match("^plan is fine") then
		return true
	end
	return false
end

--- Build a new agent frame.
--- opts: profile ("main"|"subtask"), role?, system_prompt?, tools?,
---       goal?, goals?, steps?, depth?, parent_call_id?
function M.new_frame(opts)
	opts = opts or {}

	local is_sub = opts.profile == "subtask"
	local role = is_sub and M.parse_role(opts.role, opts) or "orchestrator"
	local phase = opts.phase
	if not phase and role == "orchestrator" then
		phase = "decompose"
	end
	local system = opts.system_prompt or M.prompt_for(role, phase)
	local goals = M.parse_goals(opts.goal, opts.goals)
	local goal = goals[1]

	local tool_list = M.tools_for_role(role, is_sub and opts.tools or nil)
	if not is_sub then
		tool_list = vim.deepcopy(M.main_tools)
	end

	local root = opts.plan_root
	local path = opts.plan_path
	if type(root) ~= "table" then
		root = plan.sanitize(opts.plan)
		path = {}
	elseif type(path) ~= "table" then
		path = {}
	end

	local frame = {
		label = is_sub and (M.role_label[role] or "SUBTASK") or "MAIN",
		role = role,
		system_prompt = system,
		tools = tool_list,
		history = { { role = "system", content = system } },
		goal = goal,
		original_goal = goal,
		goals = goals,
		goal_index = 1,
		steps = vim.deepcopy(opts.steps or {}),
		isolated = is_sub,
		depth = opts.depth or 0,
		parent_call_id = opts.parent_call_id,
		tool_outputs = {},
		validate_retries = 0,
		turns = 0,
		plan = root,
		plan_root = root,
		plan_path = path,
		task_notes = opts.task_notes or "",
		plan_step = opts.plan_step,
		phase = phase,
		file_changes = {},
		changed_set = {},
		commands = {},
		git_dirty = (role == "coder") and changes.snapshot(config.root) or {},
	}
	if goal and goal ~= "" then
		table.insert(frame.history, { role = "user", content = goal })
	end
	return frame
end

return M
