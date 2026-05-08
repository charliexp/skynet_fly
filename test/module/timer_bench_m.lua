local skynet = require "skynet"
local log = require "skynet-fly.log"
local timer = require "skynet-fly.timer"

local CMD = {}

--------------------------------------------------------------------------------
-- 辅助：简单计时（skynet.hpc 返回纳秒）
--------------------------------------------------------------------------------
local function hpc_ms()
	return skynet.hpc() / 1e6
end

local function fmt(n)
	-- 格式化大数字，加千位逗号
	local s = tostring(math.floor(n))
	local result = ""
	local len = #s
	for i = 1, len do
		if i > 1 and (len - i + 1) % 3 == 0 then
			result = result .. ","
		end
		result = result .. s:sub(i, i)
	end
	return result
end

local SEPARATOR = string.rep("-", 60)

local function bench_header(name)
	log.info(SEPARATOR)
	log.info("[BENCH] " .. name)
	log.info(SEPARATOR)
end

--------------------------------------------------------------------------------
-- Bench 1：批量创建定时器（不等触发，纯堆插入性能）
-- 测量：N 个定时器 new() 调用的总耗时 & 吞吐量
--------------------------------------------------------------------------------
local function bench_create_cancel(N)
	N = N or 10000
	bench_header(string.format("bench_create_cancel  N=%s", fmt(N)))

	-- 先创建，再批量取消（避免触发回调干扰计时）
	-- expire 设较大值（300s），避免测试期间到期
	local timers = {}
	local t0 = hpc_ms()
	for i = 1, N do
		timers[i] = timer:new(30000, 1, function() end)
	end
	local t1 = hpc_ms()

	local create_ms = t1 - t0
	log.info(string.format("[BENCH] create %s timers : %.3f ms  (%.0f ops/s)",
		fmt(N), create_ms, N / (create_ms / 1000)))

	-- 批量取消
	local t2 = hpc_ms()
	for i = 1, N do
		timers[i]:cancel()
	end
	local t3 = hpc_ms()

	local cancel_ms = t3 - t2
	log.info(string.format("[BENCH] cancel %s timers : %.3f ms  (%.0f ops/s)",
		fmt(N), cancel_ms, N / (cancel_ms / 1000)))

	log.info(string.format("[BENCH] total create+cancel : %.3f ms", create_ms + cancel_ms))
end

--------------------------------------------------------------------------------
-- Bench 2：批量到期（测量 dispatch 循环处理 N 个同时到期定时器的速度）
-- 所有定时器 expire=1（约 10ms），同一批次到期，测量从第一个回调触发到全部触发的时间
--------------------------------------------------------------------------------
local function bench_batch_expire(N)
	N = N or 1000
	bench_header(string.format("bench_batch_expire  N=%s", fmt(N)))

	local done = 0
	local t_first, t_last

	-- 用 expire=1 让它们尽快全部到期
	for i = 1, N do
		timer:new(1, 1, function()
			local now = hpc_ms()
			if not t_first then t_first = now end
			t_last = now
			done = done + 1
		end)
	end

	-- 等待全部触发（最多 5s）
	local deadline = skynet.now() + 500  -- 5s
	while done < N and skynet.now() < deadline do
		skynet.sleep(1)
	end

	if done < N then
		log.error(string.format("[BENCH] bench_batch_expire: only %d/%d triggered (timeout)", done, N))
		return
	end

	local spread_ms = (t_last - t_first)
	log.info(string.format("[BENCH] %s timers expired: first→last spread=%.3f ms", fmt(N), spread_ms))
	-- spread 越小说明 dispatch 处理越快
end

