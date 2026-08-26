local M = {}

local log = require("tai.log")
local config = require("tai.config")
local agent = require("tai.agent")
local context = require("tai.context")
local tools_io = require("tai.tools.io")
local tools_shell = require("tai.tools.shell")
local tools_edit = require("tai.tools.edit")
local tools_subtask = require("tai.tools.subtask")
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
	return string.format("SUBTASK %d", d)
end

-- Keep collapsed fold text aligned with the subtask indent.
-- Regular leading spaces are stripped from foldtext; use NBSP.
_G.TaiChatFoldText = function()
	local line = vim.fn.getline(vim.v.foldstart)
	local indent = (line:match("^(%s*)") or ""):gsub(" ", "\194\160")
	local n = vim.v.foldend - vim.v.foldstart + 1
	return indent .. "{{{ " .. tostring(n) .. " lines }}}"
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

local function append_output(label, body, depth)
	if label and label ~= "" then
		M.append(label .. "\n", depth)
	end
	if body and body ~= "" then
		M.append("{{{\n" .. body .. "\n}}}\n", depth)
		refresh_and_close_folds()
	end
end

-- Keep {{{ / }}} inside old/new text from closing the chat fold early.
local function fold_safe(s)
	if type(s) ~= "string" or s == "" then
		return "(empty)"
	end
	return (s:gsub("}}}", "} } }"):gsub("{{{", "{ { {"))
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
	-- Isolated workers always start from scratch: system + goal only.
	local msgs = frame.isolated and worker_history(frame) or vim.deepcopy(frame.history)
	if msgs[1] and msgs[1].role == "system" then
		local parts = { frame.system_prompt }
		local tool_section = agent.render_tools(frame.tools)
		if tool_section ~= "" then
			table.insert(parts, tool_section)
		end
		local notes = tools_subtask.render_notes()
		if notes ~= "" then
			table.insert(parts, notes)
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

	local function finish(out)
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
			on_done(out)
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
			finish(full)
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
		finish("Failed to start: " .. command)
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

