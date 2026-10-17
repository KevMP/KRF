--!strict
local types = {}
export type Dependencies = {
	Now: () -> number,
	IsClientReady: (Player) -> boolean,
	RequestReplacementBaseline: (Player, number, string?) -> (boolean, string?),
	ObserveClientClosed: ((Player) -> ()) -> () -> (),
}
-- Hard admission bounds are injected for deterministic boundary tests.
export type Options = { windowSeconds: number, maxRequestsPerClient: number, maxRequestsPerActor: number }
export type Runtime = {
	Handle: (self: Runtime, player: Player, payload: any, ...any) -> (boolean, string?),
	Destroy: (self: Runtime) -> (),
}
export type RuntimeModule = { new: (Dependencies, Options) -> Runtime }
return types
