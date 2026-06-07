--!strict
--[[
Signal Types (KRF)

Goals:
- Provide reusable type shapes for a yield-safe Signal implementation (e.g. GoodSignal)
- Support a read-only "Event surface" (Connect/Once/Wait) separate from the full Signal (Fire)
- Keep types independent of any concrete implementation details

Notes:
- `T...` is a generic type pack for fired arguments.
- `Event<T...>` is the public surface you expose to consumers.
- `Signal<T...>` is the private/full object that includes Fire + teardown.
]]

local SignalTypes = {}

export type Handler<T...> = (T...) -> ()

export type Connection = {
	-- Public `self` is intentionally loose to avoid recursive hover expansion.
	Disconnect: (any) -> (),
}

export type Event<T...> = {
	Connect: (any, fn: Handler<T...>) -> Connection,
	Once: (any, fn: Handler<T...>) -> Connection,
	Wait: (any) -> T...,
}

export type Signal<T...> = Event<T...> & {
	Fire: (any, T...) -> (),
	DisconnectAll: (any) -> (),
	Destroy: (any) -> (),
}

export type OwnedSignals = {
	Destroy: (any) -> (),
	WithDeferredDestroy: (any, callback: () -> ()) -> (),
}

export type New = <T...>() -> Signal<T...>
export type WrapEvent = <T...>(signal: Signal<T...>) -> Event<T...>

return SignalTypes
