--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

export type ActionEventKind = "Started" | "Ended" | "Interrupted"
export type TagEventKind = "Added" | "Refreshed" | "Removed" | "Expired"

export type ActionEventDescriptor = { read source: "Action", read event: ActionEventKind }
export type TagEventDescriptor = { read source: "Tag", read event: TagEventKind }
export type ResourceEventDescriptor = { read source: "Resource", read event: "Changed" }
export type HintEventDescriptor = { read source: "Hint", read event: "Received" }

export type PresentationEventDescriptor =
	ActionEventDescriptor
	| TagEventDescriptor
	| ResourceEventDescriptor
	| HintEventDescriptor

export type ActionEntryEvent = {
	read source: "Action",
	read event: ActionEventKind,
	read actor: ActorTypes.ActorView,
	read action: ActorTypes.ActionSnapshot,
}

export type TagEntryEvent = {
	read source: "Tag",
	read event: TagEventKind,
	read actor: ActorTypes.ActorView,
	read tagId: string,
}

export type ResourceEntryEvent = {
	read source: "Resource",
	read event: "Changed",
	read actor: ActorTypes.ActorView,
	read change: ActorTypes.ResourceViewChange,
}

export type HintEntryEvent = {
	read source: "Hint",
	read event: "Received",
	read actor: ActorTypes.ActorView?,
	read hintId: string,
	read payload: any?,
}

export type PresentationEntryEvent = ActionEntryEvent | TagEntryEvent | ResourceEntryEvent | HintEntryEvent

export type TagActiveDescriptor = { read source: "Tag", read state: "Active" }
export type ActionActiveDescriptor = { read source: "Action", read state: "Active" }
export type ResourceCurrentDescriptor = { read source: "Resource", read state: "Current" }
export type ActorModelDescriptor = { read source: "Actor", read state: "Model" }
export type PresentationStateEntryDescriptor = TagActiveDescriptor | ActionActiveDescriptor

export type PresentationStateDescriptor =
	PresentationStateEntryDescriptor
	| ResourceCurrentDescriptor
	| ActorModelDescriptor

export type TagStateEntry = {
	read source: "State",
	read kind: "Tag",
	read actor: ActorTypes.ActorView,
	read tagId: string,
	read tag: ActorTypes.ActiveTagSnapshot,
}

export type ActionStateEntry = {
	read source: "State",
	read kind: "Action",
	read actor: ActorTypes.ActorView,
	read action: ActorTypes.ActionSnapshot,
}

export type PresentationStateEntry = TagStateEntry | ActionStateEntry
export type PresentationEntry = PresentationEntryEvent | PresentationStateEntry

export type ActorScopedId = { read id: string, read actor: ActorTypes.ActorView }
export type AnyHintId = { read id: string, read scope: "Any" }
export type ActionListener = (ActionEntryEvent) -> ()
export type TagListener = (TagEntryEvent) -> ()
export type ResourceListener = (ResourceEntryEvent) -> ()
export type HintListener = (HintEntryEvent) -> ()

export type PresentationOn =
	((PresentationContext, ActionEventDescriptor, ActionListener) -> SignalTypes.Connection)
	& ((PresentationContext, ActionEventDescriptor, string | ActorScopedId, ActionListener) -> SignalTypes.Connection)
	& ((PresentationContext, TagEventDescriptor, TagListener) -> SignalTypes.Connection)
	& ((PresentationContext, TagEventDescriptor, string | ActorScopedId, TagListener) -> SignalTypes.Connection)
	& ((PresentationContext, ResourceEventDescriptor, ResourceListener) -> SignalTypes.Connection)
	& ((PresentationContext, ResourceEventDescriptor, string | ActorScopedId, ResourceListener) -> SignalTypes.Connection)
	& ((PresentationContext, HintEventDescriptor, HintListener) -> SignalTypes.Connection)
	& ((
		PresentationContext,
		HintEventDescriptor,
		string | ActorScopedId | AnyHintId,
		HintListener
	) -> SignalTypes.Connection)

export type TagWatchCallback = (ActorTypes.ActiveTagSnapshot?) -> ()
export type ActionWatchCallback = (ActorTypes.ActionSnapshot?) -> ()
export type ResourceWatchCallback = (ActorTypes.ResourceSnapshot?) -> ()
export type ModelWatchCallback = (Model?) -> ()

export type PresentationWatch =
	((PresentationContext, TagActiveDescriptor, string, TagWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, ActionActiveDescriptor, ActionWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, ResourceCurrentDescriptor, string, ResourceWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, ActorModelDescriptor, ModelWatchCallback) -> SignalTypes.Connection)

export type PresentationContext = {
	read entry: PresentationEntry,
	read actor: ActorTypes.ActorView?,
	read Own: (self: PresentationContext, cleanup: () -> ()) -> (),
	read Finish: (self: PresentationContext) -> (),
	read IsActive: (self: PresentationContext) -> boolean,
	read On: PresentationOn,
	read Watch: PresentationWatch,
}

export type PresentationEntryBinding = {
	read event: PresentationEventDescriptor,
	read id: string,
}

export type PresentationStateEntryBinding = {
	read state: PresentationStateEntryDescriptor,
	read id: string,
}

export type PresentationDefinitionEntry = PresentationEntryBinding | PresentationStateEntryBinding

export type PresentationDefinition = {
	read id: string,
	read entry: PresentationDefinitionEntry,
	read create: (PresentationContext) -> (),
}

export type PresentationEventCatalog = { [PresentationEventDescriptor]: { [string]: { PresentationDefinition } } }

export type PresentationStateCatalog = {
	[PresentationStateEntryDescriptor]: { [string]: { PresentationDefinition } },
}

export type PresentationCatalog = {
	read events: PresentationEventCatalog,
	read states: PresentationStateCatalog,
}

export type PresentationActionAssociation = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read sequenceId: number?,
}

export type PresentationSubscriptionEnvironment = {
	read IsEligible: (ActorTypes.ActorView) -> boolean,
	read TrackActor: (ActorTypes.ActorView, () -> ()) -> () -> (),
	read IsStateReady: (ActorTypes.ActorView) -> boolean,
	read ObserveReadiness: (ActorTypes.ActorView, () -> ()) -> () -> (),
}

export type PresentationSubscriptionHost = {
	read IsActive: () -> boolean,
	read GetActionAssociation: () -> PresentationActionAssociation?,
	read Fail: (PresentationEntry, string) -> (),
}

return {}
