local M = {}

local STATUSES = {
	pending = true,
	running = true,
	ok = true,
	blocked = true,
	error = true,
	skipped = true,
}

local function trim(s)
	if s == nil or s == vim.NIL then
		return ""
	end
	if type(s) ~= "string" then
		s = tostring(s)
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.parse_index(index)
	if type(index) == "number" then
		if index < 1 then
			return nil
		end
		return { index }
	end
	if type(index) ~= "string" then
		return nil
	end
	local path = {}
	for part in index:gmatch("[^%.]+") do
		local n = tonumber(part)
		if not n or n < 1 then
			return nil
		end
		table.insert(path, n)
	end
	if #path == 0 then
		return nil
	end
	return path
end

function M.normalize_item(raw)
	if type(raw) == "string" then
		raw = { goal = raw }
	end
	if type(raw) ~= "table" then
		return nil
	end
	local goal = trim(raw.goal or raw.text or "")
	if goal == "" then
		return nil
	end
	local agent = trim(raw.agent or raw.role or "coder"):lower()
	if agent == "manager" then
		agent = "orchestrator"
	end
	if agent ~= "coder" and agent ~= "orchestrator" then
		agent = "coder"
	end
	local status = trim(raw.status or "pending"):lower()
	if not STATUSES[status] then
		status = "pending"
	end
	local tools = {}
	if type(raw.tools) == "table" then
		for _, name in ipairs(raw.tools) do
			if type(name) == "string" and name ~= "" then
				table.insert(tools, name)
			end
		end
	end
	return {
		agent = agent,
		status = status,
		goal = goal,
		notes = type(raw.notes) == "string" and raw.notes or "",
		result = type(raw.result) == "string" and raw.result or nil,
		tools = tools,
		children = M.sanitize(raw.children or raw.items),
	}
end

function M.sanitize(items)
	local out = {}
	if type(items) ~= "table" then
		return out
	end
	for _, raw in ipairs(items) do
		local item = M.normalize_item(raw)
		if item then
			table.insert(out, item)
		end
	end
	return out
end

function M.node_at(list, path)
	if type(list) ~= "table" or type(path) ~= "table" or #path == 0 then
		return nil
	end
	local cur = list
	local node
	for i, idx in ipairs(path) do
		node = cur[idx]
		if not node then
			return nil
		end
		if i < #path then
			if type(node.children) ~= "table" then
				node.children = {}
			end
			cur = node.children
		end
	end
	return node
end

function M.visible(frame)
	if not frame then
		return {}
	end
	local root = frame.plan_root or frame.plan
	if type(root) ~= "table" then
		return {}
	end
	local path = frame.plan_path or {}
	if #path == 0 then
		return root
	end
	local node = M.node_at(root, path)
	if not node then
		return {}
	end
	if type(node.children) ~= "table" then
		node.children = {}
	end
	return node.children
end

function M.get(frame)
	return M.visible(frame)
end

local function replace_list(dest, items)
	if type(dest) ~= "table" then
		return items
	end
	for i = #dest, 1, -1 do
		dest[i] = nil
	end
	for _, item in ipairs(items) do
		table.insert(dest, item)
	end
	return dest
end