--------------------------------------------------------------------------------
-- Bench 3：高频循环定时器（expire=1）持续触发 T 秒，统计实际触发次数与期望触发次数
-- 验证高频情况下调度精度与 overhead
--------------------------------------------------------------------------------
local function bench_high_freq_loop(T_sec, expire_tick)
	T_sec       = T_sec or 3
	expire_tick = expire_tick or 1   -- 1 tick ≈ 10ms

	bench_header(string.format("bench_high_freq_loop  expire=%dtick  duration=%ds", expire_tick, T_sec))

	local count = 0
	local t_start = hpc_ms()
	local t = timer:new(expire_tick, timer.loop, function()
		count = count + 1
	end)

	skynet.sleep(T_sec * 100)   -- 等待 T 秒
	t:cancel()

	local elapsed_ms = hpc_ms() - t_start
	local expected = math.floor(elapsed_ms / (expire_tick * 10))  -- expire_tick * 10ms

	log.info(string.format("[BENCH] elapsed=%.1f ms  triggered=%s  expected≈%s",
		elapsed_ms, fmt(count), fmt(expected)))
	log.info(string.format("[BENCH] actual_interval=%.2f ms/trigger  (target=%d ms)",
		elapsed_ms / count, expire_tick * 10))

	local ratio = count / expected
	if ratio >= 0.90 and ratio <= 1.10 then
		log.info(string.format("[BENCH] [OK] trigger ratio=%.2f (within ±10%%)", ratio))
	else
		log.error(string.format("[BENCH] [WARN] trigger ratio=%.2f (outside ±10%%)", ratio))
	end
end

