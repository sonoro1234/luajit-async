
--- Thread type for LuaJIT
-- Supports both windows threads and pthreads.
--
-- Each exposed function is defined twice; one for windows threads, one for pthreads.
-- The exposed functions will only be documented in the windows section; the pthreads
-- API is the same.

local ffi = require "ffi"
local CallbackFactory = require "lj-async.callback"
local C = ffi.C

local ptrs = require"lj-async.ptr"
local addr = ptrs.addr
local ptr  = ptrs.ptr

local Thread = {}
Thread.__index = Thread
local callback_t
------------coop_cancel wrap
local function coop_cancel_wrap(self, func)
			self.coop_cancel = true
			self.done = ffi.new"bool[1]"
			local oldfunc = func
			func = function(done ,...)
				local ffi = require"ffi"
				local ptrs = require"lj-async.ptr"
				done = ptrs.ptr("bool*", done)
				------------------------------------
				--print(self,self.coop_cancel,coop_cancel)
				-- require"anima.utils"
				-- prtable(self)
				---------------------------------------
				--print"setting testcancel_hook"
				local function hook(ev, line)

						if done[0] then 
						
							print("returning",ev,line);
							local info = debug.getinfo(2,"Sl")
							print(string.format("deb %s %d",info.source, info.currentline))
							debug.sethook()
							error"cancelled" 
						end
						--io.write"."
						--io.write(ev.."."..tostring(line).." ")
					end

				debug.sethook(hook, "", 100)
				
				--------------------------------------
				local inner_f = oldfunc(...)
				return function(ud1)
					if self.coop_cancel then 
						print"==================jitoff======================"
						jit.off(inner_f, true)
						jit.off(true, true)
						jit.off()
					end
					local ok, ret = pcall(inner_f, ud1)
					print("--------inner_f ret", ok, ret)
					if self.coop_cancel then debug.sethook() end
					done[0] = true
					if not ok then 
						error(ret) 
					end
					return ret
				end
			end
	return func
end
------------------------------------------
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
		void ExitThread(unsigned long);
		
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
		local coop_cancel
		if type(func) == "table" then
			func = func[1]
			coop_cancel = true
		end
		local self = setmetatable({}, Thread)
		--print("coop_cancel",self,self.coop_cancel,coop_cancel)
		if coop_cancel then
			func = coop_cancel_wrap(self, func)
			self.cb = callback_t(func, addr(self.done), ...)
		else
			self.cb = callback_t(func, ...)
		end
		
		self.ud = ud -- anchor
		
		local t = C.CreateThread(nil, 0, self.cb:funcptr(), ud, 0, nil)
		if t == nil then
			error_win(3)
		end
		ffi.gc(t,function() self:free() end)
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
		--print("Thread:free",self.thread)
		
		if self.thread ~= nil then
			--print("Thread:free CloseHandle", self.thread)
			ffi.gc(self.thread, nil)
			error_check(C.CloseHandle(self.thread))
			self.thread = nil
		end
		
		if self.cb ~= nil then
			--self.cb:free()
			--self.cb = nil
		end
	end
	
	function Thread._return(val)
		return val
	end
	function Thread:Exit(val)
		if self.coop_cancel then
			self.done[0] = true
			--self.cancelled = true
		else
			print"call TerminateThread"
			error_check(C.TerminateThread(self.thread, val or 0))
		end
	end
	function Thread.exit(val)
		--print("call ExitThread")
		C.ExitThread(val)
		--print"done"
	end
