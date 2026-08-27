local M = {}

local log = require("tai.log")
local config = require("tai.config")
local agent = require("tai.agent")
local context = require("tai.context")
local tools_io = require("tai.tools.io")
local tools_shell = require("tai.tools.shell")
local tools_edit = require("tai.tools.edit")
local tools_subtask = require("tai.tools.subtask")
local tools_plan = require("tai.tools.plan")
local tools_changes = require("tai.tools.changes")
local tools_skill = require("tai.tools.skill")
local tools_mcp = require("tai.tools.mcp")
local nest = require("tai.ui.nest")
local mcp = require("tai.mcp")

if not config.provider then
	return M
end

local providers_factory = require("tai.providers")
local provider = providers_factory.get_provider(config.provider)

local chat_win
local input_win
local bufname_prefix = "tai-chat"
local input_bufname = "tai-chat-input"

-- Agent stack: main frame at [1], optional subtask on top
local stack = { agent.new_frame() }

local hard_stop = false
local pending_tools = nil
local current_job = nil
local current_state = "idle" -- idle | waiting | throttled | thinking | tools

local function top()
	return stack[#stack]
end

local function is_worker()
	return #stack > 1
end

-- Nesting: MAIN is 0, first subtask is 1, its child is 2, …
local function nest_depth(frame)
	if frame and frame.depth and frame.depth > 0 then
		return frame.depth
	end
	return math.max(0, #stack - 1)
end

local function nest_label(frame)
	local d = nest_depth(frame)
	if d < 1 then
		return "MAIN"
	end
	if frame and frame.label and frame.label ~= "SUBTASK" then
		return frame.label
	end
	return string.format("SUBTASK %d", d)
end

-- Keep collapsed fold text aligned with the subtask indent.
-- Regular leading spaces are stripped from foldtext; use NBSP.
_G.TaiChatFoldText = function()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent = (line:match("^(%s*)") or ""):gsub(" ", "\194\160")
	local inner = line:match("%{%{%{%s*(.*)$") or ""
	inner = inner:gsub("%s+$", "")
	if inner == "" then
		inner = tostring(vim.v.foldend - vim.v.foldstart + 1) .. " lines"
	end
	return indent .. "{{{ " .. inner .. " }}}"
end

local function apply_fold_settings(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	-- Only tool output is folded (plain {{{ / }}}).
	-- High foldlevel: buffer edits must not re-close folds the user opened.
	vim.wo[win].foldmethod = "marker"
	vim.wo[win].foldtext = "v:lua.TaiChatFoldText()"
	vim.wo[win].foldenable = true
	vim.wo[win].foldlevel = 99
	vim.wo[win].wrap = true
	vim.wo[win].breakindent = true
	pcall(function()
		vim.wo[win].fillchars = "fold: "
	end)
end

-- Close only the newest tool fold. Leave folds the user opened alone,
-- and do not move their cursor.
local function refresh_and_close_folds()
	if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
		return
	end
	vim.api.nvim_win_call(chat_win, function()
		if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
			return
		end
		local lines = vim.api.nvim_buf_get_lines(M.buffer_nr, 0, -1, false)
		local start
		for i = #lines, 1, -1 do
			if lines[i]:find("{{{", 1, true) then
				start = i
				break
			end
		end
		if not start then
			return
		end
		local view = vim.fn.winsaveview()
		pcall(function()
			vim.api.nvim_win_set_cursor(chat_win, { start, 0 })
			vim.cmd("silent! normal! zc")
		end)
		pcall(vim.fn.winrestview, view)
	end)
end

-- Keep {{{ / }}} inside old/new text from closing the chat fold early.
local function fold_safe(s)
	if type(s) ~= "string" or s == "" then
		return "(empty)"
	end
	return (s:gsub("}}}", "} } }"):gsub("{{{", "{ { {"))
end

local function mark_last_fold_failed()
	if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(M.buffer_nr, 0, -1, false)
	for i = #lines, 1, -1 do
		if lines[i]:find("{{{", 1, true) then
			if not lines[i]:find("%[failed%]") then
				local updated = lines[i]:gsub("%s*$", "") .. " [failed]"
				vim.api.nvim_buf_set_lines(M.buffer_nr, i - 1, i, false, { updated })
			end
			return
		end
	end
end

local function append_output(label, body, depth, failed)
	if failed and label and label ~= "" and not label:find("%[failed%]") then
		label = label .. " [failed]"
	end
	local head = (label and label ~= "") and ("{{{ " .. label) or "{{{"
	local text = head .. "\n"
	if body and body ~= "" then
		text = text .. fold_safe(body) .. "\n"
	end
	text = text .. "}}}\n"
	M.append(text, depth)
	refresh_and_close_folds()
end

local function format_edit_fold(old_text, new_text, result)
	local parts = {
		"old:",
		fold_safe(old_text),
		"",
		"new:",
		fold_safe(new_text),
	}
	if result and result ~= "" then
		table.insert(parts, "")
		table.insert(parts, result)
	end
	return table.concat(parts, "\n")
end

local function worker_history(frame)
	local goal = tools_subtask.frame_goal(frame)
	local hist = { { role = "system", content = frame.system_prompt or "" } }
	if goal ~= "" then
		table.insert(hist, { role = "user", content = goal })
	end
	return hist
end

local function prepare_messages(frame)
	-- Isolated coordinators start from scratch: system + goal only.
	-- Coders keep tool history so they can take more than one turn.
	local msgs
	if frame.isolated and not agent.iterates(frame) then
		msgs = worker_history(frame)
	else
		msgs = vim.deepcopy(frame.history)
	end
	if msgs[1] and msgs[1].role == "system" then
		local parts = { agent.prompt_for(frame.role, frame.phase) }
		local tool_section = agent.render_tools(frame.tools)
		if tool_section ~= "" then
			table.insert(parts, tool_section)
		end
		local notes = tools_subtask.render_notes()
		if notes ~= "" then
			table.insert(parts, notes)
		end
		local task_notes = tools_plan.render_task_notes(frame.task_notes)
		if task_notes ~= "" then
			table.insert(parts, task_notes)
		end
		local plan_section = tools_plan.render_for(frame)
		if plan_section ~= "" then
			table.insert(parts, plan_section)
		end
		if frame.role == "orchestrator" then
			if frame.phase == "decompose" then
				table.insert(parts, "Here is the goal. Analyse it and answer if you should split it into smaller tasks.\n"
					.. "Write a plan of children, or say this is a leaf.")
			elseif frame.phase == "revise" then
				table.insert(parts, "Last task: " .. tostring(frame.last_child_goal or "")
					.. "\n\nOutput:\n" .. tostring(frame.last_child_report or "(no output)")
					.. "\n\nHere is the plan. Analyse it and answer if you need to update later items."
					.. " Copy useful discoveries from the output into notes.")
			elseif frame.phase == "handoff" then
				table.insert(parts, "Nothing is pending. Reply with the result of your goal. Include short discoveries from the reports.")
			end
		end
		if frame.isolated then
			local live = tools_subtask.render_memory(frame)
			if live ~= "" then
				table.insert(parts, live)
			end
		end
		local mcp_section = mcp.render_prompt_section()
		if mcp_section ~= "" then
			table.insert(parts, table.concat({
				"========== MCP ==========",
				mcp_section,
				"========== END MCP ==========",
			}, "\n"))
		end
		-- Single system message (providers that allow only one); never stored in history.
		msgs[1].content = table.concat(parts, "\n\n")
	end
	return msgs
end

local function frame_config(frame)
	local cfg = vim.deepcopy(config)
	cfg.tools = frame.tools
	return cfg
end

local function get_agent_ctx()
	local hist = top().history
	for i = #hist, 1, -1 do
		local msg = hist[i]
		if msg and type(msg.token_usage) == "number" then
			return msg.token_usage
		end
	end
	return nil
end

local function update_input_name()
	local current_ctx = get_agent_ctx()
	local stats = providers_factory.get_rate_limits()
	local rate_part = string.format("%d req/min, %d tokens/min", stats.requests or 0, stats.tokens or 0)
	local name
	if current_ctx then
		name = string.format("%s (ctx: %u | %s)", input_bufname, current_ctx, rate_part)
	else
		name = string.format("%s (%s)", input_bufname, rate_part)
	end
	if M.input_buffer_nr and vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.input_buffer_nr, name)
	end
end

providers_factory.on_throttle = function()
	vim.schedule(function()
		current_state = "throttled"
		update_input_name()
	end)
end

local function strip_restore_banners(lines)
	local out = {}
	local i = 1
	while i <= #lines do
		local line = lines[i]
		if type(line) == "string" and line:match("^%[tai%] Restored session") then
			i = i + 1
			if lines[i] == "" then
				i = i + 1
			end
		else
			table.insert(out, line)
			i = i + 1
		end
	end
	while out[1] == "" do
		table.remove(out, 1)
	end
	return out
end

local function get_chat_lines()
	if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
		return {}
	end
	return strip_restore_banners(vim.api.nvim_buf_get_lines(M.buffer_nr, 0, -1, false))
end

local function save_session()
	if not config.context or not config.context.enabled then
		return
	end
	local ok = context.save({
		stack = stack,
		notes = tools_subtask.get_notes(),
		last_ctx = get_agent_ctx(),
		chat_lines = get_chat_lines(),
	}, config.context)
	if not ok then
		log.warning("[persist] save_session failed")
	end
end

local function maybe_auto_save()
	if config.context and config.context.enabled and config.context.auto_save then
		save_session()
	end
end

function M.init()
	-- Idempotent: plugin/tai.lua and user init.lua may both call setup().
	if M.input_buffer_nr and vim.api.nvim_buf_is_valid(M.input_buffer_nr)
		and M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		M.update_chat_name()
		update_input_name()
		return
	end

	M.input_buffer_nr = vim.api.nvim_create_buf(true, false)
	-- Unique name avoids E95 if a prior ghost buffer still holds "tai-chat-input"
	pcall(vim.api.nvim_buf_set_name, M.input_buffer_nr, input_bufname)
	vim.bo[M.input_buffer_nr].buftype = "nofile"
	vim.bo[M.input_buffer_nr].bufhidden = "hide"
	vim.bo[M.input_buffer_nr].swapfile = false
	vim.bo[M.input_buffer_nr].filetype = "text"
	vim.bo[M.input_buffer_nr].modifiable = true

	M.buffer_nr = vim.api.nvim_create_buf(false, true)
	vim.bo[M.buffer_nr].buftype = "nofile"
	vim.bo[M.buffer_nr].bufhidden = "hide"
	vim.bo[M.buffer_nr].swapfile = false
	vim.bo[M.buffer_nr].modifiable = true
	vim.bo[M.buffer_nr].filetype = "text"

    -- Load session history
    local chat_lines = context.load()
    if chat_lines and #chat_lines > 0 then
      vim.api.nvim_buf_set_lines(M.buffer_nr, -1, -1, false, chat_lines)
    else
      print("[DEBUG] No chat_lines to append or chat_lines is empty")
    end

	if not config.stream then
		vim.keymap.set("i", "}", function()
			if vim.wo.foldmethod ~= "marker" then
				return "}"
			end
			local line = vim.fn.getline(".")
			local c = vim.fn.col(".")
			local new_line = line:sub(1, c - 1) .. "}" .. line:sub(c)
			if new_line:match("}}}%s*$") then
				local tc = vim.api.nvim_replace_termcodes
				return "}" .. tc("<C-o>zx<C-o>zc", true, false, true)
			end
			return "}"
		end, { buffer = M.buffer_nr, expr = true, noremap = true })
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("TaiUiCleanup", { clear = true }),
		callback = function()
			if config.context and config.context.enabled and config.context.save_on_shutdown then
				save_session()
			end
			pcall(mcp.disconnect_all)
			if vim.api.nvim_buf_is_valid(M.buffer_nr) then
				vim.api.nvim_buf_delete(M.buffer_nr, { force = true })
			end
			if vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
				vim.api.nvim_buf_delete(M.input_buffer_nr, { force = true })
			end
		end,
	})
	vim.keymap.set("n", "<CR>", M.send_input, { buffer = M.input_buffer_nr })
	vim.keymap.set("i", "<S-CR>", M.send_input, { buffer = M.input_buffer_nr })

	M.update_chat_name()
	update_input_name()
