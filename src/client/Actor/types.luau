--!strict
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

local types = {}

export type DomainChangeSource = "Commit" | "Baseline"
export type DomainChange = { read previous: any, read current: any, read source: DomainChangeSource }
export type DomainMembershipChange = { read added: { string }, read removed: { string } }
export type ActionSnapshot = { read actionId: string, read sequenceId: number }

export type ActionsView = {
	read IsActionActive: (self: ActionsView, actionId: string) -> boolean,
	read GetAction: (self: ActionsView, sequenceId: number) -> ActionSnapshot?,
	read GetActiveActions: (self: ActionsView) -> { ActionSnapshot },
	read OnActionStarted: SignalTypes.Event<ActionSnapshot>,
	read OnActionEnded: SignalTypes.Event<ActionSnapshot>,
	read OnActionInterrupted: SignalTypes.Event<ActionSnapshot>,
	read OnStateChanged: SignalTypes.Event<DomainChangeSource>,
}

export type ActionsViewOwner = { read view: ActionsView, Destroy: (self: ActionsViewOwner) -> () }
export type ActionsViewModule = { new: (getDomain: () -> DomainView?) -> ActionsViewOwner }
export type ActiveTagSnapshot = { read tagId: string, read stackCount: number, read remainingDuration: number? }

export type TagsView = {
	read HasTag: (self: TagsView, tagId: string) -> boolean,
	read GetTag: (self: TagsView, tagId: string) -> ActiveTagSnapshot?,
	read GetActiveTags: (self: TagsView) -> { ActiveTagSnapshot },
	read OnTagAdded: SignalTypes.Event<string>,
	read OnTagRefreshed: SignalTypes.Event<string>,
	read OnTagRemoved: SignalTypes.Event<string>,
	read OnTagExpired: SignalTypes.Event<string>,
	read OnStateChanged: SignalTypes.Event<DomainChangeSource>,
}

export type TagsViewOwner = { read view: TagsView, Destroy: (self: TagsViewOwner) -> () }

export type TagsViewModule = {
	new: (getDomain: () -> DomainView?, serverTimeNow: (() -> number)?) -> TagsViewOwner,
}

export type ResourceSnapshot = {
	read resourceId: string,
	read current: number,
	read min: number,
	read max: number,
	read regenRate: number?,
}

export type ResourceViewChange = {
	read resourceId: string,
	read previous: ResourceSnapshot?,
	read current: ResourceSnapshot?,
	read source: DomainChangeSource,
}

export type ResourcesView = {
	read HasResource: (self: ResourcesView, resourceId: string) -> boolean,
	read GetResource: (self: ResourcesView, resourceId: string) -> ResourceSnapshot?,
	read GetCurrent: (self: ResourcesView, resourceId: string) -> number?,
	read GetMin: (self: ResourcesView, resourceId: string) -> number?,
	read GetMax: (self: ResourcesView, resourceId: string) -> number?,
	read GetRegenRate: (self: ResourcesView, resourceId: string) -> number?,
	read GetAssignedResources: (self: ResourcesView) -> { ResourceSnapshot },
	read OnResourceChanged: SignalTypes.Event<ResourceViewChange>,
}

export type ResourcesViewOwner = { read view: ResourcesView, Destroy: (self: ResourcesViewOwner) -> () }

export type ResourcesViewModule = {
	new: (getDomain: () -> DomainView?, serverTimeNow: (() -> number)?) -> ResourcesViewOwner,
}

export type DomainView = {
	read GetId: (self: any) -> string,
	read GetState: (self: any) -> any,
	read GetEvent: (self: any, eventId: string) -> SignalTypes.Event<any>?,
	read OnChanged: SignalTypes.Event<DomainChange>,
}

export type ActorView = {
	read GetActions: (self: ActorView) -> ActionsView,
	read GetTags: (self: ActorView) -> TagsView,
	read GetResources: (self: ActorView) -> ResourcesView,
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