else
	local pthread = require"pthread"
	Thread.pthread = pthread
	callback_t = CallbackFactory("void *(*)(void *)")
	
	ffi.cdef[[
	typedef int clockid_t;
	int clock_gettime(clockid_t clk_id, timespec *tp);
	]]
	ffi.cdef[[
	int pthread_timedjoin_np(pthread_t thread, void **retval, const timespec *abstime);
	]]
	
	local has_pthread_timedjoin_np = pcall(function() return ffi.C.pthread_timedjoin_np end)
	
	
	function Thread.new(func, ud, ...)
		local coop_cancel
		if type(func) == "table" then
			func = func[1]
			coop_cancel = true
		end
		local self = setmetatable({}, Thread)
		self.coop_cancel = coop_cancel
		--print(self,self.coop_cancel,coop_cancel)
		if not has_pthread_timedjoin_np then
			self.mutex = pthread.mutex()
			self.cond = pthread.cond()
			self.done = ffi.new"bool[1]"
			local is_winpthread = WINUSEPTHREAD
			local oldfunc = func
			func = function(cond, mut ,done ,...)
				local ffi = require"ffi"
				local pthread = require"pthread"
				local ptrs = require"lj-async.ptr"
				cond = ptrs.ptr("pthread_cond_t*", cond)
				mut = ptrs.ptr("pthread_mutex_t*", mut)
				done = ptrs.ptr("bool*", done)
				WINUSEPTHREAD = is_winpthread
				
				---------------------------------------
				-- print("WINUSEPTHREAD",WINUSEPTHREAD)
				-- print(self,self.coop_cancel,coop_cancel)
				-- print("thread",self.thread)
				-- require"anima.utils"
				-- prtable(self)
				if self.coop_cancel then
					--print"setting pthread_testcancel"
					local function hook(ev, line)
						if done[0] then 
							print("returning",ev,line);
							local info = debug.getinfo(2,"Sl")
							print(string.format("deb %s %d",info.source, info.currentline))
							debug.sethook()
							error"cancelled" 
						end
						--io.write"."
						--io.write(ev.."."..tostring(line).." ")
						--pthread.C.pthread_testcancel()
					end
					--debug.sethook(hook, "l", 10)
					debug.sethook(hook, "", 100)
				end
				
				--------------------------------------
				local inner_f = oldfunc(...)
				return function(ud1)
					if self.coop_cancel then 
						print("========jitoff============");
						jit.off(inner_f, true) 
						jit.off(true, true)
						jit.off()
					end
					local ok, ret = pcall(inner_f, ud1)
					print("--------inner_f ret", ok, ret)
					if self.coop_cancel then debug.sethook() end
					local tr_ret = mut:trylock()
					print("tr_ret",tr_ret)
					if tr_ret then
						--print("trylock true",self.thread)
						done[0] = true
						cond:signal()
						mut:unlock()
						--print("unlock on thread", self.thread)
					else
						--print("could not trylock",self.thread)
						done[0] = true
					end
					if not ok then 
						error(ret) 
					end
					return ret
				end
			end
			self.cb = callback_t(func, addr(self.cond), addr(self.mutex), addr(self.done), ...)
		else --has_pthread_timedjoin_np
			if coop_cancel then
				func = coop_cancel_wrap(self, func)
				self.cb = callback_t(func, addr(self.done), ...)
			else
				self.cb = callback_t(func, ...)
			end
		end
		
		self.ud = ud --anchor
		local t = pthread.new(self.cb:funcptr(),nil,ud)
		ffi.gc(t,function() self:free() end)
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
	
	local function prepare_timeout2(timeout)
		local tsl = prepare_timeout(timeout)
		return tonumber(tsl.s + tsl.ns*1e-9)
	end
	
	local function get_unsigned_long(ud)
		if ud==nil then return nil end
		ud = ffi.cast("struct { unsigned long x; }*",ud)
		return ud.x
	end
	
	function Thread:join(timeout, ret_unsigned_long)

		if self.thread == nil then error("invalid thread",3) end
		if not timeout then
			local ret = pthread.join(self.thread)
			ret = ret_unsigned_long and get_unsigned_long(ret) or ret
			return true, ret
		elseif has_pthread_timedjoin_np then
			local tsl = prepare_timeout(timeout)
			local status = ffi.new'void*[1]'
			local ret_np = ffi.C.pthread_timedjoin_np(self.thread, status,tsl)
			if ret_np == 0 then
				local ret = status[0]
				ret = ret_unsigned_long and get_unsigned_long(ret) or ret
				return true, ret
			elseif ret_np == pthread.H.ETIMEDOUT then
				return false
			else
				error("error on pthread_mutex_timedlock:"..tostring(ret_np))
			end
		else
			local tsl = prepare_timeout2(timeout)
			--print("join lock on thread", self.thread)
			self.mutex:lock()
			if not self.done[0] then
				--print"cond wait"
				local ret_w = self.cond:wait(self.mutex, tsl) -- tsl.s + tsl.ns*1e-9)
				--print(string.format("\ncond wait return %s",tostring(ret_w)))
				self.mutex:unlock()
				--print("join unlock on thread", self.thread)
				if not ret_w then 
					return false -- timeout
				else
					--print("pthread.join(self.thread)2222", self.thread, ret)
					local ret = pthread.join(self.thread)
					-- local status = ffi.new'void*[1]'
					-- local ret_pt = pthread.C.pthread_join(self.thread, status)
					-- print(string.format(" %d", ret_pt))
					-- local ret = status[0]
					ret = ret_unsigned_long and get_unsigned_long(ret) or ret
					return true, ret
				end
			else
				self.mutex:unlock()
				--print("join unlock2 on thread", self.thread)
				local ret = pthread.join(self.thread)
				--print("pthread.join(self.thread)", self.thread, ret)
				ret = ret_unsigned_long and get_unsigned_long(ret) or ret
				return true, ret
			end
		end
	end
	function Thread:free()
		--print("Thread:free",self.thread)
		if self.thread ~= nil then
		ffi.gc(self.thread, nil)
		end
	end
	ffi.cdef[[int pthread_cancel(pthread_t thread);]]
	ffi.cdef[[void pthread_testcancel(void);]]
	ffi.cdef[[
       int pthread_setcancelstate(int state, int *oldstate);
       int pthread_setcanceltype(int type, int *oldtype);
       //void pthread_cleanup_push(void (void *) *routine, void *arg);
	   void pthread_cleanup_push(void (*routine)(void *),void *arg);
       void pthread_cleanup_pop(int execute);   ]]
	function Thread:Exit(val)
		-- local cstate = ffi.new("int[1]")
		-- assert(pthread.C.pthread_setcancelstate( pthread.C.PTHREAD_CANCEL_ENABLE, cstate)==0)
		-- print("pthread_setcancelstate",pthread.C.PTHREAD_CANCEL_ENABLE, cstate[0])
		
		-- local ctype = ffi.new("int[1]")
		-- assert(pthread.C.pthread_setcanceltype( pthread.C.PTHREAD_CANCEL_DEFERRED, ctype)==0)
		-- print("pthread_setcanceltype",pthread.C.PTHREAD_CANCEL_DEFERRED, ctype[0])
		self.done[0] = true
		local ret
		--print("Exit going to lock on thread", self.thread)
		if self.mutex then
			if self.mutex:trylock() then
				self.done[0] = true
				self.cond:signal()
				--self.cancelled = true
				self.mutex:unlock()
				--print"leaving lock in Exit"
			else
				--print"could not trylock in Exit"
				self.done[0] = true
			end
		end
		--print"done set to true on Exit"
		if not self.coop_cancel then print"CANCELLATION WONT WORK." end
			--print("self.thread cancelling", self.thread)
			--ret = pthread.C.pthread_cancel(self.thread)
		return ret
	end
	function Thread.exit(val)
		pthread.C.pthread_exit(nil)
	end
	
	function Thread._return(val)
		print("Thread._return", val)
		local ud = ffi.new("struct { unsigned long x; }",val)
		return ud
	end
	
end


return Thread
