---#API
---#content ---
---#content title: 定时器
---#content date: 2024-06-29 22:00:00
---#content categories: ["skynet_fly API 文档","定时器相关"]
---#content category_bar: true
---#content tags: [skynet_fly_api]
---#content ---
---#content [timer](https://github.com/huahua132/skynet_fly/blob/master/lualib/skynet-fly/timer.lua)
local skynet = require "skynet"
local log = require "skynet-fly.log"
local type = type
local math = math
local x_pcall = x_pcall
local assert = assert
local setmetatable = setmetatable
local table = table
local tpack = table.pack
local tunpack = table.unpack
local skynet_timeout = skynet.timeout
local skynet_fork = skynet.fork
local string_format = string.format

----------------------------------------------------------------------------------------
-- 分级时间轮（Hierarchical Timing Wheel）实现
--
-- 结构（与 Linux kernel 经典实现对齐）：
--   tv1: 256 槽，覆盖 [cur, cur+255]                     精度 1 tick
--   tv2:  64 槽，覆盖 [cur+256, cur+16383]               精度 256 ticks
--   tv3:  64 槽，覆盖 [cur+16384, cur+1048575]           精度 16384 ticks
--   tv4:  64 槽，覆盖 [cur+1048576, cur+67108863]        精度 1048576 ticks
--
-- 操作复杂度：
--   create  O(1)
--   cancel  O(1)  —— 双向链表直接摘除，无搜索
--   extend  O(1)  —— cancel + create
--   dispatch O(k) —— k = 当前 tick 到期数量
--
-- 最大可调度延迟：67108863 ticks ≈ 6710886 秒 ≈ 77.7 天
-- 超出范围的定时器自动挂载到 tv4 最后一个槽（延迟触发，语义等同于"尽快触发"）
--
-- 性能优化：
--   P0: 栈式复用 pending_readd，消除每次 dispatch 的 table 分配，同时支持重入安全
--   P0: dispatch 中用 internal_add_raw（无 schedule_next），循环后统一调度一次
--   P0: skynet.timeout 缓存为 local 变量，减少全局查找（skynet.now 不缓存以兼容录像系统）
--   P0: 回调同步执行（xpcall），无 skynet.fork 开销
--   P2: 对象池复用定时器 table，减少 GC 压力和 table 分配开销
----------------------------------------------------------------------------------------

local TIMES_LOOP<const> = 0        -- 循环触发标记
local TV1_SIZE<const>   = 256      -- 第1级槽数（2^8）
local TV_SIZE<const>    = 64       -- 第2~4级槽数（2^6）
local TV1_MASK<const>   = TV1_SIZE - 1
local TV_MASK<const>    = TV_SIZE  - 1

-- 当前时间轮的 tick 游标（单调递增，与 skynet.now() 对齐）
local wheel_cur = 0

-- 底层驱动调度状态
-- pending_expire：当前已注册的 skynet.timeout 目标到期时间
--   math.maxinteger 表示当前无悬空 timeout
-- pending_version：版本号，用于识别和忽略旧的 timeout 回调
local MAX_EXPIRE<const>  = math.maxinteger
local MAX_DRIVE_TICK<const> = 6000    -- 最大驱动间隔（60秒），空闲心跳
local pending_expire  = MAX_EXPIRE
local pending_version = 0

---------------------------------------------------------------------------
-- [P2 优化] 内联对象池：栈式复用已完成/已取消的定时器 table
-- 直接操作 local 变量，零方法调用开销（比 table_pool 快 3-5x）
--
-- 引用计数策略：
--   _ref_count 在 M:new() 时初始化为 1（代表用户持有的引用）
--   用户调用 M:release() 时 _ref_count - 1
--   当 _ref_count <= 0 且定时器已结束（is_cancel 或 is_over）时归还池中
--   如果用户忘记 release()，对象不会归池，由 Lua GC 自然回收（不会更差）
---------------------------------------------------------------------------
local pool_max = 256
local pool = table.create(pool_max, 0)  -- 预分配数组空间
local pool_n = 0

