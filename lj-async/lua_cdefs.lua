local ffi = require"ffi"
local C = ffi.C

ffi.cdef[[
    static const int LUA_GLOBALSINDEX   = -10002;
    static const int LUA_MULTRET = -1;
	
	static const int LUA_TNIL = 0;
	static const int LUA_TBOOLEAN = 1;
	static const int LUA_TLIGHTUSERDATA = 2;
	static const int LUA_TNUMBER = 3;
	static const int LUA_TSTRING = 4;
	static const int LUA_TTABLE = 5;
	static const int LUA_TFUNCTION = 6;
	static const int LUA_TUSERDATA = 7;
	static const int LUA_TTHREAD = 8;
	
    typedef struct lua_State lua_State;
    typedef ptrdiff_t lua_Integer;
    
    lua_State* luaL_newstate(void);
    void luaL_openlibs(lua_State *L);
    void lua_close (lua_State *L);
    void lua_call(lua_State *L, int nargs, int nresults);
    int lua_pcall (lua_State *L, int nargs, int nresults, int errfunc);
    void lua_checkstack (lua_State *L, int sz);
    void lua_settop (lua_State *L, int index);
	int lua_gettop (lua_State *L);
    void  lua_pushlstring (lua_State *L, const char *s, size_t l);
    void lua_gettable (lua_State *L, int idx);
    void lua_getfield (lua_State *L, int idx, const char *k);
    lua_Integer lua_tointeger (lua_State *L, int index);
    int lua_isnumber(lua_State*,int);
    const char *lua_tostring (lua_State *L, int index);
    const char *lua_tolstring (lua_State *L, int index, size_t *len);
    void lua_pushnumber (lua_State *L, double n);
    void lua_pushnil (lua_State *L);
    void lua_pushboolean (lua_State *L, int b);
    void lua_pushlightuserdata (lua_State *L, void *p);
	void lua_createtable (lua_State *L, int narr, int nrec);
	void lua_settable (lua_State *L, int index);
	const char *lua_setupvalue (lua_State *L, int funcindex, int n);
	//void lua_setglobal (lua_State *L, const char *name);
	//void lua_getglobal (lua_State *L, const char *name);
	int lua_type (lua_State *L, int index);
	void lua_setfield (lua_State *L, int index, const char *k);
	size_t lua_objlen (lua_State *L, int index);
	//void lua_pop (lua_State *L, int n);
	void lua_insert (lua_State *L, int index);
	int luaL_loadstring (lua_State *L, const char *s);
	int lua_pcall (lua_State *L, int nargs, int nresults, int errfunc);
	int lua_next (lua_State *L, int index);
	double lua_tonumber (lua_State *L, int index);
	void lua_rawgeti (lua_State *L, int index, int n);
	void lua_rawseti (lua_State *L, int index, int n);
	//const char *lua_tostring (lua_State *L, int index);
	const char *lua_tolstring (lua_State *L, int index, size_t *len);
	int lua_toboolean (lua_State *L, int index);
]]

local M = {}

local lookup_t = {} --for detectin cicles
local xpcall_hook = function(err) return debug.traceback(tostring(err) or "<nonstring error>") end
local function push(L, v, setupvals)
	
	--local xpcall, dtraceback, tostring, error = _G.xpcall, _G.debug.traceback, _G.tostring, _G.error
	--local  dtraceback = debug.traceback
    --local xpcall_hook = function(err) return debug.traceback(tostring(err) or "<nonstring error>") end
	--print("push", type(v), v)
    if type(v) == 'nil' then
		C.lua_pushnil(L)
	elseif type(v) == 'boolean' then
		C.lua_pushboolean(L,v)
	elseif type(v) == 'number' then
		C.lua_pushnumber(L, v)
	elseif type(v) == 'string' then
		C.lua_pushlstring(L,v,#v)
	elseif type(v) == 'function' then

		local stfunc = string.dump(v)
        C.lua_getfield(L, C.LUA_GLOBALSINDEX, "loadstring")
        C.lua_pushlstring(L, stfunc, #stfunc)
        C.lua_call(L,1,1)
		if setupvals then
		local i = 1
		while true do

			local uname, uv = debug.getupvalue(v, i)
			if not uname then break end
			print("push upvalue",v,i,uname,uv)
			if v==uv then
				error"recurrence in push function upvalues"
			end
			--push(L, uv, setupvals)
			--local ok = true
			--local ok,err = pcall(push, L, uv, setupvals)
			local ok,err = xpcall(push, xpcall_hook, L, uv, setupvals)
						
			if not ok then
				--error("false error")
				local info = debug.getinfo(v)
				
				print("error pushing upvalue", uname, "of function:", info.name,"defined in",info.source,info.linedefined);
				
				print(err)
				
				error("pushing upvalue",2) 
			else
				C.lua_setupvalue(L, -2, i)
				i = i + 1
			end
		end
		end
	elseif type(v) == 'table' then
		if lookup_t[v] then error"push: cicles in table" end
		lookup_t[v] = true
		--NOTE: doesn't check duplicate refs
		--NOTE: doesn't check for cycles
		--NOTE: stack-bound on table depth
		assert(C.lua_checkstack(L, 3) ~= 0, 'stack overflow')
		C.lua_createtable(L, 0, 0)
		local top = C.lua_gettop(L)
		for k,v in pairs(v) do
			push(L, k, setupvals)
			push(L, v, setupvals)
			C.lua_settable(L, top)
		end
		assert(C.lua_gettop(L) == top)
		lookup_t[v] = nil
	elseif type(v) == 'userdata' then
		--NOTE: there's no Lua API to get the size or lightness of a userdata,
		--so we don't have enough info to duplicate a userdata automatically.
		error('Not implemented push userdata', 2)
	elseif type(v) == 'thread' then
		--NOTE: there's no Lua API to get the 'lua_State*' of a coroutine.
		error('Not implemented push thread', 2)
	elseif type(v) == 'cdata' then
		--NOTE: there's no Lua C API to push a cdata.
		--cdata are not shareable anyway because ctypes are not shareable.
		--error('Not implemented push cdata '..tostring(v), 2)
		--we push it as a pointer
		C.lua_pushlightuserdata(L,v)
	end
end

M.push = push

return M