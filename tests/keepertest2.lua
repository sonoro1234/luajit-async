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
		local i=1
		while true do
			K:send("clave",i)
			local key,val = K:receive("clave2")
			if key then print("received1",key,val) end
			if val == "end" then
				print("sending finish"..i)
				K:send("clave","finish")
				break
			end
			i = i + 1
		end
		return 0
	end
end

local thread_func2 = function(K)
	print("init args2",K)
	local Kmaker = require"lj-async.keeper"
	K = Kmaker.KeeperCast(K)
	print(K)
	return function(ud)
		while true do
			--print(counter)
			local key,value = K:receive("clave")
			if key then print("received2",key,value) end
			if value == 10 then 
				K:send("clave2","end")
			elseif value == "finish" then
				return 0
			end
		end
	end
end

local K = Kmaker.MakeKeeper()

local th2 = Thread(thread_func2,nil,K)
local th = Thread(thread_func,nil,K)


print(1,th:join())
print(2,th2:join())

print"done"