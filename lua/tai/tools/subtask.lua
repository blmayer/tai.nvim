local M = {}
local log = require("tai.log")
local skills = require("tai.skills")

function M.frame_goal(frame)
	frame = frame or {}
	if type(frame.goal) == "string" and frame.goal ~= "" then
		return frame.goal
	end
	for i = #(frame.history or {}), 1, -1 do
		local msg = frame.history[i]
		if msg and msg.role == "user" and type(msg.content) == "string" then
			return msg.content
		end
	end
	return ""
end

--- True when `child` is the same job as `parent` with different wording.
function M.same_goal(parent, child)
	local function core(s)
		s = tostring(s or ""):lower()
		s = s:gsub("[\"'`]", "")
		s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
		s = s:gsub("%s+to%s+.*$", "")
		s = s:gsub("%s+and%s+.*$", "")
		s = s:gsub("%s+so%s+that%s+.*$", "")
		s = s:gsub("%s+so%s+.*$", "")
		s = s:gsub("%.$", "")
		return s
	end
	local a, b = core(parent), core(child)
	if a == "" or b == "" then
		return false
	end
	if a == b then
		return true
	end
	-- One restates the other with extra trailing purpose.
	if #a >= 24 and #b >= 24 and (a:find(b, 1, true) or b:find(a, 1, true)) then
		return true
	end
	return false
end

local function trim_text(s)
	if s == nil or s == vim.NIL then
		return ""
	end
	if type(s) ~= "string" then
		s = tostring(s)
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_weak_reply(s)
	if s == "" then
		return true
	end
	if s:match("^I'll ") or s:match("^I will ") or s:match("^Let me ")
		or s:match("^Looking ") or s:match("^I am going") then
		return true
	end
	return false
end

function M.outcome_for(frame, assistant_text)
	local assistant = trim_text(assistant_text)
	local parts = (frame and frame.tool_outputs) or {}
	local tools = #parts > 0 and table.concat(parts, "\n\n") or ""
	if assistant ~= "" and not is_weak_reply(assistant) then
		return assistant
	end
	if tools ~= "" then
		return tools
	end
	if assistant ~= "" then
		return assistant
	end
	return "(no output)"
end

function M.cap_report(text, max_chars)
	if type(text) ~= "string" or text == "" then
		return text
	end
	max_chars = max_chars or 600
	if #text <= max_chars then
		return text
	end
	return text:sub(1, max_chars) .. "\n[truncated]"
end

--- Same-level previous steps (request-ephemeral). Goal stays the user message.
function M.format_progress(frame)
	frame = frame or {}
	local steps = frame.steps or {}
	if #steps == 0 then
		return ""
	end
	local lines = { "Previous steps at this level:" }
	local start = 1
	if #steps > 8 then
		start = #steps - 7
		table.insert(lines, "(earlier steps omitted)")
	end
	for i = start, #steps do
		local step = steps[i]
		table.insert(lines, string.format("%d. %s", i, step.text or ""))
		local resp = step.response
		if type(resp) == "string" and resp ~= "" then
			resp = M.cap_report(resp, 600)
			for line in (resp .. "\n"):gmatch("(.-)\n") do
				table.insert(lines, "   " .. line)
			end
		end
	end
	return table.concat(lines, "\n")
end

-- Shared notepad for the whole stack (main + every worker).
local notes_text = ""

function M.get_notes()
	return notes_text
end

function M.set_notes(text)
	if text == nil or text == vim.NIL then
		notes_text = ""
		return
	end
	notes_text = tostring(text)
end

