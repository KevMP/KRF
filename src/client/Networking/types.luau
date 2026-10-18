--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)

local types = {}

-- Actor stream and Model discovery
-- N4 owns one stable identity record per awareness lifetime and updates its Model
-- in place. Consumers must not manufacture or mutate these records.
export type ActorStreamRecord = { read actorId: string, read handle: number, read model: Model? }

export type ActorStreamConsumer = {
	OnBaselineReady: (ActorStreamRecord, number, { [string]: SharedNetworkingTypes.ActorDomainTruth }) -> (),
	OnCommitReady: (
		ActorStreamRecord,
		number,
		{ SharedNetworkingTypes.ActorDomainPatch },
		{ SharedNetworkingTypes.ActorEvent }
	) -> (),
	-- Once per terminal failure, after assembly cleanup, even before the first baseline.
	-- N5 must invalidate authoritative state, mark the view unavailable and stop resync
	-- for this handle. Identity and Model lifecycle continue until OnActorRemoved.
	OnActorHalted: (ActorStreamRecord) -> (),
	-- A decoded record is attributable to this Actor but cannot be consumed.
	-- Valid assembly is preserved; a completed invalid body is released first.
	OnActorFault: (ActorStreamRecord, string) -> (),
	OnActorRemoved: (ActorStreamRecord) -> (),
	OnModelBound: (ActorStreamRecord, Model) -> (),
	OnModelUnbound: (ActorStreamRecord, Model) -> (),
}

export type ActorModelCandidate = { marker: Instance, model: Model, actorId: string }

export type ActorModelDiscovery = {
	GetCandidates: () -> { ActorModelCandidate },
	ObserveAdded: ((ActorModelCandidate) -> ()) -> () -> (),
	ObserveRemoved: ((Instance) -> ()) -> () -> (),
}

export type ActorModelDiscoveryAdapter = ActorModelDiscovery & { Destroy: () -> () }
export type ActorModelDiscoveryModule = { new: (root: Instance?) -> ActorModelDiscoveryAdapter }
export type ActorStreamOptions = { maxBaselineBytes: number, maxPendingBaselines: number, ReportFault: (string) -> () }

export type ActorStreamRuntime = {
	Handle: (self: ActorStreamRuntime, payload: any) -> (boolean, string?),
	GetByHandle: (self: ActorStreamRuntime, handle: number) -> ActorStreamRecord?,
	GetByActorId: (self: ActorStreamRuntime, actorId: string) -> ActorStreamRecord?,
	GetByModel: (self: ActorStreamRuntime, model: Model) -> ActorStreamRecord?,
	Destroy: (self: ActorStreamRuntime) -> (),
}

export type ActorStreamRuntimeModule = {
	new: (
		SharedNetworkingTypes.ActorStreamCodec,
		ActorStreamConsumer?,
		ActorModelDiscovery,
		ActorStreamOptions
	) -> ActorStreamRuntime,
}

-- ActorView application and recovery
export type ActorViewFault = { actorId: string, reason: string }

export type ActorViewOptions = {
	Now: () -> number,
	ScheduleTimeout: (number, () -> ()) -> () -> (),
	SendReliable: (buffer) -> (),
	ReportFault: (ActorViewFault) -> (),
}

-- Private diagnostics, never reachable through ActorView or its public registry.
export type ActorViewDiagnostics = {
	revision: number?,
	status: "Live" | "AwaitingBaseline" | "Halted",
	bufferedCommitCount: number,
}

export type ActorViewRuntime = {
	read consumer: ActorStreamConsumer,
	read registry: PublicTypes.ActorViewRegistry,
	_InspectForTests: (self: ActorViewRuntime, handle: number) -> ActorViewDiagnostics?,
	Destroy: (self: ActorViewRuntime) -> (),
}

export type ActorViewRuntimeModule = {
	new: (
		SharedNetworkingTypes.ClientProtocol,
		SharedNetworkingTypes.ActorSchemaCatalog,
		ActorViewOptions
	) -> ActorViewRuntime,
}

return types
