--WINUSEPTHREAD=true
local ffi = require "ffi"
local Thread = require "lj-async.thread"

local thread_func = function(f,...)
	print("init args",...)
	local args = {...}
	return function(ud)
		local ffi = require "ffi"
		ud = ffi.cast("struct { int x; }*", ud)
		print("ud.x is:",ud.x)
		f(unpack(args))
	end
end


local thread_data_t = ffi.typeof("struct { int x; }")

local function testThread(c, f, ...)
	local thread = Thread(thread_func, thread_data_t(c),f,...)
	local ok, err = thread:join()
	if ok then
		print("Thread "..c.." ran successfully")
	else
		print("Thread "..c.." terminated with error: "..tostring(err))
	end
	thread:free()
end
	
print("Basic hello world thread")
testThread(1, function()
	print("\tThread 1 says hi!")
end)

print("\nThread error test")
testThread(2, function()
	error("Thread 2 has errors.")
end)

print("\nArguments test")
testThread(3, function(...)
	print("\tGot values:",...)
end, 2,nil, "c", true)

print("\nCdata test")
local vec = ffi.new("struct {int x, y, z;}", 100,200,300)
testThread(4, function(v)
	local ffi = require "ffi"
	v = ffi.cast("struct {int x,y,z;}*", v)
	print("",v.x, v.y, v.z)
end, vec)
