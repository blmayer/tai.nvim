-- Run: nvim --headless -u NONE --noplugin -c "set rtp+=." -c "luafile lua/tai/tests/chat_test.lua" -c "qa!"

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

package.loaded["tai.config"] = {
	root = "/tmp/test-project",
	provider = "mock",
	model = "test",
	use_tools = true,
	stream = false,
	rpm = 60,
	context = { enabled = false },
	get_allowed_commands = function()
		return { ls = true }
	end,
}
package.loaded["tai.log"] = {
	debug = function() end,
	info = function() end,
	warning = function() end,
	error = function() end,
	set_level = function() end,
	DEBUG = 0,
}
package.loaded["tai.agent"] = nil
package.loaded["tai.tools"] = nil
package.loaded["tai.tools.notes"] = nil

local agent = require("tai.agent")
local tools = require("tai.tools")
local notes = require("tai.tools.notes")

print("\n=== chat agent ===")
local frame = agent.new_frame()
assert_eq(agent.system_prompt, frame.history[1].content, "history starts with the chat prompt")
assert_eq(1, #frame.history, "no extra history")
assert_true(frame.system_prompt:find("one coding assistant", 1, true), "one agent")
assert_true(frame.system_prompt:find("Do not guess paths", 1, true), "do not guess paths")
assert_true(frame.system_prompt:find("Do the work", 1, true), "do the work")
assert_true(frame.system_prompt:find("reply in text", 1, true), "reply in text")
assert_true(not frame.system_prompt:find("Use the skill tool", 1, true), "skill load is not a standing bullet")
assert_true(not frame.system_prompt:find("Use the mcp tool", 1, true), "mcp instruction is not in the chat prompt")
assert_true(not frame.system_prompt:find("There is no other agent", 1, true), "no other-agent line")
assert_true(not frame.system_prompt:find("No markdown", 1, true), "no style line")
assert_true(not frame.system_prompt:find("Use only tools", 1, true), "no tool-list sentence")
assert_true(not frame.system_prompt:find("Available Skills", 1, true), "no skill catalog in the prompt")
assert_true(not frame.system_prompt:find("subtask", 1, true), "prompt does not mention subtask")
assert_true(not frame.system_prompt:find("/tmp/test-project", 1, true), "prompt has no project path")
for _, name in ipairs({ "read", "shell", "edit", "write", "notes" }) do
	assert_true(vim.tbl_contains(frame.tools, name), "chat has " .. name)
end
assert_true(not vim.tbl_contains(frame.tools, "subtask"), "chat has no subtask")
assert_true(tools.defs.subtask == nil, "subtask tool is gone")
assert_true(tools.defs.read ~= nil, "read tool remains")

local shown = agent.render_tools(frame.tools)
assert_true(shown:find("read: open a file", 1, true) ~= nil, "tool list describes read")
assert_true(not shown:find("subtask", 1, true), "tool list has no subtask")

print("\n=== notes ===")
notes.set_notes("")
assert_eq("", notes.render_notes(), "empty notes are not injected")
assert_true(notes.run({ action = "write", content = "hi" }):find("updated", 1, true) ~= nil, "write notes")
assert_eq("hi", notes.get_notes(), "notes stored")
assert_true(notes.render_notes():find("NOTES\nUse the notes tool to manage this.", 1, true) ~= nil, "notes intro")
assert_true(notes.render_notes():find("hi", 1, true) ~= nil, "notes injected")
assert_true(notes.run({ action = "append", content = "more" }):find("appended", 1, true) ~= nil, "append notes")
assert_eq("hi\nmore", notes.get_notes(), "append joins")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	os.exit(1)
end