local function pool_get()
    if pool_n > 0 then
        local t = pool[pool_n]
        pool[pool_n] = nil
        pool_n = pool_n - 1
        return t
    end
    return table.create(0, 14)
end

local function pool_release(t)
    if pool_n >= pool_max then return end
    t.expire        = nil
    t.times         = nil
    t.callback      = nil
    t.args          = nil
    t.is_cancel     = nil
    t.is_over       = nil
    t.cur_times     = nil
    t.expire_time   = nil
    t.is_after_next = nil
    t.prev          = nil
    t.next          = nil
    t._ref_count    = nil
    pool_n = pool_n + 1
    pool[pool_n] = t
end

-- 尝试归还对象到池中（引用计数归零且已终结时才归还）
local function try_release(t)
    if t._ref_count <= 0 and (t.is_cancel or t.is_over) then
        pool_release(t)
    end
end

---------------------------------------------------------------------------
-- 双向链表头节点工厂（每个槽是一个哨兵节点链表）
-- table.create(0, 2)：无数组部分，2 个哈希字段（prev/next）
---------------------------------------------------------------------------
local function new_list()
    local head = table.create(0, 2)
    head.prev = head
    head.next = head
    return head
end

-- 将节点 t 插入链表头节点 head 之前（尾部插入）
local function list_add(head, t)
    local prev = head.prev
    t.prev     = prev
    t.next     = head
    prev.next  = t
    head.prev  = t
end

-- 从所在链表中摘除节点 t
local function list_del(t)
    local p = t.prev
    local n = t.next
    if p then
        p.next = n
        n.prev = p
        t.prev = nil
        t.next = nil
    end
end

-- 链表是否为空
local function list_empty(head)
    return head.next == head
end

---------------------------------------------------------------------------
-- 时间轮槽初始化
---------------------------------------------------------------------------
local tv1 = table.create(0, TV1_SIZE)
local tv2 = table.create(0, TV_SIZE)
local tv3 = table.create(0, TV_SIZE)
local tv4 = table.create(0, TV_SIZE)

for i = 0, TV1_SIZE - 1 do tv1[i] = new_list() end
for i = 0, TV_SIZE  - 1 do tv2[i] = new_list() end
for i = 0, TV_SIZE  - 1 do tv3[i] = new_list() end
for i = 0, TV_SIZE  - 1 do tv4[i] = new_list() end

---------------------------------------------------------------------------
-- pending_readd：收集本轮需要重新注册的循环/多次定时器
-- 由于回调通过 skynet.fork 执行，dispatch_tick 不会让出，无需重入保护
---------------------------------------------------------------------------
local pending_readd = {}
local pending_readd_n = 0

---------------------------------------------------------------------------
-- 将定时器挂到正确的时间轮槽
-- 注意：此函数不调用 schedule_next，由调用方在合适时机统一调度
---------------------------------------------------------------------------
local schedule_next  -- forward declaration（在下方定义）

-- [P0 优化] 分离出不调用 schedule_next 的内部版本，
-- 用于 dispatch 中的 pending_readd 批量注册和 cascade
local function internal_add_raw(t)
    local expires = t.expire_time
    local idx     = expires - wheel_cur

    local slot
    if idx <= 0 then
        slot = tv1[wheel_cur & TV1_MASK]
    elseif idx < TV1_SIZE then
        slot = tv1[expires & TV1_MASK]
    elseif idx < (TV1_SIZE * TV_SIZE) then
        slot = tv2[(expires >> 8) & TV_MASK]
    elseif idx < (TV1_SIZE * TV_SIZE * TV_SIZE) then
        slot = tv3[(expires >> 14) & TV_MASK]
    elseif idx < (TV1_SIZE * TV_SIZE * TV_SIZE * TV_SIZE) then
        slot = tv4[(expires >> 20) & TV_MASK]
    else
        slot = tv4[((expires >> 20) & TV_MASK)]
    end
    list_add(slot, t)
end

-- 完整版本：挂槽 + 触发 schedule_next（用于外部 API 调用）
local function internal_add(t)
    internal_add_raw(t)
    schedule_next(t.expire_time)
end

