--WINUSEPTHREAD=true
local Thread = require "lj-async.thread"
local ffi = require "ffi"

local thread_func = function(...)
	--WINUSEPTHREAD=true
	return function(ud)
		local ffi = require "ffi"
		ud = ffi.cast("struct { int x; }*", ud)
		if ffi.os=="Windows" and not WINUSEPTHREAD then
			return ud.x
		else
			return ud
		end
	end
end

local thread_data_t = ffi.typeof("struct { int x; }")

local datas = {}
local threads = {}
local expected = 0
for i=1,10000 do
	datas[i] = thread_data_t(i)
	threads[i] = Thread(thread_func, datas[i])
	expected = expected + i
end
print("expected",expected)
local gotten = 0
for i,thread in ipairs(threads) do
	local ok, res = thread:join()
	assert(ok)
	if ffi.os~="Windows" or WINUSEPTHREAD then 
		res = ffi.cast("struct { int x; }*", res).x 
	end
	assert(i==res,"i="..i.." res="..res)
	gotten = gotten + res
end
print("gotten",gotten)