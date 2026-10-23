-- One-shot editor actions. Each kind has its own system prompt and never
-- enters the planner. selection / selection_prompt answer in the chat.
-- complete / insert return only the text to place at the cursor.

local M = {}

M.limits = {
	before = 6000,
	after = 2500,
	selection = 12000,
}

M.prompts = {}

M.prompts.selection = [[
You are Tai in Neovim. The user selected text and sent it with no other instruction.

If the selection asks a question or requests a change, answer that request.
If the selection is code, explain what it does in a few sentences and name the important symbols.

Use only the selection. Do not invent files, commands, or a plan.
Plain sentences. No markdown heading. No code fence unless a short snippet is required to answer.
]]

M.prompts.selection_prompt = [[
You are Tai in Neovim. The user selected a region and wrote an instruction.

Follow the instruction. The selection is the only source text you can see.
Do not invent files or a plan.
Write a direct answer. No preamble.
If the instruction asks for code, put that code in one fenced block and add nothing else.
]]

M.prompts.complete = [[
You are the autocomplete for a Neovim buffer.

The user message is the cursor position.
<before> is the text before the cursor.
<after> is the text after the cursor.

Return only the missing characters between <before> and <after>.
Do not repeat characters already in <before> or <after>.
Do not add a fence, a quote, or an explanation.
Copy the file's indentation and names.
Stop at the end of the current statement. Continue onto another line only when the current line is unfinished.
]]

M.prompts.insert = [[
You are writing text that Neovim will insert at the cursor.

The user message has an instruction, <before> (text before the cursor), and <after> (text after the cursor).
Follow the instruction.
Return only the insertion. It must read correctly between <before> and <after>.
Do not repeat <before> or <after>.
No explanation, no fence, and no quotes around the whole answer.
Copy the file's indentation and style.
]]

