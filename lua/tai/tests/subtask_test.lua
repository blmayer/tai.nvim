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
assert_true(p.properties.goals ~= nil, "goals list field")
assert_true(p.properties.role ~= nil, "role field")
assert_true(p.properties.step ~= nil, "step field")
assert_true(p.properties.system_prompt ~= nil, "system_prompt optional field")
assert_true(tools.defs.plan ~= nil, "plan tool exists")

print("\n=== agent frames ===")
local main = agent.new_frame({ profile = "main" })
assert_eq("MAIN", main.label, "main label")
assert_true(not main.isolated, "main shares the user chat")
assert_true(vim.tbl_contains(main.tools, "subtask"), "main has subtask")
assert_true(vim.tbl_contains(main.tools, "notes"), "main has notes")
assert_true(vim.tbl_contains(main.tools, "plan"), "main has plan")
assert_true(not vim.tbl_contains(main.tools, "todos"), "main has no todos")
assert_true(not vim.tbl_contains(main.tools, "edit"), "main has no edit")

local child = agent.new_frame({
	profile = "subtask",
	system_prompt = "You are a reviewer only.",
	tools = { "read", "shell", "subtask", "edit" },
	goal = "Review foo.lua exports",
})
assert_eq("CODER", child.label, "work tools infer coder")
assert_eq("coder", child.role, "child role")
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
assert_true(agent.system_prompt:find("cannot read, edit, or run commands", 1, true),
	"main cannot work itself")
assert_true(agent.system_prompt:find("Coders do the work", 1, true)
	or agent.decompose_prompt:find("You cannot do the work", 1, true),
	"main only delegates")
assert_true(agent.system_prompt:find("subtask, notes, and plan", 1, true),
	"main writes a plan first")
assert_true(main.phase == "decompose", "main starts by decomposing")
assert_true(not main.system_prompt:find("List the project", 1, true),
	"main has no work guide")
local default_prompt = agent.new_frame({ profile = "subtask", goal = "Look" })
assert_eq("orchestrator", default_prompt.role, "default child is orchestrator")
assert_true(default_prompt.system_prompt:find("break this goal", 1, true)
	or default_prompt.phase == "decompose",
	"default child starts in decompose")
assert_eq("decompose", default_prompt.phase, "new orchestrator decomposes")
assert_true(agent.decompose_prompt:find("smaller tasks", 1, true),
	"decompose prompt exists")
assert_true(agent.revise_prompt:find("update later items", 1, true),
	"revise prompt exists")
local coder_prompt = agent.new_frame({ profile = "subtask", role = "coder", goal = "Edit x" })
assert_true(coder_prompt.system_prompt:find("Do this one goal", 1, true),
	"coder stays on one goal")
assert_true(coder_prompt.system_prompt:find("several turns", 1, true),
	"coder may iterate")
assert_true(coder_prompt.system_prompt:find("invalid premise", 1, true),
	"coder reports missing files")
assert_true(coder_prompt.system_prompt:find("Do not call subtask unless it is listed", 1, true),
	"coder is not told to subtask by default")
assert_true(coder_prompt.system_prompt:find("short discoveries", 1, true),
	"coder handoff includes discoveries")
assert_true(agent.revise_prompt:find("Copy useful discoveries", 1, true),
	"revise copies discoveries into notes")
assert_true(agent.validator_prompt:find("in the Goal's own words", 1, true),
	"validator may not invent work")
