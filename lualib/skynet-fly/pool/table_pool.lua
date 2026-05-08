local M = {}
local mt = {__index = M}

local assert = assert
local tinsert = table.insert
local tremove = table.remove
local type = type

local setmetatable = setmetatable

---创建一个 table 对象池
---@param cap number 池容量上限
---@param create_func function|nil 创建新 table 的工厂函数（可选，默认 {}），可用 table.create 预分配
---@param init_func function|nil 从池中取出时的初始化函数 init_func(t)（可选）
---@param release_func function|nil 归还到池中时的清理函数 release_func(t)（可选）
---@return table 对象池实例
function M:new(cap, create_func, init_func, release_func)
	local t = {
		cap = cap,
		len = cap,
		list = table.create(cap, 0),  -- 预分配数组部分，避免动态扩容
		create_func = create_func,
		init_func = init_func,
		release_func = release_func,
	}
	for i = 1,cap do
		if create_func then
			tinsert(t.list, create_func())
		else
			tinsert(t.list, {})
		end
	end
	setmetatable(t,mt)
	return t
end

---从池中获取一个 table（池空时创建新的）
---取出后若设置了 init_func 则自动调用
---@return table
function M:get()
	local t
	if self.len > 0 then
		t = tremove(self.list, self.len)
		self.len = self.len - 1
	else
		if self.create_func then
			t = self.create_func()
		else
			t = {}
		end
	end
	if self.init_func then
		self.init_func(t)
	end
	return t
end

---将 table 归还到池中（池满时丢弃）
---归还前若设置了 release_func 则自动调用
---@param t table 要归还的 table
---@return boolean|nil 成功归还返回 true，池满返回 nil
function M:release(t)
	assert(type(t) == 'table')
	if self.len >= self.cap then
		return
	end

	if self.release_func then
		self.release_func(t)
	end

	self.len = self.len + 1
	tinsert(self.list, t)
	return true
end

return M