end

function M.append(content, depth)
	if content == nil or content == vim.NIL then
		return
	end
	if type(content) ~= "string" then
		content = tostring(content)
	end
	if depth == nil then
		depth = nest_depth(top())
	end
	local function do_append()
		if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
			return
		end
		local last = vim.api.nvim_buf_get_lines(M.buffer_nr, -2, -1, false)
		local last_line = last and last[1] or ""
		local merged = nest.apply(content, depth, last_line)
		local lines = vim.split(merged, "\n", { plain = true })
		local line_num = vim.api.nvim_buf_line_count(M.buffer_nr)
		if not last[1] then
			vim.api.nvim_buf_set_lines(M.buffer_nr, 0, 0, false, lines)
		else
			vim.api.nvim_buf_set_lines(M.buffer_nr, line_num - 1, line_num, false, lines)
		end
	end
	if vim.in_fast_event() then
		vim.schedule(do_append)
	else
		do_append()
	end
end

function M.update_chat_name()
	local fr = top()
	local role = nest_label(fr)
	local state_part = current_state or "idle"
	local name
	if config and config.provider and config.model then
		name = string.format("%s (%s/%s - %s) [%s]", bufname_prefix, config.provider, config.model, role, state_part)
	else
		name = string.format("%s %s [%s]", bufname_prefix, role, state_part)
	end
	if M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.buffer_nr, name)
	end
