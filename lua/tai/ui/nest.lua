-- Nesting indent for the chat tree (4 spaces per subtask depth).
local M = {}

function M.prefix(depth)
	if type(depth) ~= "number" or depth < 1 then
		return ""
	end
	return string.rep("    ", depth)
end

local function is_blank(s)
	return not s or s == "" or s:match("^%s*$") ~= nil
end

-- Do not glue new text onto a header or fold marker.
local function must_break(line, pad)
	if is_blank(line) then
		return false
	end
	if line:match("^%s*SUBTASK ") or line:match("{{{") or line:match("}}}") then
		return true
	end
	if pad ~= "" and line:sub(1, #pad) ~= pad then
		return true
	end
	return false
end

--- Indent `text` as a continuation of `last_line` at `depth`.
--- Returns the string that should replace `last_line` (may contain newlines).
function M.apply(text, depth, last_line)
	if text == nil then
		text = ""
	end
	if type(text) ~= "string" then
		text = tostring(text)
	end
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	last_line = last_line or ""
	local pad = M.prefix(depth)

	if text == "" then
		return last_line
	end

	if pad == "" then
		if is_blank(last_line) then
			return text
		end
		-- Main text after an indented child starts on a new line.
		if last_line:match("^%s") or must_break(last_line, pad) then
			return last_line .. "\n" .. text
		end
		return last_line .. text
	end

	local break_now = must_break(last_line, pad)
	local head
	if is_blank(last_line) then
		head = ""
	elseif break_now then
		head = last_line .. "\n"
	else
		head = last_line
	end

	local body = text:gsub("\n", "\n" .. pad)
	-- Leading newlines stay blank; do not turn them into indent-only lines.
	if (is_blank(last_line) or break_now) and text:sub(1, 1) ~= "\n" then
		body = pad .. body
	end
	-- Trailing newline should leave an empty last line, not a leftover pad.
	if text:sub(-1) == "\n" and body:sub(-#pad) == pad then
		body = body:sub(1, #body - #pad)
	end
	return head .. body
end

return M
