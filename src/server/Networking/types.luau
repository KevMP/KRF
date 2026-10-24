--!strict
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)

local types = {}

-- Commands are startup definitions. Context and outcomes contain semantic data
-- only; connection identities, handles, buffers and egress ownership stay private.
export type CommandOutcome = {
	read requestId: number,
	read commandId: string,
	read targetActor: ActorTypes.Actor?,
	read status: "Accepted" | "Rejected" | "Unknown",
	read result: any,
	read reason: string?,
}

export type CommandContext = {
	read player: Player,
	read actor: ActorTypes.Actor?,
	read requestId: number,
	read commandId: string,
	read GetPriorOutcome: (self: CommandContext, requestId: number) -> CommandOutcome?,
}

export type CommandHandlerResult = { accepted: boolean, result: any?, reason: string? }
export type CommandAuthorize = (CommandContext, any) -> (boolean, string?)
export type CommandHandler = (CommandContext, any) -> CommandHandlerResult

export type CommandDefinition = {
	id: string,
	target: "None" | "Actor",
	request: SharedNetworkingTypes.SchemaDefinition?,
	result: SharedNetworkingTypes.SchemaDefinition?,
	authorize: CommandAuthorize,
	handle: CommandHandler,
}

export type LoadedCommandDefinition = {
	read id: string,
	read target: "None" | "Actor",
	read request: SharedNetworkingTypes.CompiledSchema?,
	read result: SharedNetworkingTypes.CompiledSchema?,
	read authorize: CommandAuthorize,
	read handle: CommandHandler,
}

export type PreparedCommandCatalog = {
	read definitionsById: { [string]: LoadedCommandDefinition },
	read orderedDefinitions: { LoadedCommandDefinition },
}

export type CommandReservation = {
	read Commit: (buffer) -> boolean,
	read Cancel: () -> (),
}

export type ServerCommandLimits = {
	maxRequests: number?,
	maxBytes: number?,
	windowSeconds: number?,
	maxQueuedRequests: number?,
	maxQueuedBytes: number?,
	maxHistory: number?,
	maxHistoryBytes: number?,
	historySeconds: number?,
	maxGlobalRequests: number?,
	maxGlobalBytes: number?,
	maxGlobalQueuedRequests: number?,
	maxGlobalQueuedBytes: number?,
	maxDispatchRequests: number?,
	maxDispatchVisits: number?,
}

export type ServerCommandDependencies = {
	Now: () -> number,
	ScheduleTimeout: ((number, () -> ()) -> () -> ())?,
	IsClientReady: (Player) -> boolean,
	ObserveClientClosed: ((Player) -> ()) -> () -> (),
	awareness: ActorAwarenessRuntime,
	ReportFault: (Player, string) -> (),
	CloseConnection: (Player, string) -> (),
}

export type ServerCommandRuntime = {
	Handle: (self: ServerCommandRuntime, Player, any, ...any) -> (boolean, string?),
	Step: (self: ServerCommandRuntime) -> (number, number),
	_GetPendingForTests: (self: ServerCommandRuntime) -> (number, number),
	Destroy: (self: ServerCommandRuntime) -> (),
}

export type ServerCommandRuntimeModule = {
	new: (
		PreparedCommandCatalog,
		SharedNetworkingTypes.ClientProtocol,
		ServerCommandDependencies,
		ServerCommandLimits?
	) -> ServerCommandRuntime,
}

-- Networking startup and handshake
export type HandshakeDependencies = {
	SendReliable: (player: Player, payload: buffer) -> (),
}

export type ServerHandshake = {
	Handle: (self: ServerHandshake, player: Player, payload: any, ...any) -> (),
	IsClientReady: (self: ServerHandshake, player: Player) -> boolean,
	Send: (self: ServerHandshake, player: Player, payload: buffer) -> (boolean, string?),
	ObserveClientReady: (self: ServerHandshake, callback: (Player) -> ()) -> () -> (),
	ObserveClientClosed: (self: ServerHandshake, callback: (Player) -> ()) -> () -> (),
	Close: (self: ServerHandshake, player: Player) -> (),
	Destroy: (self: ServerHandshake) -> (),
	_GetConnectionCountForTests: (self: ServerHandshake) -> number,
}

export type ServerHandshakeModule = {
	new: (protocol: SharedNetworkingTypes.PreparedProtocol, dependencies: HandshakeDependencies) -> ServerHandshake,
}

export type ServerNetworking = {
	Prepare: (
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		commands: PreparedCommandCatalog?
	) -> (SharedNetworkingTypes.PreparedProtocol?, string?),
	Publish: (protocol: SharedNetworkingTypes.PreparedProtocol) -> (boolean, string?),
	IsClientReady: (player: Player) -> boolean,
	ObserveClientReady: (callback: (Player) -> ()) -> () -> (),
	ObserveClientClosed: (callback: (Player) -> ()) -> () -> (),
	SendReliable: (player: Player, payload: buffer) -> (boolean, string?),
	-- Framework-private recovery entrypoint; ActorAwarenessRuntime retains ownership of the installed runtime.
	RequestReplacementBaseline: (player: Player, handle: number, reason: string?) -> (boolean, string?),
	Destroy: () -> (),
	_IsInitialized: () -> boolean,
	_ResetForTests: () -> (),
	-- Framework-private test seam for verifying startup ownership of PublicationRuntime.
	_GetPublicationRuntimeForTests: () -> PublicationRuntime?,
}