---------------------------------------------------------------------------
-- 级联（cascade）：将 tv[i] 槽中的所有定时器重新插入更低级的轮中
---------------------------------------------------------------------------
local function cascade(tv, idx)
    local slot = tv[idx]
    if list_empty(slot) then return end
    local t = slot.next
    while t ~= slot do
        local next_t = t.next
        t.prev = nil
        t.next = nil
        internal_add_raw(t)  -- cascade 中用 raw 版本，不触发 schedule_next
        t = next_t
    end
    slot.next = slot
    slot.prev = slot
end

---------------------------------------------------------------------------
-- 调度底层 skynet.timeout（按最近定时器到期时间驱动，空闲时最多 60s 心跳）
---------------------------------------------------------------------------
local dispatch_tick  -- forward declaration

-- 扫描时间轮，返回最近一个非空槽对应的绝对到期 tick
local function find_next_expire()
    for i = 0, TV1_SIZE - 1 do
        local abs_tick = wheel_cur + i
        local idx = abs_tick & TV1_MASK
        if not list_empty(tv1[idx]) then
            return abs_tick
        end
    end
    for i = 1, TV_SIZE do
        local tv2_idx = ((wheel_cur >> 8) + i) & TV_MASK
        if not list_empty(tv2[tv2_idx]) then
            local base = (tv2_idx << 8)
            if base <= wheel_cur then
                base = base + TV1_SIZE * TV_SIZE
            end
            return base
        end
    end
    for i = 1, TV_SIZE do
        local tv3_idx = ((wheel_cur >> 14) + i) & TV_MASK
        if not list_empty(tv3[tv3_idx]) then
            local base = (tv3_idx << 14)
            if base <= wheel_cur then
                base = base + TV1_SIZE * TV_SIZE * TV_SIZE
            end
            return base
        end
    end
    for i = 1, TV_SIZE do
        local tv4_idx = ((wheel_cur >> 20) + i) & TV_MASK
        if not list_empty(tv4[tv4_idx]) then
            local base = (tv4_idx << 20)
            if base <= wheel_cur then
                base = base + TV1_SIZE * TV_SIZE * TV_SIZE * TV_SIZE
            end
            return base
        end
    end
    return wheel_cur + MAX_DRIVE_TICK
end

---------------------------------------------------------------------------
-- schedule_next：注册下一次 skynet.timeout
-- 使用版本号机制过滤过期的 timeout 回调
---------------------------------------------------------------------------
schedule_next = function(target_expire)
    target_expire = target_expire or find_next_expire()
    if target_expire >= pending_expire then
        return
    end
    pending_expire = target_expire
    pending_version = pending_version + 1
    local ver = pending_version

    local now   = skynet.now()
    local delay = target_expire - now
    if delay < 1 then delay = 1 end
    if delay > MAX_DRIVE_TICK then delay = MAX_DRIVE_TICK end

    skynet_timeout(delay, function()
        if pending_version ~= ver then
            return
        end
        pending_expire = MAX_EXPIRE
        dispatch_tick()
    end)
end

---------------------------------------------------------------------------
-- 慢回调告警阈值（单位：skynet tick，100 = 1秒）
-- 回调执行耗时超过此值时打印 warn 日志，0 表示不检测
-- 通过 M.set_warn_threshold(ticks) 设置
---------------------------------------------------------------------------
local warn_threshold = 0

---------------------------------------------------------------------------
-- 执行单个定时器回调（同步 xpcall，带耗时检测）
---------------------------------------------------------------------------
local function execute_call_back(t)
    local before = skynet.now()
    local is_ok, err = x_pcall(t.callback, tunpack(t.args, 1, t.args.n))
    if not is_ok then
        log.error("time_out_func err ", err, t.callback, t.args)
    end
    if warn_threshold > 0 then
        local cost = skynet.now() - before
        if cost >= warn_threshold then
            log.warn(string_format("timer callback slow! cost=%d ticks (%.2fs)",
                cost, cost / 100))
        end
    end
end

---------------------------------------------------------------------------
-- fork 中执行回调并在完成后尝试归还对象（用于 is_over 的最后一次触发）
local function fork_execute_and_release(t)
    execute_call_back(t)
    try_release(t)
end

