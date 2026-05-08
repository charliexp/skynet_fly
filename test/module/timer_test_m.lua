local skynet = require "skynet"
local log = require "skynet-fly.log"
local timer = require "skynet-fly.timer"
local timer_point = require "skynet-fly.time_extend.timer_point"
local time_util = require "skynet-fly.utils.time_util"

local CMD = {}

--------------------------------------------------------------------------------
-- 辅助函数
--------------------------------------------------------------------------------

-- 简单断言：条件为 false 时记录错误并返回 false
local function assert_true(cond, msg)
	if not cond then
		log.error("[FAIL] " .. tostring(msg))
		return false
	end
	log.info("[PASS] " .. tostring(msg))
	return true
end

-- 断言两值近似相等（误差在 tol 以内）
local function assert_near(a, b, tol, msg)
	tol = tol or 20
	local ok = math.abs(a - b) <= tol
	if not ok then
		log.error("[FAIL] " .. tostring(msg) .. string.format(" (expected ~%d, got %d, diff=%d)", b, a, math.abs(a-b)))
	else
		log.info("[PASS] " .. tostring(msg) .. string.format(" (~%d ±%d)", b, tol))
	end
	return ok
end

--------------------------------------------------------------------------------
-- 测试 1：基本单次触发
-- 创建 expire=100(1s), times=1 的定时器，等 120 ticks，确认触发了 1 次
--------------------------------------------------------------------------------
local function test_basic_once()
	log.info("=== test_basic_once ===")
	local count = 0
	local t = timer:new(100, 1, function()
		count = count + 1
	end)
	skynet.sleep(150)
	assert_true(count == 1, "basic once: triggered exactly 1 time")
	assert_true(t.is_over == true, "basic once: is_over=true after completion")
	assert_true(t:remain_expire() == 0, "basic once: remain_expire=0 after over")
	assert_true(t:is_finished() == true, "basic once: is_finished()=true")
	assert_true(t:is_valid() == false, "basic once: is_valid()=false after over")
	assert_true(t:remain_times() == 0, "basic once: remain_times()=0 after over")
end

--------------------------------------------------------------------------------
-- 测试 2：立即取消（创建后马上 cancel，不应触发）
--------------------------------------------------------------------------------
local function test_cancel_before_trigger()
	log.info("=== test_cancel_before_trigger ===")
	local count = 0
	local t = timer:new(100, 1, function()
		count = count + 1
	end)
	t:cancel()
	assert_true(t.is_cancel == true, "cancel: is_cancel=true")
	assert_true(t:remain_expire() == 0, "cancel: remain_expire=0 after cancel")
	assert_true(t:is_cancelled() == true, "cancel: is_cancelled()=true")
	assert_true(t:is_valid() == false, "cancel: is_valid()=false after cancel")
	skynet.sleep(150)
	assert_true(count == 0, "cancel: not triggered after cancel")
end

--------------------------------------------------------------------------------
-- 测试 3：循环触发，然后手动 cancel
-- expire=100, times=0(loop)，等 350 ticks(3次触发时间)，然后 cancel，确认触发了 3 次
--------------------------------------------------------------------------------
local function test_loop_and_cancel()
	log.info("=== test_loop_and_cancel ===")
	local count = 0
	local t = timer:new(100, timer.loop, function()
		count = count + 1
	end)
	skynet.sleep(350)
	t:cancel()
	local final_count = count
	skynet.sleep(100)  -- 再等 1s，确认 cancel 后不再触发
	assert_true(final_count == 3, "loop+cancel: triggered 3 times in 3.5s (got " .. final_count .. ")")
	assert_true(count == final_count, "loop+cancel: no more triggers after cancel")
end

--------------------------------------------------------------------------------
-- 测试 4：多次触发（times=3），确认精确触发 3 次后 is_over
--------------------------------------------------------------------------------
local function test_fixed_times()
	log.info("=== test_fixed_times ===")
	local count = 0
	local t = timer:new(100, 3, function()
		count = count + 1
	end)
	skynet.sleep(400)  -- 等 4s，足够 3 次触发
	assert_true(count == 3, "fixed times: triggered exactly 3 times (got " .. count .. ")")
	assert_true(t.is_over == true, "fixed times: is_over=true")
	skynet.sleep(150)  -- 再等，确认不再触发
	assert_true(count == 3, "fixed times: no more triggers after is_over")
end