-- Publication
-- Framework-private publication contracts. ActorAwarenessRuntime owns recipient filtering and wire records.
export type PublicationPatch = SharedNetworkingTypes.ActorPatch
export type PublicationCaptureResult = { read value: any, read patch: PublicationPatch?, read encodedSizeBytes: number }

export type PublicationCapturePlan = {
	Capture: (
		self: PublicationCapturePlan,
		value: any,
		previous: PublicationCaptureResult?
	) -> (PublicationCaptureResult?, string?),
}

export type PublicationCaptureModule = {
	Compile: (schema: SharedNetworkingTypes.CompiledSchema) -> PublicationCapturePlan,
}

export type PublicationDomainPatch = SharedNetworkingTypes.ActorDomainPatch
export type PublicationEvent = SharedNetworkingTypes.ActorEvent

export type PublicationCommit = {
	read actor: ActorTypes.Actor,
	read sequence: number,
	read patches: { PublicationDomainPatch },
	read events: { PublicationEvent },
}

-- The wrapper preserves a present domain whose Optional state is nil.
export type PublicationDomainTruth = SharedNetworkingTypes.ActorDomainTruth
export type PublicationBaseline = { read sequence: number, read domains: { [string]: PublicationDomainTruth } }
export type PublicationFault = { read actorId: string, read domainId: string, read reason: string }
export type PublicationRuntimeOptions = { ReportFault: ((fault: PublicationFault) -> ())? }

export type PublicationRuntime = {
	IsActorAttached: (self: PublicationRuntime, actor: ActorTypes.Actor) -> boolean,
	AttachActor: (self: PublicationRuntime, actor: ActorTypes.Actor) -> (boolean, string?),
	DetachActor: (self: PublicationRuntime, actor: ActorTypes.Actor) -> (),
	GetActorSequence: (self: PublicationRuntime, actor: ActorTypes.Actor) -> number,
	GetAttachedActors: (self: PublicationRuntime) -> { ActorTypes.Actor },
	CaptureBaseline: (self: PublicationRuntime, actor: ActorTypes.Actor) -> PublicationBaseline?,
	ObserveCommits: (self: PublicationRuntime, observer: (commit: PublicationCommit) -> ()) -> () -> (),
	WithActorCommit: (self: PublicationRuntime, actor: ActorTypes.Actor, callback: () -> ()) -> (),
	Destroy: (self: PublicationRuntime) -> (),
}

export type PublicationRuntimeModule = {
	new: (
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		options: PublicationRuntimeOptions?
	) -> PublicationRuntime,
	ValidateEventBounds: (
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		maxEventBytes: number
	) -> (boolean, string?),
}

export type PublicationLifecycleModule = {
	AttachActor: (actor: ActorTypes.Actor) -> (boolean, string?),
	DetachActor: (actor: ActorTypes.Actor) -> (),
	WithActorCommit: (actor: ActorTypes.Actor, callback: () -> ()) -> (),
}

-- Stream identities are opaque to PublicationRuntime; ActorAwarenessRuntime supplies recipient-visible work.
export type PublicationStreamKey = { read recipient: any, read actor: any }

export type PublicationFilteredCommit = {
	read sequence: number,
	read patches: { PublicationDomainPatch },
	read events: { PublicationEvent },
}

export type PublicationRecord = {
	read stream: PublicationStreamKey,
	read commit: PublicationFilteredCommit,
	read encodedSizeBytes: number,
}

export type PublicationStreamStatus = {
	read needsBaseline: boolean,
	read pendingRecords: number,
	read pendingEvents: number,
	read queuedBytes: number,
}

export type PublicationDrainResult = {
	read records: { PublicationRecord },
	read encodedBytes: number,
	read visitedStreams: number,
}

export type PublicationSchedulerOptions = {
	read maxBarriers: number,
	read maxEvents: number,
	read maxQueuedBytes: number,
	-- ActorAwarenessRuntime supplies codec-aware record sizing, including conservative framing.
	read MeasureRecord: (commit: PublicationFilteredCommit) -> number,
}

export type PublicationScheduler = {
	Enqueue: (
		self: PublicationScheduler,
		stream: PublicationStreamKey,
		commit: PublicationFilteredCommit,
		order: number?
	) -> (boolean, string?),
	MarkBaselinePending: (self: PublicationScheduler, stream: PublicationStreamKey) -> (),
	-- Delivered visible truth permits cancellation of net-zero Map tail changes.
	ResetAfterBaseline: (
		self: PublicationScheduler,
		stream: PublicationStreamKey,
		domains: { [string]: PublicationDomainTruth }
	) -> (),
	RemoveStream: (self: PublicationScheduler, stream: PublicationStreamKey) -> (),
	GetStreamStatus: (self: PublicationScheduler, stream: PublicationStreamKey) -> PublicationStreamStatus,
	GetNextRecordBytes: (self: PublicationScheduler, stream: PublicationStreamKey) -> number?,
	GetNextRecordOrder: (self: PublicationScheduler, stream: PublicationStreamKey) -> number?,
	DrainBudgeted: (self: PublicationScheduler, maxBytes: number, maxRecords: number) -> PublicationDrainResult,
	Destroy: (self: PublicationScheduler) -> (),
}

