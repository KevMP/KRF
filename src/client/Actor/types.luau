--!strict
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

local types = {}

export type DomainChangeSource = "Commit" | "Baseline"
export type DomainChange = { read previous: any, read current: any, read source: DomainChangeSource }
export type DomainView = {
	GetId: (self: any) -> string,
	GetState: (self: any) -> any,
	GetEvent: (self: any, eventId: string) -> SignalTypes.Event<any>?,
	read OnChanged: SignalTypes.Event<DomainChange>,
}
export type ActorView = {
	GetId: (self: any) -> string,
	GetModel: (self: any) -> Model?,
	GetDomain: (self: any, domainId: string) -> DomainView?,
	GetDomainIds: (self: any) -> { string },
	read OnModelChanged: SignalTypes.Event<Model?, Model?>,
}
export type ActorViewRegistry = {
	GetActorViewById: (actorId: string) -> ActorView?,
	GetActorViewByModel: (model: Model) -> ActorView?,
	GetAllActorViews: () -> { ActorView },
	read OnActorViewAdded: SignalTypes.Event<ActorView>,
	read OnActorViewRemoving: SignalTypes.Event<ActorView>,
}

return types