assert_true(agent.iterates(coder_prompt), "coder iterates")
assert_true(not agent.iterates(main), "main does not iterate tools")
assert_true(agent.iterates(default_prompt), "isolated orchestrator iterates")
assert_true(not agent.iterates(vframe), "validator does not iterate")
assert_eq(12, agent.MAX_CODER_TURNS, "coder turn cap")
local vframe = agent.new_frame({ profile = "subtask", role = "validator", goal = "check" })
assert_eq(0, #vframe.tools, "validator has no tools")
assert_true(vframe.system_prompt:find("Judge only", 1, true), "validator judges")

print("\n=== render_tools ===")
assert_eq("", agent.render_tools(nil), "nil list is empty")
assert_eq("", agent.render_tools({}), "empty list is empty")
local granted = agent.render_tools({ "subtask", "notes" })
assert_match("You may call only:", granted, "call header")
assert_match("%- subtask: spawn a plan step", granted, "describes subtask")
assert_match("%- notes: shared pad", granted, "describes notes")
assert_match("%- plan: write or update", granted, "describes plan")
assert_match("including ones you cannot call:", granted, "grant header")
assert_match("%- shell: run a command", granted, "describes shell for granting")
assert_match("%- read: open a file", granted, "describes read for granting")
assert_true(not granted:find("Other tools are denied", 1, true), "no blanket deny")
local leaf_cat = agent.render_tools({ "read" })
assert_match("%- read: open a file", leaf_cat, "leaf describes granted")
assert_true(not leaf_cat:find("including ones you cannot call", 1, true), "leaf has no grant list")
assert_true(not leaf_cat:find("- shell:", 1, true), "leaf does not advertise shell")

print("\n=== roles and goals ===")
assert_eq("orchestrator", agent.parse_role("manager"), "manager alias")
assert_eq("coder", agent.parse_role(nil, { profile = "subtask", tools = { "read" } }), "infer coder")
assert_eq("orchestrator", agent.parse_role(nil, { profile = "subtask", tools = { "subtask" } }), "infer orchestrator")
local gs = agent.parse_goals(nil, { " list a ", "", "read b" })
assert_eq(2, #gs, "drops empty goals")
assert_eq("list a", gs[1], "trims goals")
assert_eq("read b", gs[2], "keeps second")
assert_eq("only", agent.parse_goals("only", nil)[1], "single goal")
local coder_def = agent.tools_for_role("coder", nil)
assert_true(vim.tbl_contains(coder_def, "read"), "coder default has read")
assert_true(not vim.tbl_contains(coder_def, "subtask"), "coder default does not nest")
assert_eq(0, #agent.tools_for_role("validator", { "shell" }), "validator strips tools")
local orch_tools = agent.tools_for_role("orchestrator", { "read", "shell", "edit" })
assert_eq(3, #orch_tools, "orchestrator has fixed tool count")
assert_true(vim.tbl_contains(orch_tools, "subtask"), "orchestrator has subtask")
assert_true(vim.tbl_contains(orch_tools, "notes"), "orchestrator has notes")
assert_true(vim.tbl_contains(orch_tools, "plan"), "orchestrator has plan")
assert_true(not vim.tbl_contains(orch_tools, "read"), "orchestrator cannot take read")
local forced = agent.new_frame({
	profile = "subtask",
	role = "orchestrator",
	tools = { "read", "shell" },
	goal = "Coordinate",
})
assert_true(not vim.tbl_contains(forced.tools, "read"), "orchestrator frame drops work tools")
assert_true(agent.system_prompt:find("reply in text with no tool call", 1, true)
	or agent.revise_prompt:find("handoff", 1, true),
	"orchestrator knows how to hand off")
local queued = agent.new_frame({
	profile = "subtask",
	role = "coder",
	goals = { "list lua/tai", "read agent.lua 1:20" },
})
assert_eq(2, #queued.goals, "stores goal list")
assert_eq("list lua/tai", queued.goal, "current is first")
assert_eq(1, queued.goal_index, "starts at first")

print("\n=== validator verdict ===")
assert_eq("ok", mem.parse_verdict("ok"), "ok")
assert_eq("ok", mem.parse_verdict("OK\nextra"), "ok first line")
local v, miss = mem.parse_verdict("missing: read lua/tai/context.lua 1:40")
assert_eq("missing", v, "missing verdict")
assert_eq("read lua/tai/context.lua 1:40", miss, "missing action")
assert_eq("missing", mem.parse_verdict(""), "empty is missing")
local bv, why = mem.parse_verdict("blocked: lua/tai/nope.lua does not exist")
assert_eq("blocked", bv, "blocked verdict")
assert_eq("lua/tai/nope.lua does not exist", why, "blocked reason")
assert_eq("blocked", mem.parse_verdict("blocked"), "blocked alone")
local _, why2 = mem.parse_verdict("BLOCKED: No such path")
assert_eq("No such path", why2, "blocked is case-insensitive")
assert_match("blocked:", mem.validator_brief("list files", "agent.lua"), "brief lists blocked")
assert_match("Goal:", mem.validator_brief("list files", "agent.lua"), "brief has goal")
assert_match("agent%.lua", mem.validator_brief("list files", "agent.lua"), "brief has result")
assert_match("Do not invent", mem.validator_brief("list files", "agent.lua"), "brief forbids new tasks")
assert_true(not mem.validator_brief("g", "r"):find("Changes", 1, true), "no changes section when empty")
local ch = require("tai.tools.changes")
local fr = { file_changes = {}, changed_set = {} }
ch.record_edit(fr, "a.lua", "old line", "new line")
local rendered = ch.render(fr)
assert_match("%-old line", rendered, "edit removes old")
assert_match("%+new line", rendered, "edit adds new")
ch.record_write(fr, "b.lua", "hello")
assert_match("b%.lua", ch.render(fr), "write is included")
ch.record_command(fr, "read: lua/tai/context.lua [1:80]", false)
ch.record_command(fr, "find . -name '*.lua'", false)
ch.record_command(fr, "edit: lua/tai/ui/core.lua", false)
ch.record_command(fr, "ls nope", true)
local cmds = ch.render_commands(fr)
assert_match("read: lua/tai/context%.lua", cmds, "records read")
assert_match("edit: lua/tai/ui/core%.lua", cmds, "records edit")
assert_match("find %. %-name", cmds, "records command")
assert_match("%[failed%]", cmds, "marks failed command")
assert_true(not cmds:find("output", 1, true), "tool list has no output")
local with_ch = mem.validator_brief("g", "r", ch.render(fr), cmds)
assert_match("Changes %(this agent only%)", with_ch, "brief includes this agent's diff")
assert_match("Tools %(this agent only", with_ch, "brief includes tools")
assert_eq("", ch.render({}), "empty frame has no changes")
assert_eq("", ch.render_commands({}), "empty frame has no commands")
assert_true(mem.same_scope(
	"Identify where session history is loaded",
	"identify where session history is loaded"
), "missing restates the goal")
assert_true(not mem.same_scope(
	"Identify where session history is loaded",
	"run ls -R to map the directory"
), "invented command is off scope")
assert_true(not mem.same_scope(
	"Identify where session history is loaded",
	"Add a call to context.load in ui/core.lua"
), "invented implementation is off scope")
local miss_frame = { goal = "Identify where session history is loaded", original_goal = "Identify where session history is loaded" }
mem.apply_missing(miss_frame, "run ls -R in the project")
assert_eq("Identify where session history is loaded", miss_frame.goal, "invented missing does not replace the goal")
assert_true(not (miss_frame.task_notes or ""):find("ls -R", 1, true), "invented missing is not stored")
mem.apply_missing(miss_frame, "identify where session history is loaded")
assert_match("Still undone from the Goal", miss_frame.task_notes, "on-scope missing is noted")

print("\n=== plan ===")
local plan = require("tai.tools.plan")
local host = { plan = {} }
local written = plan.run({
	action = "write",
	items = {
		{ agent = "coder", goal = "list lua/tai", notes = "look for session load" },
		{ agent = "manager", goal = "decide the file", notes = "" },
		{ goal = "" },
	},
}, host)
assert_match("2 steps", written, "write drops empty items")
assert_eq("coder", host.plan[1].agent, "first is coder")
assert_eq("orchestrator", host.plan[2].agent, "manager alias")
assert_eq("pending", host.plan[1].status, "default pending")
assert_eq("look for session load", host.plan[1].notes, "keeps item notes")
plan.mark(host, 1, "ok", "found context.lua")
assert_eq("ok", host.plan[1].status, "mark ok")
local upd, uerr = plan.update(host, 2, { notes = "read lua/tai/context.lua", goal = "read the load fn" })
assert_true(upd ~= nil, "update later item")
assert_eq(nil, uerr, "update ok")
assert_eq("read the load fn", host.plan[2].goal, "updated goal")
assert_eq("read lua/tai/context.lua", host.plan[2].notes, "updated notes")
assert_eq("pending", host.plan[2].status, "update keeps status")
local rendered = plan.render(host.plan)
assert_true(not rendered:find("=====", 1, true), "no plan fence")
assert_match("1%. list lua/tai", rendered, "renders goal")
assert_match("Notes: look for session load", rendered, "renders notes")
assert_match("%[PENDING%]", rendered, "renders status tag")
assert_match("%(coder %- read shell edit%)", rendered, "renders agent tools")
assert_eq("", plan.render_task_notes(""), "empty task notes skip")
assert_match("TASK NOTES", plan.render_task_notes("only this step"), "task notes fence")
local tasked = agent.new_frame({
	profile = "subtask",
	role = "coder",
	goal = "list lua/tai",
	task_notes = "look for session load",
	plan_step = 1,
})
assert_eq("look for session load", tasked.task_notes, "child carries task notes")
assert_eq(1, tasked.plan_step, "child remembers plan step")

print("\n=== plan tree ===")
local topf = { plan = {}, role = "orchestrator", plan_path = {} }
topf.plan_root = topf.plan
plan.set(topf, {
	{ agent = "orchestrator", goal = "implement load", notes = "branch" },
	{ agent = "coder", goal = "sibling work" },
})
local branch = {
	role = "orchestrator",
	plan_root = topf.plan,
	plan_path = { 1 },
}
plan.set(branch, {
	{ agent = "coder", goal = "list files", notes = "cwd" },
})
assert_eq("list files", topf.plan[1].children[1].goal, "branch write is nested")
assert_eq("sibling work", topf.plan[2].goal, "sibling untouched")
plan.update(branch, 1, { notes = "filled" })
assert_eq("filled", topf.plan[1].children[1].notes, "branch update is local")
local _, berr = plan.update(branch, 2, { goal = "nope" })
assert_true(berr ~= nil, "branch cannot update a missing sibling")
plan.update(topf, "1.1", { goal = "list lua/tai" })
assert_eq("list lua/tai", topf.plan[1].children[1].goal, "top can edit a deep node")
local tree = plan.render(topf.plan)
assert_match("1%.1%. list lua/tai", tree, "renders nested path")
assert_true(not tree:find("=====", 1, true), "tree has no fence")
assert_eq(1, plan.next_pending(branch), "branch next is its first child")
plan.mark(topf, 1, "running")
local n1, p1 = plan.next_pending(topf)
assert_eq(2, n1, "top next pending skips running")
assert_eq("sibling work", p1.goal, "pending sibling")
plan.mark(topf, 2, "ok")
assert_eq(nil, plan.next_pending(topf), "no pending left at top")
local br = plan.render_for(branch)
assert_match("branch: 1", br, "branch header")
assert_match("list lua/tai", br, "branch sees its children")
assert_true(not br:find("sibling work", 1, true), "branch does not see sibling")
assert_eq("", plan.render_for({ role = "coder", plan = topf.plan }), "coder is not shown the plan")

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
local orch_mem = mem.render_memory({
	role = "orchestrator",
	steps = { { text = "list lua/tai", response = "found context.lua" } },
})
assert_match("Update later plan items", orch_mem, "orchestrator revises after ok")
local blocked_mem = mem.render_memory({
	role = "orchestrator",
	steps = { { text = "read nope.lua", response = "blocked: not found", status = "blocked" } },
})
assert_match("%[blocked%]", blocked_mem, "blocked step is tagged")
assert_match("Last step was blocked", blocked_mem, "orchestrator must replan")
assert_true(not blocked_mem:find("Last step was validated", 1, true), "blocked is not treated as ok")

local payload = mem.format_complete("ok", "looked around", { goal = "Read agent.lua" })
assert_match("status: ok", payload, "format_complete ok")
assert_match("step: Read agent%.lua", payload, "format_complete step")
assert_match("report:", payload, "format_complete report")
assert_match("looked around", payload, "format_complete findings")

local errp = mem.format_complete("error", "ERROR [429 Too Many Requests]: rate limited", { goal = "Read agent.lua" })
assert_match("status: error", errp, "format_complete error status")
assert_match("error: ERROR %[429", errp, "format_complete keeps 429")

local blk = mem.format_complete("blocked", "file does not exist", { goal = "Read nope.lua" })
assert_match("status: blocked", blk, "format_complete blocked status")
assert_match("blocked: file does not exist", blk, "format_complete blocked reason")

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