export type PublicationSchedulerModule = { new: (options: PublicationSchedulerOptions) -> PublicationScheduler }

-- Actor awareness
export type ActorAwarenessFault = { player: Player, actorId: string, reason: string }

export type ActorAwarenessDependencies = {
	CloseConnection: ((Player, string) -> ())?,
	IsClientReady: (Player) -> boolean,
	ObserveClientReady: ((Player) -> ()) -> () -> (),
	ObserveClientClosed: ((Player) -> ()) -> () -> (),
	SendReliable: (Player, buffer) -> (boolean, string?),
	GetPlayerFromCharacter: (Model) -> Player?,
	-- Notify both the previous and current Character Model when their association changes.
	ObserveAssociationChanged: ((Model) -> ()) -> () -> (),
	ReportFault: (ActorAwarenessFault) -> (),
}

-- Small injected limits exercise boundaries without large allocations. Defaults are private tuning.
export type ActorAwarenessOptions = {
	maxBaselineBytes: number,
	maxChunkBytes: number,
	maxQueuedBytes: number,
	maxEvents: number,
	maxHandle: number,
	maxRevision: number,
	maxGeneration: number?,
}

export type ActorAwarenessRuntime = {
	ResolveActor: (self: ActorAwarenessRuntime, player: Player, handle: number) -> (ActorTypes.Actor?, string?),
	ReserveCommandResult: (
		self: ActorAwarenessRuntime,
		player: Player,
		maxBytes: number
	) -> (CommandReservation?, string?),
	OnActorRegistered: (self: ActorAwarenessRuntime, actor: ActorTypes.Actor) -> (),
	OnActorUnregistering: (self: ActorAwarenessRuntime, actor: ActorTypes.Actor) -> (),
	RefreshPlayerAssociation: (self: ActorAwarenessRuntime, actor: ActorTypes.Actor) -> (),
	GetActorForPlayer: (self: ActorAwarenessRuntime, player: Player) -> ActorTypes.Actor?,
	GetPlayerForActor: (self: ActorAwarenessRuntime, actor: ActorTypes.Actor) -> Player?,
	IsAware: (self: ActorAwarenessRuntime, player: Player, actor: ActorTypes.Actor) -> boolean,
	GetHandle: (self: ActorAwarenessRuntime, player: Player, actor: ActorTypes.Actor) -> number?,
	RequestReplacementBaseline: (
		self: ActorAwarenessRuntime,
		player: Player,
		handle: number,
		reason: string?
	) -> (boolean, string?),
	Step: (self: ActorAwarenessRuntime, maxBytes: number, maxRecords: number) -> (),
	Destroy: (self: ActorAwarenessRuntime) -> (),
}

export type ActorAwarenessRuntimeModule = {
	new: (
		publication: PublicationRuntime,
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		protocol: SharedNetworkingTypes.ClientProtocol,
		dependencies: ActorAwarenessDependencies,
		options: ActorAwarenessOptions
	) -> ActorAwarenessRuntime,
}

export type ActorRecipientSelectionModule = {
	ShouldBeAware: (player: Player, actor: ActorTypes.Actor) -> boolean,
}

export type ActorModelMarkerModule = {
	Install: (actor: ActorTypes.Actor) -> (boolean, string?),
	Remove: (actor: ActorTypes.Actor) -> (),
	GetActorId: (marker: Instance) -> string?,
	GetMarker: (model: Model) -> Instance?,
}

export type AwarenessStepBudget = { read maxBytes: number, read maxRecords: number }

export type AwarenessSchedulingModule = {
	GetBudget: () -> AwarenessStepBudget,
	ObserveStep: (() -> ()) -> () -> (),
}

export type PlayerAssociationSource = {
	GetPlayerFromCharacter: (Model) -> Player?,
	ObserveAssociationChanged: ((Model) -> ()) -> () -> (),
	Destroy: () -> (),
}

export type PlayerAssociationModule = { new: (players: Players?) -> PlayerAssociationSource }

-- Recovery
export type ResyncDependencies = {
	Now: () -> number,
	IsClientReady: (Player) -> boolean,
	RequestReplacementBaseline: (Player, number, string?) -> (boolean, string?),
	ObserveClientClosed: ((Player) -> ()) -> () -> (),
}

-- Hard admission bounds are injected for deterministic boundary tests.
export type ResyncOptions = { windowSeconds: number, maxRequestsPerClient: number, maxRequestsPerActor: number }

export type ResyncRuntime = {
	Handle: (self: ResyncRuntime, player: Player, payload: any, ...any) -> (boolean, string?),
	Destroy: (self: ResyncRuntime) -> (),
}

export type ResyncRuntimeModule = { new: (ResyncDependencies, ResyncOptions) -> ResyncRuntime }

return types
