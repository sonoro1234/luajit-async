--WINUSEPTHREAD=true
local Thread = require "lj-async.thread"
local Kmaker = require"lj-async.keeper"
local ffi = require "ffi"

local thread_func = function(K)
	print("init args",K)
	local Kmaker = require"lj-async.keeper"
	K = Kmaker.KeeperCast(K)
	print(K)
	return function(ud)
		for i=1,100 do
			K:send("clave",i)
		end
	end
end

local thread_func2 = function(K)
	print("init args2",K)
	local Kmaker = require"lj-async.keeper"
	K = Kmaker.KeeperCast(K)
	print(K)
	return function(ud)
		while true do
			local key,value = K:receive("clave")
			print("received",key,value)
			if value == 10 then break end
		end
	end
end

local K = Kmaker.MakeKeeper()

local th2 = Thread(thread_func2,nil,K)
local th = Thread(thread_func,nil,K)


th:join()
th2:join()

print"done"