local skynet = require "skynet"
local log = require "skynet-fly.log"
local frpc_client = require "skynet-fly.client.frpc_client"
local watch_client = require "skynet-fly.rpc.watch_client"
local watch_syn_client = require "skynet-fly.rpc.watch_syn_client"
local timer = require "skynet-fly.timer"
local service = require "skynet.service"
local orm_frpc_client = require "skynet-fly.client.orm_frpc_client"
local CMD = {}

-- 测试基础消息
local function test_base_msg()
	local function test_mode(mode)
		local cli = frpc_client:new(mode, "frpc_s", "test_m") --用简单轮询的方式访问frpc_s的test_m模板
		if mode == frpc_client.FRPC_MODE.byid then
			cli:set_svr_id(1)
		end
		cli:balance_send("hello", "balance_send:" .. mode)
		cli:mod_send("hello","mod_send:" .. mode)
		for i = 1,3 do
			log.info("balance ping ", mode, i, cli:balance_call("ping", i))
		end
		for i = 1,3 do
			log.info("mod ping ", mode, i, cli:mod_call("ping", i))
		end

		cli:broadcast("hello", "broadcast:" .. mode)
		log.info("broadcast_call:", mode, cli:broadcast_call("ping", "broadcast_call:" .. mode))

		cli:set_instance_name("test_one")
		cli:set_svr_id(2)
		cli:balance_send_by_name("hello","balance_send_by_name:" .. mode)
		cli:mod_send_by_name("hello","mod_send_by_name" .. mode)
		for i = 1,3 do
			log.info("balance_call_by_name ping ", mode, i, cli:balance_call_by_name("ping", i))
		end
		for i = 1,3 do
			log.info("mod_call_by_name ping ", mode, i, cli:mod_call_by_name("ping", i))
		end

		cli:broadcast_by_name("hello","broadcast_by_name:" .. mode)
		log.info("broadcast_call_by_name:", mode, cli:broadcast_call_by_name("ping", "broadcast_call_by_name:" .. mode))

		cli = frpc_client:new(mode, "frpc_s", ".testserver_1") --用简单轮询的方式访问frpc_s的.testserver_1别名服务
		if mode == frpc_client.FRPC_MODE.byid then
			cli:set_svr_id(1)
		end
		cli:send_by_alias("hello", "send_by_alias:" .. mode)
		log.info("call_by_alias:", cli:call_by_alias("ping", "call_by_alias:" .. mode))
	end

	test_mode(frpc_client.FRPC_MODE.one)
	test_mode(frpc_client.FRPC_MODE.byid)
	test_mode(frpc_client.FRPC_MODE.all)
end

