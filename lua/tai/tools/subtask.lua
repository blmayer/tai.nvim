local M = {}
local log = require("tai.log")
local skills = require("tai.skills")

local function split_lines(s)
	if type(s) ~= "string" then
		return { tostring(s) }
	end
	if vim and vim.split then
		return vim.split(s, "\n", { plain = true })
	end
	local out = {}
	for line in (s .. "\n"):gmatch("(.-)\n") do
		table.insert(out, line)
	end
	return out
end

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

local function trim_text(s)
	if s == nil or s == vim.NIL then
		return ""
	end
	if type(s) ~= "string" then
		s = tostring(s)
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Work tools end the turn before the child can summarize, so the
--- parent must receive a compact slice of the tool result.
function M.compact_tool_outputs(frame, max_chars)
	max_chars = max_chars or 700
	local parts = (frame and frame.tool_outputs) or {}
	if #parts == 0 then
		return nil
	end
	local text = table.concat(parts, "\n\n")
	if text == "" then
		return nil
	end
	if #text <= max_chars then
		return text
	end
	local keep = math.floor((max_chars - 8) / 2)
	return text:sub(1, keep) .. "\n[...]\n" .. text:sub(-keep)
end

local function is_weak_reply(s)
	if s == "" then
		return true
	end
	if s:match("[Oo]utcome:") or s:match("[Ff]ound:") then
		return false
	end
	if #s < 80 then
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
	local tools = M.compact_tool_outputs(frame)
	if assistant ~= "" and not is_weak_reply(assistant) then
		return assistant
	end
	if tools then
		return tools
	end
	if assistant ~= "" then
		return assistant
	end
	return "(no output)"
end

--- True when a child pasted fenced evidence instead of a fact summary.
function M.looks_like_dump(text)
	if type(text) ~= "string" or text == "" then
		return false
	end
	return text:match("{{{") ~= nil or text:match("```") ~= nil
end

--- Keep only a parent-usable handoff. Dumps become a retry signal.
function M.summarize_handoff(text)
	if type(text) ~= "string" or text == "" then
		return text
	end
	if not M.looks_like_dump(text) then
		return text
	end
	local found = text:match("[Ff]ound:%s*([^\n]+)")
	if found then
		found = found:match("^%s*(.-)%s*$")
	end
	if not found or found == "" or #found > 200 then
		found = "none"
	end
	return table.concat({
		"found: " .. found,
		"outcome: reply was a dump (code or tool output). Ask for the specific fact again.",
	}, "\n")
end

--- Cap a handoff so coordinators (especially main) stay high-level.
function M.cap_report(text, max_chars)
	if type(text) ~= "string" or text == "" then
		return text
	end
	max_chars = max_chars or 800
	if #text <= max_chars then
		return text
	end
	return text:sub(1, max_chars)
		.. "\n[truncated] Report was too long. Ask again for found:/outcome: only."
end

local function step_is_error(step)
	if not step then
		return false
	end
	if step.status == "error" then
		return true
	end
	local resp = step.response
	return type(resp) == "string"
		and (resp:match("^ERROR ") or resp:match("^status: error"))
end

--- Short steering line from progress so far (request-ephemeral).
function M.next_step_hint(frame)
	frame = frame or {}
	local steps = frame.steps or {}
	if #steps == 0 then
		return "No progress yet. First: list the project dir and read README.md / AGENTS.md."
	end
	if step_is_error(steps[#steps]) then
		return "Last step failed. Next: inspect that failure only."
	end
	return "Continue from the last report. Do not repeat a finished step."
end

--- Goal + same-level previous steps (request-ephemeral data only).
function M.format_progress(frame)
	frame = frame or {}
	local goal = M.frame_goal(frame)
	local lines = {
		"Goal:",
		goal ~= "" and goal or "(none)",
		"",
		"Previous steps:",
	}
	local steps = frame.steps or {}
	-- Main stays high-level; workers may keep a bit more.
	local cap = frame.isolated and 800 or 400
	if #steps == 0 then
		table.insert(lines, "(none)")
	else
		for i, step in ipairs(steps) do
			local tag = step_is_error(step) and " [error]" or ""
			table.insert(lines, string.format("%d. %s%s", i, step.text or "", tag))
			local resp = step.response
			if type(resp) == "string" and resp ~= "" then
				resp = M.cap_report(resp, cap)
				for _, rl in ipairs(split_lines(resp)) do
					table.insert(lines, "   " .. rl)
				end
			end
		end
	end
	table.insert(lines, "")
	table.insert(lines, "Now:")
	table.insert(lines, M.next_step_hint(frame))
	table.insert(lines, "Handoff: found: + outcome: only. Parent cannot see your tools.")
	return table.concat(lines, "\n")
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

--- Live context injected into the system prompt each request (never stored in history).
--- Returns "" when empty so callers can skip injection.
function M.render_memory(frame)
	frame = frame or {}
	local inner = { M.format_progress(frame) }
	local notes = M.format_notes(frame.notes)
	if notes ~= "" then
		table.insert(inner, "Notes:\n" .. notes)
	end
	local loaded = skills.render_loaded()
	if loaded ~= "" then
		table.insert(inner, "Loaded skills:\n" .. loaded)
	end
	return table.concat({
		"========== CURRENT STATE ==========",
		"",
		table.concat(inner, "\n\n"),
		"",
		"========== END CURRENT STATE ==========",
	}, "\n")
end

local function is_error_text(s)
	return type(s) == "string" and (s:match("^ERROR ") or s:match("^status: error"))
end

--- Payload returned to parent when a worker finishes.
function M.format_complete(status, summary, frame)
	local outcome = summary or M.outcome_for(frame, nil)
	if status ~= "error" and not is_error_text(outcome) then
		outcome = M.summarize_handoff(outcome)
	end
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
--- @param frame table agent frame with notes string
function M.run_notes(args, frame)
	local action = args.action
	if action == "write" then
		if not args.content then
			return "Error: 'content' is required for 'write'"
		end
		frame.notes = args.content
		return string.format("Notes updated (%d chars).", #args.content)
	elseif action == "append" then
		if not args.content then
			return "Error: 'content' is required for 'append'"
		end
		if frame.notes == "" then
			frame.notes = args.content
		else
			frame.notes = frame.notes .. "\n" .. args.content
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