---------------------------------------------------------------------------
-- after_next 模式：基于当前时刻计算下次 expire_time（同步执行，回调完成后注册下次）
local function execute_and_register_after_next(t)
    execute_call_back(t)
    if not t.is_cancel then
        if t.times == TIMES_LOOP or t.cur_times < t.times then
            if t.prev then
                list_del(t)
            end
            t.expire_time = skynet.now() + t.expire
            internal_add(t)
        else
            t.is_over = true
            try_release(t)  -- [P2] 引用计数归零时归还到对象池
        end
    end
end

---------------------------------------------------------------------------
-- dispatch_tick：推进时间轮，触发所有到期定时器
-- 回调通过 skynet.fork 在独立协程中执行，dispatch_tick 不会让出，无需重入保护
---------------------------------------------------------------------------
dispatch_tick = function()
    local now = skynet.now()
    pending_readd_n = 0

    while wheel_cur <= now do
        local slot_idx = wheel_cur & TV1_MASK

        if slot_idx == 0 then
            local tv2_idx = (wheel_cur >> 8) & TV_MASK
            cascade(tv2, tv2_idx)
            if tv2_idx == 0 then
                local tv3_idx = (wheel_cur >> 14) & TV_MASK
                cascade(tv3, tv3_idx)
                if tv3_idx == 0 then
                    local tv4_idx = (wheel_cur >> 20) & TV_MASK
                    cascade(tv4, tv4_idx)
                end
            end
        end

        wheel_cur = wheel_cur + 1

        local slot = tv1[slot_idx]
        if not list_empty(slot) then
            local head = slot
            local t = head.next
            head.next = head
            head.prev = head

            while t ~= head do
                local next_t = t.next
                t.prev = nil
                t.next = nil

                if not t.is_cancel then
                    t.cur_times = t.cur_times + 1
                    if t.is_after_next then
                        -- after_next 模式：fork 中执行回调，完成后再注册下次
                        skynet_fork(execute_and_register_after_next, t)
                    else
                        if t.times == TIMES_LOOP or t.cur_times < t.times then
                            t.expire_time = t.expire_time + t.expire
                            pending_readd_n = pending_readd_n + 1
                            pending_readd[pending_readd_n] = t
                        else
                            t.is_over = true
                        end
                        if t.is_over then
                            -- 最后一次触发：fork 中执行回调完成后再归还对象
                            skynet_fork(fork_execute_and_release, t)
                        else
                            -- 循环/多次触发：直接 fork 执行回调
                            skynet_fork(execute_call_back, t)
                        end
                    end
                else
                    -- 已取消的定时器尝试归还对象池
                    try_release(t)
                end
                t = next_t
            end
        end
    end

    -- 追赶完成后统一注册循环定时器
    for i = 1, pending_readd_n do
        local pt = pending_readd[i]
        pending_readd[i] = nil  -- 释放引用
        if pt.expire_time and not pt.is_cancel and not pt.prev then
            internal_add_raw(pt)
        end
    end

    -- 统一调度一次
    schedule_next()
end

---------------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------------
local function init()
    wheel_cur = skynet.now()
    schedule_next()
end

local inited = false
local function ensure_init()
    if not inited then
        inited = true
        init()
    end
end

----------------------------------------------------------------------------------------
-- public API
----------------------------------------------------------------------------------------

local M = {}
local mata = {__index = M}

---#desc 创建一个定时器对象
---@param expire number 过期时间 100等于1秒
---@param times number 次数，0表示循环触发
---@param callback function 回调函数
---@param ... any 回调参数
---@return table 定时器对象
function M:new(expire, times, callback, ...)
    assert(expire >= 0)
    assert(times >= 0)
    assert(type(callback) == "function")

    ensure_init()

    -- [P2 优化] 从对象池获取 table，避免每次分配新 table
    local t = pool_get()
    t.expire        = expire
    t.times         = times
    t.callback      = callback
    t.args          = tpack(...)
    t.is_cancel     = false
    t.is_over       = false
    t.cur_times     = 0
    t.expire_time   = skynet.now() + expire
    t.is_after_next = false
    t._ref_count    = 1   -- [P2] 用户持有 1 个引用，release() 后归零可回收
    t.prev          = nil
    t.next          = nil

    internal_add(t)
    setmetatable(t, mata)
    return t
