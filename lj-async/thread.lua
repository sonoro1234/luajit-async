
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
		
		void* CreateMutexA(void*, int, const char*);
		int ReleaseMutex(void*);
		
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
	
	function Thread.new(func, ud, ...)
		local self = setmetatable({}, Thread)
		local cb = callback_t(func, ...)
		self.cb = cb
		local t = pthread.new(cb:funcptr(),nil,ud)
		self.thread = t
		return self
	end
	
	ffi.cdef[[
	int pthread_timedjoin_np(pthread_t thread, void **retval,
                                const struct timespec *abstime);
	]]
	
	local has_pthread_timedjoin_np = pcall(function() return ffi.C.pthread_timedjoin_np end)
	
	if not has_pthread_timedjoin_np then
		--[=[
		ffi.cdef[[
		struct args {
		bool joined;
		pthread_t td;
		pthread_mutex_t mtx;
		pthread_cond_t cond;
		void **res;
		};]]

		local function waiter(ap)
			struct args *args = ap;
			pthread_join(args->td, args->res);
			pthread_mutex_lock(&args->mtx);
			args->joined = 1;
			pthread_mutex_unlock(&args->mtx);
			pthread_cond_signal(&args->cond);
			return 0;
		end

		local function pthread_timedjoin_np(td, res, ts)
			pthread_t tmp;
			int ret;
			struct args args = { .td = td, .res = res };
		
			pthread_mutex_init(&args.mtx, 0);
			pthread_cond_init(&args.cond, 0);
			pthread_mutex_lock(&args.mtx);
		
			ret = pthread_create(&tmp, 0, waiter, &args);
			if (ret) goto done;
		
			do ret = pthread_cond_timedwait(&args.cond, &args.mtx, ts);
			while (!args.joined && ret != ETIMEDOUT);
		
			pthread_mutex_unlock(&args.mtx);
		
			pthread_cancel(tmp);
			pthread_join(tmp, 0);
		
			pthread_cond_destroy(&args.cond);
			pthread_mutex_destroy(&args.mtx);
		
			return args.joined ? 0 : ret;
		end
		--]=]
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
			tsl = prepare_timeout(timeout)
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
			error("not pthread_timedjoin_np",2)
		end
	end
	function Thread:free()
		--if self.thread ~= nil then
		--end
	end
end

return Thread
