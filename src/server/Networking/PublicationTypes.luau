--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local SchemaTypes = require(script.Parent.Parent.Parent.shared.Networking.types)

local types = {}

-- N3 framework-private draft contracts. No wire revisions, handles, or recipients
-- are allocated here. All behavior remains unimplemented for the TDD handoff.
export type Patch =
	{ read kind: "Replace", read value: any }
	| { read kind: "Struct", read fields: { [string]: Patch } }
	| { read kind: "Map", read entries: { [any]: any }, read removed: { any } }
export type CaptureResult = { read value: any, read patch: Patch?, read encodedSizeBytes: number }
export type CapturePlan = {
	Capture: (self: CapturePlan, value: any, previous: CaptureResult?) -> (CaptureResult?, string?),
}
export type CaptureModule = { Compile: (schema: SchemaTypes.CompiledSchema) -> CapturePlan }
export type DomainPatch = { read domainId: string, read patch: Patch }
export type Event = { read domainId: string, read eventId: string, read payload: any }
export type Commit = {
	read actor: ActorTypes.Actor,
	read sequence: number,
	read patches: { DomainPatch },
	read events: { Event },
}
export type Baseline = { read sequence: number, read domains: { [string]: any } }
export type Fault = { read actorId: string, read domainId: string, read reason: string }
export type RuntimeOptions = { ReportFault: ((fault: Fault) -> ())? }
export type Runtime = {
	AttachActor: (self: Runtime, actor: ActorTypes.Actor) -> (boolean, string?),
	DetachActor: (self: Runtime, actor: ActorTypes.Actor) -> (),
	GetActorSequence: (self: Runtime, actor: ActorTypes.Actor) -> number,
	GetAttachedActors: (self: Runtime) -> { ActorTypes.Actor },
	CaptureBaseline: (self: Runtime, actor: ActorTypes.Actor) -> Baseline?,
	ObserveCommits: (self: Runtime, observer: (commit: Commit) -> ()) -> () -> (),
	WithActorCommit: (self: Runtime, actor: ActorTypes.Actor, callback: () -> ()) -> (),
	Destroy: (self: Runtime) -> (),
}
export type RuntimeModule = {
	new: (catalog: ReplicationTypes.PreparedReplicationDomainCatalog, options: RuntimeOptions?) -> Runtime,
	ValidateEventBounds: (
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		maxEventBytes: number
	) -> (boolean, string?),
}
export type LifecycleModule = {
	AttachActor: (actor: ActorTypes.Actor) -> (boolean, string?),
	DetachActor: (actor: ActorTypes.Actor) -> (),
}

-- Stream identities are opaque to N3; N4 supplies recipient-visible work.
export type StreamKey = { read recipient: any, read actor: any }
export type FilteredCommit = {
	read sequence: number,
	read patches: { DomainPatch },
	read events: { Event },
}
export type Record = { read stream: StreamKey, read commit: FilteredCommit, read encodedSizeBytes: number }
export type StreamStatus = {
	read needsBaseline: boolean,
	read pendingRecords: number,
	read pendingEvents: number,
	read queuedBytes: number,
}
export type DrainResult = { read records: { Record }, read encodedBytes: number, read visitedStreams: number }
export type SchedulerOptions = {
	read maxBarriers: number,
	read maxEvents: number,
	read maxQueuedBytes: number,
	-- N4 supplies codec-aware record sizing, including conservative framing.
	read MeasureRecord: (commit: FilteredCommit) -> number,
}
export type Scheduler = {
	Enqueue: (self: Scheduler, stream: StreamKey, commit: FilteredCommit) -> (boolean, string?),
	MarkBaselinePending: (self: Scheduler, stream: StreamKey) -> (),
	-- Delivered visible truth permits cancellation of net-zero Map tail changes.
	ResetAfterBaseline: (self: Scheduler, stream: StreamKey, domains: { [string]: any }) -> (),
	RemoveStream: (self: Scheduler, stream: StreamKey) -> (),
	GetStreamStatus: (self: Scheduler, stream: StreamKey) -> StreamStatus,
	DrainBudgeted: (self: Scheduler, maxBytes: number, maxRecords: number) -> DrainResult,
	Destroy: (self: Scheduler) -> (),
}
export type SchedulerModule = { new: (options: SchedulerOptions) -> Scheduler }

return types