end

function M.update_input_name()
	update_input_name()
end

function M.focus_input()
	vim.schedule(function()
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("startinsert")
	end)
end

local function scroll_down()
	vim.schedule(function()
		if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
			return
		end
		local current_win = vim.api.nvim_get_current_win()
		if current_win == chat_win then
			local cursor_line = vim.api.nvim_win_get_cursor(chat_win)[1]
			local last_line = vim.api.nvim_buf_line_count(M.buffer_nr)
			if cursor_line < last_line - 2 then
				return
			end
		end
		local original_win = current_win
		vim.api.nvim_set_current_win(chat_win)
		local scroll_cmd = "normal! zz"
		if input_win and vim.api.nvim_win_is_valid(input_win) then
			scroll_cmd = "normal! z-"
		end
		vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(M.buffer_nr), 0 })
		vim.cmd(scroll_cmd)
		vim.api.nvim_set_current_win(original_win)
	end)
end

local function add_sep(title, depth)
	local width = 80
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		width = vim.api.nvim_win_get_width(chat_win)
	end
	local result = title
	for _ = 1, math.max(0, width - #title) do
		result = result .. "_"
	end
	M.append("\n" .. result .. "\n", depth)
end

local function run_live_shell(command, on_done, depth)
	local chunks = {}
	local shell = vim.o.shell or "sh"
	local flag = vim.o.shellcmdflag or "-c"
	local finished = false
	local stop_timer = nil

	local function finish(out, code)
		if finished then
			return
		end
		finished = true
		current_job = nil
		if stop_timer then
			pcall(function()
				stop_timer:stop()
				stop_timer:close()
			end)
			stop_timer = nil
		end
		vim.schedule(function()
			on_done(out, code or 0)
		end)
	end

	local job_opts = {
		on_stdout = function(_, data, _)
			if not data then
				return
			end
			local text = table.concat(data, "\n")
			if text ~= "" then
				M.append(text, depth)
				table.insert(chunks, text)
			end
		end,
		on_stderr = function(_, data, _)
			if not data then
				return
			end
			local text = table.concat(data, "\n")
			if text ~= "" then
				M.append(text, depth)
				table.insert(chunks, text)
			end
		end,
		on_exit = function(_, code, _)
			local full = table.concat(chunks, "")
			if (code or 0) ~= 0 then
				full = full .. "\n[exit " .. tostring(code or 0) .. "]"
			end
			finish(full, code)
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	}
	-- Tool contract: shell starts in project root (where .tai was found).
	if config.root and config.root ~= "" then
		job_opts.cwd = config.root
	end
	-- List form: argv is not re-parsed by an outer shell (avoids double-quoting).
	-- {shell, flag, script} is one -c argument; nested quotes in `command` are preserved.
	local job = vim.fn.jobstart({ shell, flag, command .. " 2>&1" }, job_opts)

	current_job = job
	if job <= 0 then
		finish("Failed to start: " .. command, 1)
		return
	end

	stop_timer = vim.uv.new_timer()
	stop_timer:start(100, 100, vim.schedule_wrap(function()
		if finished then
			return
		end
		if hard_stop then
			log.info("[UI] hard_stop: stopping shell job " .. tostring(job))
			pcall(vim.fn.jobstop, job)
		end
	end))
end

local function stringify_tool_content(content)
	if content == nil or content == vim.NIL then
		return ""
	end
	if type(content) == "string" then
		return content
	end
	return vim.inspect(content)
end

local function record_tool_output(frame, content)
	if not frame or not is_worker() then
		return
	end
	frame.tool_outputs = frame.tool_outputs or {}
	local text = stringify_tool_content(content)
	if text == "" then
		return
	end
	table.insert(frame.tool_outputs, text)
end

local function reset_worker(frame, goal)
	frame.goal = goal
	frame.tool_outputs = {}
	frame.last_assistant = nil
	frame.last_outcome = nil
	frame._printed_content = nil
	frame.continue_after_tools = false
	frame.turns = 0
	frame.last_tool_ok = nil
	frame.history = worker_history(frame)
end

local print_plan

local function return_to_parent(frame, status, outcome)
	local close_depth = nest_depth(frame)
	if close_depth > 0 then
		close_depth = close_depth - 1
	end
	add_sep("___ END ", close_depth)
	if top() == frame then
		table.remove(stack)
	end
	local report = tools_subtask.format_complete(status, outcome, frame)
	local parent = top()
	if parent then
		parent.steps = parent.steps or {}
		local label = frame.goal or ""
		if type(frame.goals) == "table" and #frame.goals > 1 then
			label = table.concat(frame.goals, "; ")
		end
		table.insert(parent.steps, {
			text = label,
			response = report,
			status = status,
		})
		if frame.plan_step then
			tools_plan.mark(parent, frame.plan_step, status, outcome)
		end
		if parent.role == "orchestrator" then
			parent.phase = "revise"
			parent.last_child_report = report
			parent.last_child_goal = frame.goal
			parent._needs_revise = true
		end
	end
	M.update_chat_name()
	update_input_name()
	maybe_auto_save()
	if frame.on_parent_resume then
		local resume = frame.on_parent_resume
		frame.on_parent_resume = nil
		resume(report)
		return true
	end
	if parent and frame.parent_call_id and not parent.isolated then
		table.insert(parent.history, {
			role = "tool",
			name = "subtask",
			tool_call_id = frame.parent_call_id,
			content = report,
		})
	end
	return true
end

local function queue_report(frame)
	local parts = {}
	for i, r in ipairs(frame.goal_reports or {}) do
		table.insert(parts, i .. ". " .. tostring(r.text or "") .. "\n" .. tostring(r.response or ""))
	end
	if #parts == 0 then
		return frame.last_outcome or "(no output)"
	end
	return table.concat(parts, "\n\n")
end

local spawn_validator
local after_goal_ok
local finish_validator
local after_orchestrator_turn
local start_plan_child

local function append_child_header(parent, child, step)
	local depth = nest_depth(parent)
	local child_depth = #stack
	local head = child.label or "SUBTASK"
	local goal = child.goal or ""
	if step then
		M.append(string.format("%s %s [%s]\n", head, goal, tostring(step)), depth)
	else
		M.append(head .. " " .. goal .. "\n", depth)
	end
	if child.tools and #child.tools > 0 then
		M.append("tools: " .. table.concat(child.tools, ", ") .. "\n", child_depth)
	end
end

print_plan = function(frame, why)
	if not frame then
		return
	end
	local body = tools_plan.render_for(frame)
	if body == "" then
		return
	end
	local title = "PLAN"
	if why and why ~= "" then
		title = "PLAN " .. why
	end
	M.append(title .. "\n" .. body .. "\n", nest_depth(frame))
end

start_plan_child = function(parent, step, item, resume)
	item = item or (step and tools_plan.item(parent, step))
	if not item then
		return false
	end
	local role = agent.parse_role(item.agent, { profile = "subtask", tools = item.tools })
	local child = agent.new_frame({
		profile = "subtask",
		role = role,
		tools = role == "orchestrator" and nil or item.tools,
		goal = item.goal,
		depth = #stack,
		task_notes = item.notes or "",
		plan_step = step,
		plan_root = parent.plan_root or parent.plan,
		plan_path = step and tools_plan.child_path(parent, step) or (parent.plan_path or {}),
		phase = role == "orchestrator" and "decompose" or nil,
	})
	if step then
		tools_plan.mark(parent, step, "running")
	end
	append_child_header(parent, child, step)
	child.on_parent_resume = resume or function(report)
		parent.phase = "revise"
		parent.last_child_report = report
		parent.last_child_goal = child.goal
		M.continue()
	end
	table.insert(stack, child)
	M.update_chat_name()
	update_input_name()
	maybe_auto_save()
	M.continue()
	return true
end

after_orchestrator_turn = function(frame, text)
	local step, item = tools_plan.next_pending(frame)
	if step then
		frame.phase = "run"
		return start_plan_child(frame, step, item)
	end
	if frame.phase == "decompose" then
		frame.phase = "run"
		local leaf = {
			agent = "coder",
			goal = frame.goal or tools_subtask.frame_goal(frame),
			notes = frame.task_notes or "",
			tools = vim.deepcopy(agent.coder_tools),
			status = "pending",
		}
		return start_plan_child(frame, nil, leaf)
	end
	if is_worker() then
		if text and not agent.weak_phase_reply(text) then
			frame.phase = "handoff"
			frame.last_outcome = text
			return spawn_validator(frame, text)
		end
		frame.phase = "handoff"
		M.continue()
		return true
	end
	frame.phase = nil
	current_state = "idle"
	update_input_name()
	maybe_auto_save()
	return false
end

after_goal_ok = function(frame)
	frame.goal_reports = frame.goal_reports or {}
	table.insert(frame.goal_reports, {
		text = frame.goal,
		response = frame.last_outcome or "",
	})
	frame.steps = frame.steps or {}
	table.insert(frame.steps, {
		text = frame.goal,
		response = frame.last_outcome or "",
		status = "ok",
	})
	local idx = frame.goal_index or 1
	local goals = frame.goals or { frame.goal }
	if idx < #goals then
		frame.goal_index = idx + 1
		frame.validate_retries = 0
		local next_goal = goals[frame.goal_index]
		local parent_depth = math.max(0, nest_depth(frame) - 1)
		local n = #goals
		M.append(string.format("%s %s (%d/%d)\n", frame.label or "CODER", next_goal, idx + 1, n), parent_depth)
		if frame.tools and #frame.tools > 0 then
			M.append("tools: " .. table.concat(frame.tools, ", ") .. "\n", nest_depth(frame))
		end
		reset_worker(frame, next_goal)
		M.update_chat_name()
		maybe_auto_save()
		M.continue()
		return true
	end
	return return_to_parent(frame, "ok", queue_report(frame))
end

spawn_validator = function(subject, outcome)
	if #stack >= (agent.MAX_DEPTH or 8) then
		return after_goal_ok(subject)
	end
	tools_changes.collect_shell(subject, config.root)
	local child = agent.new_frame({
		profile = "subtask",
		role = "validator",
		goal = tools_subtask.validator_brief(
			subject.goal,
			outcome,
			tools_changes.render(subject),
			tools_changes.render_commands(subject)
		),
		tools = {},
		depth = #stack,
		task_notes = subject.task_notes,
	})
	M.append("VALIDATOR\n", nest_depth(subject))
	table.insert(stack, child)
	M.update_chat_name()
	update_input_name()
	maybe_auto_save()
	M.continue()
	return true
end

finish_validator = function(vframe, assistant_text)
	local text = assistant_text or ""
	if not vframe._printed_content and type(text) == "string" and text ~= "" then
		M.append("\n" .. text .. "\n", nest_depth(vframe))
	end
	if top() == vframe then
		table.remove(stack)
	end
	local subject = top()
	if not subject or subject.role == "validator" or #stack <= 1 then
		return false
	end
	local verdict, detail = tools_subtask.parse_verdict(text)
	if verdict == "ok" then
		return after_goal_ok(subject)
	end
	if verdict == "blocked" then
		local why = detail or "blocked"
		M.append("BLOCKED " .. why .. "\n", nest_depth(subject))
		local outcome = subject.last_outcome or ""
		if outcome ~= "" then
			outcome = "blocked: " .. why .. "\n\n" .. outcome
		else
			outcome = "blocked: " .. why
		end
		return return_to_parent(subject, "blocked", outcome)
	end
	subject.validate_retries = (subject.validate_retries or 0) + 1
	if subject.validate_retries > (agent.MAX_VALIDATE_RETRIES or 2) then
		M.append("validator retries exhausted\n", nest_depth(subject))
		return after_goal_ok(subject)
	end
	local goal = subject.original_goal or subject.goal
	if detail and tools_subtask.same_scope(goal, detail) then
		tools_subtask.apply_missing(subject, detail)
		M.append("RETRY " .. detail .. "\n", nest_depth(subject))
	else
		M.append("RETRY (stay on the Goal)\n", nest_depth(subject))
	end
	reset_worker(subject, goal)
	M.update_chat_name()
	maybe_auto_save()
	M.continue()
	return true
end

-- Worker is done: validate (unless this is the validator), then pop or retry.
local function finish_oneshot(frame, assistant_text, status)
	if not frame or #stack <= 1 then
		return false
	end
	if not status then
		if type(assistant_text) == "string" and assistant_text:match("^ERROR ") then
			status = "error"
		else
			status = "ok"
		end
	end
	if frame.role == "validator" then
		return finish_validator(frame, assistant_text)
	end
	if frame.last_tool_ok == false and tools_subtask.is_weak_reply(assistant_text or "") then
		M.append("tool failed; continuing\n", nest_depth(frame))
		M.continue()
		return true
	end
	if frame.role == "orchestrator"
		and (frame.phase == "decompose" or frame.phase == "revise") then
		return after_orchestrator_turn(frame, assistant_text)
	end
	local outcome = tools_subtask.outcome_for(frame, assistant_text)
	if not frame._printed_content and type(assistant_text) == "string" and assistant_text ~= "" then
		M.append("\n" .. assistant_text .. "\n", nest_depth(frame))
	end
	if status == "error" then
		return return_to_parent(frame, "error", outcome)
	end
	frame.last_outcome = outcome
	return spawn_validator(frame, outcome)
end

local function after_tool_round(frame, stop)
	maybe_auto_save()
	if hard_stop then
		if is_worker() then
			finish_oneshot(frame, "ERROR [stopped]: Stopped by user", "error")
		end
		return
	end
	if stop then
		return
	end
	if frame._needs_revise then
		frame._needs_revise = false
		frame.phase = "revise"
		M.continue()
		return
	end
	if frame.role == "orchestrator"
		and (frame.phase == "decompose" or frame.phase == "revise") then
		after_orchestrator_turn(frame, frame.last_assistant)
		return
	end
	-- A failed tool never ends a coder. They must see the error and retry.
	if agent.iterates(frame) and frame.last_tool_ok == false then
		M.continue()
		return
	end
	-- Coordinators end on work tools. Coders keep going until they reply
	-- with no tool call. Nested subtask / notes / plan set continue_after_tools.
	if is_worker() and not frame.continue_after_tools and not agent.iterates(frame) then
		finish_oneshot(frame, frame.last_assistant)
		return
	end
	if frame.isolated and not agent.iterates(frame) then
		frame.history = worker_history(frame)
	end
	M.continue()
end

local function decode_tool_args(raw)
	if type(raw) == "table" then
		return raw
	end
	if type(raw) ~= "string" or raw == "" then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if ok and type(decoded) == "table" then
		return decoded
	end
	if ok and type(decoded) == "string" then
		local ok2, decoded2 = pcall(vim.json.decode, decoded)
		if ok2 and type(decoded2) == "table" then
			return decoded2
		end
	end
	return {}
end

local function run_tools(tool_calls, frame, start_index, on_done)
	start_index = start_index or 1
	on_done = on_done or function() end
	local stop = false
	local history = frame.history
	local depth = nest_depth(frame)
	frame.continue_after_tools = false

	if start_index == 1 then
		M.append("\n", depth)
	end

	local function process_from(i)
		if hard_stop then
			on_done(true)
			return
		end

		local calls = tool_calls or {}
		if i > #calls then
			on_done(stop)
			return
		end

		local call = calls[i]
		log.debug("[UI] running tool: " .. vim.inspect(call))
		local name = call["function"].name
		local args = decode_tool_args(call["function"].arguments)

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id,
		}

		local function finish_one()
			record_tool_output(frame, res.content)
			table.insert(history, res)
			if stop then
				on_done(true)
				return
			end
			process_from(i + 1)
		end

		local function note_call(summary, failed)
			if type(summary) == "string" and summary ~= "" then
				tools_changes.record_command(frame, summary, failed)
			end
		end

		frame.last_tool_ok = true

		if not agent.tool_granted(frame.tools, name) then
			local granted = table.concat(frame.tools or {}, ", ")
			if granted == "" then
				granted = "(none)"
			end
			res.content = "Tool `" .. tostring(name) .. "` is not granted. Granted: "
				.. granted .. ". Call subtask and pass the tool if a child needs it."
			append_output("tool denied: " .. tostring(name), res.content, depth, true)
			note_call(tostring(name), true)
			frame.last_tool_ok = false
			finish_one()
			return
		end

		if name == "shell" then
			local command = args.command
			if type(command) ~= "string" or command == "" then
				res.content = "missing command field"
				append_output("shell: missing command", res.content, depth, true)
				note_call("shell: missing command", true)
				frame.last_tool_ok = false
			else
				local unsafe = tools_shell.unsafe_command(command)
				if not unsafe or config.auto_approve then
					M.append("{{{ shell: " .. command .. "\n", depth)
					current_state = "tools"
					update_input_name()
					run_live_shell(command, function(out, code)
						res.content = tools_io.limit_output(out, "shell")
						local failed = (code or 0) ~= 0
						tools_changes.record_command(frame, command, failed)
						if failed then
							frame.last_tool_ok = false
							mark_last_fold_failed()
						end
						M.append((out or "") .. "\n}}}\n", depth)
						refresh_and_close_folds()
						finish_one()
					end, depth)
					return
				end
				local tcs = {}
				for j = i, #calls do
					table.insert(tcs, calls[j])
				end
				pending_tools = tcs
				M.append("Run `" .. command .. "`? (y/n/s) ", depth)
				M.focus_input()
				on_done(true)
				return
			end
		elseif name == "read" then
			if not args.file then
				res.content = "missing file field"
				append_output("read: missing file", res.content, depth, true)
				note_call("read: missing file", true)
				frame.last_tool_ok = false
			elseif vim.fn.filereadable(args.file) ~= 1 then
				res.content = "file does not exist or is not readable"
				append_output("read: " .. args.file, res.content, depth, true)
				note_call("read: " .. args.file, true)
				frame.last_tool_ok = false
			else
				local range_label = args.range and (" [" .. args.range .. "]") or ""
				res.content = tools_io.read_file(args.file, args.range)
				res.file_range = args.range
				local failed = type(res.content) == "string"
					and (res.content:match("^Error") or res.content:match("^Paths cannot")
						or res.content:match("^File `") or res.content:match("^Binary"))
				if failed then
					frame.last_tool_ok = false
				end
				note_call("read: " .. args.file .. range_label, failed)
				append_output("read: " .. args.file .. range_label, res.content, depth, failed)
			end
		elseif name == "edit" then
			if not args.file then
				res.content = "missing file field"
				append_output("edit: missing file", res.content, depth, true)
				note_call("edit: missing file", true)
				frame.last_tool_ok = false
			else
				local out = tools_edit.edit(args.file, args.old_text, args.new_text, args.multi, config)
				res.content = out
				local failed = type(out) == "string" and not out:match("^Patched")
				if failed then
					frame.last_tool_ok = false
				else
					tools_changes.record_edit(frame, args.file, args.old_text, args.new_text)
				end
				note_call("edit: " .. args.file, failed)
				append_output(
					"edit: " .. args.file,
					format_edit_fold(args.old_text, args.new_text, out),
					depth,
					failed
				)
			end
		elseif name == "write" then
			if not args.file then
				res.content = "missing file field"
				append_output("write: missing file", res.content, depth, true)
				note_call("write: missing file", true)
				frame.last_tool_ok = false
			elseif not args.content then
				res.content = "missing content field"
				append_output("write: " .. args.file, res.content, depth, true)
				note_call("write: " .. args.file, true)
				frame.last_tool_ok = false
			else
				local out = tools_subtask.write(args.file, args.content)
				res.content = out
				local failed = type(out) == "string" and not out:match("^File created")
				if failed then
					frame.last_tool_ok = false
				else
					tools_changes.record_write(frame, args.file, args.content)
				end
				note_call("write: " .. args.file, failed)
				append_output("write: " .. args.file, out, depth, failed)
			end
		elseif name == "subtask" then
			local first_sub
			for j, c in ipairs(calls) do
				local fn = c["function"] or {}
				if fn.name == "subtask" then
					first_sub = j
					break
				end
			end
			local step = tonumber(args.step)
			local plan_item
			if step then
				plan_item = tools_plan.item(frame, step)
			end
			local goals = agent.parse_goals(args.goal or args.Goal or args.task, args.goals)
			if plan_item and #goals == 0 then
				goals = { plan_item.goal }
			end
			local goal = goals[1]
			local parent_goal = tools_subtask.frame_goal(frame)
			local role_src = args.role or (plan_item and plan_item.agent)
			local role = agent.parse_role(role_src, { profile = "subtask", tools = args.tools })
			if first_sub and i ~= first_sub then
				res.content = "Only one subtask per turn. Wait for this step, then continue."
				append_output("subtask skipped", res.content, depth, true)
				note_call("subtask skipped", true)
			elseif step and not plan_item then
				res.content = "plan item " .. tostring(step) .. " not found. Write a plan first."
				append_output("subtask failed: no plan item " .. tostring(step), res.content, depth, true)
				note_call("subtask: no plan item " .. tostring(step), true)
			elseif not goal or goal == "" then
				res.content = "missing goal"
				append_output("subtask failed: no goal", res.content, depth, true)
				note_call("subtask: no goal", true)
			elseif parent_goal ~= "" and tools_subtask.same_goal(parent_goal, goal) then
				res.content = "goal must be a more specific next step, not a copy of the current Goal: "
					.. goal
				append_output("subtask failed: goal copies the current Goal", res.content, depth, true)
				note_call("subtask: " .. goal, true)
			elseif #stack >= (agent.MAX_DEPTH or 8) then
				res.content = "max subtask depth reached"
				append_output("subtask failed: max depth", res.content, depth, true)
				note_call("subtask: max depth", true)
			else
				local child_depth = #stack
				local child = agent.new_frame({
					profile = "subtask",
					role = role,
					system_prompt = args.system_prompt,
					tools = role == "orchestrator" and nil or args.tools,
					goal = goal,
					goals = goals,
					depth = child_depth,
					parent_call_id = call.id,
					task_notes = plan_item and plan_item.notes or "",
					plan_step = step,
					plan_root = frame.plan_root or frame.plan,
					plan_path = step and tools_plan.child_path(frame, step) or (frame.plan_path or {}),
				})
				if plan_item then
					tools_plan.mark(frame, step, "running")
				end
				local n = #(child.goals or {})
				local head = child.label or "SUBTASK"
				if n > 1 then
					M.append(string.format("%s %s (1/%d)\n", head, goal, n), depth)
				else
					M.append(head .. " " .. goal .. "\n", depth)
				end
				if child.tools and #child.tools > 0 then
					M.append("tools: " .. table.concat(child.tools, ", ") .. "\n", child_depth)
				end
				note_call("subtask: " .. goal, false)
				child.on_parent_resume = function(report)
					frame.continue_after_tools = true
					res.content = report
					finish_one()
				end
				table.insert(stack, child)
				M.update_chat_name()
				update_input_name()
				maybe_auto_save()
				M.continue()
				return
			end
		elseif name == "notes" then
			local out = tools_subtask.run_notes(args)
			res.content = out
			-- Notes is briefing, not work. Keep the worker so it can subtask next.
			frame.continue_after_tools = true
			local body = tools_subtask.get_notes()
			local notes_fail = type(out) == "string" and out:match("^Error")
			if body ~= "" then
				append_output("notes: " .. (args.action or "?"), body, depth, notes_fail)
			else
				append_output("notes: " .. (args.action or "?"), out, depth, notes_fail)
			end
			note_call("notes: " .. (args.action or "?"), notes_fail)
		elseif name == "plan" then
			local out = tools_plan.run(args, frame)
			res.content = out
			frame.continue_after_tools = true
			note_call("plan: " .. (args.action or "?"), type(out) == "string" and out:match("^Error"))
			if args.action == "write" or args.action == "update" then
				print_plan(frame, args.action)
			end
		elseif name == "skill" then
			local out = tools_skill.run(args)
			res.content = out
			append_output("skill: " .. (args.action or "?"), out, depth)
			note_call("skill: " .. (args.action or "?"), false)
		elseif name == "mcp" then
			local async_actions = { connect = true, call = true }
			if async_actions[args.action] then
				M.append("{{{ mcp: " .. (args.action or "?") .. "\n", depth)
				current_state = "tools"
				update_input_name()
				tools_mcp.run(args, function(out)
					res.content = tools_io.limit_output(out or "", "mcp")
					if type(out) == "string" and out:match("^Error") then
						frame.last_tool_ok = false
						mark_last_fold_failed()
					end
					note_call("mcp: " .. (args.action or "?"), type(out) == "string" and out:match("^Error"))
					M.append((out or "") .. "\n}}}\n", depth)
					refresh_and_close_folds()
					finish_one()
				end)
				return
			end
			local out = tools_mcp.run(args)
			res.content = out
			local mcp_fail = type(out) == "string" and out:match("^Error")
			append_output("mcp: " .. (args.action or "?"), out or "", depth, mcp_fail)
			note_call("mcp: " .. (args.action or "?"), mcp_fail)
		elseif name == "send_image" then
			if not args.file then
				res.content = "Missing file field"
				append_output("image: missing file", res.content, depth, true)
				note_call("image: missing file", true)
				frame.last_tool_ok = false
			else
				local image_url, err = tools_subtask.image_data_url(args.file)
				if not image_url then
					res.content = "Error: " .. err
					append_output("image: " .. args.file, res.content, depth, true)
					note_call("image: " .. args.file, true)
					frame.last_tool_ok = false
				else
					append_output("image: " .. args.file, args.prompt or "sent", depth)
					note_call("image: " .. args.file, false)
					local content = {}
					if args.prompt then
						table.insert(content, { type = "text", text = args.prompt })
					end
					table.insert(content, {
						type = "image_url",
						image_url = { url = image_url },
					})
					res.content = content
				end
			end
		else
			res.content = "Invalid tool name: " .. (name or "")
			append_output("invalid tool: " .. (name or ""), res.content, depth, true)
			note_call("invalid tool: " .. (name or ""), true)
			frame.last_tool_ok = false
		end

		finish_one()
	end

	process_from(start_index)
