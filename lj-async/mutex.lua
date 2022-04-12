-- Mutex objects

local ffi = require "ffi"
local C = ffi.C

local abstraction = {}
if ffi.os == "Windows" and not WINUSEPTHREAD then
	--abstractions = require "jitthreads._win"
	--abstractions = require "jitthreads._pthreads"
	ffi.cdef[[
	static const int STILL_ACTIVE = 259;
	static const int FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000;
	static const int FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200;
	static const int WAIT_ABANDONED = 0x00000080;
	static const int WAIT_OBJECT_0 = 0x00000000;
	static const int WAIT_TIMEOUT = 0x00000102;
	static const int WAIT_FAILED = 0xFFFFFFFF;
	static const int INFINITE = 0xFFFFFFFF;
	
	int CloseHandle(void*);
	int GetExitCodeThread(void*,uint32_t*);
	uint32_t WaitForSingleObject(void*, uint32_t);
	
	
	void* CreateMutexA(void*, int, const char*);
	int ReleaseMutex(void*);
	
	uint32_t GetLastError();
	uint32_t FormatMessageA(
		uint32_t dwFlags,
		const void* lpSource,
		uint32_t dwMessageId,
		uint32_t dwLanguageId,
		char* lpBuffer,
		uint32_t nSize,
		va_list *Arguments
	);
]]
	abstraction.mutex_t = ffi.typeof("void*")
	-- Some helper functions
	local function error_win(lvl)
		local errcode = C.GetLastError()
		local str = ffi.new("char[?]",1024)
		local numout = C.FormatMessageA(bit.bor(C.FORMAT_MESSAGE_FROM_SYSTEM,
			C.FORMAT_MESSAGE_IGNORE_INSERTS), nil, errcode, 0, str, 1023, nil)
		if numout == 0 then
			error("Windows Error: (Error calling FormatMessage)", lvl)
		else
			error("Windows Error("..tostring(tonumber(errcode)).."): "..ffi.string(str, numout), lvl)
		end
	end
	
	local function error_check(result)
		if result == 0 then
			error_win(4)
		end
	end
	
	function abstraction.mutex_create()
		return C.CreateMutexA(nil, false, nil)
	end
	
	function abstraction.mutex_destroy(mutex)
		if mutex ~= nil then
			error_check(C.CloseHandle(mutex))
			mutex = nil
		end
	end
	
	function abstraction.mutex_get(mutex, timeout)
		if timeout then
			timeout = timeout*1000
		else
			timeout = C.INFINITE
		end
		
		local r = C.WaitForSingleObject(mutex, timeout)
		if r == C.WAIT_OBJECT_0 or r == C.WAIT_ABANDONED then
			return true
		elseif r == C.WAIT_TIMEOUT then
			return false
		else
			error_win(3)
		end
	end
	
	function abstraction.mutex_release(mutex)
		error_check(C.ReleaseMutex(mutex))
	end
	
else

	local pthreads = require"pthread"
	abstraction.mutex_t = ffi.typeof("pthread_mutex_t")
	local mut_anchor = {}
	function abstraction.mutex_create()
		local mut =  pthreads.mutex()
		table.insert(mut_anchor, mut)
		return mut
	end

	function abstraction.mutex_destroy(mutex)
		for i,v in ipairs(mut_anchor) do
			if mutex == v then
				table.remove(mut_anchor,i)
				break
			end
		end
		mutex:free()
	end
	
	ffi.cdef[[
	typedef int clockid_t;
	int clock_gettime(clockid_t clk_id, timespec *tp);
	int pthread_mutex_timedlock(pthread_mutex_t *m,const timespec *abs_timeout); 
	]]
	local tsl
	local ETIMEDOUT = (ffi.os=="Linux" and 110) or (ffi.os=="Windows" and 138) or 60
	function pthread_mutex_timedlock(mutex,timeout)
		tsl = tsl or ffi.new'timespec'
		pthreads.C.clock_gettime(0,tsl) -- CLOCK_REALTIME
		local int, frac = math.modf(timeout)
		tsl.s = tsl.s + int
		tsl.ns = tsl.ns + frac * 1e9
		while (tsl.ns >= 1e9) do
			tsl.ns = tsl.ns - 1e9;
			tsl.s = tsl.s + 1
		end
		local ret = pthreads.C.pthread_mutex_timedlock(mutex,tsl)
		if ret == 0 then
			return true
		elseif ret == ETIMEDOUT then
			return false
		else
			error("error on pthread_mutex_timedlock:"..ret)
		end
	end
	function abstraction.mutex_get(mutex, timeout)
		if timeout then 
			return pthread_mutex_timedlock(mutex,timeout) --mutex:timedlock(timeout)
		else
			mutex:lock()
			return true
		end
	end

	function abstraction.mutex_release(mutex)
		mutex:unlock()
	end
end

-- -----------------------------------------------------------------------------

ffi.cdef([[typedef struct {$ mutex;} mutextype;]],abstraction.mutex_t)

local Mutex = {}
Mutex.__index = Mutex
--- Creates a mutex
function Mutex:__new()
    return ffi.new(self, abstraction.mutex_create())
end

--- Trys to lock the mutex. If the mutex is already locked, it blocks
-- for timeout seconds.
-- @param timeout Time to wait for the mutex to become unlocked. nil = wait forever,
-- 0 = do not block
function Mutex:lock(timeout)
	if self.mutex == nil then error("Invalid mutex",2) end
	return abstraction.mutex_get(self.mutex, timeout)
end

--- Unlocks the mutex. If the current thread is not the owner, throws an error
function Mutex:unlock()
	if self.mutex == nil then error("Invalid mutex",2) end
	abstraction.mutex_release(self.mutex)
end

--- Destroys the mutex.
function Mutex:destroy()
	if self.mutex then
		abstraction.mutex_destroy(self.mutex)
		--self.mutex = nil
	end
end
Mutex.__gc = Mutex.destroy

local mmutex = ffi.metatype("mutextype", Mutex)

--[[
local mm = mmutex()
for i=1,1000000 do
	mm:lock()
	mm:unlock()
end
print"done"
--]]

return mmutex
