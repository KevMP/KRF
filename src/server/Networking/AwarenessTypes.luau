--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local PublicationTypes = require(script.Parent.PublicationTypes)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)

local types = {}

export type Fault = { player: Player, actorId: string, reason: string }
export type Dependencies = {
	IsClientReady: (Player) -> boolean,
	ObserveClientReady: ((Player) -> ()) -> () -> (),
	ObserveClientClosed: ((Player) -> ()) -> () -> (),
	SendReliable: (Player, buffer) -> (boolean, string?),
	GetPlayerFromCharacter: (Model) -> Player?,
	-- Notify both the previous and current Character Model when their association changes.
	ObserveAssociationChanged: ((Model) -> ()) -> () -> (),
	ReportFault: (Fault) -> (),
}
-- Small injected limits exercise boundaries without large allocations. Defaults are private tuning.
export type Options = {
	maxBaselineBytes: number,
	maxChunkBytes: number,
	maxQueuedBytes: number,
	maxEvents: number,
	maxHandle: number,
	maxRevision: number,
	maxGeneration: number?,
}
export type Runtime = {
	OnActorRegistered: (self: Runtime, actor: ActorTypes.Actor) -> (),
	OnActorUnregistering: (self: Runtime, actor: ActorTypes.Actor) -> (),
	RefreshPlayerAssociation: (self: Runtime, actor: ActorTypes.Actor) -> (),
	GetActorForPlayer: (self: Runtime, player: Player) -> ActorTypes.Actor?,
	GetPlayerForActor: (self: Runtime, actor: ActorTypes.Actor) -> Player?,
	IsAware: (self: Runtime, player: Player, actor: ActorTypes.Actor) -> boolean,
	GetHandle: (self: Runtime, player: Player, actor: ActorTypes.Actor) -> number?,
	RequestReplacementBaseline: (self: Runtime, player: Player, handle: number, reason: string?) -> (boolean, string?),
	Step: (self: Runtime, maxBytes: number, maxRecords: number) -> (),
	Destroy: (self: Runtime) -> (),
}
export type RuntimeModule = {
	new: (
		publication: PublicationTypes.Runtime,
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		protocol: ProtocolTypes.ClientProtocol,
		dependencies: Dependencies,
		options: Options
	) -> Runtime,
}
export type MarkerModule = {
	Install: (actor: ActorTypes.Actor) -> (boolean, string?),
	Remove: (actor: ActorTypes.Actor) -> (),
	GetActorId: (marker: Instance) -> string?,
	GetMarker: (model: Model) -> Instance?,
}

export type StepBudget = { read maxBytes: number, read maxRecords: number }
export type SchedulingModule = {
	GetBudget: () -> StepBudget,
	ObserveStep: (() -> ()) -> () -> (),
}

export type AssociationSource = {
	GetPlayerFromCharacter: (Model) -> Player?,
	ObserveAssociationChanged: ((Model) -> ()) -> () -> (),
	Destroy: () -> (),
}
export type AssociationModule = { new: (players: Players?) -> AssociationSource }

return types