--------------------------------------------------------------------------------
-- 测试 5：多个定时器共存（堆的基本正确性）
-- 3个定时器：expire=100/200/300，各触发1次，验证触发顺序和时机
--------------------------------------------------------------------------------
local function test_multiple_timers()
	log.info("=== test_multiple_timers ===")
	local order = {}
	timer:new(100, 1, function() table.insert(order, 1) end)
	timer:new(300, 1, function() table.insert(order, 3) end)
	timer:new(200, 1, function() table.insert(order, 2) end)
	skynet.sleep(400)
	assert_true(#order == 3, "multiple timers: all 3 triggered (got " .. #order .. ")")
	assert_true(order[1] == 1 and order[2] == 2 and order[3] == 3,
		"multiple timers: triggered in order 1,2,3 (got " .. table.concat(order, ",") .. ")")
end

--------------------------------------------------------------------------------
-- 测试 6：after_next 模式
-- expire=100, times=3, after_next: 先执行回调再注册下一次
-- 每次回调 sleep 50 ticks，验证间隔比普通模式长
--------------------------------------------------------------------------------
local function test_after_next()
	log.info("=== test_after_next ===")
	local count = 0
	local timestamps = {}
	local t = timer:new(100, 3, function()
		count = count + 1
		table.insert(timestamps, skynet.now())
		skynet.sleep(50)  -- 回调耗时 50 ticks
	end)
	t:after_next()
	skynet.sleep(600)
	assert_true(count == 3, "after_next: triggered 3 times (got " .. count .. ")")
	if #timestamps >= 2 then
		-- after_next 模式：间隔 = expire + 上次回调耗时(约50) = ~150
		local interval = timestamps[2] - timestamps[1]
		assert_near(interval, 150, 30, "after_next: interval ~150 ticks")
	end
end

--------------------------------------------------------------------------------
-- 测试 7：回调中取消自身（is_after_next=false 模式）
-- expire=100, times=loop, 在第3次回调中 cancel 自身
--------------------------------------------------------------------------------
local function test_cancel_in_callback()
	log.info("=== test_cancel_in_callback ===")
	local count = 0
	local t
	t = timer:new(100, timer.loop, function()
		count = count + 1
		if count == 3 then
			t:cancel()
		end
	end)
	skynet.sleep(500)  -- 等 5s
	assert_true(count == 3, "cancel_in_callback: triggered 3 times then stopped (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 8：after_next=true 时回调中取消自身
-- expire=100, times=loop, after_next, 在第2次回调中 cancel
--------------------------------------------------------------------------------
local function test_cancel_in_callback_after_next()
	log.info("=== test_cancel_in_callback_after_next ===")
	local count = 0
	local t
	t = timer:new(100, timer.loop, function()
		count = count + 1
		if count == 2 then
			t:cancel()
		end
	end)
	t:after_next()
	skynet.sleep(500)
	assert_true(count == 2, "cancel_in_callback_after_next: triggered 2 times then stopped (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 9：extend 在首次触发前延时
-- expire=200, times=1, 等 100 ticks 后 extend(100)，新触发时间应为 ~200+100=300 ticks
--------------------------------------------------------------------------------
local function test_extend_before_trigger()
	log.info("=== test_extend_before_trigger ===")
	local trigger_time = nil
	local start_time = skynet.now()
	local t = timer:new(200, 1, function()
		trigger_time = skynet.now()
	end)
	skynet.sleep(100)  -- 等 1s，此时 remain ~100
	t:extend(100)      -- 延长 100 ticks，新的触发时间应在约 200 ticks 后
	skynet.sleep(300)  -- 等 3s，足够触发
	assert_true(trigger_time ~= nil, "extend_before_trigger: did trigger")
	if trigger_time then
		local elapsed = trigger_time - start_time
		assert_near(elapsed, 300, 30, "extend_before_trigger: elapsed ~300 ticks")
	end
end

--------------------------------------------------------------------------------
-- 测试 10：extend 在已触发一次后延时（times=2）
-- expire=100, times=2, 第1次触发后 extend(100), 第2次触发应延后
--------------------------------------------------------------------------------
local function test_extend_after_first_trigger()
	log.info("=== test_extend_after_first_trigger ===")
	local count = 0
	local trigger_times = {}
	local t
	t = timer:new(100, 2, function()
		count = count + 1
		table.insert(trigger_times, skynet.now())
		if count == 1 then
			-- 第1次触发后立即 extend，延长 100 ticks
			t:extend(100)
		end
	end)
	skynet.sleep(500)
	assert_true(count == 2, "extend_after_first_trigger: triggered 2 times (got " .. count .. ")")
	if #trigger_times == 2 then
		local interval = trigger_times[2] - trigger_times[1]
		-- 第2次应约在第1次后 100(expire)+100(extend) = 200 ticks
		assert_near(interval, 200, 40, "extend_after_first_trigger: second interval ~200 ticks")
	end
end

--------------------------------------------------------------------------------
-- 测试 11：extend 对已取消/已结束的定时器无效
--------------------------------------------------------------------------------
local function test_extend_on_finished()
	log.info("=== test_extend_on_finished ===")
	local count = 0
	local t = timer:new(100, 1, function()
		count = count + 1
	end)
	skynet.sleep(150)
	assert_true(t.is_over, "extend_on_finished: is_over after 1 trigger")
	t:extend(100)  -- 对已结束的定时器 extend，应该无效
	skynet.sleep(200)
	assert_true(count == 1, "extend_on_finished: no extra trigger after extend on over timer")

	local t2 = timer:new(200, 1, function()
		count = count + 100  -- 不应该触发
	end)
	t2:cancel()
	t2:extend(100)  -- 对已取消的定时器 extend，应该无效
	skynet.sleep(400)
	assert_true(count == 1, "extend_on_finished: no trigger after extend on cancelled timer")
end

--------------------------------------------------------------------------------
-- 测试 12：remain_expire 返回值测试
--------------------------------------------------------------------------------
local function test_remain_expire()
	log.info("=== test_remain_expire ===")
	local t = timer:new(200, 1, function() end)
	local remain1 = t:remain_expire()
	assert_near(remain1, 200, 20, "remain_expire: ~200 at start")
	skynet.sleep(100)
	local remain2 = t:remain_expire()
	assert_near(remain2, 100, 20, "remain_expire: ~100 after 1s")
	skynet.sleep(150)
	-- 触发后 remain_expire 应为 0
	local remain3 = t:remain_expire()
	assert_true(remain3 == 0, "remain_expire: 0 after trigger (got " .. tostring(remain3) .. ")")
	assert_true(t:is_finished(), "remain_expire: is_finished after trigger")

	local t2 = timer:new(300, 1, function() end)
	t2:cancel()
	assert_true(t2:remain_expire() == 0, "remain_expire: 0 after cancel")
	assert_true(t2:is_cancelled(), "remain_expire: is_cancelled after cancel")
end

--------------------------------------------------------------------------------
-- 测试 13：回调中创建新定时器（dispatch 中入堆）
-- 定时器 A 在回调中创建定时器 B，B 应正常触发
--------------------------------------------------------------------------------
local function test_create_in_callback()
	log.info("=== test_create_in_callback ===")
	local b_triggered = false
	timer:new(100, 1, function()
		-- 在 A 的回调中创建 B
		timer:new(100, 1, function()
			b_triggered = true
		end)
	end)
	skynet.sleep(300)  -- 足够 A 触发 + B 触发
	assert_true(b_triggered, "create_in_callback: timer B triggered after being created in A's callback")
end

--------------------------------------------------------------------------------
-- 测试 14：大量定时器同时创建（压测堆操作）
-- 创建 50 个 expire=100 的定时器，等待触发，确认全部触发
--------------------------------------------------------------------------------
local function test_many_timers()
	log.info("=== test_many_timers ===")
	local N = 50
	local count = 0
	for i = 1, N do
		timer:new(100, 1, function()
			count = count + 1
		end)
	end
	skynet.sleep(200)
	assert_true(count == N, "many_timers: all " .. N .. " timers triggered (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 15：不同 expire 的多定时器精度测试
-- 创建 expire=100/200/300/400/500 各 1 个定时器，验证各自的触发时机
--------------------------------------------------------------------------------
local function test_precision()
	log.info("=== test_precision ===")
	local results = {}
	local start = skynet.now()
	for _, exp in ipairs({100, 200, 300, 400, 500}) do
		local e = exp
		timer:new(e, 1, function()
			table.insert(results, {expire = e, elapsed = skynet.now() - start})
		end)
	end
	skynet.sleep(600)
	assert_true(#results == 5, "precision: all 5 timers triggered (got " .. #results .. ")")
	for _, r in ipairs(results) do
		assert_near(r.elapsed, r.expire, 25,
			string.format("precision: expire=%d elapsed=%d", r.expire, r.elapsed))
	end
end

--------------------------------------------------------------------------------
-- 测试 16：循环定时器间隔精度（不受回调耗时影响）
-- expire=100, times=loop, 触发5次，验证每次 expire_time 累加精准
--------------------------------------------------------------------------------
local function test_loop_precision()
	log.info("=== test_loop_precision ===")
	local start = skynet.now()
	local timestamps = {}
	local t
	t = timer:new(100, timer.loop, function()
		table.insert(timestamps, skynet.now() - start)
		if #timestamps >= 5 then
			t:cancel()
		end
	end)
	-- 等待足够时间
	skynet.sleep(700)
	assert_true(#timestamps >= 5, "loop_precision: triggered at least 5 times (got " .. #timestamps .. ")")
	for i, ts in ipairs(timestamps) do
		assert_near(ts, 100 * i, 25, string.format("loop_precision: #%d ~%d ticks", i, 100 * i))
	end
end

--------------------------------------------------------------------------------
-- 测试 17：expire=0 的定时器（立即触发）
--------------------------------------------------------------------------------
local function test_zero_expire()
	log.info("=== test_zero_expire ===")
	local count = 0
	timer:new(0, 3, function()
		count = count + 1
	end)
	skynet.sleep(50)
	assert_true(count == 3, "zero_expire: 3 times triggered immediately (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 18：同一时刻大量到期定时器（批量处理）
-- 创建 20 个同 expire 的定时器，验证全部被正确处理
--------------------------------------------------------------------------------
local function test_batch_expire()
	log.info("=== test_batch_expire ===")
	local count = 0
	local N = 20
	for i = 1, N do
		timer:new(100, 1, function()
			count = count + 1
		end)
	end
	skynet.sleep(200)
	assert_true(count == N, "batch_expire: all " .. N .. " timers expired together (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 19：新加更早到期的定时器（堆顶抢占）
-- 先创建 expire=300 的定时器 A，再创建 expire=100 的定时器 B
-- 验证 B 先触发，且 A 也按时触发
--------------------------------------------------------------------------------
local function test_earlier_timer_preempt()
	log.info("=== test_earlier_timer_preempt ===")
	local order = {}
	local start = skynet.now()
	timer:new(300, 1, function()
		table.insert(order, {id = "A", elapsed = skynet.now() - start})
	end)
	skynet.sleep(50)
	timer:new(100, 1, function()  -- 从现在算 100 ticks，总计 150 ticks，比 A 的 300 早
		table.insert(order, {id = "B", elapsed = skynet.now() - start})
	end)
	skynet.sleep(350)
	assert_true(#order == 2, "preempt: both A and B triggered (got " .. #order .. ")")
	if #order >= 2 then
		assert_true(order[1].id == "B", "preempt: B triggered first (got " .. order[1].id .. ")")
		assert_near(order[1].elapsed, 150, 30, "preempt: B elapsed ~150 ticks")
		assert_near(order[2].elapsed, 300, 30, "preempt: A elapsed ~300 ticks")
	end
end

--------------------------------------------------------------------------------
-- 测试 20：定时器回调内 extend 自身（循环延迟效果）
-- times=loop, 每次回调把自己 extend 100，形成递增间隔
--------------------------------------------------------------------------------
local function test_extend_in_callback()
	log.info("=== test_extend_in_callback ===")
	local count = 0
	local timestamps = {}
	local start = skynet.now()
	local t
	t = timer:new(100, timer.loop, function()
		count = count + 1
		table.insert(timestamps, skynet.now() - start)
		if count >= 3 then
			t:cancel()
		else
			t:extend(50)  -- 每次延长 50 ticks
		end
	end)
	skynet.sleep(800)
	assert_true(count == 3, "extend_in_callback: triggered 3 times (got " .. count .. ")")
	-- 第1次: ~100, 第2次: ~100(expire)+100(remain)+50(extend) ≈ 250+100=350, 第3次更晚
	-- 实际：第1次100，extend后expire=150, expire_time=触发点+150; 第2次约250...
	if #timestamps >= 2 then
		assert_true(timestamps[2] > timestamps[1] + 100,
			"extend_in_callback: second interval > 100 ticks (got " .. (timestamps[2]-timestamps[1]) .. ")")
	end
end

--------------------------------------------------------------------------------
-- 测试 21：新增方法测试（is_cancelled/is_finished/is_loop/remain_times/is_valid）
--------------------------------------------------------------------------------
local function test_new_methods()
	log.info("=== test_new_methods ===")

	-- 21.1 is_loop：循环定时器 vs 非循环
	local t_loop = timer:new(500, timer.loop, function() end)
	local t_once = timer:new(500, 3, function() end)
	local t_one  = timer:new(500, 1, function() end)
	assert_true(t_loop:is_loop() == true,  "new_methods 21.1: is_loop()=true for loop timer")
	assert_true(t_once:is_loop() == false, "new_methods 21.1: is_loop()=false for times=3 timer")
	assert_true(t_one:is_loop()  == false, "new_methods 21.1: is_loop()=false for times=1 timer")

	-- 21.2 初始状态：is_valid/is_cancelled/is_finished
	assert_true(t_loop:is_valid()     == true,  "new_methods 21.2: is_valid()=true initially (loop)")
	assert_true(t_once:is_valid()     == true,  "new_methods 21.2: is_valid()=true initially (times=3)")
	assert_true(t_loop:is_cancelled() == false, "new_methods 21.2: is_cancelled()=false initially")
	assert_true(t_loop:is_finished()  == false, "new_methods 21.2: is_finished()=false initially")

	-- 21.3 remain_times 初始值
	assert_true(t_loop:remain_times() == -1, "new_methods 21.3: remain_times()=-1 for loop timer")
	assert_true(t_once:remain_times() == 3,  "new_methods 21.3: remain_times()=3 for new timer(times=3)")
	assert_true(t_one:remain_times()  == 1,  "new_methods 21.3: remain_times()=1 for new timer(times=1)")

	-- 21.4 cancel 后状态
	t_loop:cancel()
	assert_true(t_loop:is_cancelled()  == true,  "new_methods 21.4: is_cancelled()=true after cancel")
	assert_true(t_loop:is_valid()      == false, "new_methods 21.4: is_valid()=false after cancel")
	assert_true(t_loop:is_finished()   == false, "new_methods 21.4: is_finished()=false (cancel ≠ finish)")
	assert_true(t_loop:remain_times()  == 0,     "new_methods 21.4: remain_times()=0 after cancel")
	assert_true(t_loop:remain_expire() == 0,     "new_methods 21.4: remain_expire()=0 after cancel")

	-- 21.5 触发次数递减验证：remain_times 随触发动态减少（times=3）
	t_once:cancel()  -- 清理之前创建的 t_once（expire=500 太长）
	local count_rm = 0
	-- expire=200（避免与 sleep 边界太近导致误差），times=3
	local t_rm = timer:new(200, 3, function() count_rm = count_rm + 1 end)
	assert_true(t_rm:remain_times() == 3, "new_methods 21.5: remain_times()=3 before any trigger")
	assert_true(t_rm:is_valid()     == true, "new_methods 21.5: is_valid()=true before any trigger")
	skynet.sleep(250)   -- 等第1次触发（200 ticks）
	assert_true(count_rm == 1, "new_methods 21.5: triggered exactly once after 1 expire")
	assert_true(t_rm:remain_times() == 2, "new_methods 21.5: remain_times()=2 after 1/3 trigger")
	assert_true(t_rm:is_valid()     == true, "new_methods 21.5: is_valid()=true after 1/3 trigger")
	assert_true(t_rm:is_finished()  == false, "new_methods 21.5: is_finished()=false after 1/3 trigger")
	skynet.sleep(200)   -- 等第2次触发
	assert_true(count_rm == 2, "new_methods 21.5: triggered exactly twice after 2 expire")
	assert_true(t_rm:remain_times() == 1, "new_methods 21.5: remain_times()=1 after 2/3 trigger")
	assert_true(t_rm:is_valid()     == true, "new_methods 21.5: is_valid()=true after 2/3 trigger")
	skynet.sleep(200)   -- 等第3次触发
	assert_true(count_rm == 3,           "new_methods 21.5: triggered 3 times (got " .. count_rm .. ")")
	assert_true(t_rm:is_finished()   == true,  "new_methods 21.5: is_finished()=true after all triggers")
	assert_true(t_rm:is_valid()      == false, "new_methods 21.5: is_valid()=false after finish")
	assert_true(t_rm:remain_times()  == 0,     "new_methods 21.5: remain_times()=0 after finish")
	assert_true(t_rm:remain_expire() == 0,     "new_methods 21.5: remain_expire()=0 after finish")
	assert_true(t_rm:is_cancelled()  == false, "new_methods 21.5: is_cancelled()=false (finish ≠ cancel)")

	-- 21.6 loop 定时器触发多次后取消，remain_times 始终 -1
	local count_lp = 0
	local t_lp
	t_lp = timer:new(100, timer.loop, function()
		count_lp = count_lp + 1
	end)
	assert_true(t_lp:remain_times() == -1, "new_methods 21.6: loop remain_times()=-1 initially")
	skynet.sleep(350)   -- 触发约 3 次
	assert_true(t_lp:remain_times() == -1, "new_methods 21.6: loop remain_times()=-1 after triggers")
	assert_true(t_lp:is_valid()     == true, "new_methods 21.6: loop is_valid()=true after triggers")
	t_lp:cancel()
	assert_true(t_lp:is_valid()     == false, "new_methods 21.6: loop is_valid()=false after cancel")
	assert_true(t_lp:remain_times() == 0,    "new_methods 21.6: loop remain_times()=0 after cancel")

	-- 21.7 times=1 定时器触发完毕后的完整状态
	local t_done_flag = false
	local t_done = timer:new(100, 1, function() t_done_flag = true end)
	assert_true(t_done:is_finished()   == false, "new_methods 21.7: is_finished()=false before trigger")
	assert_true(t_done:is_valid()      == true,  "new_methods 21.7: is_valid()=true before trigger")
	assert_true(t_done:is_cancelled()  == false, "new_methods 21.7: is_cancelled()=false before trigger")
	assert_true(t_done:remain_times()  == 1,     "new_methods 21.7: remain_times()=1 before trigger")
	skynet.sleep(150)
	assert_true(t_done_flag,               "new_methods 21.7: timer triggered")
	assert_true(t_done:is_finished()   == true,  "new_methods 21.7: is_finished()=true after trigger")
	assert_true(t_done:is_valid()      == false, "new_methods 21.7: is_valid()=false after finish")
	assert_true(t_done:is_cancelled()  == false, "new_methods 21.7: is_cancelled()=false (finish ≠ cancel)")
	assert_true(t_done:remain_times()  == 0,     "new_methods 21.7: remain_times()=0 after finish")
	assert_true(t_done:remain_expire() == 0,     "new_methods 21.7: remain_expire()=0 after finish")

	-- 清理 t_one（之前创建的 expire=500 定时器）
	t_one:cancel()
end

--------------------------------------------------------------------------------
-- 测试 22：大 expire（触发 tv2 级联）
-- expire=300 ticks（> 256），需 tv2 → tv1 cascade 才能触发
--------------------------------------------------------------------------------
local function test_large_expire_cascade()
	log.info("=== test_large_expire_cascade ===")
	local start = skynet.now()
	local results = {}
	-- 分布在 tv1、tv2、tv3 范围的定时器
	for _, exp in ipairs({50, 150, 300, 500, 800}) do
		local e = exp
		timer:new(e, 1, function()
			table.insert(results, {expire = e, elapsed = skynet.now() - start})
		end)
	end
	skynet.sleep(1000)
	assert_true(#results == 5, "large_expire_cascade: all 5 triggered (got " .. #results .. ")")
	for _, r in ipairs(results) do
		assert_near(r.elapsed, r.expire, 30,
			string.format("large_expire_cascade: expire=%d elapsed=%d", r.expire, r.elapsed))
	end
end

--------------------------------------------------------------------------------
-- 测试 23：双重取消不崩溃
--------------------------------------------------------------------------------
local function test_double_cancel()
	log.info("=== test_double_cancel ===")
	local count = 0
	local t = timer:new(100, 1, function() count = count + 1 end)
	t:cancel()
	t:cancel()  -- 第二次取消，不应报错
	assert_true(t:is_cancelled(), "double_cancel: still cancelled after double cancel")
	skynet.sleep(150)
	assert_true(count == 0, "double_cancel: not triggered")
end

--------------------------------------------------------------------------------
-- 测试 24：连续多次 extend 在触发前
--------------------------------------------------------------------------------
local function test_multiple_extends()
	log.info("=== test_multiple_extends ===")
	local start = skynet.now()
	local trigger_time = nil
	local t = timer:new(100, 1, function()
		trigger_time = skynet.now()
	end)
	skynet.sleep(30)
	t:extend(50)   -- remain ≈ 70, expire_time = now + 70 + 50 = now + 120
	skynet.sleep(30)
	t:extend(50)   -- remain ≈ 90, expire_time = now + 90 + 50 = now + 140
	skynet.sleep(30)
	t:extend(50)   -- remain ≈ 110, expire_time = now + 110 + 50 = now + 160
	-- 总延迟约 90(已过) + 160 = start + 250
	skynet.sleep(300)
	assert_true(trigger_time ~= nil, "multiple_extends: did trigger")
	if trigger_time then
		local elapsed = trigger_time - start
		-- 原 expire=100, 3 次 extend(50) → 累加 150, 总约 250 ticks
		assert_near(elapsed, 250, 40, "multiple_extends: elapsed ~250")
	end
end

--------------------------------------------------------------------------------
-- 测试 25：expire=1 的高频循环定时器精度
--------------------------------------------------------------------------------
local function test_high_freq_timer()
	log.info("=== test_high_freq_timer ===")
	local count = 0
	local start = skynet.now()
	local t
	t = timer:new(1, timer.loop, function()
		count = count + 1
	end)
	skynet.sleep(100)  -- 等 1 秒（100 ticks）
	t:cancel()
	local elapsed = skynet.now() - start
	-- expire=1，1 秒内应触发约 100 次（实际可能 99~100）
	assert_true(count >= 90, "high_freq: at least 90 triggers in 1s (got " .. count .. ")")
	assert_true(count <= 110, "high_freq: at most 110 triggers in 1s (got " .. count .. ")")
	log.info(string.format("[INFO] high_freq: %d triggers in %d ticks", count, elapsed))
end

--------------------------------------------------------------------------------
-- 测试 26：回调中创建大量定时器（压测 dispatch 中 internal_add）
--------------------------------------------------------------------------------
local function test_create_many_in_callback()
	log.info("=== test_create_many_in_callback ===")
	local N = 50
	local child_count = 0
	timer:new(50, 1, function()
		-- 在回调中创建 N 个新定时器
		for i = 1, N do
			timer:new(50, 1, function()
				child_count = child_count + 1
			end)
		end
	end)
	skynet.sleep(200)
	assert_true(child_count == N, "create_many_in_callback: all " .. N .. " child timers triggered (got " .. child_count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 27：循环定时器 extend 后间隔累加验证
-- expire=100, loop, 每次 extend(20) → 间隔逐渐增大：100, 120, 140, 160...
--------------------------------------------------------------------------------
local function test_loop_extend_accumulate()
	log.info("=== test_loop_extend_accumulate ===")
	local timestamps = {}
	local start = skynet.now()
	local count = 0
	local t
	t = timer:new(100, timer.loop, function()
		count = count + 1
		table.insert(timestamps, skynet.now() - start)
		if count >= 4 then
			t:cancel()
		else
			t:extend(20)
		end
	end)
	skynet.sleep(800)
	assert_true(count == 4, "loop_extend_accumulate: triggered 4 times (got " .. count .. ")")
	-- 第1次: ~100, 第2次: ~100+120=220, 第3次: ~220+140=360, 第4次: ~360+160=520
	if #timestamps >= 2 then
		-- 每次间隔应递增（至少比上一次大 10 ticks）
		local increasing = true
		for i = 3, #timestamps do
			local iv_prev = timestamps[i-1] - timestamps[i-2]
			local iv_cur  = timestamps[i]   - timestamps[i-1]
			if iv_cur < iv_prev - 10 then
				increasing = false
				break
			end
		end
		assert_true(increasing, "loop_extend_accumulate: intervals are increasing")
	end
end

--------------------------------------------------------------------------------
-- 测试 28：remain_expire 在 extend 后正确更新
--------------------------------------------------------------------------------
local function test_remain_expire_after_extend()
	log.info("=== test_remain_expire_after_extend ===")
	local t = timer:new(200, 1, function() end)
	skynet.sleep(50)
	local remain1 = t:remain_expire()
	assert_near(remain1, 150, 20, "remain_expire_extend: ~150 after 50 ticks")
	t:extend(100)
	local remain2 = t:remain_expire()
	-- extend(100) 后：remain = old_remain + 100 ≈ 150 + 100 = 250
	assert_near(remain2, 250, 20, "remain_expire_extend: ~250 after extend(100)")
	t:cancel()
end

--------------------------------------------------------------------------------
-- 测试 29：after_next 模式下回调中 extend（验证基于回调完成时刻重算）
--------------------------------------------------------------------------------
local function test_after_next_extend_in_callback()
	log.info("=== test_after_next_extend_in_callback ===")
	local timestamps = {}
	local start = skynet.now()
	local count = 0
	local t
	t = timer:new(100, 3, function()
		count = count + 1
		table.insert(timestamps, skynet.now() - start)
		skynet.sleep(30)  -- 回调耗时 30 ticks
		if count < 3 then
			t:extend(20)
		end
	end)
	t:after_next()
	skynet.sleep(700)
	assert_true(count == 3, "after_next_extend: triggered 3 times (got " .. count .. ")")
	-- after_next 模式：每次间隔 = expire + callback_time ≈ 120 + 30 = 150
	-- 加上 extend(20)：expire 每次增加 20 → 120, 140, 160... + callback(30)
	-- 但 after_next extend 效果可能不同，主要验证能正确触发不卡死
end

--------------------------------------------------------------------------------
-- 测试 30：cancel 已经结束的循环定时器（边界：is_over 的循环定时器不存在）
-- times=2 的循环在 2 次后 is_over，然后 cancel 不崩溃
--------------------------------------------------------------------------------
local function test_cancel_after_over()
	log.info("=== test_cancel_after_over ===")
	local count = 0
	local t = timer:new(50, 2, function() count = count + 1 end)
	skynet.sleep(200)
	assert_true(count == 2, "cancel_after_over: triggered 2 times (got " .. count .. ")")
	assert_true(t:is_finished(), "cancel_after_over: is_finished")
	t:cancel()  -- cancel 已结束的定时器，不应崩溃
	assert_true(t:is_cancelled(), "cancel_after_over: is_cancelled after cancel on finished")
	assert_true(t:remain_expire() == 0, "cancel_after_over: remain_expire=0")
end

--------------------------------------------------------------------------------
-- 测试 31：同时有短期和长期定时器（验证 schedule_next 抢占正确性）
-- 先创建 expire=5000(50s) 的长期定时器，再创建 expire=50(0.5s) 的短期定时器
-- 短期定时器应按时触发，不受长期定时器影响
--------------------------------------------------------------------------------
local function test_short_long_mix()
	log.info("=== test_short_long_mix ===")
	local long_triggered = false
	local short_triggered = false
	local start = skynet.now()
	local t_long = timer:new(5000, 1, function() long_triggered = true end)
	timer:new(50, 1, function() short_triggered = true end)
	skynet.sleep(100)
	assert_true(short_triggered, "short_long_mix: short timer triggered")
	assert_true(not long_triggered, "short_long_mix: long timer NOT triggered yet")
	t_long:cancel()
end

--------------------------------------------------------------------------------
-- 测试 32：大量定时器逐个 expire 不同（1~200），验证全部按序触发
--------------------------------------------------------------------------------
local function test_sequential_expiry()
	log.info("=== test_sequential_expiry ===")
	local N = 100
	local results = {}
	local start = skynet.now()
	for i = 1, N do
		local e = i * 2  -- expire = 2, 4, 6, ..., 200
		timer:new(e, 1, function()
			table.insert(results, {id = i, elapsed = skynet.now() - start})
		end)
	end
	skynet.sleep(250)
	assert_true(#results == N, "sequential_expiry: all " .. N .. " triggered (got " .. #results .. ")")
	-- 验证触发顺序（id 应单调递增）
	local ordered = true
	for i = 2, #results do
		if results[i].id < results[i-1].id then
			ordered = false
			break
		end
	end
	assert_true(ordered, "sequential_expiry: triggered in order")
end

--------------------------------------------------------------------------------
-- 测试 33：once() 快捷方法
--------------------------------------------------------------------------------
local function test_once_shortcut()
	log.info("=== test_once_shortcut ===")
	local count = 0
	local t = timer:once(100, function() count = count + 1 end)
	skynet.sleep(150)
	assert_true(count == 1, "once_shortcut: triggered exactly 1 time (got " .. count .. ")")
	assert_true(t:is_finished(), "once_shortcut: is_finished()")
	assert_true(not t:is_loop(), "once_shortcut: not is_loop()")
	skynet.sleep(150)
	assert_true(count == 1, "once_shortcut: no extra trigger after finish")
end

--------------------------------------------------------------------------------
-- 测试 34：new_loop() 快捷方法
--------------------------------------------------------------------------------
local function test_new_loop_shortcut()
	log.info("=== test_new_loop_shortcut ===")
	local count = 0
	local t = timer:new_loop(100, function() count = count + 1 end)
	skynet.sleep(350)
	t:cancel()
	assert_true(count == 3, "new_loop_shortcut: triggered 3 times in 3.5s (got " .. count .. ")")
	assert_true(t:is_loop(), "new_loop_shortcut: is_loop()")
	assert_true(t:is_cancelled(), "new_loop_shortcut: is_cancelled()")
end

--------------------------------------------------------------------------------
-- 测试 35：回调参数传递正确性
--------------------------------------------------------------------------------
local function test_callback_args()
	log.info("=== test_callback_args ===")
	local received_args = {}
	timer:once(50, function(a, b, c)
		received_args = {a, b, c}
	end, "hello", 42, true)
	skynet.sleep(100)
	assert_true(received_args[1] == "hello", "callback_args: arg1='hello' (got " .. tostring(received_args[1]) .. ")")
	assert_true(received_args[2] == 42, "callback_args: arg2=42 (got " .. tostring(received_args[2]) .. ")")
	assert_true(received_args[3] == true, "callback_args: arg3=true (got " .. tostring(received_args[3]) .. ")")
end

--------------------------------------------------------------------------------
-- 测试 36：extend 负值（缩短触发时间）
--------------------------------------------------------------------------------
local function test_extend_negative()
	log.info("=== test_extend_negative ===")
	local start = skynet.now()
	local trigger_time = nil
	local t = timer:once(300, function()
		trigger_time = skynet.now()
	end)
	skynet.sleep(50)
	t:extend(-100)  -- 缩短 100 ticks，新到期 ≈ start + 200
	skynet.sleep(250)
	assert_true(trigger_time ~= nil, "extend_negative: did trigger")
	if trigger_time then
		local elapsed = trigger_time - start
		assert_near(elapsed, 200, 40, "extend_negative: elapsed ~200 after extend(-100)")
	end
end

--------------------------------------------------------------------------------
-- 测试 37：大量 cancel 后重建（验证对象池复用）
--------------------------------------------------------------------------------
local function test_pool_recycle()
	log.info("=== test_pool_recycle ===")
	-- 第一轮：创建 200 个定时器并立即 cancel
	for i = 1, 200 do
		local t = timer:once(30000, function() end)
		t:cancel()
	end
	-- 第二轮：再创建 200 个定时器（应复用池中的 table）
	local count = 0
	local timers = {}
	for i = 1, 200 do
		timers[i] = timer:once(50, function() count = count + 1 end)
	end
	skynet.sleep(100)
	assert_true(count == 200, "pool_recycle: all 200 recycled timers triggered (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 38：循环定时器 extend 后 expire 字段正确更新
--------------------------------------------------------------------------------
local function test_extend_updates_expire()
	log.info("=== test_extend_updates_expire ===")
	local count = 0
	local intervals = {}
	local last_time = skynet.now()
	local t
	t = timer:new_loop(100, function()
		count = count + 1
		local now = skynet.now()
		table.insert(intervals, now - last_time)
		last_time = now
		if count >= 3 then
			t:cancel()
		end
	end)
	-- 在首次触发前 extend(50)，之后 expire 应变为 150
	skynet.sleep(30)
	t:extend(50)
	skynet.sleep(600)
	assert_true(count == 3, "extend_updates_expire: triggered 3 times (got " .. count .. ")")
	-- 第1次间隔 ≈ 150（原 expire=100 + extend=50），后续每次 ≈ 150
	if #intervals >= 2 then
		assert_near(intervals[2], 150, 30, "extend_updates_expire: 2nd interval ~150")
	end
end

--------------------------------------------------------------------------------
-- 测试 39：cancel 已在 pending_readd 中的定时器（回调中 cancel 循环定时器）
-- 验证 dispatch 结束后 pending_readd 中已 cancel 的定时器不会被 internal_add
--------------------------------------------------------------------------------
local function test_cancel_pending_readd()
	log.info("=== test_cancel_pending_readd ===")
	local count = 0
	local t
	t = timer:new(50, timer.loop, function()
		count = count + 1
		if count == 2 then
			t:cancel()
		end
	end)
	skynet.sleep(300)
	-- 循环定时器：非 after_next 模式，第2次回调中 cancel
	-- 由于回调在 fork 中执行，cancel 时定时器已在 pending_readd 中
	-- dispatch 结束后 internal_add_raw 时不应检查 is_cancel（只在触发时检查）
	-- 但下次 dispatch 遇到时会跳过
	assert_true(count == 2, "cancel_pending_readd: stopped at 2 triggers (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 40：timer 常量值验证
--------------------------------------------------------------------------------
local function test_constants()
	log.info("=== test_constants ===")
	assert_true(timer.loop == 0, "constants: timer.loop == 0")
	assert_true(timer.second == 100, "constants: timer.second == 100")
	assert_true(timer.minute == 6000, "constants: timer.minute == 6000")
	assert_true(timer.hour == 360000, "constants: timer.hour == 360000")
	assert_true(timer.day == 8640000, "constants: timer.day == 8640000")
end


--------------------------------------------------------------------------------
-- 测试 42：release() 基本功能
-- 验证 release 后对象可被对象池回收
--------------------------------------------------------------------------------
local function test_release_basic()
	log.info("=== test_release_basic ===")
	-- 创建并立即 cancel + release
	local t = timer:new(500, 1, function() end)
	assert_true(t._ref_count == 1, "release_basic: _ref_count=1 after new")
	t:cancel()
	-- cancel 后 _ref_count 仍为 1（用户还持有引用）
	-- 只是 is_cancel=true
	assert_true(t.is_cancel == true, "release_basic: is_cancel after cancel")
	-- release 减引用，归零后应被 pool_release（字段清空）
	t:release()
	-- release 后 _ref_count 被清为 nil（pool_release 清理了）
	assert_true(t._ref_count == nil, "release_basic: _ref_count=nil after release (returned to pool)")
	assert_true(t.callback == nil, "release_basic: callback=nil after pool_release")
end

--------------------------------------------------------------------------------
-- 测试 43：release() 在定时器结束后调用
-- 先让 timer 自然结束（is_over），然后 release 归还池
--------------------------------------------------------------------------------
local function test_release_after_over()
	log.info("=== test_release_after_over ===")
	local count = 0
	local t = timer:new(50, 1, function() count = count + 1 end)
	skynet.sleep(100)
	assert_true(count == 1, "release_after_over: triggered once")
	assert_true(t.is_over == true, "release_after_over: is_over=true")
	assert_true(t._ref_count == 1, "release_after_over: _ref_count=1 (user still holds)")
	-- 查询状态仍然正常
	assert_true(t:is_finished() == true, "release_after_over: is_finished()=true")
	-- release 后归还池
	t:release()
	assert_true(t._ref_count == nil, "release_after_over: _ref_count=nil (returned to pool)")
end

--------------------------------------------------------------------------------
-- 测试 44：release() 在定时器结束前调用（不应提前归还）
-- _ref_count 归零但 is_over=false，不应被 pool_release
--------------------------------------------------------------------------------
local function test_release_before_over()
	log.info("=== test_release_before_over ===")
	local count = 0
	local t = timer:new(200, 1, function() count = count + 1 end)
	-- 定时器还没到期，先 release
	t:release()
	assert_true(t._ref_count == 0, "release_before_over: _ref_count=0 after release")
	-- is_over=false, is_cancel=false，所以 try_release 不归还
	assert_true(t.callback ~= nil, "release_before_over: callback still valid (not pooled)")
	-- 定时器仍应正常触发
	skynet.sleep(250)
	assert_true(count == 1, "release_before_over: still triggered once after release")
	-- 触发后 is_over=true，此时 _ref_count <= 0，try_release 应归还
	assert_true(t._ref_count == nil, "release_before_over: _ref_count=nil (returned after over)")
end

--------------------------------------------------------------------------------
-- 测试 45：重复 release 不崩溃
-- 多次 release 应安全（第二次 _ref_count 已为 nil，直接忽略）
--------------------------------------------------------------------------------
local function test_release_double()
	log.info("=== test_release_double ===")
	local t = timer:new(500, 1, function() end)
	t:cancel()
	t:release()  -- 第一次 release，归还池
	t:release()  -- 第二次 release，_ref_count=nil，应安全忽略
	assert_true(true, "release_double: no crash on double release")
end

--------------------------------------------------------------------------------
-- 测试 46：release + cancel 顺序无关
-- cancel 后 release 和 release 后 cancel 都应正常工作
--------------------------------------------------------------------------------
local function test_release_cancel_order()
	log.info("=== test_release_cancel_order ===")
	-- 场景1：先 release 再 cancel
	local t1 = timer:new(500, 1, function() end)
	t1:release()  -- _ref_count=0, 但 is_cancel=false/is_over=false, 不归还
	assert_true(t1._ref_count == 0, "release_cancel_order: _ref_count=0 after release")
	assert_true(t1.callback ~= nil, "release_cancel_order: not pooled yet")
	t1:cancel()   -- is_cancel=true, _ref_count=0, try_release 归还
	assert_true(t1._ref_count == nil, "release_cancel_order: pooled after cancel")

	-- 场景2：先 cancel 再 release（与 test_release_basic 类似）
	local t2 = timer:new(500, 1, function() end)
	t2:cancel()
	assert_true(t2._ref_count == 1, "release_cancel_order2: _ref_count=1 after cancel")
	t2:release()
	assert_true(t2._ref_count == nil, "release_cancel_order2: pooled after release")
end

--------------------------------------------------------------------------------
-- 测试 47：release 后对象池复用验证
-- cancel+release 200个定时器后，重新创建200个应复用池中 table
--------------------------------------------------------------------------------
local function test_release_pool_recycle()
	log.info("=== test_release_pool_recycle ===")
	local old_tables = {}
	-- 第一轮：创建+cancel+release
	for i = 1, 200 do
		local t = timer:once(30000, function() end)
		old_tables[i] = t
		t:cancel()
		t:release()  -- 归还池
	end
	-- 第二轮：创建新的，应复用
	local count = 0
	for i = 1, 200 do
		local t = timer:once(50, function() count = count + 1 end)
		t:release()  -- release 但不 cancel，定时器仍正常运行
	end
	skynet.sleep(100)
	assert_true(count == 200, "release_pool_recycle: all 200 recycled timers triggered (got " .. count .. ")")
end

--------------------------------------------------------------------------------
-- 测试 48：set_warn_threshold 设置和清除
--------------------------------------------------------------------------------
local function test_set_warn_threshold()
	log.info("=== test_set_warn_threshold ===")
	-- 设置阈值为 50 ticks（0.5秒）
	timer.set_warn_threshold(50)
	-- 创建一个回调耗时约 100 ticks 的定时器
	-- 此测试主要验证不崩溃、阈值设置/清除正常
	local triggered = false
	local t = timer:new(50, 1, function()
		skynet.sleep(100)  -- 耗时 100 ticks，超过阈值 50
		triggered = true
	end)
	skynet.sleep(200)
	assert_true(triggered, "set_warn_threshold: timer triggered with slow callback")
	-- 清除阈值
	timer.set_warn_threshold(0)
	-- 再创建一个正常回调，不应有 warn
	local triggered2 = false
	timer:once(50, function() triggered2 = true end)
	skynet.sleep(100)
	assert_true(triggered2, "set_warn_threshold: timer triggered after clearing threshold")
end

--------------------------------------------------------------------------------
-- 测试 49：同步执行验证（回调不使用 skynet.fork）
-- 多个同 expire 定时器，回调中记录的 skynet.now() 应相同
-- 因为同步执行时不 yield，skynet.now() 不变
--------------------------------------------------------------------------------
local function test_sync_execution()
	log.info("=== test_sync_execution ===")
	local times = {}
	for i = 1, 5 do
		timer:new(100, 1, function()
			table.insert(times, skynet.now())
		end)
	end
	skynet.sleep(150)
	assert_true(#times == 5, "sync_execution: all 5 triggered (got " .. #times .. ")")
	-- 同步执行下，同一 tick 的回调 skynet.now() 应相同
	if #times >= 2 then
		local all_same = true
		for i = 2, #times do
			if times[i] ~= times[1] then
				all_same = false
				break
			end
		end
		assert_true(all_same, "sync_execution: all callbacks see same skynet.now() (sync execution)")
	end
end

--------------------------------------------------------------------------------
-- 测试 50：循环定时器 release 后仍正常运行直到 cancel
-- release 只减引用，不影响定时器行为
--------------------------------------------------------------------------------
local function test_release_loop_timer()
	log.info("=== test_release_loop_timer ===")
	local count = 0
	local t
	t = timer:new(100, timer.loop, function()
		count = count + 1
		if count >= 3 then
			t:cancel()
		end
	end)
	t:release()  -- 提前 release，_ref_count=0
	assert_true(t._ref_count == 0, "release_loop: _ref_count=0 after release")
	skynet.sleep(400)
	assert_true(count == 3, "release_loop: triggered 3 times before cancel (got " .. count .. ")")
	-- cancel 后 _ref_count=0 + is_cancel=true，应被归还池
	assert_true(t._ref_count == nil, "release_loop: pooled after cancel (ref was already 0)")
end

--------------------------------------------------------------------------------
-- 测试 51：回调报错不影响后续定时器
-- 验证 execute_call_back 中 xpcall 捕获 error，后续定时器正常运行
--------------------------------------------------------------------------------
local function test_error_callback()
	log.info("=== test_error_callback ===")
	local error_triggered = false
	-- 创建一个会报错的定时器
	timer:new(50, 1, function()
		error_triggered = true
		error("intentional error for test_error_callback")
	end)
	skynet.sleep(100)
	assert_true(error_triggered, "error_callback: error callback was entered")
	-- 此测试主要验证不崩溃且 error 不影响后续定时器
	local subsequent_ok = false
	timer:once(50, function() subsequent_ok = true end)
	skynet.sleep(100)
	assert_true(subsequent_ok, "error_callback: subsequent timer works after error callback")
end

--------------------------------------------------------------------------------
-- 测试 52：慢回调 warn 日志
-- 设置低阈值，创建慢回调定时器，验证 warn 日志打印且不崩溃
--------------------------------------------------------------------------------
local function test_slow_callback_warn()
	log.info("=== test_slow_callback_warn ===")
	-- 设置阈值为 10 ticks（100ms）
	timer.set_warn_threshold(10)
	local slow_triggered = false
	timer:new(50, 1, function()
		skynet.sleep(50)  -- 耗时 50 ticks（500ms），远超阈值 10
		slow_triggered = true
	end)
	skynet.sleep(150)
	assert_true(slow_triggered, "slow_callback_warn: slow callback triggered")
	-- 清除阈值
	timer.set_warn_threshold(0)
end

--------------------------------------------------------------------------------
-- 主测试入口（定时器相关）
--------------------------------------------------------------------------------
local function timer_test()
	test_basic_once()
	test_cancel_before_trigger()
	test_loop_and_cancel()
	test_fixed_times()
	test_multiple_timers()
	test_after_next()
	test_cancel_in_callback()
	test_cancel_in_callback_after_next()
	test_extend_before_trigger()
	test_extend_after_first_trigger()
	test_extend_on_finished()
	test_remain_expire()
	test_create_in_callback()
	test_many_timers()
	test_precision()
	test_loop_precision()
	test_zero_expire()
	test_batch_expire()
	test_earlier_timer_preempt()
	test_extend_in_callback()
	test_new_methods()
	-- 新增测试用例（第二批）
	test_large_expire_cascade()
	test_double_cancel()
	test_multiple_extends()
	test_high_freq_timer()
	test_create_many_in_callback()
	test_loop_extend_accumulate()
	test_remain_expire_after_extend()
	test_after_next_extend_in_callback()
	test_cancel_after_over()
	test_short_long_mix()
	test_sequential_expiry()
	-- 新增测试用例（第三批）
	test_once_shortcut()
	test_new_loop_shortcut()
	test_callback_args()
	test_extend_negative()
	test_pool_recycle()
	test_extend_updates_expire()
	test_cancel_pending_readd()
	test_constants()
	-- 新增测试用例（第四批：引用计数、source、慢日志、同步执行）
	test_release_basic()
	test_release_after_over()
	test_release_before_over()
	test_release_double()
	test_release_cancel_order()
	test_release_pool_recycle()
	test_set_warn_threshold()
	test_sync_execution()
	test_release_loop_timer()
	-- 新增测试用例（第五批：error/warn 日志验证）
	test_error_callback()
	test_slow_callback_warn()
	log.info("=== timer_test all done ===")
end

--------------------------------------------------------------------------------
-- 整点报时测试
--------------------------------------------------------------------------------
local function time_point_test()
	local _ = timer_point:new(timer_point.EVERY_MINUTE):set_sec(10):builder(function()
		log.error("每分钟:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	local _ = timer_point:new(timer_point.EVERY_HOUR):set_min(5):set_sec(20):builder(function()
		log.error("每小时:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	local _ = timer_point:new(timer_point.EVERY_DAY):set_hour(6):set_min(5):set_sec(20):builder(function()
		log.error("每天:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	local _ = timer_point:new(timer_point.EVERY_WEEK):set_wday(1):set_hour(6):set_min(5):set_sec(20):builder(function()
		log.error("每周:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	local _ = timer_point:new(timer_point.EVERY_MOUTH):set_day(1):set_hour(6):set_min(5):set_sec(20):builder(function()
		log.error("每月:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	local _ = timer_point:new(timer_point.EVERY_YEAR):set_month(1):set_day(1):set_hour(6):set_min(5):set_sec(20):builder(function()
		log.error("每年:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	local _ = timer_point:new(timer_point.EVERY_YEAR_DAY):set_yday(1):set_hour(6):set_min(5):set_sec(20):builder(function()
		log.error("每年第几天:",os.date("%Y%m%d-%H:%M:%S",time_util.time()))
	end)

	log.info("string_to_date:",time_util.string_to_date("2023:10:27 0:0:0"))
end

--------------------------------------------------------------------------------
-- 时间工具函数测试
--------------------------------------------------------------------------------
local function time_utils_test()
	local pre_time = os.time({year=2025, month=1, day=11, hour=4, min=59, sec=59})
	local cur_time = os.time({year=2025, month=1, day=12, hour=5, min=0, sec=0})
	assert(time_util.diff_day(pre_time, cur_time, 5) == 2)
	assert(time_util.diff_day(cur_time, pre_time, 5) == -2)
	assert(time_util.diff_day(pre_time, cur_time, 0) == 1)
	assert(time_util.diff_day(cur_time, pre_time, 0) == -1)
end

function CMD.start(config)
	timer_test()
	--time_point_test()
	time_utils_test()
	return true
end

function CMD.exit()
	return true
end

return CMD
