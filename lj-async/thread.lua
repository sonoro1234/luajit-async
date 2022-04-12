
--- Thread type for LuaJIT
-- Supports both windows threads and pthreads.
--
-- Each exposed function is defined twice; one for windows threads, one for pthreads.
-- The exposed functions will only be documented in the windows section; the pthreads
-- API is the same.

local ffi = require "ffi"
local CallbackFactory = require "lj-async.callback"
local C = ffi.C

local Thread = {}
Thread.__index = Thread
local callback_t

setmetatable(Thread, {__call=function(self,...) return self.new(...) end})

if ffi.os == "Windows" and not WINUSEPTHREAD then
	ffi.cdef[[
		//static const int STILL_ACTIVE = 259;
		static const int WAIT_ABANDONED_TH = 0x00000080;
		static const int WAIT_OBJECT_0_TH = 0x00000000;
		static const int WAIT_TIMEOUT_TH = 0x00000102;
		//static const int WAIT_FAILED = 0xFFFFFFFF;
		static const int INFINITE_TH = 0xFFFFFFFF;
		
		int CloseHandle(void*);
		int GetExitCodeThread(void*,unsigned long*);
		unsigned long WaitForSingleObject(void*, unsigned long);
		
		typedef unsigned long (__stdcall *ThreadProc)(void*);
		void* CreateThread(
			void* lpThreadAttributes,
			size_t dwStackSize,
			ThreadProc lpStartAddress,
			void* lpParameter,
			unsigned long dwCreationFlags,
			unsigned long* lpThreadId
		);
		int TerminateThread(void*, unsigned long);
		
		unsigned long GetLastError();
		unsigned long FormatMessageA(
			unsigned long dwFlags,
			const void* lpSource,
			unsigned long dwMessageId,
			unsigned long dwLanguageId,
			char* lpBuffer,
			unsigned long nSize,
			va_list *Arguments
		);
	]]
	
	callback_t = CallbackFactory("unsigned long (__stdcall *)(void*)")
	
	local function error_win(lvl)
		local errcode = C.GetLastError()
		local str = ffi.new("char[?]",1024)
		local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
		local FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200
		local numout = C.FormatMessageA(bit.bor(FORMAT_MESSAGE_FROM_SYSTEM,
			FORMAT_MESSAGE_IGNORE_INSERTS), nil, errcode, 0, str, 1023, nil)
		if numout == 0 then
			error("Windows Error: (Error calling FormatMessage)", lvl)
		else
			error("Windows Error: "..ffi.string(str, numout), lvl)
		end
	end

	local function error_check(result)
		if result == 0 then
			error_win(4)
		end
	end
	
	--- Creates and startes a new thread. This can also be called as simply Thread(func,ud)
	-- func is a function or source/bytecode (see callback.lua for info and limitations)
	-- It takes a void* userdata as a parameter and should always return 0.
	-- ud is the userdata to pass into the thread.
	function Thread.new(func, ud, ...)
		local self = setmetatable({}, Thread)
		local cb = callback_t(func, ...)
		self.cb = cb
		self.ud = ud -- anchor
		
		local t = C.CreateThread(nil, 0, cb:funcptr(), ud, 0, nil)
		if t == nil then
			error_win(3)
		end
		self.thread = t
		
		return self
	end
	
	--- Waits for the thread to terminate, or after the timeout has passed.
	-- Returns true if the thread has terminated or false if the timeout was
	-- exceeded.
	function Thread:join(timeout)
		if self.thread == nil then error("invalid thread",3) end
		if timeout then
			timeout = timeout*1000
		else
			timeout = C.INFINITE_TH
		end
		
		local r = C.WaitForSingleObject(self.thread, timeout)
		if r == C.WAIT_OBJECT_0_TH or r == C.WAIT_ABANDONED_TH then
			local result = ffi.new"unsigned long[1]"
			local ret = C.GetExitCodeThread(self.thread,result)
			if ret==0 then error_win(2) end
			return true,result[0]
		elseif r == C.WAIT_TIMEOUT_TH then

			return false
		else

			error_win(2)
		end
	end
	
	--- Destroys a thread and the associated callback.
	-- Be sure to join the thread first!
	function Thread:free()
		if self.thread ~= nil then
			error_check(C.CloseHandle(self.thread))
			--self.thread = nil
		end
		
		if self.cb ~= nil then
			self.cb:free()
			--self.cb = nil
		end
	end
