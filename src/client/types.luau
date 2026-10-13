--!strict
local ProtocolTypes = require(script.Parent.Parent.shared.Networking.ProtocolTypes)

local types = {}

export type StartupFailure = { system: string, reason: string }
export type ClientTransport = {
	ConnectReliable: (callback: (any, ...any) -> ()) -> () -> (),
	SendReliable: (payload: buffer) -> (),
}
-- Framework-private adapters for deterministic startup tests; no consumer hook.
export type Dependencies = {
	Now: () -> number,
	DiscoverTransport: (deadline: number) -> (ClientTransport?, string?),
	ScheduleTimeout: (seconds: number, callback: () -> ()) -> () -> (),
	Resume: (thread) -> (),
	InstallConsumers: (protocol: ProtocolTypes.ClientProtocol) -> (boolean, string?, (() -> ())?),
}
export type Client = {
	Init: () -> (boolean, StartupFailure?),
	_IsInitialized: () -> boolean,
	_SetDependenciesForTests: (dependencies: Dependencies) -> (),
	_ResetForTests: () -> (),
}

return types