end

function M.send_input()
	if hard_stop then
		hard_stop = false
	end

	vim.schedule(function()
		scroll_down()
		local input = table.concat(vim.api.nvim_buf_get_lines(M.input_buffer_nr, 0, -1, false), "\n")
		vim.api.nvim_buf_set_lines(M.input_buffer_nr, 0, -1, false, {})
		if not input or input == "" then
			return
		end

		local frame = top()
		local history = frame.history

		if pending_tools and #pending_tools > 0 then
			local call = pending_tools[1]
			local args = decode_tool_args(call["function"].arguments)
			local res = {
				role = "tool",
				name = call["function"].name,
				tool_call_id = call.id,
			}
			local response = input:lower():gsub("^%s*(.-)%s*$", "%1")
			local depth = nest_depth(frame)
			M.append(input .. "\n", depth)

			local command = args.command
			if response == "y" or response == "yes" then
				M.append("Confirmed...\n", depth)
				M.append("{{{ shell: " .. tostring(command) .. "\n", depth)
				run_live_shell(command, function(out, code)
					res.content = tools_io.limit_output(out, "shell")
					local failed = (code or 0) ~= 0
					tools_changes.record_command(frame, command, failed)
					if failed then
						frame.last_tool_ok = false
						mark_last_fold_failed()
					end
					M.append((out or "") .. "\n}}}\n", depth)
					refresh_and_close_folds()
					record_tool_output(frame, res.content)
					table.insert(history, res)
					table.remove(pending_tools, 1)
					run_tools(pending_tools, frame, 1, function(stop)
						after_tool_round(frame, stop)
					end)
				end, depth)
				return
			elseif response == "s" or response == "stop" then
				append_output("shell: " .. tostring(command), "User stopped execution.", depth, true)
				hard_stop = true
				res.content = "User stopped execution."
				record_tool_output(frame, res.content)
				table.insert(history, res)
				table.remove(pending_tools, 1)
				if is_worker() then
					finish_oneshot(frame, "ERROR [stopped]: Stopped by user", "error")
				end
				maybe_auto_save()
				return
			else
				res.content = "User declined running this command: " .. input
				append_output("shell: " .. tostring(command), res.content, depth, true)
				record_tool_output(frame, res.content)
				table.insert(history, res)
				table.remove(pending_tools, 1)
				run_tools(pending_tools, frame, 1, function(stop)
					after_tool_round(frame, stop)
				end)
				return
			end
		else
			if not is_worker() then
				frame.goal = input
				frame.steps = {}
				frame.phase = "decompose"
			end
			table.insert(history, { role = "user", content = input })
			add_sep("___ USER ")
			M.append(input .. "\n")
		end

		add_sep("___ " .. nest_label(frame) .. " ")
		if frame.tools and #frame.tools > 0 then
			M.append("tools: " .. table.concat(frame.tools, ", ") .. "\n", nest_depth(frame))
		end
		maybe_auto_save()
		M.continue()
		update_input_name()
	end)
