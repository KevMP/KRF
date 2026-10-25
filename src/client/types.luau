--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.shared.Networking.types)

local types = {}

export type StartupFailure = { system: string, reason: string }
export type ClientStepObserver = (callback: () -> ()) -> () -> ()

export type ClientTransport = {
	ConnectReliable: (callback: (any, ...any) -> ()) -> () -> (),
	SendReliable: (payload: buffer) -> (),
	SendUnreliable: ((payload: buffer) -> ())?,
}

-- Framework-private adapters for deterministic startup tests; no consumer hook.
export type Dependencies = {
	Now: () -> number,
	DiscoverTransport: (deadline: number) -> (ClientTransport?, string?),
	ScheduleTimeout: (seconds: number, callback: () -> ()) -> () -> (),
	Resume: (thread) -> (),
	ObserveStep: ClientStepObserver?,
	InstallConsumers: (
		protocol: SharedNetworkingTypes.ClientProtocol,
		manifest: SharedNetworkingTypes.ProtocolManifest?,
		installActorReceiver: (((any) -> ()) -> ())?,
		sendReliable: ((buffer) -> ())?,
		isReady: (() -> boolean)?,
		onTerminalFailure: (() -> ())?,
		sendUnreliable: ((buffer) -> ())?
	) -> (boolean, string?, (() -> ())?),
}

export type Client = {
	Init: () -> (boolean, StartupFailure?),
	_IsInitialized: () -> boolean,
	_SetDependenciesForTests: (dependencies: Dependencies) -> (),
	_ResetForTests: () -> (),
}

return types
