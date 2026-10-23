local M = {}

local log = require("tai.log")
local config = require("tai.config")
local ui = require("tai.ui")
local mcp = require("tai.mcp")
local tools = require("tai.tools")
local inline = require("tai.inline")

local function blank(s)
	return type(s) ~= "string" or s:match("^%s*$") ~= nil
end

local function ui_mod()
	if type(ui.inline_request) ~= "function" then
		vim.notify("tai: no provider configured", vim.log.levels.WARN)
		return nil
	end
	return ui
end

local function resume_insert(ctx)
	if not ctx or not ctx.return_insert then
		return
	end
	local mode = vim.api.nvim_get_mode().mode
	if mode:sub(1, 1) == "i" then
		return
	end
	local win = ctx.win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
	end
	vim.cmd("startinsert")
end

local function note_error(ctx, err)
	if err == "stopped" then
		resume_insert(ctx)
		return
	end
	if err == "busy" then
		vim.notify("tai: busy", vim.log.levels.WARN)
	else
		vim.notify("tai: " .. tostring(err), vim.log.levels.ERROR)
	end
	resume_insert(ctx)
end

local function place_text(ctx, raw)
	local text = inline.reply_text(ctx.insert_kind or "insert", raw, ctx)
	if text == "" then
		vim.notify("tai: empty reply", vim.log.levels.WARN)
		resume_insert(ctx)
		return
	end
	local buf = ctx.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		vim.notify("tai: buffer is gone", vim.log.levels.WARN)
		resume_insert(ctx)
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, ctx.row - 1, ctx.row, false)[1] or ""
	local moved = false
	if ctx.line_at ~= nil then
		moved = line ~= ctx.line_at
	else
		moved = line:sub(1, ctx.col) ~= (ctx.line_prefix or "")
	end
	if moved then
		vim.notify("tai: buffer changed, reply discarded", vim.log.levels.WARN)
		resume_insert(ctx)
		return
	end
	local in_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
	if in_insert then
		vim.cmd("stopinsert")
	end
	local _, row_off, new_col = inline.splice(line, ctx.col, text)
	local lines = vim.split(text, "\n", { plain = true })
	local wrote, write_err = pcall(vim.api.nvim_buf_set_text, buf, ctx.row - 1, ctx.col, ctx.row - 1, ctx.col, lines)
	if not wrote then
		vim.notify("tai: " .. tostring(write_err), vim.log.levels.ERROR)
		resume_insert(ctx)
		return
	end
	local new_row = ctx.row + row_off
	local win = ctx.win
	if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
		vim.api.nvim_set_current_win(win)
		pcall(vim.api.nvim_win_set_cursor, win, { new_row, new_col })
	end
	if in_insert or ctx.return_insert then
		vim.cmd("startinsert")
	end
end

local function ask_insert(kind, ctx)
	local view = ui_mod()
	if not view then
		resume_insert(ctx)
		return
	end
	local label = (kind == "complete") and "Tai: completing…" or "Tai: writing at the cursor…"
	vim.notify(label, vim.log.levels.INFO)
	ctx.insert_kind = kind
	view.inline_request(inline.messages(kind, ctx), kind, function(raw, err)
		if err then
			note_error(ctx, err)
			return
		end
		place_text(ctx, raw)
	end)
end

local function region_missing(sel)
	return not sel or sel.text == nil or not sel.start_line or sel.start_line == 0
end

local function deliver_selection(sel)
	local view = ui_mod()
	if not view then
		return
	end
	if region_missing(sel) or (blank(sel.text) and blank(sel.instruction)) then
		vim.notify("tai: empty selection", vim.log.levels.WARN)
		return
	end
	local kind = blank(sel.instruction) and "selection" or "selection_prompt"
	vim.notify("Tai: asking about the selection…", vim.log.levels.INFO)
	view.inline_request(inline.messages(kind, sel), kind, function(raw, err)
		if err then
			note_error(nil, err)
			return
		end
		local text = inline.reply_text(kind, raw, sel)
		if text == "" then
			vim.notify("tai: empty reply", vim.log.levels.WARN)
			return
		end
		view.show_exchange("SELECTION", inline.preview(sel), text)
	end)