end

function M.stop()
	hard_stop = true
	if current_job then
		pcall(vim.fn.jobstop, current_job)
		current_job = nil
	end
	pcall(function()
		providers_factory.cancel_pending_waits()
	end)
	M.append("\n[tai] Stopped by user\n")
end

function M.open()
	vim.schedule(function()
		local chat_window_nr = vim.fn.bufwinnr(M.buffer_nr)
		if chat_window_nr == -1 then
			vim.cmd("vsplit")
			chat_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(chat_win, M.buffer_nr)
			vim.api.nvim_win_set_width(chat_win, 80)
			apply_fold_settings(chat_win)
			-- First show: collapse existing tool dumps. Later updates
			-- must not reset this, or user-opened folds slam shut.
			vim.api.nvim_win_call(chat_win, function()
				pcall(vim.cmd, "silent! normal! zM")
			end)

			vim.cmd("below split")
			input_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(input_win, M.input_buffer_nr)
			vim.api.nvim_win_set_height(input_win, 12)
		else
			chat_win = vim.fn.win_getid(chat_window_nr)
			local input_window_nr = vim.fn.bufwinnr(M.input_buffer_nr)
			if input_window_nr ~= -1 then
				input_win = vim.fn.win_getid(input_window_nr)
			end
		end
	end)
