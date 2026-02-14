--!strict

local Types = require(script.Parent.types)
local GoodSignal = require(script.Parent.GoodSignal)

export type Handler<T...> = Types.Handler<T...>
export type Connection = Types.Connection
export type Event<T...> = Types.Event<T...>
export type Signal<T...> = Types.Signal<T...>

type _State = {
	raw: any, -- underlying GoodSignal instance
	destroyed: boolean,
}

local _stateBySignal = setmetatable({}, { __mode = "k" }) :: { [any]: _State }
local _stateByEvent = setmetatable({}, { __mode = "k" }) :: { [any]: _State }

local function _getStateForSignal(self: any): _State
	local st = _stateBySignal[self]
	if not st then
		error("Signal: invalid instance", 2)
	end
	if st.destroyed then
		error("Signal: destroyed", 2)
	end
	return st
end

local function _getStateForEvent(self: any): _State
	local st = _stateByEvent[self]
	if not st then
		error("Event: invalid instance", 2)
	end
	if st.destroyed then
		error("Event: destroyed", 2)
	end
	return st
end

local function _makeStrictInstance(methods: {}, className: string)
	return setmetatable({}, {
		__index = function(_, key)
			local v = (methods :: any)[key]
			if v ~= nil then
				return v
			end
			error(("Attempt to get %s::%s (not a valid member)"):format(className, tostring(key)), 2)
		end,
		__newindex = function(_, key, _value)
			error(("Attempt to set %s::%s (not a valid member)"):format(className, tostring(key)), 2)
		end,
	})
end

-- Event (read-only surface)
local EventMethods = {}

function EventMethods:Connect(fn: (...any) -> ()): Connection
	local st = _getStateForEvent(self)
	return st.raw:Connect(fn)
end

function EventMethods:Once(fn: (...any) -> ()): Connection
	local st = _getStateForEvent(self)
	return st.raw:Once(fn)
end

function EventMethods:Wait(): ...any
	local st = _getStateForEvent(self)
	return st.raw:Wait()
end

-- Signal (full surface)
local SignalMethods = {}

function SignalMethods:Connect(fn: (...any) -> ()): Connection
	local st = _getStateForSignal(self)
	return st.raw:Connect(fn)
end

function SignalMethods:Once(fn: (...any) -> ()): Connection
	local st = _getStateForSignal(self)
	return st.raw:Once(fn)
end

function SignalMethods:Wait(): ...any
	local st = _getStateForSignal(self)
	return st.raw:Wait()
end

function SignalMethods:Fire(...: any)
	local st = _getStateForSignal(self)
	st.raw:Fire(...)
end

function SignalMethods:DisconnectAll()
	local st = _getStateForSignal(self)
	st.raw:DisconnectAll()
end

function SignalMethods:Destroy()
	local st = _getStateForSignal(self)
	if st.destroyed then
		return
	end
	st.destroyed = true
	-- Ensure all handlers are dropped
	st.raw:DisconnectAll()
	-- Allow raw to GC if nothing else holds it
	st.raw = nil
end

-- Module API
local SignalModule = {}

function SignalModule.new<T...>(): Signal<T...>
	local raw = GoodSignal.new()
	local st: _State = { raw = raw, destroyed = false }

	local self = _makeStrictInstance(SignalMethods, "Signal")
	_stateBySignal[self] = st

	return (self :: any) :: Signal<T...>
end

function SignalModule.wrapEvent<T...>(signal: Signal<T...>): Event<T...>
	local st = _stateBySignal[signal :: any]
	if not st then
		error("wrapEvent: expected a Signal instance created by Signal.new()", 2)
	end
	if st.destroyed then
		error("wrapEvent: signal is destroyed", 2)
	end

	local ev = _makeStrictInstance(EventMethods, "Event")
	_stateByEvent[ev] = st

	return (ev :: any) :: Event<T...>
end

return SignalModule
