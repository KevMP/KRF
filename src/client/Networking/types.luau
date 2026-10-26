--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

local types = {}

-- Private local introspection; absent outside the owning runtime lifetime.
export type NetworkingDiagnostics = {
	read GetClientSnapshot: () -> SharedNetworkingTypes.DiagnosticSnapshot?,
}

export type HintReceived = { read hintId: string, read actorView: PublicTypes.ActorView?, read payload: any? }

export type HintRuntime = {
	read Send: (string, PublicTypes.ActorView?, any?) -> (boolean, string?),
	read OnHintReceived: SignalTypes.Event<HintReceived>,
}

export type HintReceiveLimits = {
	windowSeconds: number,
	maxPackets: number,
	maxBytes: number,
	maxPendingPackets: number,
	maxPendingBytes: number,
	maxRecords: number,
	maxLatestKeys: number,
}

export type HintReceiveDependencies = {
	Now: () -> number,
	IsReady: () -> boolean,
	Notify: (HintReceived) -> (),
}

export type HintReceiverRuntime = {
	Handle: (self: HintReceiverRuntime, any, ...any) -> (boolean, string?),
	Step: (self: HintReceiverRuntime) -> (number, number),
	ForgetActor: (self: HintReceiverRuntime, PublicTypes.ActorView) -> (),
	Destroy: (self: HintReceiverRuntime) -> (),
}

export type ClientHintLimits = {
	maxPending: number?,
	maxPendingBytes: number?,
	maxLatestKeys: number?,
	maxAttempts: number?,
	maxBytes: number?,
	windowSeconds: number?,
	maxRecords: number?,
	maxSends: number?,
	maxSequence: number?,
}

export type ClientHintDependencies = { Now: () -> number, IsReady: () -> boolean, SendUnreliable: (buffer) -> () }

export type ClientHintRuntime = {
	Send: (self: ClientHintRuntime, string, PublicTypes.ActorView?, any?) -> (boolean, string?),
	Step: (self: ClientHintRuntime) -> (number, number),
	ForgetActor: (self: ClientHintRuntime, PublicTypes.ActorView) -> (),
	Destroy: (self: ClientHintRuntime) -> (),
}

export type CommandResult = {
	read requestId: number,
	read commandId: string,
	read targetActorView: PublicTypes.ActorView?,
	read status: "Accepted" | "Rejected" | "Unknown",
	read result: any,
	read reason: string?,
}

export type CommandRuntime = {
	read Send: (string, PublicTypes.ActorView?, any?) -> (number?, string?),
	read OnCommandResult: SignalTypes.Event<CommandResult>,
	read OnCommandUncertain: SignalTypes.Event<CommandResult>,
}

export type ClientCommandOptions = {
	IsReady: () -> boolean,
	SendReliable: (buffer) -> (),
	ScheduleTimeout: (number, () -> ()) -> () -> (),
	maxRequestId: number?,
	maxPending: number?,
	maxPendingBytes: number?,
	timeoutSeconds: number?,
	graceSeconds: number?,
}

export type ClientCommandRuntime = {
	Send: (self: ClientCommandRuntime, string, PublicTypes.ActorView?, any?) -> (number?, string?),
	Handle: (self: ClientCommandRuntime, any) -> boolean,
	Destroy: (self: ClientCommandRuntime) -> (),
}

-- Actor stream and Model discovery
-- The Actor stream runtime owns one stable identity record per awareness lifetime and updates its Model
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
	-- The ActorView runtime must invalidate authoritative state, mark the view unavailable and stop resync
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
	-- True only at the once-per-owner terminal transition; logging may suppress retries.
	ReportFault: (ActorViewFault, boolean?) -> (),
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