end

function M.visual_send()
	local kind = vim.fn.visualmode()
	if kind == "" then
		kind = "v"
	end
	deliver_selection(inline.capture(0, "<", ">", kind))
end

function M.visual_prompt()
	local kind = vim.fn.visualmode()
	if kind == "" then
		kind = "v"
	end
	local sel = inline.capture(0, "<", ">", kind)
	if region_missing(sel) then
		vim.notify("tai: empty selection", vim.log.levels.WARN)
		return
	end
	vim.ui.input({ prompt = "Tai selection: " }, function(input)
		if blank(input) then
			return
		end
		sel.instruction = input
		deliver_selection(sel)
	end)
end

function M.operator_send(type)
	deliver_selection(inline.capture(0, "[", "]", type or "char"))
end

function M.operator_send_with_prompt(type)
	local sel = inline.capture(0, "[", "]", type or "char")
	if region_missing(sel) then
		vim.notify("tai: empty selection", vim.log.levels.WARN)
		return
	end
	vim.ui.input({ prompt = "Tai selection: " }, function(input)
		if blank(input) then
			return
		end
		sel.instruction = input
		deliver_selection(sel)
	end)
end

function M.complete()
	local ctx = inline.capture_cursor()
	ctx.return_insert = true
	ask_insert("complete", ctx)
end

function M.prompt_insert()
	local ctx = inline.capture_cursor()
	ctx.return_insert = true
	vim.ui.input({ prompt = "Tai insert: " }, function(input)
		if blank(input) then
			resume_insert(ctx)
			return
		end
		ctx.instruction = input
		ask_insert("insert", ctx)
	end)
end

-- Insert-mode <C-X> opens completion mode before a two-key map can run, so
-- <C-T> would stay thesaurus completion. This reads the next key first.
function M.ctrl_x()
	local ok, key = pcall(vim.fn.getcharstr)
	if not ok or type(key) ~= "string" or key == "" then
		return ""
	end
	local function same(name)
		return key == vim.api.nvim_replace_termcodes(name, true, false, true)
	end
	if same("<C-T>") then
		vim.schedule(function()
			M.complete()
		end)
		return ""
	end
	if same("<C-A>") then
		vim.schedule(function()
			M.prompt_insert()
		end)
		return ""
	end
	return vim.api.nvim_replace_termcodes("<C-X>", true, false, true) .. key
end

function _G.tai_operator_send(type)
	M.operator_send(type)
end

function _G.tai_operator_send_with_prompt(type)
	M.operator_send_with_prompt(type)
end

function M.setup(opts)
	opts = opts or {}
	log.set_level(opts.log_level or log.DEBUG)

	if not config.provider then
		return
	end

	-- Initialize context module if enabled
	if config.context and config.context.enabled then
		local context = require("tai.context")
		context.setup(config.context)
	end

	-- Configure + connect MCP servers from .tai
	mcp.configure(config.mcps)
	mcp.update_tool_def(tools.defs)
	mcp.connect_all(function()
		mcp.update_tool_def()
	end)

	ui.init()
end

function M.reload(opts)
	local ok, err = config.reload()
	if not ok then
		vim.notify("tai: failed to reload config: " .. (err or ""), vim.log.levels.ERROR)
		return
	end
	mcp.configure(config.mcps)
	mcp.update_tool_def(tools.defs)
	mcp.connect_all(function()
		mcp.update_tool_def()
	end)
	ui.update_chat_name()
	ui.update_input_name()
	vim.notify("tai: config reloaded", vim.log.levels.INFO)
end

function M.toggle_chat_window()
	ui.toggle_chat_window()
end

function M.clear_history()
	ui.clear()
end

function M.chat()
	ui.open()
	ui.focus_input()
end

function M.stop()
	ui.stop()
end

return M