--- Truncate notes for injection (head + tail).
function M.format_notes(notes, max_chars)
	notes = notes or ""
	if notes == "" then
		return ""
	end
	max_chars = max_chars or 6000
	if #notes <= max_chars then
		return notes
	end
	local half = math.floor(max_chars / 2)
	return notes:sub(1, half)
		.. "\n\n[notes truncated]\n\n"
		.. notes:sub(#notes - half + 1)
end

--- Shared notes block injected into every request (never stored in history).
function M.render_notes()
	local notes = M.format_notes(notes_text)
	if notes == "" then
		return ""
	end
	return table.concat({
		"========== NOTES ==========",
		"",
		notes,
		"",
		"========== END NOTES ==========",
	}, "\n")
end

--- Live context injected into the system prompt each request (never stored in history).
--- Isolated workers have no chat history; this is how they see sibling step reports.
function M.render_memory(frame)
	frame = frame or {}
	local parts = {}
	local progress = M.format_progress(frame)
	if progress ~= "" then
		table.insert(parts, progress)
	end
	local loaded = skills.render_loaded()
	if loaded ~= "" then
		table.insert(parts, "Loaded skills:\n" .. loaded)
	end
	if #parts == 0 then
		return ""
	end
	return table.concat({
		"========== LIVE CONTEXT ==========",
		"",
		table.concat(parts, "\n\n"),
		"",
		"========== END LIVE CONTEXT ==========",
	}, "\n")
end

local function is_error_text(s)
	return type(s) == "string" and (s:match("^ERROR ") or s:match("^status: error"))
end

--- Payload returned to parent when a worker finishes.
function M.format_complete(status, summary, frame)
	local outcome = summary or M.outcome_for(frame, nil)
	local step = frame and frame.goal or "?"
	if status == "error" or is_error_text(outcome) then
		return table.concat({
			"status: error",
			"step: " .. step,
			"error: " .. outcome,
		}, "\n")
	end
	return table.concat({
		"status: ok",
		"step: " .. step,
		"",
		"report:",
		outcome,
	}, "\n")
end

--- @param args table
function M.run_notes(args)
	local action = args.action
	if action == "write" then
		if not args.content then
			return "Error: 'content' is required for 'write'"
		end
		notes_text = args.content
		return string.format("Notes updated (%d chars).", #args.content)
	elseif action == "append" then
		if not args.content then
			return "Error: 'content' is required for 'append'"
		end
		if notes_text == "" then
			notes_text = args.content
		else
			notes_text = notes_text .. "\n" .. args.content
		end
		return string.format("Notes appended (%d chars).", #args.content)
	end
	return "Error: unknown action '" .. tostring(action) .. "'"
end

-- Add write function
function M.write(file, content)
	log.debug("Running write_file for: " .. file)

	if file:sub(1, 1) == "/" then
		return "Paths cannot start from root (/). Use relative."
	end

	-- Ensure parent directory exists
	local dir = vim.fn.fnamemodify(file, ":p:h")
	if dir and dir ~= "" and dir ~= "." and vim.fn.isdirectory(dir) == 0 then
		local mkdir_result = vim.fn.mkdir(dir, "p")
		if mkdir_result == -1 then
			return "[sys] Error: Could not create directory: " .. dir
		end
	end

	-- Write content to file
	local f = io.open(file, "w")
	if not f then
		return "Error: Could not open file for writing: " .. file
	end
	f:write(content)
	f:close()

	return "File created: " .. file
end

-- Add image_data_url function
function M.image_data_url(image_path)
	-- Check if file exists
	if vim.fn.filereadable(image_path) ~= 1 then
		return nil, "Image file not found: " .. image_path
	end

	-- Detect MIME type from extension
	local ext = image_path:match("%.(%w+)$")
	if not ext then
		return nil, "File has no extension, cannot determine image type"
	end
	local mime_types = {
		png = "image/png",
		jpg = "image/jpeg",
		jpeg = "image/jpeg",
		gif = "image/gif",
		webp = "image/webp",
		bmp = "image/bmp",
	}
	local mime = mime_types[ext:lower()]
	if not mime then
		return nil, "Unsupported image format: " .. ext .. ". Supported formats: png, jpg, jpeg, gif, webp, bmp."
	end

	-- Read file and encode to base64 using curl
	local cmd = string.format("base64 -i '%s' | tr -d '\n'", image_path)
	local handle = io.popen(cmd, "r")
	if not handle then
		return nil, "Failed to read image file"
	end
	local base64_content = handle:read("*a")
	handle:close()

	if not base64_content or #base64_content == 0 then
		return nil, "Failed to encode image to base64"
	end

	return "data:" .. mime .. ";base64," .. base64_content, nil
end

return M
