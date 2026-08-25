-- nest_test.lua
-- Run: nvim --headless -u NONE --noplugin -c "set rtp+=." -c "luafile lua/tai/tests/nest_test.lua" -c "qa!"

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

package.loaded["tai.ui.nest"] = nil
local nest = require("tai.ui.nest")

print("\n=== nest.prefix ===")
assert_eq("", nest.prefix(0), "depth 0")
assert_eq("", nest.prefix(nil), "nil depth")
assert_eq("    ", nest.prefix(1), "depth 1")
assert_eq("        ", nest.prefix(2), "depth 2")

print("\n=== nest.apply worker text ===")
assert_eq("    hello", nest.apply("hello", 1, ""), "first line at depth 1")
assert_eq("    a\n    b", nest.apply("a\nb", 1, ""), "multiline at depth 1")
assert_eq("SUBTASK search\n    I found it", nest.apply("I found it", 1, "SUBTASK search"), "after SUBTASK header")
assert_eq("    SUBTASK run\n        I found", nest.apply("I found", 2, "    SUBTASK run"), "nested header then text")
assert_eq("    hel" .. "lo", nest.apply("lo", 1, "    hel"), "stream continuation")
assert_eq("    hello\n    world", nest.apply("\nworld", 1, "    hello"), "newline then next line")
assert_eq("    {{{" .. "\n    output\n    }}}", nest.apply("{{{\noutput\n}}}", 1, ""), "fold body indented")
assert_eq("    }}}\n    I found", nest.apply("I found", 1, "    }}}"), "text after fold close")
assert_eq("}}}\n    I found", nest.apply("I found", 1, "}}}"), "text after unindented fold close")

print("\n=== nest.apply main after child ===")
assert_eq("    I found\nNext step", nest.apply("Next step", 0, "    I found"), "main after indented child")
assert_eq("hello there", nest.apply(" there", 0, "hello"), "main mid-line glue")

print("\n=== nest.apply sequence (chat tree) ===")
local buf = ""
local function step(text, depth)
	local last = buf:match("([^\n]*)$") or ""
	local head = buf:sub(1, #buf - #last)
	buf = head .. nest.apply(text, depth, last)
end
step("\nSUBTASK search\n", 0)
step("I'll look around\n", 1)
step("shell: find . -name '*.lua'\n{{{\n", 1)
step("lua/tai/init.lua\n", 1)
step("}}}\n", 1)
step("Found init.lua\n", 1)
step("\nSUBTASK summarize\n", 1)
step("It is the entrypoint\n", 2)

local expect = table.concat({
	"",
	"SUBTASK search",
	"    I'll look around",
	"    shell: find . -name '*.lua'",
	"    {{{",
	"    lua/tai/init.lua",
	"    }}}",
	"    Found init.lua",
	"",
	"    SUBTASK summarize",
	"        It is the entrypoint",
	"",
}, "\n")
assert_eq(expect, buf, "full tree")

print("\n=== nest.apply 3-level (sub-subtask) ===")
buf = ""
-- Same calls as run_tools: header at parent depth, body at child depth.
step("\nSUBTASK search\n", 0) -- main → child
step("orient done\n", 1)
step("\nSUBTASK list lua/tai\n", 1) -- child → grandchild
step("shell: ls lua/tai\n{{{\n", 2)
step("agent.lua\nui\n", 2)
step("}}}\n", 2)
step("found: lua/tai/agent.lua\n", 2)
step("\nSUBTASK read agent.lua\n", 2) -- grandchild → great-grandchild
step("main_tools is subtask only\n", 3)

local expect3 = table.concat({
	"",
	"SUBTASK search",
	"    orient done",
	"",
	"    SUBTASK list lua/tai",
	"        shell: ls lua/tai",
	"        {{{",
	"        agent.lua",
	"        ui",
	"        }}}",
	"        found: lua/tai/agent.lua",
	"",
	"        SUBTASK read agent.lua",
	"            main_tools is subtask only",
	"",
}, "\n")
assert_eq(expect3, buf, "3-level tree")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	vim.cmd("cquit 1")
end
