local M = {}

M.MAX_CHANGES = 6000

local function trim(s)
	if type(s) ~= "string" then
		return ""
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellescape(s)
	if vim and vim.fn and vim.fn.shellescape then
		return vim.fn.shellescape(s)
	end
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(cmd)
	local h = io.popen(cmd, "r")
	if not h then
		return ""
	end
	local out = h:read("*a") or ""
	h:close()
	return out
end

function M.snapshot(root)
	local set = {}
	if type(root) ~= "string" or root == "" then
		return set
	end
	local out = run("git -C " .. shellescape(root) .. " status --porcelain -uall 2>/dev/null")
	for line in (out .. "\n"):gmatch("(.-)\n") do
		local path = line:match("^..%s+(.*)$")
		if path then
			path = path:gsub('^"', ""):gsub('"$', "")
			local renamed = path:match("%s%->%s(.+)$")
			set[renamed or path] = true
		end
	end
	return set
end

local function unified(file, old, new)
	old = old or ""
	new = new or ""
	local a = {}
	local b = {}
	if old ~= "" then
		for line in (old .. "\n"):gmatch("(.-)\n") do
			table.insert(a, line)
		end
	end
	if new ~= "" then
		for line in (new .. "\n"):gmatch("(.-)\n") do
			table.insert(b, line)
		end
	end
	local lines = { "--- a/" .. file, "+++ b/" .. file, "@@" }
	for _, line in ipairs(a) do
		table.insert(lines, "-" .. line)
	end
	for _, line in ipairs(b) do
		table.insert(lines, "+" .. line)
	end
	return table.concat(lines, "\n")
end

function M.record_command(frame, command, failed)
	if not frame or type(command) ~= "string" or command == "" then
		return
	end
	frame.commands = frame.commands or {}
	table.insert(frame.commands, {
		command = command,
		failed = failed == true,
	})
end

function M.render_commands(frame)
	local cmds = (frame and frame.commands) or {}
	if #cmds == 0 then
		return ""
	end
	local lines = {}
	for _, c in ipairs(cmds) do
		local line = "- " .. c.command
		if c.failed then
			line = line .. " [failed]"
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

function M.record_edit(frame, file, old, new)
	if not frame or type(file) ~= "string" or file == "" then
		return
	end
	frame.file_changes = frame.file_changes or {}
	frame.changed_set = frame.changed_set or {}
	frame.changed_set[file] = true
	table.insert(frame.file_changes, {
		file = file,
		kind = "edit",
		diff = unified(file, old, new),
	})
end

function M.record_write(frame, file, content)
	if not frame or type(file) ~= "string" or file == "" then
		return
	end
	frame.file_changes = frame.file_changes or {}
	frame.changed_set = frame.changed_set or {}
	frame.changed_set[file] = true
	local body = content or ""
	local shown = body
	if #shown > 2000 then
		shown = shown:sub(1, 2000) .. "\n[truncated]"
	end
	table.insert(frame.file_changes, {
		file = file,
		kind = "write",
		diff = unified(file, "", shown),
	})
end

local function git_diff(root, file)
	local diff = run("git -C " .. shellescape(root) .. " diff -- " .. shellescape(file) .. " 2>/dev/null")
	diff = trim(diff)
	if diff ~= "" then
		return diff
	end
	local path = root .. "/" .. file
	local f = io.open(path, "r")
	if not f then
		return ""
	end
	local content = f:read("*a") or ""
	f:close()
	if #content > 2000 then
		content = content:sub(1, 2000) .. "\n[truncated]"
	end
	return unified(file, "", content)
end

--- Files dirtied after this worker started, excluding ones already recorded
--- via edit/write (those keep the tool patch, not a full working-tree diff).
function M.collect_shell(frame, root)
	if not frame or type(root) ~= "string" or root == "" then
		return
	end
	local now = M.snapshot(root)
	local before = frame.git_dirty or {}
	local seen = frame.changed_set or {}
	frame.file_changes = frame.file_changes or {}
	frame.changed_set = seen
	for file, _ in pairs(now) do
		if not before[file] and not seen[file] then
			local diff = git_diff(root, file)
			if diff ~= "" then
				seen[file] = true
				table.insert(frame.file_changes, {
					file = file,
					kind = "shell",
					diff = diff,
				})
			end
		end
	end
end

function M.render(frame, max_chars)
	max_chars = max_chars or M.MAX_CHANGES
	local parts = {}
	for _, ch in ipairs((frame and frame.file_changes) or {}) do
		if ch.diff and ch.diff ~= "" then
			table.insert(parts, ch.diff)
		end
	end
	if #parts == 0 then
		return ""
	end
	local text = table.concat(parts, "\n\n")
	if #text > max_chars then
		text = text:sub(1, max_chars) .. "\n[changes truncated]"
	end
	return text
end

return M
