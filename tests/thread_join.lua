local ThreadF = function()
print"init thread"
return function(ud)
	local ffi = require "ffi"
	print("inside thread",ud)
	if ffi.os == "Windows" then
		ffi.cdef[[void Sleep(uint32_t);]]
		ffi.C.Sleep(5000)
	else
		ffi.cdef[[unsigned int sleep(unsigned int);]]
		ffi.C.sleep(5)
	end
	
end
end

--WINUSEPTHREAD = true
local Thread = require "lj-async.thread"
local Mutex = require "lj-async.mutex"
local ffi = require"ffi"
local thread_data_t = ffi.typeof("struct { int x; }")

local t = Thread(ThreadF,thread_data_t(1))
print("Thread will run for 5 seconds. Joining with 1 second timeouts.")
while true do
	local ok, err = t:join(1)
	if ok then
		print("  Joined")
		break
	elseif not err then
		print("  Timed out")
	else
		print("  Error:")
		print(err)
		break
	end
end
t:free()