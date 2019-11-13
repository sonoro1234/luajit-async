local ffi = require "ffi"

--WINUSEPTHREAD = true
local Mutex = require "lj-async.mutex"
local Thread = require "lj-async.thread"
local thread_data_t = ffi.typeof("struct { int x; }")

local function threadMain(m,...)
print("init thread")
return function(threadid)
	local ffi = require "ffi"
	--WINUSEPTHREAD = true
	local Mutex = require "lj-async.mutex"
	m = ffi.cast(ffi.typeof("$*",Mutex), m)
	threadid = ffi.cast("struct { int x; }*",threadid)
	for i=1,20 do
		m:lock()
		print("Thread ",tostring(threadid.x)," got mutex, i=",i)
		m:unlock()
	end
end
end

print("Each thread will try to aquire the mutex 20 times.")

local mutex = Mutex()
local threads = {}
for i=1,3 do
	threads[i] = Thread(threadMain, thread_data_t(i), mutex)
end

for i=#threads,1,-1 do
	local ok, err = threads[i]:join()
	if ok then
		print("Thread "..i.." ran successfully")
	else
		print("Thread "..i.." terminated with error: "..tostring(err))
	end
	threads[i]:free()
	threads[i] = nil
end

mutex:destroy()
mutex = nil