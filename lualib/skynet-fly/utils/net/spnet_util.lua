local socket = require "skynet.socket"
local sp_netpack = require "skynet-fly.netpack.sp_netpack"
local util_net_base = require "skynet-fly.utils.net.util_net_base"

--------------------------------------------------------
--这是给skynet gate网关服务处理消息用的 基于sproto协议
--------------------------------------------------------

local M = {}

function M.new(name, pack_obj)
    local ret_M = {}

    pack_obj = pack_obj or sp_netpack.new(name)

    --给fd发送socket消息
    ret_M.send = util_net_base.create_gate_send(pack_obj.pack)

    --群发
    ret_M.broadcast = util_net_base.create_gate_broadcast(pack_obj.pack)

    --解包
    ret_M.unpack = util_net_base.create_gate_unpack(pack_obj.unpack)

    --客户端读取消息包
    ret_M.recv = util_net_base.create_recv(socket.read,pack_obj.unpack)

    return ret_M
end

local g_default = M.new('default', sp_netpack)

local mata = {__index = g_default}
setmetatable(M, mata)

return M 