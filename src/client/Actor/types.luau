--!strict
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

local types = {}

export type DomainChangeSource = "Commit" | "Baseline"
export type DomainChange = { read previous: any, read current: any, read source: DomainChangeSource }
export type DomainMembershipChange = { read added: { string }, read removed: { string } }
export type DomainView = {
	read GetId: (self: any) -> string,
	read GetState: (self: any) -> any,
	read GetEvent: (self: any, eventId: string) -> SignalTypes.Event<any>?,
	read OnChanged: SignalTypes.Event<DomainChange>,
}
export type ActorView = {
	read GetId: (self: any) -> string,
	read GetModel: (self: any) -> Model?,
	read GetDomain: (self: any, domainId: string) -> DomainView?,
	read GetDomainIds: (self: any) -> { string },
	read IsAvailable: (self: any) -> boolean,
	read OnModelChanged: SignalTypes.Event<Model?, Model?>,
	read OnDomainsChanged: SignalTypes.Event<DomainMembershipChange>,
	read OnUnavailable: SignalTypes.Event<>,
}
export type ActorViewRegistry = {
	read GetActorViewById: (actorId: string) -> ActorView?,
	read GetActorViewByModel: (model: Model) -> ActorView?,
	read GetAllActorViews: () -> { ActorView },
	read OnActorViewAdded: SignalTypes.Event<ActorView>,
	read OnActorViewRemoving: SignalTypes.Event<ActorView>,
}

-- Framework-private owners. Public facades contain none of these mutation methods.
-- Installation never fires events. Networking installs the entire Actor's state
-- before invoking any notification, preserving atomic multi-domain publication.
export type DomainViewOwner = {
	read view: DomainView,
	InstallState: (self: DomainViewOwner, state: any) -> (),
	NotifyChanged: (self: DomainViewOwner, change: DomainChange) -> (),
	FireEvent: (self: DomainViewOwner, eventId: string, payload: any) -> (),
	Destroy: (self: DomainViewOwner) -> (),
}
export type DomainViewModule = {
	new: (domainId: string, immutableState: any, eventIds: { string }) -> (DomainViewOwner?, string?),
}
export type ActorViewOwner = {
	read view: ActorView,
	InstallModel: (self: ActorViewOwner, model: Model?) -> (),
	InstallDomains: (self: ActorViewOwner, domains: { [string]: DomainViewOwner }) -> DomainMembershipChange?,
	InstallUnavailable: (self: ActorViewOwner) -> (),
	NotifyModelChanged: (self: ActorViewOwner, previous: Model?, current: Model?) -> (),
	NotifyDomainsChanged: (self: ActorViewOwner, change: DomainMembershipChange) -> (),
	NotifyUnavailable: (self: ActorViewOwner) -> (),
	Destroy: (self: ActorViewOwner) -> (),
}
export type ActorViewModule = {
	new: (actorId: string, model: Model?, domains: { [string]: DomainViewOwner }) -> (ActorViewOwner?, string?),
}
export type ActorViewRegistryOwner = {
	GetActorViewById: (actorId: string) -> ActorView?,
	GetActorViewByModel: (model: Model) -> ActorView?,
	GetAllActorViews: () -> { ActorView },
	Install: (view: ActorView) -> (boolean, string?),
	InstallModel: (view: ActorView, previous: Model?, current: Model?) -> (boolean, string?),
	Remove: (view: ActorView) -> (),
	Reset: () -> (),
	read Added: SignalTypes.Signal<ActorView>,
	read Removing: SignalTypes.Signal<ActorView>,
}

return types