--------------------------------------------------------------------------------
-- Bench 4：混合场景 — 同时存在大量活跃定时器时的调度开销
-- 创建 BASE 个长周期背景定时器（不取消），再叠加 BURST 个短周期定时器
-- 测量叠加后短周期定时器的调度误差
--------------------------------------------------------------------------------
local function bench_mixed_load(BASE, BURST)
	BASE  = BASE  or 5000
	BURST = BURST or 100

	bench_header(string.format("bench_mixed_load  background=%s  burst=%s", fmt(BASE), fmt(BURST)))

	-- 创建大量背景定时器（expire=6000，即60s，不会触发）
	local bg_timers = {}
	for i = 1, BASE do
		bg_timers[i] = timer:new(6000, timer.loop, function() end)
	end

	log.info(string.format("[BENCH] %s background timers created, now scheduling %s burst timers...", fmt(BASE), fmt(BURST)))

	-- 在背景定时器存在的情况下，测量 BURST 个 expire=10 (100ms) 定时器的触发误差
	local results = {}
	local done = 0
	for i = 1, BURST do
		local t0 = skynet.now()
		timer:new(10, 1, function()
			local elapsed = skynet.now() - t0
			results[#results + 1] = elapsed
			done = done + 1
		end)
	end

	-- 等待全部触发
	local deadline = skynet.now() + 500
	while done < BURST and skynet.now() < deadline do
		skynet.sleep(1)
	end

	-- 统计误差
	local sum, max_err, min_err = 0, 0, math.huge
	for _, v in ipairs(results) do
		local err = math.abs(v - 10)
		sum = sum + err
		if err > max_err then max_err = err end
		if err < min_err then min_err = err end
	end
	local avg_err = done > 0 and (sum / done) or 0

	log.info(string.format("[BENCH] burst timers triggered: %d/%d", done, BURST))
	log.info(string.format("[BENCH] timing error (ticks): avg=%.2f  min=%d  max=%d  (target=10 ticks)",
		avg_err, min_err, max_err))

	-- 清理背景定时器
	for i = 1, BASE do
		bg_timers[i]:cancel()
	end
	log.info(string.format("[BENCH] %s background timers cancelled", fmt(BASE)))
end

--------------------------------------------------------------------------------
-- Bench 5：extend 操作性能（在运行中频繁延长定时器）
--------------------------------------------------------------------------------
local function bench_extend(N)
	N = N or 5000
	bench_header(string.format("bench_extend  N=%s", fmt(N)))

	-- 创建 N 个定时器
	local timers = {}
	for i = 1, N do
		timers[i] = timer:new(6000, 1, function() end)
	end

	-- 对每个定时器调用 extend(1)
	local t0 = hpc_ms()
	for i = 1, N do
		timers[i]:extend(1)
	end
	local t1 = hpc_ms()

	local extend_ms = t1 - t0
	log.info(string.format("[BENCH] extend %s timers : %.3f ms  (%.0f ops/s)",
		fmt(N), extend_ms, N / (extend_ms / 1000)))

	-- 清理
	for i = 1, N do
		timers[i]:cancel()
	end
end

--------------------------------------------------------------------------------
-- Bench 6：多规模梯度测试（create+cancel）
--------------------------------------------------------------------------------
local function bench_scale()
	bench_header("bench_scale  (create+cancel ladder)")
	local sizes = {100, 500, 1000, 5000, 10000, 50000}
	for _, N in ipairs(sizes) do
		local timers = {}
		local t0 = hpc_ms()
		for i = 1, N do
			timers[i] = timer:new(30000, 1, function() end)
		end
		local create_ms = hpc_ms() - t0

		local t1 = hpc_ms()
		for i = 1, N do
			timers[i]:cancel()
		end
		local cancel_ms = hpc_ms() - t1

		log.info(string.format("[BENCH] N=%-6s  create=%.2f ms (%.0f/s)  cancel=%.2f ms (%.0f/s)",
			fmt(N),
			create_ms, N / (create_ms / 1000),
			cancel_ms, N / (cancel_ms / 1000)))
	end
end

--------------------------------------------------------------------------------
-- Bench 7：级联性能 — 大量 tv2/tv3 定时器的 dispatch 速度
-- 创建 N 个 expire 在 256~1024 范围的定时器（落入 tv2），然后等待全部触发
-- 测量从第一个触发到全部触发的 spread
--------------------------------------------------------------------------------
local function bench_cascade_dispatch(N)
	N = N or 1000
	bench_header(string.format("bench_cascade_dispatch  N=%s (tv2 range)", fmt(N)))

	local done = 0
	local t_first, t_last

	-- expire=300（落入 tv2：idx > 255），全部同一到期时间
	for i = 1, N do
		timer:new(300, 1, function()
			local now = hpc_ms()
			if not t_first then t_first = now end
			t_last = now
			done = done + 1
		end)
	end

	-- 等待全部触发（最多 10s）
	local deadline = skynet.now() + 1000
	while done < N and skynet.now() < deadline do
		skynet.sleep(1)
	end

	if done < N then
		log.error(string.format("[BENCH] bench_cascade_dispatch: only %d/%d triggered (timeout)", done, N))
		return
	end

	local spread_ms = (t_last - t_first)
	log.info(string.format("[BENCH] %s tv2 timers expired: first→last spread=%.3f ms", fmt(N), spread_ms))
end

--------------------------------------------------------------------------------
-- Bench 8：多循环定时器并发精度
-- 创建 N 个不同 expire 的循环定时器，跑 T 秒，统计实际触发次数与期望次数的偏差
--------------------------------------------------------------------------------
local function bench_concurrent_loops(N, T_sec)
	N     = N or 50
	T_sec = T_sec or 3

	bench_header(string.format("bench_concurrent_loops  N=%s  duration=%ds", fmt(N), T_sec))

	local timers = {}
	local counts = {}
	local expires = {}

	for i = 1, N do
		counts[i] = 0
		expires[i] = 10 + i * 2  -- expire = 12, 14, 16, ..., 10+2N
		local idx = i
		timers[i] = timer:new(expires[i], timer.loop, function()
			counts[idx] = counts[idx] + 1
		end)
	end

	skynet.sleep(T_sec * 100)

	-- 取消所有
	for i = 1, N do
		timers[i]:cancel()
	end

	-- 统计误差
	local total_err = 0
	local max_err = 0
	local min_err = math.huge
	for i = 1, N do
		local expected = math.floor(T_sec * 100 / expires[i])
		local err = math.abs(counts[i] - expected)
		total_err = total_err + err
		if err > max_err then max_err = err end
		if err < min_err then min_err = err end
	end
	local avg_err = total_err / N

	log.info(string.format("[BENCH] %s concurrent loop timers for %ds", fmt(N), T_sec))
	log.info(string.format("[BENCH] count error: avg=%.2f  min=%d  max=%d", avg_err, min_err, max_err))

	if avg_err <= 2 then
		log.info("[BENCH] [OK] average error ≤ 2 triggers")
	else
		log.error(string.format("[BENCH] [WARN] average error=%.2f (> 2)", avg_err))
	end
end

--------------------------------------------------------------------------------
-- Bench 9：不同 expire 范围的创建性能（tv1/tv2/tv3/tv4 分层）
-- 分别测试 expire 落入 tv1(1~255)、tv2(256~16383)、tv3(16384~)、tv4 范围的创建速度
--------------------------------------------------------------------------------
local function bench_create_by_tier()
	bench_header("bench_create_by_tier  (tv1/tv2/tv3/tv4)")

	local tiers = {
		{name = "tv1", expire = 100,     N = 10000},
		{name = "tv2", expire = 500,     N = 10000},
		{name = "tv3", expire = 20000,   N = 10000},
		{name = "tv4", expire = 2000000, N = 10000},
	}

	for _, tier in ipairs(tiers) do
		local timers = {}
		local t0 = hpc_ms()
		for i = 1, tier.N do
			timers[i] = timer:new(tier.expire, 1, function() end)
		end
		local create_ms = hpc_ms() - t0

		-- 清理
		for i = 1, tier.N do
			timers[i]:cancel()
		end

		log.info(string.format("[BENCH] %s (expire=%s): create %s in %.2f ms (%.0f ops/s)",
			tier.name, fmt(tier.expire), fmt(tier.N),
			create_ms, tier.N / (create_ms / 1000)))
	end
end

--------------------------------------------------------------------------------
-- Bench 10：GC 压力测试 — 创建/取消大量定时器后内存回收
--------------------------------------------------------------------------------
local function bench_gc_pressure()
	bench_header("bench_gc_pressure  (create+cancel+GC)")

	local rounds = 5
	local N = 10000

	-- 预热 GC
	collectgarbage("collect")
	local mem_before = collectgarbage("count")

	for r = 1, rounds do
		local timers = {}
		for i = 1, N do
			timers[i] = timer:new(30000, 1, function() end)
		end
		for i = 1, N do
			timers[i]:cancel()
		end
		timers = nil
	end

	collectgarbage("collect")
	collectgarbage("collect")
	local mem_after = collectgarbage("count")
	local leaked_kb = mem_after - mem_before

	log.info(string.format("[BENCH] %d rounds × %s create+cancel", rounds, fmt(N)))
	log.info(string.format("[BENCH] memory: before=%.1f KB  after=%.1f KB  diff=%.1f KB",
		mem_before, mem_after, leaked_kb))

	if leaked_kb < 100 then
		log.info("[BENCH] [OK] memory leak < 100 KB")
	else
		log.error(string.format("[BENCH] [WARN] potential memory leak: %.1f KB", leaked_kb))
	end
end

--------------------------------------------------------------------------------
-- Bench 11：频繁 extend 性能（同一定时器反复 extend）
--------------------------------------------------------------------------------
local function bench_rapid_extend()
	bench_header("bench_rapid_extend  (single timer, 10000 extends)")

	local N = 10000
	local t = timer:new(60000, 1, function() end)

	local t0 = hpc_ms()
	for i = 1, N do
		t:extend(1)
	end
	local t1 = hpc_ms()
	local extend_ms = t1 - t0

	log.info(string.format("[BENCH] %s extends on 1 timer: %.3f ms (%.0f ops/s)",
		fmt(N), extend_ms, N / (extend_ms / 1000)))

	t:cancel()
end

--------------------------------------------------------------------------------
-- 汇总入口
--------------------------------------------------------------------------------
function CMD.start(config)
	log.info("╔══════════════════════════════════════════════════════════╗")
	log.info("║            timer performance benchmark start             ║")
	log.info("╚══════════════════════════════════════════════════════════╝")

	-- 1. 基础 create/cancel 吞吐
	bench_create_cancel(10000)
	skynet.sleep(10)

	-- 2. 批量到期分发速度
	bench_batch_expire(1000)
	skynet.sleep(10)

	-- 3. 高频循环触发（1 tick ≈ 10ms，持续 3s）
	bench_high_freq_loop(3, 1)
	skynet.sleep(10)

	-- 4. 混合负载（5000 背景 + 100 突发）
	bench_mixed_load(5000, 100)
	skynet.sleep(10)

	-- 5. extend 操作性能
	bench_extend(5000)
	skynet.sleep(10)

	-- 6. 规模梯度
	bench_scale()
	skynet.sleep(10)

	-- 7. 级联 dispatch 性能（tv2 范围）
	bench_cascade_dispatch(1000)
	skynet.sleep(10)

	-- 8. 多循环定时器并发精度
	bench_concurrent_loops(50, 3)
	skynet.sleep(10)

	-- 9. 不同层级创建性能
	bench_create_by_tier()
	skynet.sleep(10)

	-- 10. GC 压力测试
	bench_gc_pressure()
	skynet.sleep(10)

	-- 11. 频繁 extend 性能
	bench_rapid_extend()
	skynet.sleep(10)

	log.info("╔══════════════════════════════════════════════════════════╗")
	log.info("║             timer performance benchmark done             ║")
	log.info("╚══════════════════════════════════════════════════════════╝")
	return true
end

function CMD.exit()
    return true
end

return CMD