-- Worker is done: print reply at this indent, then pop and resume parent.
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
	local outcome = tools_subtask.outcome_for(frame, assistant_text)
	if not frame._printed_content and type(assistant_text) == "string" and assistant_text ~= "" then
		M.append("\n" .. assistant_text .. "\n", nest_depth(frame))
	end
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
		table.insert(parent.steps, {
			text = frame.goal or "",
			response = report,
			status = status,
		})
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
	-- Main keeps tool results in chat history. Isolated parents stay at goal-only.
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
	-- Nested subtask sets continue_after_tools. Work tools end this worker.
	if is_worker() and not frame.continue_after_tools then
		finish_oneshot(frame, frame.last_assistant)
		return
	end
	if frame.isolated then
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

	if type(tool_calls) == "table" and #tool_calls > 1 then
		for i = 2, #tool_calls do
			local extra = tool_calls[i]
			local fn = extra["function"] or {}
			table.insert(history, {
				role = "tool",
				name = fn.name,
				tool_call_id = extra.id,
				content = "Only one tool call per turn. Ignored.",
			})
		end
		tool_calls = { tool_calls[1] }
	end

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

		if not agent.tool_granted(frame.tools, name) then
			local granted = table.concat(frame.tools or {}, ", ")
			if granted == "" then
				granted = "(none)"
			end
			M.append("tool denied: " .. tostring(name) .. "\n", depth)
			res.content = "Tool `" .. tostring(name) .. "` is not granted. Granted: "
				.. granted .. ". Call subtask and pass the tool if a child needs it."
			finish_one()
			return
		end

		if name == "shell" then
			local command = args.command
			if type(command) ~= "string" or command == "" then
				M.append("shell: missing command\n", depth)
				res.content = "missing command field"
			else
				local unsafe = tools_shell.unsafe_command(command)
				if not unsafe or config.auto_approve then
					M.append("shell: " .. command .. "\n{{{\n", depth)
					current_state = "tools"
					update_input_name()
					run_live_shell(command, function(out)
						res.content = tools_io.limit_output(out, "shell")
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
				M.append("read: missing file\n", depth)
				res.content = "missing file field"
			elseif vim.fn.filereadable(args.file) ~= 1 then
				M.append("read: " .. args.file .. " not readable\n", depth)
				res.content = "file does not exist or is not readable"
			else
				local range_label = args.range and (" [" .. args.range .. "]") or ""
				res.content = tools_io.read_file(args.file, args.range)
				res.file_range = args.range
				append_output("read: " .. args.file .. range_label, res.content, depth)
			end
		elseif name == "edit" then
			if not args.file then
				M.append("edit: missing file\n", depth)
				res.content = "missing file field"
			else
				local out = tools_edit.edit(args.file, args.old_text, args.new_text, args.multi, config)
				res.content = out
				append_output(
					"edit: " .. args.file,
					format_edit_fold(args.old_text, args.new_text, out),
					depth
				)
			end
		elseif name == "write" then
			if not args.file then
				M.append("write: missing file\n", depth)
				res.content = "missing file field"
			elseif not args.content then
				M.append("write: missing content\n", depth)
				res.content = "missing content field"
			else
				local out = tools_subtask.write(args.file, args.content)
				res.content = out
				append_output("write: " .. args.file, out, depth)
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
			local goal = args.goal or args.Goal or args.task
			if type(goal) == "number" then
				goal = tostring(goal)
			end
			if type(goal) == "string" then
				goal = goal:match("^%s*(.-)%s*$") or goal
			else
				goal = nil
			end
			local parent_goal = tools_subtask.frame_goal(frame)
			if first_sub and i ~= first_sub then
				M.append("subtask skipped: only one per turn\n", depth)
				res.content = "Only one subtask per turn. Wait for this step, then continue."
			elseif not goal or goal == "" then
				M.append("subtask failed: no goal\n", depth)
				res.content = "missing goal"
			elseif parent_goal ~= "" and tools_subtask.same_goal(parent_goal, goal) then
				M.append("subtask failed: goal copies the current Goal\n", depth)
				res.content = "goal must be a more specific next step, not a copy of the current Goal: "
					.. goal
			elseif #stack >= (agent.MAX_DEPTH or 8) then
				M.append("subtask failed: max depth\n", depth)
				res.content = "max subtask depth reached"
			else
				local child_tools = agent.sanitize_subtask_tools(args.tools)
				local child_depth = #stack
				M.append("SUBTASK " .. goal .. "\n", depth)
				M.append("tools: " .. table.concat(child_tools, ", ") .. "\n", child_depth)
				local child = agent.new_frame({
					profile = "subtask",
					system_prompt = args.system_prompt,
					tools = child_tools,
					goal = goal,
					depth = child_depth,
					parent_call_id = call.id,
				})
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
			if body ~= "" then
				append_output("notes: " .. (args.action or "?"), body, depth)
			else
				M.append("notes: " .. out .. "\n", depth)
			end
		elseif name == "skill" then
			local out = tools_skill.run(args)
			res.content = out
			append_output("skill: " .. (args.action or "?"), out, depth)
		elseif name == "mcp" then
			local async_actions = { connect = true, call = true }
			if async_actions[args.action] then
				M.append("mcp: " .. (args.action or "?") .. "\n{{{\n", depth)
				current_state = "tools"
				update_input_name()
				tools_mcp.run(args, function(out)
					res.content = tools_io.limit_output(out or "", "mcp")
					M.append((out or "") .. "\n}}}\n", depth)
					refresh_and_close_folds()
					finish_one()
				end)
				return
			end
			local out = tools_mcp.run(args)
			res.content = out
			append_output("mcp: " .. (args.action or "?"), out or "", depth)
		elseif name == "send_image" then
			if not args.file then
				M.append("image: missing file\n", depth)
				res.content = "Missing file field"
			else
				local image_url, err = tools_subtask.image_data_url(args.file)
				if not image_url then
					M.append("image: " .. args.file .. " failed: " .. err .. "\n", depth)
					res.content = "Error: " .. err
				else
					M.append("image: " .. args.file .. "\n", depth)
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
			M.append("invalid tool: " .. (name or "") .. "\n", depth)
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
				M.append("shell: " .. tostring(command) .. "\n{{{\n", depth)
				run_live_shell(command, function(out)
					res.content = tools_io.limit_output(out, "shell")
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
				M.append("Stopped\n", depth)
				M.append("shell stopped: " .. tostring(command) .. "\n", depth)
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
				M.append("shell declined: " .. tostring(command) .. "\n", depth)
				res.content = "User declined running this command: " .. input
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
	local hist = frame.history
	local cfg = frame_config(frame)
	local msgs = prepare_messages(frame)
	local agent_label = nest_label(frame)
	local out_depth = nest_depth(frame)

	current_state = "waiting"
	update_input_name()

	local function on_idle_no_tools(content)
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
