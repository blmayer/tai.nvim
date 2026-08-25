-- subtask_test.lua
-- Run: nvim --headless -u NONE --noplugin -c "set rtp+=." -c "luafile lua/tai/tests/subtask_test.lua" -c "qa!"

local passed, failed = 0, 0

local function assert_eq(a, b, msg)
	if a == b then passed = passed + 1; print("  OK " .. msg)
	else failed = failed + 1; print("  FAIL " .. msg .. " exp=" .. vim.inspect(a) .. " got=" .. vim.inspect(b)) end
end
local function assert_true(v, msg)
	if v then passed = passed + 1; print("  OK " .. msg)
	else failed = failed + 1; print("  FAIL " .. msg) end
end
local function assert_match(pat, s, msg)
	if type(s) == "string" and s:find(pat) then passed = passed + 1; print("  OK " .. msg)
	else failed = failed + 1; print("  FAIL " .. msg .. " in: " .. tostring(s):sub(1, 200)) end
end

package.loaded["tai.config"] = {
	root = "/tmp/test-project",
	provider = "mock",
	model = "test",
	use_tools = true,
	stream = false,
	rpm = 60,
	context = { enabled = false },
	get_allowed_commands = function() return { ls = true } end,
}
package.loaded["tai.log"] = {
	debug = function() end, info = function() end,
	warning = function() end, error = function() end, set_level = function() end, DEBUG = 0,
}

package.loaded["tai.tools.subtask"] = nil
package.loaded["tai.tools"] = nil
package.loaded["tai.agent"] = nil

local tools = require("tai.tools")
local agent = require("tai.agent")
local mem = require("tai.tools.subtask")

print("\n=== subtask tool schema ===")
assert_true(tools.defs.subtask ~= nil, "subtask exists")
assert_true(tools.defs.todos == nil, "todos tool removed")
local p = tools.defs.subtask["function"].parameters
assert_true(vim.tbl_contains(p.required, "goal"), "goal required")
assert_true(p.properties.id == nil, "no todo id field")
assert_true(p.properties.system_prompt ~= nil, "system_prompt optional field")

print("\n=== agent frames ===")
local main = agent.new_frame({ profile = "main" })
assert_eq("MAIN", main.label, "main label")
assert_true(not main.isolated, "main shares the user chat")
assert_true(vim.tbl_contains(main.tools, "subtask"), "main has subtask")
assert_true(not vim.tbl_contains(main.tools, "todos"), "main has no todos")
assert_true(not vim.tbl_contains(main.tools, "edit"), "main has no edit")

local child = agent.new_frame({
	profile = "subtask",
	system_prompt = "You are a reviewer only.",
	tools = { "read", "shell", "subtask", "edit" },
	goal = "Review foo.lua exports",
})
assert_eq("SUBTASK", child.label, "subtask label")
assert_true(child.isolated, "child has a clean history")
assert_eq("Review foo.lua exports", child.goal, "child goal")
assert_eq(0, #child.steps, "child starts with no steps")
assert_true(vim.tbl_contains(child.tools, "subtask"), "child may nest subtask")
assert_true(not vim.tbl_contains(child.tools, "todos"), "child has no todos")
assert_eq("Review foo.lua exports", child.history[2].content, "goal as user message")

print("\n=== live context progress ===")
local empty = mem.render_memory({ goal = "", steps = {} })
assert_match("Goal:", empty, "has goal label")
assert_match("%(none%)", empty, "empty goal")
assert_match("Previous steps:", empty, "has previous steps label")
assert_match("Now:", empty, "has now hint")
assert_match("README", empty, "empty progress says read README")
assert_match("END CURRENT STATE", empty, "fenced current state")

assert_match("README", mem.next_step_hint({ steps = {} }), "hint when no steps")
assert_match("failure", mem.next_step_hint({
	steps = { { text = "x", status = "error", response = "status: error" } },
}), "hint after error")
assert_match("last report", mem.next_step_hint({
	steps = { { text = "x", response = "status: ok\nreport:\nok" } },
}), "hint after success")

local live = mem.render_memory({
	goal = "Ship the harness change",
	notes = "keep going",
	steps = {
		{ text = "Read lua/tai/agent.lua", response = "main_tools is subtask only" },
	},
})
assert_match("CURRENT STATE", live, "has current state banner")
assert_match("keep going", live, "has notes")
assert_match("Ship the harness change", live, "has goal")
assert_match("1%. Read lua/tai/agent%.lua", live, "has previous step")
assert_match("main_tools is subtask only", live, "has step response")

local payload = mem.format_complete("ok", "looked around", { goal = "Read agent.lua" })
assert_match("status: ok", payload, "format_complete ok")
assert_match("step: Read agent%.lua", payload, "format_complete step")
assert_match("report:", payload, "format_complete report")
assert_match("looked around", payload, "format_complete findings")

local errp = mem.format_complete("error", "ERROR [429 Too Many Requests]: rate limited", { goal = "Read agent.lua" })
assert_match("status: error", errp, "format_complete error status")
assert_match("error: ERROR %[429", errp, "format_complete keeps 429")

print("\n=== handoff dumps ===")
local short_out = mem.outcome_for({ tool_outputs = { "README.md\nAGENTS.md" } }, "")
assert_match("README.md", short_out, "empty reply forwards tool output")
assert_match("AGENTS.md", short_out, "forwards full short tool output")

local long_body = string.rep("x", 2000)
local no_text = mem.outcome_for({ tool_outputs = { long_body } }, "")
assert_match("%[%.%.%.%]", no_text, "long tool output is compacted")
assert_true(#no_text < 800, "compact tool output stays small")

local weak = mem.outcome_for({ tool_outputs = { "lua/tai/agent.lua" } }, "I'll look around")
assert_match("agent.lua", weak, "weak preamble yields tool output")

local strong = mem.outcome_for({ tool_outputs = { "ignored" } }, "found: a.lua\noutcome: nest.apply indents")
assert_match("nest.apply", strong, "real report wins over tools")
assert_true(not strong:match("ignored"), "real report drops tool body")

assert_true(mem.looks_like_dump("```\n" .. string.rep("code\n", 5)), "fence is a dump")
assert_true(not mem.looks_like_dump(string.rep("line\n", 25)), "plain lines are not a dump")
assert_true(not mem.looks_like_dump("found: a.lua\noutcome: nest.apply indents"), "short fact is not a dump")

local dumped = mem.summarize_handoff("found: lua/tai/ui/core.lua\n```\n" .. string.rep("local x\n", 30))
assert_match("found: lua/tai/ui/core.lua", dumped, "keeps found from dump")
assert_match("dump", dumped, "dump becomes retry signal")
assert_true(not dumped:match("local x"), "source stripped from dump")

local complete_dump = mem.format_complete("ok", "```\n" .. string.rep("local foo\n", 40), { goal = "Read core" })
assert_match("dump", complete_dump, "format_complete rejects fenced dump")
assert_true(not complete_dump:match("local foo"), "format_complete strips dump body")

print("\n=== notes ===")
local f = { notes = "" }
assert_match("updated", mem.run_notes({ action = "write", content = "hi" }, f), "write notes")
assert_eq("hi", f.notes, "notes stored")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
