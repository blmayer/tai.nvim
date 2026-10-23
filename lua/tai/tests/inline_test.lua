-- Run: nvim --headless -u NONE --noplugin -c "set rtp+=." -c "luafile lua/tai/tests/inline_test.lua" -c "qa!"

local passed, failed = 0, 0

local function assert_eq(a, b, msg)
	if a == b then
		passed = passed + 1
		print("  OK " .. msg)
	else
		failed = failed + 1
		print("  FAIL " .. msg .. " exp=" .. vim.inspect(a) .. " got=" .. vim.inspect(b))
	end
end

local function assert_true(v, msg)
	if v then
		passed = passed + 1
		print("  OK " .. msg)
	else
		failed = failed + 1
		print("  FAIL " .. msg)
	end
end

local function assert_match(pat, s, msg)
	if type(s) == "string" and s:find(pat, 1, true) then
		passed = passed + 1
		print("  OK " .. msg)
	else
		failed = failed + 1
		print("  FAIL " .. msg .. " in: " .. tostring(s):sub(1, 180))
	end
end

local inline = require("tai.inline")

print("\n=== prompts ===")
local kinds = { "selection", "selection_prompt", "complete", "insert" }
for _, kind in ipairs(kinds) do
	local p = inline.prompts[kind]
	assert_true(type(p) == "string" and #p > 80, kind .. " prompt")
	assert_true(not p:find("create_task", 1, true), kind .. " is not the planner")
end
assert_true(inline.prompts.selection ~= inline.prompts.selection_prompt, "selection prompts differ")
assert_true(inline.prompts.complete ~= inline.prompts.insert, "insert prompts differ")
assert_match("<before>", inline.prompts.complete, "complete names the cursor tags")
assert_match("<after>", inline.prompts.complete, "complete names the suffix")
assert_match("instruction", inline.prompts.insert:lower(), "insert prompt follows an instruction")
assert_match("no other instruction", inline.prompts.selection, "bare selection has no extra instruction")
assert_match("Follow the instruction", inline.prompts.selection_prompt, "selection prompt follows the instruction")
assert_match("only the missing characters", inline.prompts.complete, "complete returns an insertion")
assert_match("only the insertion", inline.prompts.insert, "insert returns an insertion")

print("\n=== messages ===")
local sel_msgs = inline.messages("selection", {
	path = "lua/tai/inline.lua",
	filetype = "lua",
	start_line = 4,
	end_line = 6,
	text = "local M = {}",
})
assert_eq("system", sel_msgs[1].role, "selection system role")
assert_eq(inline.prompts.selection, sel_msgs[1].content, "selection system prompt")
assert_match("<selection>", sel_msgs[2].content, "selection tag")
assert_match("local M = {}", sel_msgs[2].content, "selection body")
assert_true(not sel_msgs[2].content:find("Instruction:", 1, true), "bare selection has no instruction")

local ask_msgs = inline.messages("selection_prompt", {
	path = "a.lua",
	filetype = "lua",
	start_line = 1,
	end_line = 1,
	text = "print(1)",
	instruction = "explain this call",
})
assert_eq(inline.prompts.selection_prompt, ask_msgs[1].content, "prompted selection system prompt")
assert_match("explain this call", ask_msgs[2].content, "instruction is in the user message")
assert_match("<selection>", ask_msgs[2].content, "prompted selection tag")

local cur_msgs = inline.messages("complete", {
	path = "a.lua",
	filetype = "lua",
	row = 3,
	col = 4,
	before = "abc",
	after = "xyz",
})
assert_eq(inline.prompts.complete, cur_msgs[1].content, "complete system prompt")
assert_match("<before>", cur_msgs[2].content, "complete before tag")
assert_match("abc", cur_msgs[2].content, "complete before text")
assert_match("<after>", cur_msgs[2].content, "complete after tag")
assert_match("xyz", cur_msgs[2].content, "complete after text")
assert_true(not cur_msgs[2].content:find("Instruction:", 1, true), "complete has no instruction")

local ins_msgs = inline.messages("insert", {
	path = "a.lua",
	filetype = "lua",
	row = 2,
	col = 0,
	before = "",
	after = "return",
	instruction = "a guard clause",
})
assert_eq(inline.prompts.insert, ins_msgs[1].content, "insert system prompt")
assert_match("a guard clause", ins_msgs[2].content, "insert instruction")
assert_match("<before>", ins_msgs[2].content, "insert before tag")
assert_match("<after>", ins_msgs[2].content, "insert after tag")

local huge = string.rep("x", inline.limits.selection + 50)
local clipped = inline.user_text("selection", { text = huge, path = "a.lua", filetype = "lua" })
assert_match("(selection truncated)", clipped, "long selection is marked")
assert_true(clipped:find(string.rep("x", inline.limits.selection + 1), 1, true) == nil, "long selection is cut")
assert_match(string.rep("x", 40), clipped, "long selection keeps a prefix")

print("\n=== insertion cleanup ===")
assert_eq("return 1", inline.unwrap_fence("```lua\nreturn 1\n```"), "unwrap fence")
assert_eq("return 1", inline.unwrap_fence("```lua \nreturn 1\n``` \n"), "unwrap fence with trailing spaces")
assert_eq("return 1", inline.unwrap_fence("Sure:\n```lua\nreturn 1\n```\n"), "unwrap fenced preamble")
assert_eq("answer", inline.strip_thinking("<think>\nhidden\n</think>\nanswer"), "strip thinking")
assert_eq("(arg)\n  return arg", inline.strip_overlap("local function name(arg)\n  return arg", "local function name", ""), "drop echoed prefix")
assert_eq("return 1", inline.strip_overlap("        return 1", "        ", "\nend"), "drop echoed indent")
assert_eq("foo()", inline.prepare_insertion("foo()\nend", "local ", "\nend"), "drop echoed suffix")
assert_eq("x + 1", inline.prepare_insertion("```lua\nx + 1\n```\n", "total = ", ")"), "mid-line fence loses the extra newline")
assert_eq("x + 1\n", inline.prepare_insertion("x + 1\n", "total = ", ""), "keep a trailing newline at eof")
assert_eq("", inline.reply_text("complete", "```\nlocal name\n```", { before = "local name", after = "" }), "echoed completion inserts nothing")

print("\n=== cursor view ===")
local lines = {}
for i = 1, 40 do
	lines[i] = string.format("L%02d %s", i, string.rep("a", 40))
end
local view = inline.cursor_view(nil, 20, 4, lines, "src/a.lua", "lua")
assert_eq("L20 ", view.line_prefix, "prefix is the bytes before the cursor")
assert_eq(lines[20], view.line_at, "snapshot of the cursor line")
assert_true(view.before:sub(-4) == "L20 ", "before ends at the cursor")
assert_true(view.after:sub(1, 2) == "aa", "after starts at the cursor")
assert_match("L19 ", view.before, "before includes the previous line")
assert_match("L21 ", view.after, "after includes the next line")
assert_true(#view.before <= inline.limits.before, "before stays inside the budget")
assert_true(#view.after <= inline.limits.after, "after stays inside the budget")
local wide = {}
for i = 1, 200 do
	wide[i] = string.rep("b", 80)
end
local wide_view = inline.cursor_view(nil, 150, 10, wide, "", "")
assert_true(#wide_view.before <= inline.limits.before, "clipped before")
assert_true(#wide_view.after <= inline.limits.after, "clipped after")
assert_eq(wide[150]:sub(1, 10), wide_view.before:sub(-10), "clip keeps the cursor edge")
assert_eq("text", wide_view.filetype, "empty filetype is text")

print("\n=== region ===")
local src = { "abcd", "efgh", "ijkl" }
assert_eq("bcd\nefg", inline.region_text(src, 1, 1, 2, 2, "char"), "char region")
assert_eq("bcd\nefg", inline.region_text(src, 2, 2, 1, 1, "v"), "reversed char region")
assert_eq("abcd\nefgh", inline.region_text(src, 1, 1, 2, 2, "line"), "line region")
assert_eq("bc\nfg", inline.region_text(src, 1, 1, 2, 2, "block"), "block region")
assert_eq("", inline.region_text({}, 1, 0, 1, 1, "char"), "empty buffer")

vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, src)
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_mark(0, "<", 1, 1, {})
vim.api.nvim_buf_set_mark(0, ">", 3, 3, {})
local captured = inline.capture(0, "<", ">", "V")
assert_eq("abcd\nefgh\nijkl", captured.text, "linewise capture")
assert_eq("lua", captured.filetype, "capture filetype")
assert_eq(1, captured.start_line, "capture start")
assert_eq(3, captured.end_line, "capture end")
vim.api.nvim_win_set_cursor(0, { 2, 2 })
local cur = inline.capture_cursor(0)
assert_eq(2, cur.row, "cursor row")
assert_eq(2, cur.col, "cursor col")
assert_eq("ef", cur.line_prefix, "cursor prefix")
assert_match("ef", cur.before, "cursor before")
assert_true(cur.after:sub(1, 2) == "gh", "cursor after")

print("\n=== splice ===")
local one, row_off, col = inline.splice("abcd", 2, "X")
assert_eq("abXcd", one[1], "splice one line")
assert_eq(0, row_off, "splice stays on the line")
assert_eq(3, col, "splice cursor sits after the insert")
local many, row2, col2 = inline.splice("abcd", 2, "X\nY")
assert_eq("abX", many[1], "splice first line")
assert_eq("Ycd", many[2], "splice keeps the tail")
assert_eq(1, row2, "splice moves down one line")
assert_eq(1, col2, "splice cursor is after Y")

print("\n=== preview ===")
local preview = inline.preview({
	path = "a.lua",
	start_line = 2,
	end_line = 4,
	instruction = "rename it",
	text = "foo",
})
assert_match("a.lua:2-4", preview, "preview range")
assert_match("rename it", preview, "preview instruction")
assert_match("foo", preview, "preview body")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	os.exit(1)
end