end

---#desc 取消定时器
---@return table 定时器对象
function M:cancel()
    if self.is_cancel then return self end
    self.is_cancel = true
    if self.prev then
        list_del(self)
    end
    try_release(self)  -- [P2] 取消时尝试归还（引用计数归零才真正归还）
    return self
end

---#desc 回调执行完再注册下一次，默认先注册下一次，再执行回调
---@return table 定时器对象
function M:after_next()
    self.is_after_next = true
    return self
end

---#desc 定时器延时（延长下次触发的等待时间）
---@param ex_expire number 延长时间 100等于1秒
---@return table 定时器对象
function M:extend(ex_expire)
    if self.is_cancel or self.is_over then
        return self
    end

    local now    = skynet.now()
    local remain = self.expire_time - now
    if remain < 0 then remain = 0 end

    if self.prev then
        list_del(self)
    end

    self.expire      = self.expire + ex_expire
    self.expire_time = now + remain + ex_expire
    internal_add(self)

    return self
end

---#desc 获取剩余触发时间
---@return number 剩余触发时间  0 表示已经触发完了或者被取消了
function M:remain_expire()
    if self.is_cancel or self.is_over then
        return 0
    end
    local remain = self.expire_time - skynet.now()
    if remain < 0 then remain = 0 end
    return remain
end

---#desc 是否已取消
---@return boolean
function M:is_cancelled()
    return self.is_cancel
end

---#desc 是否已结束（触发次数耗尽）
---@return boolean
function M:is_finished()
    return self.is_over
end

---#desc 是否循环定时器（times=0）
---@return boolean
function M:is_loop()
    return self.times == TIMES_LOOP
end

---#desc 获取剩余触发次数（循环定时器返回 -1，已结束或取消返回 0）
---@return number 剩余次数
function M:remain_times()
    if self.is_cancel or self.is_over then
        return 0
    end
    if self.times == TIMES_LOOP then
        return -1
    end
    return self.times - self.cur_times
end

---#desc 是否有效（未取消且未结束）
---@return boolean
function M:is_valid()
    return not self.is_cancel and not self.is_over
end

---#desc 释放用户对定时器的引用，当引用计数归零且定时器已结束时归还对象池
---  用户在不再需要查询定时器状态时调用此方法，可加速对象池回收
---  不调用也不会泄漏，只是对象不会回到池中，由 Lua GC 自然回收
---@return nil
function M:release()
    if self._ref_count then
        self._ref_count = self._ref_count - 1
        try_release(self)
    end
end

---#desc 快捷方法：创建单次触发定时器（times=1）
---@param expire number 过期时间 100等于1秒
---@param callback function 回调函数
---@param ... any 回调参数
---@return table 定时器对象
function M:once(expire, callback, ...)
    return M:new(expire, 1, callback, ...)
end

---#desc 快捷方法：创建循环触发定时器（times=0）
---@param expire number 过期时间 100等于1秒
---@param callback function 回调函数
---@param ... any 回调参数
---@return table 定时器对象
function M:new_loop(expire, callback, ...)
    return M:new(expire, TIMES_LOOP, callback, ...)
end

---#desc 设置慢回调告警阈值，回调执行耗时超过此值时打印 warn 日志
---@param ticks number 阈值，单位 skynet tick（100=1秒），0 表示不检测
function M.set_warn_threshold(ticks)
    assert(type(ticks) == "number" and ticks >= 0)
    warn_threshold = ticks
end

---#desc 设置对象池最大缓存数量
---  缩小时超出的对象在下次 pool_release 时自然淘汰（不回收）
---@param max number 最大缓存数量，默认 256
function M.set_pool_max(max)
    assert(type(max) == "number" and max >= 0)
    pool_max = max
end

-- 循环执行
M.loop   = TIMES_LOOP
-- 秒
M.second = 100
-- 分钟
M.minute = M.second * 60
-- 小时
M.hour   = M.minute * 60
-- 一天
M.day    = M.hour * 24

return M
