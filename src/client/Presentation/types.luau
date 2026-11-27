--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local RequestTypes = require(script.Parent.Parent.ActionRequest.types)
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

export type PredictedActionEntry = {
	read source: "ActionPrediction",
	read event: "RequestAdmitted",
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read originalStartKey: string,
	read parameters: any?,
}

export type PredictedHintEntry = {
	read source: "HintPrediction",
	read event: "Received",
	read actor: ActorTypes.ActorView?,
	read hintId: string,
	read payload: any?,
}

export type TagActiveDescriptor = { read source: "Tag", read state: "Active" }
export type ActionActiveDescriptor = { read source: "Action", read state: "Active" }
export type ResourceCurrentDescriptor = { read source: "Resource", read state: "Current" }
export type ActorModelDescriptor = { read source: "Actor", read state: "Model" }
export type LocalPredictionDescriptor = { read source: "Action", read state: "LocalPrediction" }
export type PresentationStateEntryDescriptor = TagActiveDescriptor | ActionActiveDescriptor

export type PresentationStateDescriptor =
	PresentationStateEntryDescriptor
	| ResourceCurrentDescriptor
	| ActorModelDescriptor
	| LocalPredictionDescriptor

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
export type PresentationEntry = PresentationEntryEvent | PresentationStateEntry | PredictedActionEntry | PredictedHintEntry

export type LocalPredictionStatus = "Admitted" | "Accepted" | "Rejected" | "Unknown"

export type LocalPredictionFollowUp = {
	read requestKey: string,
	read status: LocalPredictionStatus,
	read reason: string?,
}

export type LocalPredictionInputDecision = {
	read transition: ActionTypes.LocalInputTransition,
	read reason: string?,
	read eventOrdinal: number,
}

export type LocalPredictionSnapshot = {
	read startStatus: LocalPredictionStatus,
	read startReason: string?,
	read sequenceId: number?,
	read inputTransitions: { LocalPredictionInputDecision },
	read lastStop: LocalPredictionFollowUp?,
	read lastInterrupt: LocalPredictionFollowUp?,
}

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
export type LocalPredictionWatchCallback = (LocalPredictionSnapshot) -> ()

export type PresentationWatch =
	((PresentationContext, TagActiveDescriptor, string, TagWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, ActionActiveDescriptor, ActionWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, ResourceCurrentDescriptor, string, ResourceWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, ActorModelDescriptor, ModelWatchCallback) -> SignalTypes.Connection)
	& ((PresentationContext, LocalPredictionDescriptor, LocalPredictionWatchCallback) -> SignalTypes.Connection)

export type PresentationContext = {
	read entry: PresentationEntry,
	read actor: ActorTypes.ActorView?,
	read Own: (self: PresentationContext, cleanup: () -> ()) -> (),
	read Finish: (self: PresentationContext) -> (),
	read IsActive: (self: PresentationContext) -> boolean,
	read On: PresentationOn,
	read Watch: PresentationWatch,
	read PredictHint: (
		self: PresentationContext,
		hintId: string,
		target: ActorTypes.ActorView?,
		payload: any?
	) -> (boolean, string?),
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
	read predict: boolean?,
	read create: (PresentationContext) -> (),
}

export type ActionPredictionResourceRequirement = {
	read min: number?,
	read max: number?,
	read minPercent: number?,
	read maxPercent: number?,
}

export type ActionPredictionResourceCost = {
	read amount: number?,
	read percent: number?,
	read multiplierProperty: string?,
}

export type ActionPredictionCheckContext = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read originalStartKey: string,
	read parameters: any?,
}

export type ActionPredictionPolicy = {
	read requiredTags: { string }?,
	read blockedTags: { string }?,
	read resourceRequirements: { [string]: ActionPredictionResourceRequirement }?,
	read costs: { [string]: number | ActionPredictionResourceCost }?,
	read canPredictStart: ((ActionPredictionCheckContext) -> boolean?)?,
}

export type ActionPredictionPolicies = { [string]: ActionPredictionPolicy }

export type CompiledActionPredictionPolicy = {
	read actionId: string,
	read requiredTags: { string },
	read blockedTags: { string },
	read resourceIds: { string },
	read resourceRequirements: { [string]: ActionPredictionResourceRequirement },
	read costs: { [string]: ActionPredictionResourceCost },
	read canPredictStart: ((ActionPredictionCheckContext) -> boolean?)?,
}

export type ActionPredictionPolicyCatalog = { [string]: CompiledActionPredictionPolicy }

export type HintPredictionPolicy = {
	read actorIdField: string,
	read sequenceIdField: string,
}

export type HintPredictionPolicies = { [string]: HintPredictionPolicy }
export type HintPredictionPolicyCatalog = { [string]: HintPredictionPolicy }

export type ActionPredictionEstimate = "LikelyAllowed" | "LikelyBlocked" | "Unknown"

export type PresentationEventCatalog = { [PresentationEventDescriptor]: { [string]: { PresentationDefinition } } }

export type PresentationStateCatalog = {
	[PresentationStateEntryDescriptor]: { [string]: { PresentationDefinition } },
}

export type PresentationPredictionCatalog = {
	read policies: ActionPredictionPolicyCatalog,
	read definitions: { [string]: { PresentationDefinition } },
	read hintPolicies: HintPredictionPolicyCatalog,
	read hintDefinitions: { [string]: { PresentationDefinition } },
}

export type PresentationCatalog = {
	read events: PresentationEventCatalog,
	read states: PresentationStateCatalog,
	read predictions: PresentationPredictionCatalog,
}

export type PresentationActionAssociation = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read sequenceId: number?,
	read awaitingStart: boolean?,
}

export type PresentationPredictionLink = {
	read GetAssociation: () -> PresentationActionAssociation,
	read GetSnapshot: () -> (LocalPredictionSnapshot, number),
	read Observe: (() -> ()) -> () -> (),
	read PredictHint: (string, ActorTypes.ActorView?, any?) -> (boolean, string?),
}

export type PresentationPredictionPort = {
	read ObserveActionRequest: ((ActionTypes.ActionRequestEvent) -> ()) -> () -> (),
	read ObserveStartPayloads: ((RequestTypes.ActionStartPayload) -> ()) -> () -> (),
	read Delay: ((number, () -> ()) -> () -> ())?,
	read Measure: (() -> number)?,
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
	read GetPrediction: () -> PresentationPredictionLink?,
	read Fail: (PresentationEntry, string) -> (),
}

return {}