end

function M.toggle_chat_window()
	local winid = vim.fn.bufwinnr(M.buffer_nr)
	local input_winid = vim.fn.bufwinnr(M.input_buffer_nr)
	if winid ~= -1 then
		vim.api.nvim_win_close(chat_win, false)
		if input_winid ~= -1 then
			vim.api.nvim_win_close(input_win, false)
		end
	else
		M.open()
	end
end

function M.clear()
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, {})
	stack = { agent.new_frame({ profile = "main" }) }
	tools_subtask.set_notes("")
	pending_tools = nil
	pcall(function()
		providers_factory.cancel_pending_waits()
	end)
	if config.context and config.context.enabled then
		context.clear(config.context)
	end
	M.update_chat_name()
	update_input_name()
end

function M.continue()
	local frame = top()
	frame.turns = (frame.turns or 0) + 1
	if agent.iterates(frame) and frame.turns > (agent.MAX_CODER_TURNS or 12) then
		M.append("coder turn limit\n", nest_depth(frame))
		finish_oneshot(frame, frame.last_assistant or "(turn limit)", "ok")
		return
	end
	local hist = frame.history
	local cfg = frame_config(frame)
	local msgs = prepare_messages(frame)
	local agent_label = nest_label(frame)
	local out_depth = nest_depth(frame)

	current_state = "waiting"
	update_input_name()

	local function on_idle_no_tools(content)
		if frame.role == "orchestrator"
			and (frame.phase == "decompose" or frame.phase == "revise") then
			after_orchestrator_turn(frame, content)
			return
		end
		if frame.last_tool_ok == false and tools_subtask.is_weak_reply(content or "") then
			M.continue()
			return
		end
		if is_worker() then
			finish_oneshot(frame, content or "(no output)")
			return
		end
		current_state = "idle"
		update_input_name()
		maybe_auto_save()
	end

	local function handle_tools(tool_calls)
		current_state = "tools"
		update_input_name()
		local ok, err = pcall(run_tools, tool_calls, frame, 1, function(stop)
			after_tool_round(frame, stop)
		end)
		if not ok then
			log.error("[UI] run_tools failed: " .. tostring(err))
			M.append("tool error: " .. tostring(err) .. "\n", out_depth)
			if is_worker() then
				finish_oneshot(frame, "ERROR [tools]: " .. tostring(err), "error")
			else
				current_state = "idle"
				update_input_name()
			end
		end
	end

	if config.stream then
		log.info(agent_label .. " streaming")
		provider.request_stream(cfg, msgs, function(chunk, err)
			if err then
				current_state = "idle"
				update_input_name()
				M.append("ERROR: " .. err .. "\n", out_depth)
				return
			end
			if type(chunk) ~= "table" then
				return
			end
			if chunk.reasoning and #chunk.reasoning > 0 then
				current_state = "thinking"
				update_input_name()
				M.append(chunk.reasoning, out_depth)
			end
			if chunk.content and chunk.content ~= "" then
				if type(chunk.content) == "string" then
					M.append(chunk.content, out_depth)
					frame._printed_content = true
				end
			end
		end, function(data, err)
			if err then
				current_state = "idle"
				update_input_name()
				M.append("ERROR: " .. err .. "\n", out_depth)
				table.insert(hist, { role = "assistant", content = err })
				if is_worker() then
					finish_oneshot(frame, err, "error")
				end
				return
			end
			if type(data) ~= "table" then
				current_state = "idle"
				update_input_name()
				local msg = "ERROR [provider]: empty provider response"
				M.append(msg .. "\n", out_depth)
				table.insert(hist, { role = "assistant", content = msg })
				if is_worker() then
					finish_oneshot(frame, msg, "error")
				end
				maybe_auto_save()
				return
			end
			local response = { role = "assistant" }
			for k, v in pairs(data) do
				response[k] = v
			end
			frame.last_assistant = data.content
			table.insert(hist, response)
			if data.content and type(data.content) == "string" and data.content ~= "" then
				if not frame._printed_content then
					M.append(data.content .. "\n", out_depth)
					frame._printed_content = true
				else
					M.append("\n", out_depth)
				end
			end
			if data.token_usage then
				update_input_name()
			end
			if data.error then
				M.append("ERROR: " .. tostring(data.error) .. "\n", out_depth)
				if is_worker() then
					finish_oneshot(frame, "ERROR [provider]: " .. tostring(data.error), "error")
					return
				end
			end
			if not data.tool_calls or #data.tool_calls == 0 then
				on_idle_no_tools(data.content)
				return
			end
			handle_tools(data.tool_calls)
		end)
	else
		log.info(agent_label .. " request")
		provider.request(cfg, msgs, function(fields, err)
			if err then
				current_state = "idle"
				update_input_name()
				M.append("ERROR: " .. err .. "\n", out_depth)
				table.insert(hist, { role = "assistant", content = err })
				if is_worker() then
					finish_oneshot(frame, err, "error")
				end
				maybe_auto_save()
				return
			end
			if type(fields) ~= "table" then
				current_state = "idle"
				update_input_name()
				local msg = "ERROR [provider]: empty provider response"
				M.append(msg .. "\n", out_depth)
				table.insert(hist, { role = "assistant", content = msg })
				if is_worker() then
					finish_oneshot(frame, msg, "error")
				end
				maybe_auto_save()
				return
			end
			local response = { role = "assistant" }
			for k, v in pairs(fields) do
				response[k] = v
			end
			frame.last_assistant = fields.content
			table.insert(hist, response)
			M.open()

			if fields.token_usage then
				update_input_name()
			end
			if fields.error then
				M.append("ERROR: " .. tostring(fields.error) .. "\n", out_depth)
				if is_worker() then
					finish_oneshot(frame, "ERROR [provider]: " .. tostring(fields.error), "error")
					return
				end
			end
			if fields.content and fields.content ~= vim.NIL and fields.content ~= ""
				and type(fields.content) == "string" then
				M.append(fields.content .. "\n", out_depth)
				frame._printed_content = true
			end
			if not fields.tool_calls or #fields.tool_calls == 0 then
				on_idle_no_tools(fields.content)
				return
			end
			vim.schedule(function()
				handle_tools(fields.tool_calls)
			end)
		end)
	end
end

return M
