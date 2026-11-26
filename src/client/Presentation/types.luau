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

export type PresentationContext = {
	read entry: PresentationEntryEvent,
	read actor: ActorTypes.ActorView?,
	read Own: (self: PresentationContext, cleanup: () -> ()) -> (),
	read Finish: (self: PresentationContext) -> (),
	read IsActive: (self: PresentationContext) -> boolean,
	read On: PresentationOn,
}

export type PresentationEntryBinding = {
	read event: PresentationEventDescriptor,
	read id: string,
}

export type PresentationDefinition = {
	read id: string,
	read entry: PresentationEntryBinding,
	read create: (PresentationContext) -> (),
}

export type PresentationCatalog = { [PresentationEventDescriptor]: { [string]: { PresentationDefinition } } }

export type PresentationActionAssociation = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read sequenceId: number?,
}

export type PresentationSubscriptionEnvironment = {
	read IsEligible: (ActorTypes.ActorView) -> boolean,
	read TrackActor: (ActorTypes.ActorView, () -> ()) -> () -> (),
}

export type PresentationSubscriptionHost = {
	read IsActive: () -> boolean,
	read GetActionAssociation: () -> PresentationActionAssociation?,
	read Fail: (PresentationEntryEvent, string) -> (),
}

return {}
