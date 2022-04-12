
local Mutex = require"lj-async.mutex"
local ffi = require"ffi"
local C = ffi.C

local common = require"lj-async.lua_cdefs"
local push = common.push

local M = {}

local keeper_cdef = [[
typedef struct keeper{
    lua_State* L;
    mutextype *mutex;
} keeper;
]]
ffi.cdef(keeper_cdef)

local Keeper_typ = ffi.typeof("keeper")
local Keeper = {}
Keeper.__index = Keeper
local mutex_anchor = {}
function Keeper:__new()
	--print"new keeper"
	local obj = ffi.new(self)
    
    local L = C.luaL_newstate()
    if L == nil then
        error("Could not allocate new state",2)
    end
    obj.L = L
	local mut = Mutex()
    obj.mutex = mut
	table.insert(mutex_anchor, mut)
    C.luaL_openlibs(L)
	
	C.lua_settop(L,0) -- eliminar pila
	C.lua_createtable(L,0,0);
    --C.lua_setglobal (L, "DATA");
	C.lua_setfield(L, C.LUA_GLOBALSINDEX, "DATA")
    return obj
end

function Keeper:send(key,val)
	--print("send",key,val,self.L)
	local L = self.L
	self.mutex:lock()
	C.lua_settop(L,0) -- eliminar pila

    if C.lua_checkstack(L, 20) == 0 then
        error("out of memory")
    end

	--C.lua_getglobal (L, "DATA");
	C.lua_getfield(L, C.LUA_GLOBALSINDEX, "DATA") --DATA
	assert(C.lua_type(L, -1)==C.LUA_TTABLE)
	local top = C.lua_gettop(L)
	---[[
	push(L, key, true) --DATA/key
	C.lua_gettable(L, top) --DATA/keyval
	local istable = C.lua_type(L, -1)==C.LUA_TTABLE
	--print("istable",istable)
	if istable then
		local leng = C.lua_objlen(L, -1)
		C.lua_pushnumber(L, leng + 1)
		push(L, val, true)
		C.lua_settable(L, -3); 
	else
		assert(C.lua_type(L, -1)==C.LUA_TNIL)
		--C.lua_pop(L, 1) -- deletee nil
		C.lua_settop(L, -(1)-1) --DATA
		assert(C.lua_type(L, -1)==C.LUA_TTABLE)
		C.lua_createtable(L,0,0); --DATA/table
		local top1 = C.lua_gettop(L)
		C.lua_pushnumber(L, 1) --DATA/table/1
		push(L, val, true) --DATA/table/1/val
		C.lua_settable(L, top1) --DATA/table
		push(L, key, true) --DATA/table/key
		C.lua_insert(L, 2) --DATA/key/table
		C.lua_settable(L, -3); --DATA
	end
	
	self.mutex:unlock()

end
local function pop_value(L, index)
	--print("pop_value",index)
	index = index or -1
	if C.lua_type(L, index)==C.LUA_TNIL then
		return nil
	elseif C.lua_type(L, index)==C.LUA_TBOOLEAN then
		return C.lua_toboolean(L, index)==1 and true or false
	elseif C.lua_type(L, index)==C.LUA_TNUMBER then
		return C.lua_tonumber(L, index)
	elseif C.lua_type(L, index)==C.LUA_TSTRING then
		return ffi.string(C.lua_tolstring(L, index,nil))
	elseif C.lua_type(L, index)==C.LUA_TTABLE then
		local tab = {}
		C.lua_pushnil(L);
		while (C.lua_next(L, index-1) ~= 0) do
			--print"next iter"
			local k = pop_value(L, -2)
			local v  = pop_value(L, -1)
			tab[k] = v
			--C.lua_pop(L,1)
			C.lua_settop(L, -(1)-1) 
		end
		return tab
	else
		error"pop_value bad value"
	end
end

local function pop_DATA(L, key)

	--print("pop_DATA",key,C.lua_gettop(L))
	push(L, key, true)--DATA/key
	--C.lua_pushlstring(L,key,#key)
	--print("pop_DATA2",key,C.lua_gettop(L))
---[[
	C.lua_gettable(L, -2) --DATA/keyval
	if not(C.lua_type(L, -1)==C.LUA_TTABLE) then C.lua_settop(L, -(1)-1);return nil end
	local n = C.lua_objlen(L,-1)

	C.lua_rawgeti(L, -1, 1)--DATA/table/table[1]

	local val = pop_value(L,-1)
	--print("val",val)
	C.lua_settop(L, -(1)-1)--DATA/table
	--remove from table
	for i=1,n-1 do
		C.lua_rawgeti(L,-1,i+1)--DATA/table/table[i+1]
		C.lua_rawseti(L,-2,i)--DATA/table
	end
	C.lua_pushnil(L) --DATA/table/nil
	C.lua_rawseti(L,-2,n) --DATA/table
	C.lua_settop(L, -(1)-1)
--]]
-- C.lua_settop(L, -(1)-1)
-- print("pop_DATA3",key,C.lua_gettop(L))
	return val

end
function Keeper:receive(...)
    local n = select("#", ...)
    local L = self.L
	local val
	self.mutex:lock()

    if C.lua_checkstack(L, n) == 0 then
        error("out of memory")
    end
    
	
	C.lua_getfield(L, C.LUA_GLOBALSINDEX, "DATA") --DATA
    for i=1,n do
        local v = select(i, ...)
        val = pop_DATA(L, v)
		if val~=nil then 
			C.lua_settop(L, -(1)-1)
			self.mutex:unlock();
			return v,val 
		end
    end
	C.lua_settop(L, -(1)-1)

	self.mutex:unlock()
    return val
end


function Keeper:read()
	print"read"
	local L = self.L
	local code = [[print("readsss",DATA,#DATA)]]
	local code =[[
	for k,v in pairs(DATA) do
		print("key",k,v)
		for i,val in ipairs(v) do
			print(i,val)
		end
	 end
	]]

	assert(C.luaL_loadstring(L, code)==0)

	--C.lua_call(L,0,0)
	local ret = C.lua_pcall(L, 0, C.LUA_MULTRET, 0)
	assert(ret==0)

end

local M = {}

M.MakeKeeper = ffi.metatype(Keeper_typ, Keeper)
function M.KeeperCast(v)
	return ffi.cast("keeper*",v)
end

--[[
require"anima.utils"
local K = M.MakeKeeper()


K:send("uno",11)
K:send("uno",false)
K:send("dos",33)
K:send("uno","stringgg")
local t = {1,pedro={hola=false},3}
K:send("uno",t)
K:send("uno",t)

--K:read()
print(K.mutex)
print"receive--------------------"
for i=1,7 do
print("--------receive",i,K.mutex.mutex)
local key,val = K:receive("uno","dos")
prtable(key,val)
end
--]]
--[[
local K = M.MakeKeeper()
for i=1,20000 do 
--print(i)
	K:receive("clace") 
	--K.mutex:lock()
	--K.mutex:unlock()
end
--]]
return M