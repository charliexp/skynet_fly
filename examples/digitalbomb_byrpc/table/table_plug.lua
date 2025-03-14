local skynet = require "skynet"
local pb_netpack = require "skynet-fly.netpack.pb_netpack"
local sp_netpack = require "skynet-fly.netpack.sp_netpack"
local module_cfg = require "skynet-fly.etc.module_info".get_cfg()
local table_logic = require "table.table_logic"
local errors_msg = require "msg.errors_msg"
local rsp_msg = require "msg.rsp_msg"
local log = require "skynet-fly.log"
local msg_id = require "enum.msg_id"
local pack_helper = require "common.pack_helper"

local pbnet_byrpc = require "skynet-fly.utils.net.pbnet_byrpc"
local ws_pbnet_byrpc = require "skynet-fly.utils.net.ws_pbnet_byrpc"

local spnet_byrpc = require "skynet-fly.utils.net.spnet_byrpc"
local ws_spnet_byrpc = require "skynet-fly.utils.net.ws_spnet_byrpc"

local assert = assert
local tunpack = table.unpack

local g_table_conf = module_cfg.table_conf
local g_interface_mgr = nil

local test_proto = skynet.getenv("test_proto")

--======================enum=================================
local MINE_MIN = 1
local MINE_MAX = 100
--======================enum=================================

local M = {}

--发包函数
if test_proto == 'pb' then
	M.send = pbnet_byrpc.send
	M.broadcast = pbnet_byrpc.broadcast
	M.ws_send = ws_pbnet_byrpc.send
	M.ws_broadcast = ws_pbnet_byrpc.broadcast
else
	M.send = spnet_byrpc.send
	--广播函数
	M.broadcast = spnet_byrpc.broadcast
	--发包函数
	M.ws_send = ws_spnet_byrpc.send
	--广播函数
	M.ws_broadcast = ws_spnet_byrpc.broadcast
end
--rpc包处理工具
M.rpc_pack = require "skynet-fly.utils.net.rpc_server"

function M.init(interface_mgr)
	g_interface_mgr = interface_mgr
    g_table_conf.mine_min = MINE_MIN
    g_table_conf.mine_max = MINE_MAX
	assert(g_table_conf.player_num,"not player_num")
	pb_netpack.load('./proto')
	sp_netpack.load('./sproto')
	pack_helper.set_packname_id()
	pack_helper.set_sp_packname_id()
end

function M.table_creator(table_id, table_name, ...)
	local args = {...}
	local create_player_id = args[1]
    local m_interface_mgr = g_interface_mgr:new(table_id)
	local m_errors_msg = errors_msg:new(m_interface_mgr)
	local m_rsp_msg = rsp_msg:new(m_interface_mgr)
    local m_logic = table_logic:new(m_interface_mgr, g_table_conf, table_id)

	log.info("table_creator >>> ",table_id, table_name, create_player_id)

    return {
        enter = function(player_id)
            return m_logic:enter(player_id)
        end,

		leave = function(player_id)
			return m_logic:leave(player_id)
		end,

		disconnect = function(player_id)
			return m_logic:disconnect(player_id)
		end,

		reconnect = function(player_id)
			return m_logic:reconnect(player_id)
		end,
        
		handle = {
			[msg_id.game_DoingReq] = function(player_id, packid, pack_body, rsp_session)
                return m_logic:doing_req(player_id, packid, pack_body)
			end,

			[msg_id.game_GameStatusReq] = function(player_id, packid, pack_body, rsp_session)
				return m_logic:game_status_req(player_id, packid, pack_body)
			end
		},
		handle_end_rpc = function(player_id, packid, pack_body, rsp_session, handle_res)
			log.info("table handle_end_rpc >>> ", player_id, packid, pack_body, rsp_session, handle_res)
			local ret, errcode, errmsg = tunpack(handle_res)
			if not ret then
				m_errors_msg:errors(player_id, errcode, errmsg, packid, rsp_session)
			else
				m_rsp_msg:rsp_msg(player_id, packid, ret, rsp_session)
			end
		end,
		------------------------------------服务退出回调-------------------------------------
		herald_exit = function()
			return m_logic:herald_exit()
		end,

		exit = function()
			return m_logic:exit()
		end,
		
		fix_exit = function()
			return m_logic:fix_exit()
		end,

		cancel_exit = function()
			return m_logic:cancel_exit()
		end,

		check_exit = function()
			return m_logic:check_exit()
		end,
    }
end

return M