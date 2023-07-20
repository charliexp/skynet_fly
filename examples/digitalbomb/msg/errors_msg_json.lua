local jsonet_util = require "jsonet_util"
local errorcode = require "errorcode"

local M = {}

function M.errors(gate,fd,code,msg,packname)
	if not code then
		code = errorcode.UNKOWN_ERR
		msg = "unkown err"
	end
	local error = {
		code = code,
		msg = msg,
		packname = packname,
	}

	jsonet_util.send(gate,fd,'.errors.Error',error)
end

return M