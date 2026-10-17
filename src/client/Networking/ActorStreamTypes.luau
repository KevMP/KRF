--!strict
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)

local types = {}

export type ActorRecord = { read actorId: string, read handle: number, read model: Model? }
export type Consumer = {
	OnBaselineReady: (ActorRecord, number, { [string]: WireTypes.DomainTruth }) -> (),
	OnCommitReady: (ActorRecord, number, { WireTypes.DomainPatch }, { WireTypes.Event }) -> (),
	-- Once per terminal failure, after assembly cleanup, even before the first baseline.
	-- N5 must invalidate authoritative state, mark the view unavailable and stop resync
	-- for this handle. Identity and Model lifecycle continue until OnActorRemoved.
	OnActorHalted: (ActorRecord) -> (),
	OnActorRemoved: (ActorRecord) -> (),
	OnModelBound: (ActorRecord, Model) -> (),
	OnModelUnbound: (ActorRecord, Model) -> (),
}
export type Candidate = { marker: Instance, model: Model, actorId: string }
export type Discovery = {
	GetCandidates: () -> { Candidate },
	ObserveAdded: ((Candidate) -> ()) -> () -> (),
	ObserveRemoved: ((Instance) -> ()) -> () -> (),
}
export type DiscoveryAdapter = Discovery & { Destroy: () -> () }
export type DiscoveryModule = { new: (root: Instance?) -> DiscoveryAdapter }
export type Options = { maxBaselineBytes: number, maxPendingBaselines: number, ReportFault: (string) -> () }
export type Runtime = {
	Handle: (self: Runtime, payload: any) -> (boolean, string?),
	GetByHandle: (self: Runtime, handle: number) -> ActorRecord?,
	GetByActorId: (self: Runtime, actorId: string) -> ActorRecord?,
	GetByModel: (self: Runtime, model: Model) -> ActorRecord?,
	Destroy: (self: Runtime) -> (),
}
export type RuntimeModule = {
	new: (WireTypes.Codec, Consumer?, Discovery, Options) -> Runtime,
}

return types
