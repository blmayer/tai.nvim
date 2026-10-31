local M = {}

-- Import submodules
local tools_io = require("tai.tools.io")
local tools_shell = require("tai.tools.shell")
local tools_edit = require("tai.tools.edit")
local tools_notes = require("tai.tools.notes")
local tools_skill = require("tai.tools.skill")
local tools_mcp = require("tai.tools.mcp")

-- Re-export functions from submodules
M.read_file = tools_io.read_file
M.limit_output = tools_io.limit_output
M.unsafe_command = tools_shell.unsafe_command
M.exec_command = tools_shell.exec_command
M.edit = tools_edit.edit
M.write = tools_io.write
M.image_data_url = tools_io.image_data_url

M.get_notes = tools_notes.get_notes
M.set_notes = tools_notes.set_notes
M.render_notes = tools_notes.render_notes
M.run_notes = tools_notes.run
M.run_skill = tools_skill.run
M.run_mcp = tools_mcp.run

-- Tool definitions (API schema)
M.defs = {
	read = {
		type = "function",
		["function"] = {
			name = "read",
			description =
			"Use this to read a file's content, it will return the file's content or range if given. Line numbers are added.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description =
						"The path to the file to read. Relative to the project's folder."
					},
					range = {
						type = "string",
						description =
						"Optional range of lines to read, starts at 1, colon separated. Formats: \\d: single line; \\d:\\d: inclusive range; $: last line; Negative numbers are counted from the end: -\\d:$: get last lines. Examples: lines 1 throught 10: 1:10; fith line: 5; tenth to last: 10:$; last 5 lines: -5:$.",
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	shell = {
		type = "function",
		["function"] = {
			name = "shell",
		description =
			"Use this tool when you need to run commands in a shell in the project's folder, use it for running builds, exploring the codebase etc. Use relative paths (don't start with /). Do NOT prefix with `cd` to the project root — the shell already starts there. Arguments, pipes (|), conditionals (||, &&), and chaining (;) are allowed. Redirects (>, >>, <, <<, 2>&1 etc.) are NOT allowed. Returns the stdout and stderr of the command. The shell runs in the project's root directory.",
			parameters = {
				type = "object",
				properties = {
					command = {
						type = "string",
						description =
						"The pipeline to be interpreted by the shell in the project's folder. Already cwd is the project root — do not `cd` there first. All paths are relative to the project's folder. Avoid redirections like >, >>, <, <<, 2>&1 etc. 2>&1 is added to the end of the command."
					}
				},
				additionalProperties = false,
				required = { "command" }
			}
		}
	},
	send_image = {
		type = "function",
		["function"] = {
			name = "send_image",
			description =
			"Use this tool to send images to the agent so it can see and interpret screenshots, diagrams, UI mockups, error messages, or any visual content. Make sure you select the correct image file.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description =
						"The path to the image file to send. Relative to the project's folder."
					},
					prompt = {
						type = "string",
						description = "Optional prompt to guide what to look for in the image."
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	write = {
		type = "function",
		["function"] = {
			name = "write",
			description =
			"Use this to create new files with the given content. Ensures parent directories exist.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "Path to create, relative to project folder"
					},
					content = {
						type = "string",
						description = "Content to write to the file"
					}
				},
				additionalProperties = false,
				required = { "file", "content" }
			}
		}
	},
	edit = {
		type = "function",
		["function"] = {
			name = "edit",
			description =
			"Use this to edit existing files by providing the old content to be replaced by the new content. If old_text is empty, changes are made at the start of the file. Matching uses line-by-line comparison after normalizing whitespace (collapse runs of spaces, trim).",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "Path to edit, relative to project folder"
					},
					old_text = {
						type = "string",
						description =
						"Content to be changed. Empty means start of file. This must match exactly (after per-line whitespace normalization). Use the MINIMUM number of context lines needed to uniquely identify the location — typically 1-3 distinctive lines, not large blocks. Don't add line numbers that appear on the read output, they are just for reference."
					},
					new_text = {
						type = "string",
						description = "New content to replace old_text in the file."
					},
					multi = {
						type = "boolean",
						description = "If true, replace every matching occurrence of the old_text block (instead of only the first match). Use when the same change should be applied in multiple places."
					}
				},
				additionalProperties = false,
				required = { "file", "old_text", "new_text" }
			}
		}
	},
	notes = {
		type = "function",
		["function"] = {
			name = "notes",
			description =
			"Shared pad injected every turn for every agent. They cannot see your chat. "
				.. "Write short facts others need (paths, names, findings) before you spawn a child. "
				.. "Actions: write (replace), append.",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "write or append",
						enum = { "write", "append" },
					},
					content = {
						type = "string",
						description = "Content to write or append.",
					},
				},
				additionalProperties = false,
				required = { "action", "content" },
			},
		},
	},
	skill = {
		type = "function",
		["function"] = {
			name = "skill",
			description =
			"Manage Agent Skills (SKILL.md with required YAML frontmatter name + description). "
				.. "Actions: list (available skills), status (inspect one), "
				.. "load (inject full skill instructions into context), unload (deactivate).",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "list, status, load, or unload",
						enum = { "list", "status", "load", "unload" },
					},
					id = {
						type = "string",
						description = "Skill name (must match directory / frontmatter name). Required for status/load/unload.",
					},
				},
				additionalProperties = false,
				required = { "action" },
			},
		},
	},
	mcp = {
		type = "function",
		["function"] = {
			name = "mcp",
			description =
			"Manage MCP servers and call their tools. Actions: status, connect, disconnect, list_tools, call. "
				.. "For call: provide server, tool, and arguments object. "
				.. "Servers are configured in .tai under `mcps`.",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "status | connect | disconnect | list_tools | call",
						enum = { "status", "connect", "disconnect", "list_tools", "call" },
					},
					server = {
						type = "string",
						description = "MCP server name (from .tai mcps).",
					},
					tool = {
						type = "string",
						description = "Tool name on the server (for call).",
					},
					arguments = {
						type = "object",
						description = "Arguments object for tools/call.",
					},
				},
				additionalProperties = false,
				required = { "action" },
			},
		},
	},
}

M.MAX_TOOL_OUTPUT = tools_io.MAX_TOOL_OUTPUT

return M
