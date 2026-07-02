
local Mutex = require"lj-async.mutex"
local ffi = require"ffi"
local C = ffi.C

local common = require"lj-async.lua_cdefs"
local push = common.push
local init_push = common.init_push

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

function Keeper:clear(key)
	assert(type(key)~="table", "keys cant be tables.")
	assert(type(key)~="function", "keys cant be functions.")
	local L = self.L
	self.mutex:lock()
	C.lua_settop(L,0) -- eliminar pila

    if C.lua_checkstack(L, 20) == 0 then
        error("out of memory")
    end

	C.lua_getfield(L, C.LUA_GLOBALSINDEX, "DATA") --DATA
	assert(C.lua_type(L, -1) == C.LUA_TTABLE)

	push(L, key, true) --DATA/key
	C.lua_createtable(L,0,0); --DATA/key/{}
	C.lua_settable(L, -3);        --DATA
	
	self.mutex:unlock()

end

function Keeper:send(key,val)
	--print("send",key,val,self.L)
	assert(type(key)~="table", "keys cant be tables.")
	assert(type(key)~="function", "keys cant be functions.")
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
	--this key already exists
	if istable then
		local leng = C.lua_objlen(L, -1)
		C.lua_pushnumber(L, leng + 1) -- #table + 1
		--if type(val)=="table" then print("--going to push1",val) end
		init_push(L)
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
		--if type(val)=="table" then print("--going to push2",val,"top:",C.lua_gettop(L)) end
		init_push(L)
		push(L, val, true) --DATA/table/1/val
		--if type(val)=="table" then print("--after to push2",val,"top:",C.lua_gettop(L)) end
		C.lua_settable(L, top1) --DATA/table
		push(L, key, true) --DATA/table/key
		C.lua_insert(L, 2) --DATA/key/table
		C.lua_settable(L, -3); --DATA
		--if type(val)=="table" then print("-- end going to push2",val,"top:",C.lua_gettop(L)) end
	end
	
	self.mutex:unlock()

end

local seen_pop = {}
local function init_pop(L)
	seen_pop = {}
	--create or delete seen_pop_inner
	C.lua_createtable(L,0,0);
	C.lua_setfield(L, C.LUA_GLOBALSINDEX, "seen_pop_inner")
	
end
local function pop_value(L, index)
	--local print = function() end
	local positive_index = C.lua_gettop(L)+index+1
	--print("pop_value",index, positive_index)
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
		--print("getting table from",index)
		--if seen_pop_inner return saved
		C.lua_getfield(L, C.LUA_GLOBALSINDEX, "seen_pop_inner") --/seen_pop_inner
		C.lua_pushvalue(L,-2)                                   --/seen_pop_inner/table
		C.lua_gettable(L, -2)                                   --/seen_pop_inner/value
		local clave_inner
		if C.lua_type(L, -1)==C.LUA_TSTRING then -- if value is string then was seen
			clave_inner = ffi.string(C.lua_tolstring(L, -1,nil))
		else 
			assert(C.lua_type(L, -1)==C.LUA_TNIL)
		end
		if clave_inner then --was already seen_pop
			--print("return seen",clave_inner)
			--C.lua_pop(L,2) cant be used because: #define lua_pop(L,n)lua_settop(L,-(n)-1)
			C.lua_settop(L, -(2)-1)                            --/
			return seen_pop[clave_inner]
		end
		-----else create and save
		local tab = {}

		---save to seen_pop_inner
		C.lua_settop(L, -(1)-1)                                  --/seen_pop_inner
		--C.lua_getfield(L, C.LUA_GLOBALSINDEX, "seen_pop_inner") --/seen_pop_inner
		C.lua_pushvalue(L,positive_index)                                   --/seen_pop_inner/table
		local str_tab = tostring(tab):gsub("[: ]+","")
		C.lua_pushlstring(L,str_tab,#str_tab)                   --/seen_pop_inner/table/str_tab
		C.lua_settable(L, -3)                                   --/seen_pop_inner
		seen_pop[str_tab] = tab
		C.lua_settop(L, -(1)-1)                                 --/
		
		--print("poping table from",index, C.lua_gettop(L))
		C.lua_pushnil(L); --first key
		--print("before while",index, C.lua_gettop(L))
		while (C.lua_next(L, index-1) ~= 0) do
			--print("next iter-------------------------------- top:", C.lua_gettop(L))
			local k = pop_value(L, -2)
			local v  = pop_value(L, -1)
			tab[k] = v
			--C.lua_pop(L,1) cant be used because: #define lua_pop(L,n)lua_settop(L,-(n)-1)
			C.lua_settop(L, -(1)-1) 
			--print("next iter end---------------------------- top:", C.lua_gettop(L))
		end
		--print("after while",positive_index)

		return tab
	elseif C.lua_type(L, index)==C.LUA_TLIGHTUSERDATA then
		return C.lua_topointer(L, index)
	elseif C.lua_type(L, index)==C.LUA_TFUNCTION then
		error"pop_value bad value: function."
	else
		error"pop_value bad value"
	end
end

local function pop_DATA(L, key)
	assert(type(key)~="table", "keys cant be tables.")
	assert(type(key)~="function", "keys cant be functions.")
	--local print = function() end --to stop printing
	--print("pop_DATA",key,C.lua_gettop(L))
	push(L, key, true)--DATA/key
	--C.lua_pushlstring(L,key,#key)
	--print("pop_DATA2",key,C.lua_gettop(L))

	C.lua_gettable(L, -2) --DATA/keyval
	if not(C.lua_type(L, -1)==C.LUA_TTABLE) then 
		C.lua_settop(L, -(1)-1);
		--print("not table in key:",key)
		return nil 
	end
	--print("we have table in ",key)
	local n = C.lua_objlen(L,-1)
	n = tonumber(n)

	C.lua_rawgeti(L, -1, 1)--DATA/table/table[1]
	--print"going to pop_value"
	init_pop(L)
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
	--print("pop_DATA3",key,C.lua_gettop(L))
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

--for debugging, reads and posts DATA
function Keeper:read()
	--print"read"
	local L = self.L
	local code = [[print("readsss",DATA,#DATA)]]
	local code =[[
	print("Keeper:read DATA")
	for k,v in pairs(DATA) do
		print("Keeper:read DATA","key",k,v)
		for i,val in pairs(v) do
			print("Keeper:read DATA","",i,val)
		end
	 end
	 local ok,serializer = pcall(require,"imgui.libs.serializer")
	 if ok then
		print(serializer("tab",DATA))
	 end
	 print("globals")
	 for k,v in pairs(_G) do
		print("Keeper:read _G","key",k,v)
	 end
	]]

	assert(C.luaL_loadstring(L, code)==0)

	--C.lua_call(L,0,0)
	local ret, err = C.lua_pcall(L, 0, C.LUA_MULTRET, 0)
	assert(ret==0, err)

end

local M = {}

M.MakeKeeper = ffi.metatype(Keeper_typ, Keeper)
function M.KeeperCast(v)
	return ffi.cast("keeper*",v)
end


return M