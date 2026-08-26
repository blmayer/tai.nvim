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
assert_true(vim.tbl_contains(main.tools, "notes"), "main has notes")
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
assert_eq(4, #child.tools, "explicit tools are not replaced by the default set")
assert_eq("Review foo.lua exports", child.history[2].content, "goal as user message")

print("\n=== same_goal ===")
assert_true(mem.same_goal(
	"search for the term 'provider' in Makefile to identify configurations",
	"search for the term 'provider' in Makefile and return any matching lines"
), "same search restated")
assert_true(mem.same_goal("Read README.md", "read README.md"), "case/space only")
assert_true(not mem.same_goal(
	"list files in lua/tai",
	"grep provider in README.md"
), "different jobs")

print("\n=== clean history ===")
local informed = agent.new_frame({
	profile = "subtask",
	tools = { "shell" },
	goal = "grep provider in README.md",
	steps = { { text = "list files", response = "README.md exists" } },
})
assert_eq("grep provider in README.md", informed.history[2].content, "history is only the goal")
assert_eq(2, #informed.history, "no extra history messages")
assert_true(not mem.render_memory(informed):match("grep provider"), "goal stays out of system state")
assert_match("list files", mem.render_memory(informed), "sibling steps are injected")
assert_match("README.md exists", mem.render_memory(informed), "step report is injected")

print("\n=== tool_granted ===")
assert_true(agent.tool_granted({ "subtask", "notes" }, "subtask"), "granted name")
assert_true(agent.tool_granted({ "subtask", "notes" }, "notes"), "granted notes")
assert_true(not agent.tool_granted({ "subtask", "notes" }, "shell"), "ungranted shell")
assert_true(not agent.tool_granted({ "subtask", "notes" }, "read"), "ungranted read")
assert_true(not agent.tool_granted(nil, "shell"), "nil list")
assert_true(not agent.tool_granted({ "subtask" }, ""), "empty name")
assert_true(not agent.tool_granted({ "subtask" }, nil), "nil name")

print("\n=== orchestrator prompt ===")
assert_true(main.system_prompt:find("cannot read, edit, or run commands", 1, true),
	"main cannot work itself")
assert_true(main.system_prompt:find("only reply to the user or call subtask", 1, true),
	"main only delegates")
assert_true(main.system_prompt:find("even if you cannot call them", 1, true),
	"main grants tools it cannot call")
assert_true(not main.system_prompt:find("List the project", 1, true),
	"main has no work guide")
local default_prompt = agent.new_frame({ profile = "subtask", goal = "Look" })
assert_true(default_prompt.system_prompt:find("even ones you cannot call", 1, true),
	"child may grant tools it cannot call")

print("\n=== render_tools ===")
assert_eq("", agent.render_tools(nil), "nil list is empty")
assert_eq("", agent.render_tools({}), "empty list is empty")
local granted = agent.render_tools({ "subtask", "notes" })
assert_match("You may call only:", granted, "call header")
assert_match("%- subtask: spawn one smaller step", granted, "describes subtask")
assert_match("%- notes: shared pad", granted, "describes notes")
assert_match("before you spawn", granted, "notes is for briefing")
assert_match("including ones you cannot call:", granted, "grant header")
assert_match("%- shell: run a command", granted, "describes shell for granting")
assert_match("%- read: open a file", granted, "describes read for granting")
assert_true(not granted:find("Other tools are denied", 1, true), "no blanket deny")
local leaf_cat = agent.render_tools({ "read" })
assert_match("%- read: open a file", leaf_cat, "leaf describes granted")
assert_true(not leaf_cat:find("including ones you cannot call", 1, true), "leaf has no grant list")
assert_true(not leaf_cat:find("- shell:", 1, true), "leaf does not advertise shell")

print("\n=== sanitize_subtask_tools ===")
local leaf = agent.sanitize_subtask_tools({ "read", "shell" })
assert_eq(2, #leaf, "keeps a valid list")
assert_true(not vim.tbl_contains(leaf, "subtask"), "does not add subtask")

local nest = agent.sanitize_subtask_tools({ "read", "subtask" })
assert_true(vim.tbl_contains(nest, "subtask"), "keeps requested subtask")

assert_true(vim.tbl_contains(agent.sanitize_subtask_tools({ "read", "nope" }), "read"), "drops unknown")
local fallback = agent.sanitize_subtask_tools({ "grep" })
assert_true(vim.tbl_contains(fallback, "subtask"), "unknown list uses coordinator default")
assert_true(not vim.tbl_contains(fallback, "read"), "default has no read")
assert_true(vim.tbl_contains(agent.sanitize_subtask_tools(nil), "subtask"), "nil uses coordinator default")
assert_true(not vim.tbl_contains(agent.sanitize_subtask_tools(nil), "read"), "nil default has no read")

local read_only = agent.new_frame({
	profile = "subtask",
	tools = { "read" },
	goal = "Read README.md lines 1:20",
})
assert_eq("read", read_only.tools[1], "read-only child is a leaf")
assert_true(not vim.tbl_contains(read_only.tools, "subtask"), "leaf does not nest")

local default_child = agent.new_frame({ profile = "subtask", goal = "Look around" })
assert_true(vim.tbl_contains(default_child.tools, "subtask"), "default child may nest")
assert_true(not vim.tbl_contains(default_child.tools, "read"), "default child has no read")
assert_true(not vim.tbl_contains(default_child.tools, "shell"), "default child has no shell")

print("\n=== live context ===")
assert_eq("", mem.render_memory({ goal = "Ship the harness change" }), "no fence without skills or steps")
assert_true(not mem.render_memory({ goal = "Ship the harness change" }):match("Ship the"), "goal not injected")
local stepped = mem.render_memory({
	steps = { { text = "list lua/tai", response = "found context.lua" } },
})
assert_match("LIVE CONTEXT", stepped, "steps open a live context fence")
assert_match("list lua/tai", stepped, "step text")
assert_match("found context%.lua", stepped, "step response")

local payload = mem.format_complete("ok", "looked around", { goal = "Read agent.lua" })
assert_match("status: ok", payload, "format_complete ok")
assert_match("step: Read agent%.lua", payload, "format_complete step")
assert_match("report:", payload, "format_complete report")
assert_match("looked around", payload, "format_complete findings")

local errp = mem.format_complete("error", "ERROR [429 Too Many Requests]: rate limited", { goal = "Read agent.lua" })
assert_match("status: error", errp, "format_complete error status")
assert_match("error: ERROR %[429", errp, "format_complete keeps 429")

print("\n=== handoff ===")
local short_out = mem.outcome_for({ tool_outputs = { "README.md\nAGENTS.md" } }, "")
assert_match("README.md", short_out, "empty reply forwards tool output")
assert_match("AGENTS.md", short_out, "forwards full tool output")

local long_body = string.rep("x", 2000)
local no_text = mem.outcome_for({ tool_outputs = { long_body } }, "")
assert_true(#no_text == 2000, "tool output is not sliced")

local said = mem.outcome_for({ tool_outputs = { "README.md" } }, "I'll look around")
assert_match("README.md", said, "weak intent yields the tool result")
assert_true(not said:match("I'll look around"), "does not hand off a promise")
local fact = mem.outcome_for({ tool_outputs = { "ignored" } }, "found: lua/tai/context.lua")
assert_match("found: lua/tai/context.lua", fact, "keeps a real report")

print("\n=== build_request_tools ===")
local common = require("tai.provider_common")
local built = common.build_request_tools("chat_completions", { "subtask", "notes" })
assert_eq(2, #built, "only granted tools")
assert_eq("subtask", built[1]["function"].name, "first is subtask")
assert_eq("notes", built[2]["function"].name, "second is notes")
assert_eq(0, #common.build_request_tools("chat_completions", nil), "nil list is empty")
local unknown = common.build_request_tools("chat_completions", { "nope", "shell" })
assert_eq(1, #unknown, "drops unknown")
assert_eq("shell", unknown[1]["function"].name, "keeps known")

print("\n=== notes ===")
mem.set_notes("")
assert_eq("", mem.render_notes(), "empty notes skip injection")
assert_match("updated", mem.run_notes({ action = "write", content = "hi" }), "write notes")
assert_eq("hi", mem.get_notes(), "notes stored globally")
assert_match("NOTES", mem.render_notes(), "fenced notes block")
assert_match("hi", mem.render_notes(), "notes body injected")
assert_true(not mem.render_memory({ goal = "x" }):match("hi"), "notes stay out of SHARED NOTES fence")
assert_match("appended", mem.run_notes({ action = "append", content = "more" }), "append notes")
assert_eq("hi\nmore", mem.get_notes(), "append joins globally")
mem.set_notes("")
assert_eq("", mem.get_notes(), "set_notes clears")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
