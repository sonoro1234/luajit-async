local ThreadF = function(m)
	local ffi = require "ffi"
	--WINUSEPTHREAD = true
	local Mutex = require "lj-async.mutex"
	m = ffi.cast(ffi.typeof("$*",Mutex),m)
return function()
	for i=1,5 do
		assert(not m:lock(1), "Thread locked the mutex, somehow.")
		print("Timed out, i=",i)
	end
end
end
--WINUSEPTHREAD = true
local Thread = require "lj-async.thread"
local Mutex = require "lj-async.mutex"

local m = Mutex()
assert(m:lock(), "Couldn't lock a new mutex")

print("Thread will try to aquire locked mutex 5 times with 1 second timeout")
local t = Thread(ThreadF,nil, m)
t:join()
t:free()
m:unlock()
m:destroy()