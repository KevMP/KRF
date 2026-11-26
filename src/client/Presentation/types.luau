--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)

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

export type PresentationContext = {
	read entry: PresentationEntryEvent,
	read actor: ActorTypes.ActorView?,
	read Own: (self: PresentationContext, cleanup: () -> ()) -> (),
	read Finish: (self: PresentationContext) -> (),
	read IsActive: (self: PresentationContext) -> boolean,
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

return {}
