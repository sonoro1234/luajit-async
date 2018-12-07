
LuaJIT-Async
============

*This is currently a work-in-progress.*

lj-async is a library for creating LuaJIT callbacks capable of being called asynchronously. It does this by creating the callback in a different Lua state.

Callback Usage
--------------

The core component of lj-async is the `callback` class, exposed as `lj-async.callback`. It handles all the work of creating a Lua state for the callback and setting things up.

To use it, first `require` it by doing `local CallbackFactory = require "lj-async.callback"`. This will return a type factory function, which will create ctypes from your function pointer types.

To create a callback ctype, call the function with the string ctype: `local MyCallback_t = CallbackFactory("void(*)(int)")`. Note: You MUST pass a string here; ctypes cannot be transferred between states.

Now that you've created the ctype, you can now create a callback.

```lua
function initcallback(...)
	-- can init things here
	print("init args are", ...)
	return function(n) 
		print(n) 
	end 
end
local MyCallback = MyCallback_t(initcallback,"some string",33)
local MyCallback_funcptr = MyCallback:funcptr() -- Get the actual callback
MyCallback_funcptr(123) -- Prints 123
MyCallback:free() -- Destroy the callback and the Lua state.
```

The passed function must be compatible with `string.dump` (ie. it can't have upvalues). Thus, this will not work:

```lua

local ffi = require "ffi"

...

local MyCallback = MyCallback_t(function() return function(userdata)
	userdata = ffi.cast("int[1]", userdata) -- BAD! ffi is an upvalue and not preserved by string.dump!
	...
end end)
```

You will have to re-require needed libraries in the function.

```lua

local ffi = require "ffi"

...

local MyCallback = MyCallback_t(function()
	local ffi = require "ffi" -- Import FFI in the new state
	return function(userdata)
	
	userdata = ffi.cast("int[1]", userdata) -- This will now work
	...
end)
```

Some other notes:
* You can pass in LuaJIT source/bytecode instead of a function. If you will be creating many callbacks from the same function, you can use `string.dump` on the function and pass the results to the callback constructor.
* The callback object must be kept alive as long as the callback may be called.

Threads
-------

lj-async also provides threads, built on top of the callback objects. The module is `lj-async.thread`.

The API is:

* `Thread.new(func, ud, ...)` or `Thread(func, ud, ...)`: Creates and starts a new thread. `func` is an async-callback compatible function or source/bytecode that takes a userdata pointer and returns 0. `ud` is the userdata to pass to the function and ... can be any init args.
* `thread:join([timeout])`: Joins with a thread. `timeout` is the time, in seconds, to block. `0` means don't block, while `nil` means block forever. Returns `true` if the thread terminated, or `false` if the timeout was exceeded.
* `thread:destroy()`: Destroys the thread and callback. Don't call this until after you join!

Synchronization
---------------

Not yet implemented.