else
	local pthread = require"pthread"
	callback_t = CallbackFactory("void *(*)(void *)")
	
	ffi.cdef[[
	typedef int clockid_t;
	int clock_gettime(clockid_t clk_id, timespec *tp);
	]]
	ffi.cdef[[
	int pthread_timedjoin_np(pthread_t thread, void **retval,
                                const struct timespec *abstime);
	]]
	
	local has_pthread_timedjoin_np = pcall(function() return ffi.C.pthread_timedjoin_np end)
	
	local function addr(cdata)
		return tonumber(ffi.cast('intptr_t', ffi.cast('void*', cdata)))
	end

	local function ptr(ctype, p)
		return ffi.cast(ctype, ffi.cast('void*', p))
	end
	
	function Thread.new(func, ud, ...)
		local self = setmetatable({}, Thread)

		if not has_pthread_timedjoin_np then
			self.mutex = pthread.mutex()
			self.cond = pthread.cond()
			self.done = ffi.new"bool[1]"
			local oldfunc = func
			func = function(cond, mut ,done ,...)
				local ffi = require"ffi"
				local pthread = require"pthread"
				cond = ffi.cast("pthread_cond_t*", ffi.cast('void*', cond))
				mut = ffi.cast("pthread_mutex_t*", ffi.cast('void*', mut))
				done = ffi.cast("bool*", ffi.cast('void*', done))
				local inner_f = oldfunc(...)
				return function(ud1)
					local ret = inner_f(ud1)
					mut:lock()
					done[0] = true
					cond:signal()
					mut:unlock()
					return ret
				end
			end
			self.cb = callback_t(func, addr(self.cond), addr(self.mutex), addr(self.done), ...)
		else
			self.cb = callback_t(func, ...)
		end
		
		self.ud = ud --anchor
		local t = pthread.new(self.cb:funcptr(),nil,ud)
		self.thread = t
		return self
	end
	
	local function prepare_timeout(timeout)
		local tsl = ffi.new'timespec'
		pthread.C.clock_gettime(0,tsl)
		local int, frac = math.modf(timeout)
		tsl.s = tsl.s + int
		tsl.ns = tsl.ns + frac * 1e9
		while (tsl.ns >= 1e9) do
			tsl.ns = tsl.ns - 1e9;
			tsl.s = tsl.s + 1
		end
		return tsl
	end
	
	function Thread:join(timeout)
		if self.thread == nil then error("invalid thread",3) end
		if not timeout then
			return true,pthread.join(self.thread)
		elseif has_pthread_timedjoin_np then
			local tsl = prepare_timeout(timeout)
			local status = ffi.new'void*[1]'
			local ret = ffi.C.pthread_timedjoin_np(self.thread, status,tsl)
			if ret == 0 then
				return true, status[0]
			elseif ret == ETIMEDOUT then
				return false
			else
				error("error on pthread_mutex_timedlock:"..ret)
			end
		else
			local tsl = prepare_timeout(timeout)
			self.mutex:lock()
			if not self.done[0] then
				
				local ret = self.cond:wait(self.mutex, tsl.s + tsl.ns*1e-9)
				self.mutex:unlock()
				if not ret then 
					return false -- timeout
				else
					return true,pthread.join(self.thread)
				end
			else
				self.mutex:unlock()
				return true,pthread.join(self.thread)
			end
		end
	end
	function Thread:free()
		--if self.thread ~= nil then
		--end
	end
end

return Thread
