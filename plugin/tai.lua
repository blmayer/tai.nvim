-- Tai Neovim Plugin Autoload
-- This file is loaded automatically by Neovim on startup

local tai = require("tai")

-- Setup the plugin with default/user config
tai.setup({})

-- Register vim commands
vim.api.nvim_create_user_command("Tai", function(args)
	if args.args == "chat" then
		tai.chat()
	elseif args.args == "toggle" then
		tai.toggle_chat_window()
	elseif args.args == "reload" then
		tai.reload()
	elseif args.args == "clear" then
		tai.clear_history()
	else
		vim.notify("Tai: Unknown command: " .. args.args, vim.log.levels.WARN)
	end
end, {
	nargs = 1,
	complete = function(_, _, _)
		return { "chat", "toggle", "reload", "clear" }
	end,
})
