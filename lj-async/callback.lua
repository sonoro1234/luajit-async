
--- Framework for creating Lua callbacks that can be asynchronously called.

local ffi = require "ffi"
local C = ffi.C

-- Setup function ran by the Lua state to create
local callback_setup_func = string.dump(function(cbtype, cbsource, ...)
	--print("in callback_setup_func",cbtype, cbsource,...)
    local ffi = _G.require("ffi")
    local initfunc = cbsource 
	--local initfunc = _G.loadstring(cbsource)
    local ret_fail2 = cbtype:match("%s*(.-)%s*%(.-%*.-%)")
    ret_fail2 = (ret_fail2 ~= "void") and ffi.new(ret_fail2) or nil
    local xpcall, dtraceback, tostring, error = _G.xpcall, _G.debug.traceback, _G.tostring, _G.error
    
    local xpcall_hook = function(err) return dtraceback(tostring(err) or "<nonstring error>") end

    --local cbfunc = initfunc(...)
	local ok, cbfunc = xpcall(initfunc, xpcall_hook, ...)
	if not ok then print("initfunc error", cbfunc);error("initfunc") end
    local waserror = false
    local cb = ffi.cast(cbtype, function(...)
        if not waserror then
        local ok, val = xpcall(cbfunc, xpcall_hook, ...)
        if not ok then
            print("error in callback",val)
            waserror = true
            return ret_fail2
        else
            return val or ret_fail2
        end
        else
            return ret_fail2
        end
    end)
    local ptr = tonumber(ffi.cast('uintptr_t', ffi.cast('void *', cb)))
    return cb, ptr
end)

local common = require"lj-async.lua_cdefs"
local push = common.push

-- Maps callback object ctypes to the callback pointer types
local ctype2cbstr = {}

local Callback = {}
Callback.__index = Callback


-- Copies values into a lua state
local function moveValues(L, ...)
    local n = select("#", ...)
    
    if C.lua_checkstack(L, n) == 0 then
        error("out of memory")
    end

    for i=1,n do
        local v = select(i, ...)
        push(L, v, true)
    end
    return n
end

local function MakeCallback(L, cb2type, cb2, ... )
    if type(cb2) == "function" then
	--[[
        local name,val = debug.getupvalue(cb2,1)
        if name then
            print("init callback function has upvalue ",name)
            error("upvalues in init callback")
        end
        cb2 = string.dump(cb2)
		--]]
    end
    C.lua_settop(L,0)
    
    if C.lua_checkstack(L, 20) == 0 then
        error("out of memory")
    end
    -- Load the callback setup function
    C.lua_getfield(L, C.LUA_GLOBALSINDEX, "loadstring")
    C.lua_pushlstring(L, callback_setup_func, #callback_setup_func)
    C.lua_call(L,1,1)
    -- Load the actual callback
    C.lua_pushlstring(L, cb2type, #cb2type)
    --C.lua_pushlstring(L, cb2, #cb2)
	push(L,cb2,true)
    local n = moveValues(L, ...)
    local ret = C.lua_pcall(L,2+n,2,0)
    if ret > 0 then
        print(ffi.string(C.lua_tolstring(L,1,nil)))
        error("error making callback",2)
        return nil
    end
     -- Get and pop the callback function pointer
    assert(C.lua_isnumber(L,2) ~= 0)
    local ptr = C.lua_tointeger(L,2)
    assert(ptr ~= 0)
    C.lua_settop(L, 1)
    local callback = ffi.cast(cb2type, ptr)
    assert(callback ~= nil)
    
    return callback
end

--- Creates a new callback object.
-- callback_func is either a function compatible with string.dump (i.e. a Lua function without upvalues)
-- or LuaJIT source/bytecode representing such a function (ex. The output of string.dump(func). This is recommended if you
-- plan on making many callbacks).
--
-- The function is (re)created in a separate Lua state; thus, no Lua values may be shared.
-- The only way to share information between the main Lua state and the callback is by a
-- userdata pointer in the callback function, which you will need to synchronize
-- yourself.
--
-- The returned object must be kept alive for as long as the callback may still be called.
-- 
-- Errors in callbacks are not caught; thus, they will cause its Lua state's panic function
-- to run and terminate the process.
function Callback:__new(callback_func,...)

    local obj = ffi.new(self)
    local cbtype = assert(ctype2cbstr[tonumber(self)])
    
    local L = C.luaL_newstate()
    if L == nil then
        error("Could not allocate new state",2)
    end
    obj.L = L
    
    C.luaL_openlibs(L)

	obj.callback = MakeCallback(L, cbtype, callback_func, ...)
    return obj
end

---for getting another callback from the same Lua state
function Callback:additional_cb(cb2,cb2type,...)
    return MakeCallback(self.L, cb2type, cb2, ...)
end
--- Gets and returns the callback function pointer.
function Callback:funcptr()
    return self.callback
end

--- Frees the callback object and associated callback.
function Callback:free()
    if self.L ~= nil then
        -- TODO: Do we need to free the callback, or will lua_close free it for us?
        C.lua_close(self.L)
        self.L = nil
    end
end
Callback.__gc = Callback.free

--- Returns a newly created callback ctype.
-- cb_type is a string representation of the callback pointer type (ex. what you would pass to ffi.typeof).
-- This must be a string; actual ctype objects cannot be used.
return function(cb_type)
    assert(type(cb_type) == "string", "Bad argument #1 to async type creator; string expected")
    
    local typ = ffi.typeof([[struct {
        lua_State* L;
        $ callback;
    }]], ffi.typeof(cb_type))
    
    ctype2cbstr[tonumber(typ)] = cb_type
    
    return ffi.metatype(typ, Callback)
end