local function clip_tail(s, n)
	if #s <= n then
		return s
	end
	local cut = s:sub(#s - n + 1)
	local nl = cut:find("\n", 1, true)
	if nl and nl < #cut then
		return cut:sub(nl + 1)
	end
	return cut
end

local function clip_head(s, n)
	if #s <= n then
		return s
	end
	local cut = s:sub(1, n)
	local last
	local i = 1
	while true do
		local p = cut:find("\n", i, true)
		if not p then
			break
		end
		last = p
		i = p + 1
	end
	if last and last > 1 then
		return cut:sub(1, last - 1)
	end
	return cut
end

local function split_lines(text)
	return vim.split(text, "\n", { plain = true })
end

function M.strip_thinking(text)
	if type(text) ~= "string" then
		return ""
	end
	local lower = text:sub(1, 8)
	local tag, closer
	if lower:sub(1, 7) == "<think>" then
		tag, closer = 7, "</think>"
	elseif text:sub(1, 10) == "<thinking>" then
		tag, closer = 10, "</thinking>"
	end
	if not tag then
		return text
	end
	local close = text:find(closer, tag + 1, true)
	if not close then
		return text
	end
	return (text:sub(close + #closer):gsub("^%s+", ""))
end

function M.unwrap_fence(text)
	if type(text) ~= "string" then
		return ""
	end
	text = text:gsub("\r\n", "\n"):gsub("^\239\187\191", "")
	local trimmed = text:gsub("%s+$", "")
	local lines = split_lines(trimmed)
	local function is_open(line)
		return line:gsub("%s+$", ""):match("^```[%w_.+-]*$") ~= nil
	end
	local function is_close(line)
		return line:gsub("%s+$", ""):match("^```$") ~= nil
	end
	if #lines >= 2 and is_open(lines[1]) and is_close(lines[#lines]) then
		table.remove(lines, 1)
		table.remove(lines)
		return table.concat(lines, "\n")
	end
	local start_i, end_i
	for i, line in ipairs(lines) do
		if not start_i and is_open(line) then
			start_i = i
		elseif start_i and is_close(line) then
			end_i = i
			break
		end
	end
	if start_i and end_i and end_i > start_i then
		local body = {}
		for i = start_i + 1, end_i - 1 do
			body[#body + 1] = lines[i]
		end
		return table.concat(body, "\n")
	end
	-- Keep a trailing newline. Completions at the end of the buffer need it.
	return text:gsub("[ \t]+$", "")
end

function M.strip_overlap(text, before, after)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	before = before or ""
	after = after or ""
	local limit = math.min(#text, #before)
	for n = limit, 8, -1 do
		local piece = text:sub(1, n)
		if piece:match("%S") and before:sub(-n) == piece then
			text = text:sub(n + 1)
			break
		end
	end
	local last_line = before:match("([^\n]*)$") or ""
	if last_line ~= "" and text:sub(1, #last_line) == last_line then
		text = text:sub(#last_line + 1)
	end
	local next_line = after:match("^\n?([^\n]*)") or ""
	if next_line ~= "" and #text >= #next_line and text:sub(-#next_line) == next_line then
		local at = #text - #next_line
		if at == 0 then
			text = ""
		elseif text:sub(at, at) == "\n" then
			if after:sub(1, 1) == "\n" then
				text = text:sub(1, at - 1)
			else
				text = text:sub(1, at)
			end
		end
	end
	return text
end

--- Returns the full line list, the row offset, and the cursor column after insertion.
function M.splice(line, col, text)
	line = line or ""
	col = col or 0
	local parts = vim.split(text or "", "\n", { plain = true })
	if #parts == 0 then
		parts = { "" }
	end
	local after = line:sub(col + 1)
	parts[1] = line:sub(1, col) .. (parts[1] or "")
	parts[#parts] = parts[#parts] .. after
	return parts, #parts - 1, #parts[#parts] - #after
end

function M.prepare_insertion(text, before, after)
	text = M.unwrap_fence(M.strip_thinking(text))
	if (after or "") ~= "" then
		text = text:gsub("\n+$", "")
	end
	return M.strip_overlap(text, before, after)
end

function M.reply_text(kind, raw, ctx)
	local text = M.strip_thinking(raw or "")
	text = text:gsub("\r\n", "\n")
	if kind == "complete" or kind == "insert" then
		local before = ctx and ctx.before or ""
		local after = ctx and ctx.after or ""
		return M.prepare_insertion(text, before, after)
	end
	return text:gsub("%s+$", "")
end

--- row is 1-indexed. col is the 0-indexed byte where new text is inserted.
function M.cursor_view(buf, row, col, lines, path, filetype)
	lines = lines or {}
	row = row or 1
	col = col or 0
	if row < 1 then
		row = 1
	end
	if row > #lines then
		row = #lines
	end
	local cur = lines[row] or ""
	if col < 0 then
		col = 0
	end
	if col > #cur then
		col = #cur
	end
	local line_before = cur:sub(1, col)
	local line_after = cur:sub(col + 1)
	local before
	if row > 1 then
		before = table.concat(lines, "\n", 1, row - 1) .. "\n" .. line_before
	else
		before = line_before
	end
	local after
	if row < #lines then
		after = line_after .. "\n" .. table.concat(lines, "\n", row + 1, #lines)
	else
		after = line_after
	end
	return {
		buf = buf,
		row = row,
		col = col,
		path = path or "",
		filetype = (filetype and filetype ~= "") and filetype or "text",
		before = clip_tail(before, M.limits.before),
		after = clip_head(after, M.limits.after),
		line_prefix = line_before,
		line_at = cur,
	}
end

function M.capture_cursor(win)
	win = win or vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	local cursor = vim.api.nvim_win_get_cursor(win)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local view = M.cursor_view(
		buf,
		cursor[1],
		cursor[2],
		lines,
		vim.api.nvim_buf_get_name(buf),
		vim.bo[buf].filetype
	)
	view.win = win
	return view
end

--- srow/erow are 1-indexed. scol/ecol are 0-indexed inclusive byte columns.
--- kind is "char"|"line"|"block", or a visualmode() value "v"|"V"|"\\22".
function M.region_text(lines, srow, scol, erow, ecol, kind)
	lines = lines or {}
	if #lines == 0 then
		return ""
	end
	srow = srow or 1
	erow = erow or srow
	scol = scol or 0
	ecol = ecol or scol
	if srow > erow or (srow == erow and scol > ecol) then
		srow, erow = erow, srow
		scol, ecol = ecol, scol
	end
	if srow < 1 then
		srow = 1
	end
	if erow > #lines then
		erow = #lines
	end
	if srow > erow then
		return ""
	end
	local chunk = {}
	for i = srow, erow do
		chunk[#chunk + 1] = lines[i] or ""
	end
	if kind == "line" or kind == "V" then
		return table.concat(chunk, "\n")
	end
	if kind == "block" or kind == "\022" then
		local left, right = scol, ecol
		if left > right then
			left, right = right, left
		end
		local out = {}
		for _, line in ipairs(chunk) do
			if left >= #line then
				out[#out + 1] = ""
			else
				out[#out + 1] = line:sub(left + 1, math.min(#line, right + 1))
			end
		end
		return table.concat(out, "\n")
	end
	if srow == erow then
		return (chunk[1] or ""):sub(scol + 1, ecol + 1)
	end
	local out = { (chunk[1] or ""):sub(scol + 1) }
	for i = 2, #chunk - 1 do
		out[#out + 1] = chunk[i]
	end
	out[#out + 1] = (chunk[#chunk] or ""):sub(1, ecol + 1)
	return table.concat(out, "\n")
end

function M.capture(buf, start_mark, end_mark, kind)
	buf = buf or 0
	local s = vim.api.nvim_buf_get_mark(buf, start_mark)
	local e = vim.api.nvim_buf_get_mark(buf, end_mark)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local text = ""
	local srow, erow = s[1], e[1]
	if srow > 0 and erow > 0 then
		text = M.region_text(lines, srow, s[2], erow, e[2], kind)
		if srow > erow then
			srow, erow = erow, srow
		end
	end
	local path = ""
	local ft = "text"
	if vim.api.nvim_buf_is_valid(buf == 0 and vim.api.nvim_get_current_buf() or buf) then
		path = vim.api.nvim_buf_get_name(buf)
		ft = vim.bo[buf].filetype
		if ft == nil or ft == "" then
			ft = "text"
		end
	end
	return {
		buf = buf,
		text = text,
		path = path,
		filetype = ft,
		start_line = srow,
		end_line = erow,
		kind = kind or "char",
	}
end

local function file_label(ctx)
	local path = ctx and ctx.path or ""
	if path == "" then
		path = "[No Name]"
	end
	local ft = ctx and ctx.filetype or ""
	if ft == "" then
		ft = "text"
	end
	return path, ft
end

function M.user_text(kind, ctx)
	ctx = ctx or {}
	local path, ft = file_label(ctx)
	if kind == "selection" or kind == "selection_prompt" then
		local body = ctx.text or ""
		local note = nil
		if #body > M.limits.selection then
			body = body:sub(1, M.limits.selection)
			note = "(selection truncated)"
		end
		local lines = {
			"File: " .. path,
			"Filetype: " .. ft,
			string.format("Lines: %s-%s", tostring(ctx.start_line or "?"), tostring(ctx.end_line or "?")),
		}
		if kind == "selection_prompt" then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Instruction:"
			lines[#lines + 1] = ctx.instruction or ""
		end
		if note then
			lines[#lines + 1] = note
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "<selection>"
		lines[#lines + 1] = body
		lines[#lines + 1] = "</selection>"
		return table.concat(lines, "\n")
	end
	local lines = {
		"File: " .. path,
		"Filetype: " .. ft,
		string.format("Cursor: line %d, column %d", ctx.row or 1, (ctx.col or 0) + 1),
	}
	if kind == "insert" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Instruction:"
		lines[#lines + 1] = ctx.instruction or ""
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "<before>"
	lines[#lines + 1] = ctx.before or ""
	lines[#lines + 1] = "</before>"
	lines[#lines + 1] = "<after>"
	lines[#lines + 1] = ctx.after or ""
	lines[#lines + 1] = "</after>"
	return table.concat(lines, "\n")
end

function M.messages(kind, ctx)
	local prompt = M.prompts[kind]
	if not prompt then
		error("unknown inline kind: " .. tostring(kind))
	end
	return {
		{ role = "system", content = prompt },
		{ role = "user", content = M.user_text(kind, ctx) },
	}
end

function M.preview(sel)
	sel = sel or {}
	local path = sel.path
	if path == nil or path == "" then
		path = "[No Name]"
	end
	local body = sel.text or ""
	if #body > 1500 then
		body = body:sub(1, 1500) .. "\n…"
	end
	local head = string.format("%s:%s-%s", path, tostring(sel.start_line or "?"), tostring(sel.end_line or "?"))
	if sel.instruction and sel.instruction ~= "" then
		return head .. "\n" .. sel.instruction .. "\n\n" .. body
	end
	return head .. "\n" .. body
end

return M
