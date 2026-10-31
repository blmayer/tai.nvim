local M = {}

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

function M.render_notes()
	if notes_text == "" then
		return ""
	end
	local notes = notes_text
	local max_chars = 6000
	if #notes > max_chars then
		local half = math.floor(max_chars / 2)
		notes = notes:sub(1, half) .. "\n\n[notes truncated]\n\n" .. notes:sub(#notes - half + 1)
	end
	return "NOTES\nUse the notes tool to manage this.\n\n" .. notes
end

function M.run(args)
	args = args or {}
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

return M