function M.set(frame, items)
	if not frame then
		return {}
	end
	local list = M.sanitize(items)
	local dest = M.visible(frame)
	if dest == (frame.plan_root or frame.plan) or (frame.plan_path and #frame.plan_path > 0) then
		return replace_list(dest, list)
	end
	frame.plan = list
	frame.plan_root = list
	frame.plan_path = frame.plan_path or {}
	return frame.plan
end

function M.update(frame, index, fields)
	local vis = M.visible(frame)
	local path = M.parse_index(index)
	if not path then
		return nil, "plan item " .. tostring(index) .. " not found"
	end
	local cur = M.node_at(vis, path)
	if not cur then
		return nil, "plan item " .. tostring(index) .. " not found"
	end
	fields = fields or {}
	local merged = {
		agent = fields.agent or fields.role or cur.agent,
		status = fields.status or cur.status,
		goal = fields.goal or fields.text or cur.goal,
		notes = fields.notes ~= nil and fields.notes or cur.notes,
		result = fields.result ~= nil and fields.result or cur.result,
		tools = fields.tools or cur.tools,
		children = fields.children or fields.items or cur.children,
	}
	local item = M.normalize_item(merged)
	if not item then
		return nil, "plan item needs a goal"
	end
	local parent_list = vis
	if #path > 1 then
		local parent = {}
		for i = 1, #path - 1 do
			parent[i] = path[i]
		end
		local parent_node = M.node_at(vis, parent)
		parent_list = parent_node and parent_node.children or vis
	end
	parent_list[path[#path]] = item
	return item
end

function M.mark(frame, index, status, result)
	local vis = M.visible(frame)
	local path = M.parse_index(index)
	if not path then
		return nil
	end
	local node = M.node_at(vis, path)
	if not node then
		return nil
	end
	if STATUSES[status] then
		node.status = status
	end
	if type(result) == "string" then
		if #result > 600 then
			result = result:sub(1, 600) .. "\n[truncated]"
		end
		node.result = result
	end
	return node
end

function M.item(frame, index)
	local vis = M.visible(frame)
	local path = M.parse_index(index)
	if not path then
		return nil
	end
	return M.node_at(vis, path)
end

function M.next_pending(frame)
	local vis = M.visible(frame)
	for i, item in ipairs(vis) do
		if item.status == "pending" then
			return i, item
		end
	end
	return nil
end

function M.child_path(frame, step)
	local path = {}
	for _, p in ipairs((frame and frame.plan_path) or {}) do
		table.insert(path, p)
	end
	step = tonumber(step)
	if step then
		table.insert(path, step)
	end
	return path
end

function M.render_task_notes(notes)
	notes = trim(notes)
	if notes == "" then
		return ""
	end
	return table.concat({
		"========== TASK NOTES ==========",
		"",
		notes,
		"",
		"========== END TASK NOTES ==========",
	}, "\n")
end

local function item_tools(item)
	if item.agent == "orchestrator" then
		return "orchestrator - subtask notes plan"
	end
	local tools = item.tools
	if type(tools) ~= "table" or #tools == 0 then
		tools = { "read", "shell", "edit" }
	end
	return "coder - " .. table.concat(tools, " ")
end

local function render_list(list, prefix, depth, lines)
	if type(list) ~= "table" then
		return lines
	end
	local pad = string.rep("   ", depth)
	for i, item in ipairs(list) do
		local label = prefix == "" and tostring(i) or (prefix .. "." .. i)
		table.insert(lines, pad .. label .. ". " .. (item.goal or ""))
		if item.notes and item.notes ~= "" then
			local first = true
			for line in (item.notes .. "\n"):gmatch("(.-)\n") do
				if first then
					table.insert(lines, pad .. "   Notes: " .. line)
					first = false
				else
					table.insert(lines, pad .. "          " .. line)
				end
			end
		end
		local tag = "[" .. string.upper(item.status or "pending") .. "]"
		table.insert(lines, pad .. "   " .. tag .. " (" .. item_tools(item) .. ")")
		if item.result and item.result ~= "" then
			local first = item.result:match("^[^\n]+") or item.result
			table.insert(lines, pad .. "   Result: " .. first)
		end
		table.insert(lines, "")
		if item.children and #item.children > 0 then
			render_list(item.children, label, depth + 1, lines)
		end
	end
	return lines
end

function M.render(plan)
	if type(plan) ~= "table" or #plan == 0 then
		return ""
	end
	local lines = render_list(plan, "", 0, {})
	while lines[#lines] == "" do
		lines[#lines] = nil
	end
	return table.concat(lines, "\n")
end

function M.render_for(frame)
	if not frame or frame.role ~= "orchestrator" then
		return ""
	end
	local vis = M.visible(frame)
	local lines = {}
	local path = frame.plan_path or {}
	if #path > 0 then
		local node = M.node_at(frame.plan_root or frame.plan, path)
		if node then
			table.insert(lines, "branch: " .. table.concat(path, ".") .. " " .. (node.status or "") .. " " .. (node.agent or ""))
			table.insert(lines, "goal: " .. (node.goal or ""))
			if node.notes and node.notes ~= "" then
				table.insert(lines, "notes: " .. node.notes)
			end
		end
	end
	local body = M.render(vis)
	if body ~= "" then
		if #lines > 0 then
			table.insert(lines, "")
		end
		table.insert(lines, body)
	end
	if #lines == 0 then
		return ""
	end
	return table.concat(lines, "\n")
end

function M.run(args, frame)
	args = args or {}
	frame = frame or {}
	local action = args.action
	if action == "write" then
		local plan = M.set(frame, args.items)
		if #plan == 0 then
			return "Error: plan write needs items with a goal"
		end
		return string.format("Plan written (%d steps).", #plan)
	elseif action == "update" then
		local item, err = M.update(frame, args.path or args.index, args)
		if not item then
			return "Error: " .. (err or "update failed")
		end
		return string.format("Plan item %s updated (%s %s).", tostring(args.path or args.index), item.status, item.agent)
	elseif action == "status" then
		local text = M.render_for(frame)
		if text == "" then
			text = M.render(M.visible(frame))
		end
		if text == "" then
			return "No plan."
		end
		return text
	end
	return "Error: unknown action '" .. tostring(action) .. "'"
end

return M
