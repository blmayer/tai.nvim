local M = {}

local config = require("tai.config")

if not config.provider then
	return M
end

-- Live UI lives in ui.core; this module is the public facade.
local ui_core = require("tai.ui.core")

for k, v in pairs(ui_core) do
	M[k] = v
end

return M