--测试大包消息
local function test_large_msg()
	local req_list = {}
	for i = 1,20000 do
		table.insert(req_list, i)
	end

	local function print_one_ret(name, ret)
		log.info(name, ret.cluster_name, #ret.result[1])
	end

	local function print_broad_cast_ret(name, ret)
		for sid, r in pairs(ret.result[1]) do
			log.info(name, ret.cluster_name, sid, #r[1])
		end
	end

	local function print_all_one_ret(name, ret)
		for _,one_ret in ipairs(ret) do
			print_one_ret(name, one_ret)
		end
	end

	local function print_all_broad_cast_ret(name, ret)
		for k,v in pairs(ret) do
			print_broad_cast_ret(name,v)
		end
	end

	req_list = table.concat(req_list, ',')

	local function test_large(mode)
		local print_one = print_one_ret
		local print_broad = print_broad_cast_ret
		if mode == frpc_client.FRPC_MODE.all then
			print_one = print_all_one_ret
			print_broad = print_all_broad_cast_ret
		end
		local cli = frpc_client:new(mode, "frpc_s","test_m") --访问frpc_s的test_m模板
		if mode == frpc_client.FRPC_MODE.byid then
			cli:set_svr_id(1)
		end
		cli:balance_send("large_msg", req_list)
		local ret = cli:balance_call("large_msg", req_list)
		print_one("balance_call:" .. mode, ret)
		cli:mod_send("large_msg", req_list)
		local ret = cli:mod_call("large_msg", req_list)
		print_one("mod_call:" .. mode, ret)
		cli:broadcast("large_msg", req_list)
		local ret = cli:broadcast_call("large_msg", req_list)
		print_broad("broadcast_call:" .. mode, ret)
		cli:set_instance_name("test_one")
		cli:balance_send_by_name("large_msg", req_list)
		local ret = cli:balance_call_by_name("large_msg", req_list)
		print_one("balance_call_by_name:" .. mode, ret)
		cli:mod_send_by_name("large_msg", req_list)
		local ret = cli:mod_call_by_name("large_msg", req_list)
		print_one("mod_call_by_name:"..mode, ret)
		cli:broadcast_by_name("large_msg", req_list)
		local ret = cli:broadcast_call_by_name("large_msg", req_list)
		print_broad("broadcast_call_by_name:" .. mode, ret)
	end
	test_large(frpc_client.FRPC_MODE.one)
	test_large(frpc_client.FRPC_MODE.byid)
	test_large(frpc_client.FRPC_MODE.all)
end

--服务掉线测试
local function test_disconnect()
	local cli = frpc_client:new(frpc_client.FRPC_MODE.one,"frpc_s","test_m") --访问frpc_s的test_m模板
	while true do
		log.info("balance ping ", cli:balance_call("ping"))
		skynet.sleep(100)
	end
end

--压测 
local function test_benchmark()
	local cli = frpc_client:new(frpc_client.FRPC_MODE.byid,"frpc_s","test_m") --访问frpc_s的test_m模板
	local max_count = 10000

	local msgsz = 1024
	local msg = ""
	for i = 1, msgsz do
		msg = msg .. math.random(1,9)
	end
	cli:set_svr_id(1)
	local pre_time = skynet.time()
	local co = coroutine.running
	local over_cnt = 0
	for i = 1, max_count do
		skynet.fork(function()
			cli:mod_call("ping", msg)
			over_cnt = over_cnt + 1
			if over_cnt == max_count then
				skynet.wakeup(co)
			end
		end)
	end
	skynet.wait(co)

	log.info("tps:", max_count / (skynet.time() - pre_time))
end

--测试watch_syn活跃同步
local function test_watch_syn()
	local cli = frpc_client:new(frpc_client.FRPC_MODE.one,"frpc_s","test_m") --访问frpc_s的test_m模板
	while true do
		skynet.sleep(100)
		if frpc_client:is_active("frpc_s") then
			log.info("balance ping ", cli:balance_call("ping"))
		else
			log.info("not active")
		end
	end
end

--测试错误处理
local function test_errorcode()
	local cli = frpc_client:new(frpc_client.FRPC_MODE.byid, "frpc_s", "test_m")
	--等待连接超时
	cli:set_svr_id(3)--设置不存在的连接 3
	log.info("test_errorcode 1 >>> ", cli:balance_call("ping", "test_errorcode 1"))

	--对端出错
	cli:set_svr_id(2)
	log.info("test_errorcode 2 >>> ", cli:balance_call("call_error_test"))

	cli = frpc_client:new(frpc_client.FRPC_MODE.all, "frpc_s", "test_m")
	--部分对端出错
	local ret_list, err_list = cli:balance_call("call_same_error_test")
	log.info("test_errorcode 3 >>> ", ret_list, err_list)
end

--测试orm_frpc_client
local function test_orm_frpc_client()
	local cli = orm_frpc_client:new("frpc_s", 1, "player")
	local item_cli = orm_frpc_client:new("frpc_s", 1, "item")
	local function add_cb(one_data)
		log.info("add_cb >>> ", one_data)
	end
	local function del_cb(one_data)
		log.info("del_cb >>> ", one_data)
	end
	local function change_cb(one_data, change_data)
		log.info("change_cb >>> ", one_data, change_data)
	end
	local ret = cli:watch(10001, add_cb, change_cb, del_cb)
	local ret = item_cli:watch(10001, add_cb, change_cb, del_cb)

	skynet.fork(function()
		while true do
			skynet.sleep(200)
			log.info("test_orm_frpc_client get_table player >>>", cli:get_data(10001))
			log.info("test_orm_frpc_client get_table item >>> ", item_cli:get_data(10001))
		end
	end)

	skynet.fork(function()
		skynet.sleep(300)
		log.info("test_orm_frpc_client >>> ", ret)
		local entry = cli:call_orm("create_one_entry", {
			player_id = 10001,
			nickname = 100,
			sex = 1,
			email = "xxx.com"
		})
		log.info("create_one_entry ret >>> ", entry)
		skynet.sleep(300)

		local ret = cli:call_orm("change_save_one_entry", {player_id = 10001, email = "111.com"})
		log.info("change_save_one_entry ret >>> ", ret)
		skynet.sleep(300)

		local ret = cli:call_orm("change_save_one_entry", {player_id = 10001, email = "222.com", nickname = 200})
		log.info("change_save_one_entry ret >>> ", ret)

		skynet.sleep(300)

		local ret = cli:call_orm("delete_entry", 10001)
		log.info("delete_entry >>> ", ret)

		skynet.sleep(300)
		item_cli:call_orm("create_entry", {
			{player_id = 10001, item_id = 1001, count = 1},
			{player_id = 10001, item_id = 1002, count = 1},
			{player_id = 10001, item_id = 1003, count = 1},
		})

		skynet.sleep(300)
		item_cli:call_orm("change_save_entry", {
			{player_id = 10001, item_id = 1001, count = 2},
			{player_id = 10001, item_id = 1002, count = 3},
			{player_id = 10001, item_id = 1003, count = 4},
		})

		skynet.sleep(300)
		item_cli:call_orm("delete_entry", 10001, 1002)
	end)

	skynet.fork(function ()
		skynet.sleep(6000)
		cli:unwatch(10001)
		item_cli:unwatch(10001)
	end)
end

--测试unpubsyn取消同步的独立cancel handler
local function test_unpubsyn_cancel()
	log.info("========== test_unpubsyn_cancel start ==========")

	--测试1：基本 watch + watch_cancel（对应服务端 test_cancel_syn）
	log.info("--- 测试1: 基本 watch + watch_cancel ---")
	watch_syn_client.watch("frpc_s", "test_cancel_syn", "cancel_syn_handler", function(cluster_name, ...)
		log.info("[测试1] watch_syn test_cancel_syn data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel("frpc_s", "test_cancel_syn", "cancel_syn_handler", function(cluster_name, channel_name)
		log.info("[测试1] watch_cancel test_cancel_syn cancelled! >>> ", cluster_name, channel_name)
	end)

	--测试2：取消后重新发布（对应服务端 test_cancel_repub）
	log.info("--- 测试2: 取消后重新发布 ---")
	watch_syn_client.watch("frpc_s", "test_cancel_repub", "repub_handler", function(cluster_name, ...)
		log.info("[测试2] watch_syn test_cancel_repub data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel("frpc_s", "test_cancel_repub", "repub_cancel_handler", function(cluster_name, channel_name)
		log.info("[测试2] watch_cancel test_cancel_repub cancelled! >>> ", cluster_name, channel_name)
	end)

	--测试3：pwatch + pwatch_cancel（模式匹配 *:age:address，对应服务端 unpubsyn name1:age:address）
	log.info("--- 测试3: pwatch + pwatch_cancel ---")
	watch_syn_client.pwatch("frpc_s", "*:age:address", "pwatch_cancel_test", function(cluster_name, ...)
		log.info("[测试3] pwatch *:age:address data >>> ", cluster_name, ...)
	end)

	watch_syn_client.pwatch_cancel("frpc_s", "*:age:address", "pwatch_cancel_test", function(cluster_name, pchannel_name, channel_name)
		log.info("[测试3] pwatch_cancel *:age:address cancelled! >>> ", cluster_name, pchannel_name, channel_name)
	end)

	--测试4：多个 cancel handler 注册同一 channel（对应服务端 test_multi_cancel）
	log.info("--- 测试4: 多个 cancel handler 注册同一 channel ---")
	watch_syn_client.watch("frpc_s", "test_multi_cancel", "multi_handler_1", function(cluster_name, ...)
		log.info("[测试4] watch_syn test_multi_cancel handler_1 data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel("frpc_s", "test_multi_cancel", "multi_cancel_handler_1", function(cluster_name, channel_name)
		log.info("[测试4] watch_cancel test_multi_cancel handler_1 cancelled! >>> ", cluster_name, channel_name)
	end)

	watch_syn_client.watch("frpc_s", "test_multi_cancel", "multi_handler_2", function(cluster_name, ...)
		log.info("[测试4] watch_syn test_multi_cancel handler_2 data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel("frpc_s", "test_multi_cancel", "multi_cancel_handler_2", function(cluster_name, channel_name)
		log.info("[测试4] watch_cancel test_multi_cancel handler_2 cancelled! >>> ", cluster_name, channel_name)
	end)

	--测试5：快速 pubsyn + unpubsyn 场景（对应服务端 test_quick_cancel）
	log.info("--- 测试5: 快速 pubsyn + unpubsyn ---")
	watch_syn_client.watch("frpc_s", "test_quick_cancel", "quick_handler", function(cluster_name, ...)
		log.info("[测试5] watch_syn test_quick_cancel data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel("frpc_s", "test_quick_cancel", "quick_cancel_handler", function(cluster_name, channel_name)
		log.info("[测试5] watch_cancel test_quick_cancel cancelled! >>> ", cluster_name, channel_name)
	end)

	--测试6：watch_cancel_byid 指定 svr_id 的 cancel handler
	log.info("--- 测试6: watch_cancel_byid ---")
	watch_syn_client.watch_byid("frpc_s", 1, "test_cancel_syn", "cancel_syn_byid_handler", function(cluster_name, ...)
		log.info("[测试6] watch_byid test_cancel_syn data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel_byid("frpc_s", 1, "test_cancel_syn", "cancel_syn_byid_handler", function(cluster_name, channel_name)
		log.info("[测试6] watch_cancel_byid test_cancel_syn cancelled! >>> ", cluster_name, channel_name)
	end)

	--测试7：pwatch_cancel_byid 指定 svr_id 的 pwatch cancel handler
	log.info("--- 测试7: pwatch_cancel_byid ---")
	watch_syn_client.pwatch_byid("frpc_s", 1, "*:age:address", "pwatch_cancel_byid_test", function(cluster_name, ...)
		log.info("[测试7] pwatch_byid *:age:address data >>> ", cluster_name, ...)
	end)

	watch_syn_client.pwatch_cancel_byid("frpc_s", 1, "*:age:address", "pwatch_cancel_byid_test", function(cluster_name, pchannel_name, channel_name)
		log.info("[测试7] pwatch_cancel_byid *:age:address cancelled! >>> ", cluster_name, pchannel_name, channel_name)
	end)

	--测试8：注册 cancel handler 后注销（unwatch_cancel），验证注销后不再收到回调
	log.info("--- 测试8: unwatch_cancel 注销测试 ---")
	watch_syn_client.watch("frpc_s", "test_cancel_repub", "should_not_fire_handler", function(cluster_name, ...)
		log.info("[测试8] watch_syn test_cancel_repub data >>> ", cluster_name, ...)
	end)

	watch_syn_client.watch_cancel("frpc_s", "test_cancel_repub", "should_not_fire_cancel", function(cluster_name, channel_name)
		--此 handler 应该不会被触发，因为注册后会被注销
		log.info("[测试8] ERROR: should_not_fire_cancel was called! >>> ", cluster_name, channel_name)
	end)

	--立即注销这个 cancel handler
	watch_syn_client.unwatch_cancel("frpc_s", "test_cancel_repub", "should_not_fire_cancel")
	log.info("[测试8] unwatch_cancel should_not_fire_cancel done, this handler should not fire")

	--测试9：unpwatch_cancel 注销 pwatch cancel handler
	log.info("--- 测试9: unpwatch_cancel 注销测试 ---")
	watch_syn_client.pwatch_cancel("frpc_s", "*:age:address", "pwatch_should_not_fire", function(cluster_name, pchannel_name, channel_name)
		--此 handler 应该不会被触发
		log.info("[测试9] ERROR: pwatch_should_not_fire was called! >>> ", cluster_name, pchannel_name, channel_name)
	end)

	watch_syn_client.unpwatch_cancel("frpc_s", "*:age:address", "pwatch_should_not_fire")
	log.info("[测试9] unpwatch_cancel pwatch_should_not_fire done, this handler should not fire")

	log.info("========== test_unpubsyn_cancel all handlers registered ==========")
end

function CMD.start()
	skynet.fork(function()
		--test_base_msg()
		--test_large_msg()
		--test_disconnect()
		--test_benchmark()
		--test_watch_syn()
		--test_errorcode()
		--test_orm_frpc_client()

		--等待两个 frpc_s 节点上线后再开始测试
		local up_count = 0
		local up_svr_ids = {}
		local wait_co = coroutine.running()
		frpc_client:watch_up("frpc_s", function(svr_name, svr_id)
			if not up_svr_ids[svr_id] then
				up_svr_ids[svr_id] = true
				up_count = up_count + 1
				log.info("frpc_s svr_id up: ", svr_id, " total up_count: ", up_count)
				if up_count >= 2 then
					skynet.wakeup(wait_co)
				end
			end
		end, "test_unpubsyn_watch_up")
		log.info("waiting for 2 frpc_s nodes to come online...")
		skynet.wait(wait_co)
		log.info("2 frpc_s nodes are online, start test_unpubsyn_cancel")

		test_unpubsyn_cancel()
	end)

	-- timer:new(timer.second * 5, 1, function()
	-- 	watch_client.watch("frpc_s", "test_pub", "handle_name2", function(...)
	-- 		log.info("watch msg handle_name2 >>>> ", ...)
	-- 	end)

	-- 	watch_client.unwatch_byid("frpc_s", 1, "test_pub", "handle_name1")

	-- 	watch_client.watch_byid("frpc_s", 1, "test_pub", "handle_name2", function(...)
	-- 		log.info("watch_byid msg handle_name2 >>>> ", ...)
	-- 	end)
		
	-- 	timer:new(timer.second * 5, 1, function()
	-- 		watch_client.unwatch("frpc_s", "test_pub", "handle_name2")
	-- 		watch_client.unwatch("frpc_s", "test_pub", "handle_name1")
			
	-- 		timer:new(timer.second * 5, 1, function()
	-- 			watch_client.unwatch_byid("frpc_s", 1, "test_pub", "handle_name2")
	-- 		end)
	-- 	end)
	-- end)

	-- timer:new(timer.second * 5, 1, function()
	-- 	watch_syn_client.watch("frpc_s", "test_syn", "handle_name2", function(...)
	-- 		log.info("watch msg handle_name2 >>>> ", ...)
	-- 	end)

	-- 	watch_syn_client.unwatch_byid("frpc_s", 1, "test_syn", "handle_name1")

	-- 	watch_syn_client.watch_byid("frpc_s", 1, "test_syn", "handle_name2", function(...)
	-- 		log.info("watch_byid msg handle_name2 >>>> ", ...)
	-- 	end)
		
	-- 	timer:new(timer.second * 5, 1, function()
	-- 		watch_syn_client.unwatch("frpc_s", "test_syn", "handle_name2")
	-- 		watch_syn_client.unwatch("frpc_s", "test_syn", "handle_name1")
			
	-- 		timer:new(timer.second * 5, 1, function()
	-- 			watch_syn_client.unwatch_byid("frpc_s", 1, "test_syn", "handle_name2")
	-- 		end)
	-- 	end)
	-- end)

	-- skynet.fork(function()
	-- 	service.new("test server", function()
	-- 		local CMD = {}
	
	-- 		local skynet = require "skynet"
	-- 		local log = require "skynet-fly.log"
	-- 		local watch_syn_client = require "skynet-fly.rpc.watch_syn_client"
	-- 		local skynet_util = require "skynet-fly.utils.skynet_util"
	
	-- 		-- local watch_client = require "skynet-fly.rpc.watch_client"
	
	-- 		-- watch_syn_client.watch("frpc_s", "test_syn", "handle_name2", function(...)
	-- 		-- 	log.info("watch syn test_syn handle_name2 >>> ", ...)
	-- 		-- end)
	
	-- 		-- watch_client.watch("frpc_s", "test_pub", "handle_name1", function(...)
	-- 		-- 	log.info("watch msg handle_name1 >>>> ", ...)
	-- 		-- end)
	-- 		watch_syn_client.pwatch("frpc_s", "*:age:address", "test server handle-*:age:address", function(cluter_name, ...)
	-- 			log.info("test server handle-*:age:address >>> ", cluter_name, ...)
	-- 		end)

	-- 		watch_syn_client.pwatch_byid("frpc_s", 1, "*:age:address", "test server handle-*:age:address", function(cluter_name, ...)
	-- 			log.info("test server pwatch handle-*:age:address >>> ", cluter_name, ...)
	-- 		end)

	-- 		skynet.sleep(500)
	-- 		watch_syn_client.unpwatch("frpc_s", "*:age:address", "test server handle-*:age:address")
	-- 		watch_syn_client.unpwatch_byid("frpc_s", 1, "*:age:address", "test server handle-*:age:address")

	-- 		skynet_util.lua_dispatch(CMD)
	-- 	end)
	-- end)
	-- timer:new(timer.second * 5, 1, function()
	-- 	watch_syn_client.unpwatch("frpc_s", "*:age:address", "handle-*:age:address")
	-- 	watch_syn_client.unpwatch_byid("frpc_s", 1, "*:age:address", "handle-*:age:address")
	-- end)

	-- timer:new(timer.second * 2, 1, function()
	-- 	watch_syn_client.watch("frpc_s", "name1:age:address", "name1:age:address", function(cluter_name, ...)
	-- 		log.info("watch handle-name1:age:address >>> ", cluter_name, ...)
	-- 	end)

	-- 	watch_syn_client.watch_byid("frpc_s", 1, "name2:age:address", "name2:age:address", function(cluter_name, ...)
	-- 		log.info("watch_byid handle-name2:age:address >>> ", cluter_name, ...)
	-- 	end)
	-- end)

	return true
end

function CMD.exit()
	return true
end

-- watch_client.watch("frpc_s", "test_pub", "handle_name1", function(...)
-- 	log.info("watch msg handle_name1 >>>> ", ...)
-- end)

-- watch_client.watch_byid("frpc_s", 1, "test_pub", "handle_name1", function(...)
-- 	log.info("watch_byid msg handle_name1 >>>> ", ...)
-- end)

-- watch_client.watch_byid("frpc_s", 1, "test_pub_large", "xxxx", function(...)
-- 	log.info("watch_byid test_pub_large ")
-- end)

-- watch_syn_client.watch("frpc_s", "test_syn", "handle_name1", function(...)
-- 	log.info("watch syn test_syn handle_name1 >>> ", ...)
-- end)

-- watch_syn_client.watch("frpc_s", "test_syn", "handle_name3", function(...)
-- 	log.info("watch syn test_syn handle_name3 >>> ", ...)
-- end)

-- watch_client.watch_byid("frpc_s", 1, "test_syn", "handle_name1", function(...)
-- 	log.info("watch_byid msg handle_name1 >>>> ", ...)
-- end)

-- watch_syn_client.pwatch("frpc_s", "*:age:address", "handle-*:age:address", function(cluter_name, ...)
-- 	log.info("pwatch handle-*:age:address >>> ", cluter_name, ...)
-- end)

-- watch_syn_client.pwatch_byid("frpc_s", 1, "*:age:address", "handle-*:age:address", function(cluter_name, ...)
-- 	log.info("pwatch_byid handle-*:age:address >>> ", cluter_name, ...)
-- end)

-- watch_syn_client.pwatch("frpc_s", "name:*:address", "name:*:address", function(cluter_name, ...)
-- 	log.info("pwatch handle-name:*:address >>> ", cluter_name, ...)
-- end)

-- watch_syn_client.pwatch_byid("frpc_s", 1, "name:*:*", "name:*:*", function(cluter_name, ...)
-- 	log.info("pwatch_byid handle-name:*:* >>> ", cluter_name, ...)
-- end)

-- watch_syn_client.pwatch("frpc_s", "*:age:*", "*:age:*", function(cluter_name, ...)
-- 	log.info("pwatch handle-name:*:age:* >>> ", cluter_name, ...)
-- end)

-- watch_syn_client.pwatch_byid("frpc_s", 1, "*:*:address", "*:*:address", function(cluter_name, ...)
-- 	log.info("pwatch_byid handle-*:*:address >>> ", cluter_name, ...)
-- end)

return CMD