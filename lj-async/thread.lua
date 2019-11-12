
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

if ffi.os == "Windows" then
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

			return true
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
	function Thread:join(timeout)
		if self.thread == nil then error("invalid thread",3) end
		return pthread.join(self.thread)
	end
	function Thread:free()
		--if self.thread ~= nil then
		--end
	end
end

return Thread
