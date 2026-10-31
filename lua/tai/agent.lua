local M = {}

local config = require("tai.config")

if not config.root then
	return M
end

M.system_prompt = [[
You are Tai, one coding assistant in this chat.

- Decide only from tool results and notes. Do not guess paths.
- Grep to search (use -A/-B). Do not read a whole file to search.
- Read a range. Edit needs the previous content, not line numbers.
- Do the work. Do not stop at a plan or a promise.
- When the request is done, reply in text.
]]

M.system_prompt = config.system_prompt or M.system_prompt
if config.custom_prompt and config.custom_prompt ~= "" then
	M.system_prompt = M.system_prompt .. "\n" .. config.custom_prompt
end

M.main_tools = {
	"read",
	"shell",
	"edit",
	"write",
	"send_image",
	"notes",
	"skill",
	"mcp",
}

M.tool_blurb = {
	notes = "pad for short facts you will need later",
	read = "open a file or line range",
	shell = "run a command in the project root",
	edit = "replace text in a file",
	write = "create a file",
	send_image = "send an image for the model to see",
	skill = "list/load/unload Agent Skills",
	mcp = "status/connect/call MCP tools",
}

function M.tool_granted(tools, name)
	if type(name) ~= "string" or name == "" or type(tools) ~= "table" then
		return false
	end
	for _, t in ipairs(tools) do
		if t == name then
			return true
		end
	end
	return false
end

function M.render_tools(tools)
	if type(tools) ~= "table" or #tools == 0 then
		return ""
	end
	local lines = { "You may call only:" }
	for _, name in ipairs(tools) do
		local blurb = M.tool_blurb[name]
		if blurb then
			table.insert(lines, "- " .. name .. ": " .. blurb)
		else
			table.insert(lines, "- " .. name)
		end
	end
	return table.concat(lines, "\n")
end

function M.new_frame()
	return {
		system_prompt = M.system_prompt,
		tools = vim.deepcopy(M.main_tools),
		history = { { role = "system", content = M.system_prompt } },
	}
end

return M
