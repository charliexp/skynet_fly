local skynet = require "skynet"
local timer = require "timer"

local g_config = nil
local CMD = {}

function CMD.start(config)
	g_config = config
end

function CMD.query(k)
	return g_config[k]
end

function CMD.exit()
	timer:new(timer.second * 60,1,skynet.exit)
end

return CMD