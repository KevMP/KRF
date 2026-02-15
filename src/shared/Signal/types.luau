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
	Disconnect: (self: Connection) -> (),
}

export type Event<T...> = {
	Connect: (self: Event<T...>, fn: Handler<T...>) -> Connection,
	Once: (self: Event<T...>, fn: Handler<T...>) -> Connection,
	Wait: (self: Event<T...>) -> T...,
}

export type Signal<T...> = Event<T...> & {
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

export type New = <T...>() -> Signal<T...>
export type WrapEvent = <T...>(signal: Signal<T...>) -> Event<T...>

return SignalTypes
