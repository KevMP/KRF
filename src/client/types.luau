--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.shared.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.shared.ActionRequest.types)

local types = {}

export type StartupFailure = { system: string, reason: string }

-- Optional client startup configuration. The request schemas are the same replicated
-- network-only module passed to Server.Init; omitting it keeps Client.Init() unchanged.
export type ClientInitConfig = {
	actionRequestSchemas: ActionRequestTypes.ActionRequestSchemas?,
}

export type ClientUnreliableObserver = (callback: (any, ...any) -> ()) -> () -> ()
export type ClientStepObserver = (callback: () -> ()) -> () -> ()

export type ClientTransport = {
	ConnectReliable: (callback: (any, ...any) -> ()) -> () -> (),
	SendReliable: (payload: buffer) -> (),
	SendUnreliable: ((payload: buffer) -> ())?,
	ConnectUnreliable: ClientUnreliableObserver?,
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
		sendUnreliable: ((buffer) -> ())?,
		connectUnreliable: ClientUnreliableObserver?
	) -> (boolean, string?, (() -> ())?),
}

export type Client = {
	Init: (config: ClientInitConfig?) -> (boolean, StartupFailure?),
	_IsInitialized: () -> boolean,
	_SetDependenciesForTests: (dependencies: Dependencies) -> (),
	_ResetForTests: () -> (),
}

return types
