--!strict

export type ActionVisibility = "ServerOnly" | "ClientVisible"

local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

export type ActionStartContext = {
	read actor: ActorTypes.Actor,
	read actionId: string,
	read parameters: any?,
}

export type ActionStopRequest = {
	parameters: any?,
}

export type ActionExecutionContext = {
	read actor: ActorTypes.Actor,
	read actionId: string,
	read sequenceId: number,
	read parameters: any?,
	read IsActive: (self: ActionExecutionContext) -> boolean,
	read End: (self: ActionExecutionContext) -> (boolean, string?),
	read Interrupt: (self: ActionExecutionContext, reason: string) -> (boolean, string?),
}

export type ActionRequestAccepted = { accepted: true, sequenceId: number }
export type ActionRequestRejected = { accepted: false, reason: string }
export type ActionRequestResult = ActionRequestAccepted | ActionRequestRejected

export type ActionLifecycleEvent = {
	actor: ActorTypes.Actor,
	actionId: string,
	sequenceId: number,
}

export type ActionInterruptedEvent = ActionLifecycleEvent & { reason: string }

export type ActionController = {
	Destroy: (self: ActionController) -> (),
	SetGrants: (self: ActionController, sourceId: string, actionIds: { string }) -> (boolean, string?),
	IsActionGranted: (self: ActionController, actionId: string) -> boolean,
	GetGrantedActions: (self: ActionController) -> { string },
	RequestAction: (self: ActionController, actionId: string, parameters: any?) -> ActionRequestResult,
	RequestStop: (self: ActionController, sequenceId: number, parameters: any?) -> (boolean, string?),
	EndAction: (self: ActionController, sequenceId: number) -> (boolean, string?),
	InterruptAction: (self: ActionController, sequenceId: number, reason: string) -> (boolean, string?),
	OnActionGrantChanged: SignalTypes.Event<ActorTypes.Actor, string, boolean>,
	OnActionStarted: SignalTypes.Event<ActionLifecycleEvent>,
	OnActionEnded: SignalTypes.Event<ActionLifecycleEvent>,
	OnActionInterrupted: SignalTypes.Event<ActionInterruptedEvent>,
}

export type OnCanStart = (ActionStartContext) -> (boolean, string?)
export type OnStart = (ActionExecutionContext) -> ()
export type OnStopRequested = (ActionExecutionContext, ActionStopRequest) -> ()
export type OnUpdate = (...any) -> ()
export type OnEnd = (ActionExecutionContext) -> ()
export type OnInterrupt = (ActionExecutionContext, string) -> ()
export type CanBeInterruptedBy = (...any) -> boolean

export type ActionDefinition = {
	id: string,
	visibility: ActionVisibility,
	autoGrant: boolean?,
	requiredTags: { string }?,
	blockedTags: { string }?,
	costs: { [string]: number }?,
	locks: { string }?,
	interruptibleBy: { string }?,
	onCanStart: OnCanStart?,
	onStart: OnStart?,
	onStopRequested: OnStopRequested?,
	onUpdate: OnUpdate?,
	onEnd: OnEnd?,
	onInterrupt: OnInterrupt?,
	canBeInterruptedBy: CanBeInterruptedBy?,
}

export type ActionFactory = () -> ActionDefinition

export type InternalActionImplementation = {
	onCanStart: OnCanStart?,
	onStart: OnStart?,
	onStopRequested: OnStopRequested?,
	onUpdate: OnUpdate?,
	onEnd: OnEnd?,
	onInterrupt: OnInterrupt?,
	canBeInterruptedBy: CanBeInterruptedBy?,
}

export type LoadedActionDefinition = {
	read id: string,
	read visibility: ActionVisibility,
	read autoGrant: boolean,
	read requiredTags: { string },
	read blockedTags: { string },
	read costs: { [string]: number },
	read locks: { string },
	read interruptibleBy: { string },
}

export type PreparedActionCatalog = {
	definitionsById: { [string]: LoadedActionDefinition },
	orderedDefinitions: { LoadedActionDefinition },
	factoriesById: { [string]: ActionFactory },
}

export type ActionRegistry = {
	Get: (actionId: string) -> LoadedActionDefinition?,
	GetAll: () -> { LoadedActionDefinition },
	GetAllById: () -> { [string]: LoadedActionDefinition },
	IsLoaded: () -> boolean,
}

export type InternalActionRegistry = ActionRegistry & {
	Load: (
		factories: { ActionFactory },
		preparedTagIds: { [string]: boolean },
		preparedResourceIds: { [string]: boolean }
	) -> (boolean, string?),
	Prepare: (
		factories: { ActionFactory },
		preparedTagIds: { [string]: boolean },
		preparedResourceIds: { [string]: boolean }
	) -> (PreparedActionCatalog?, string?),
	Publish: (prepared: PreparedActionCatalog) -> (boolean, string?),
	CreateExecution: (actionId: string) -> (InternalActionImplementation?, string?),
	_resetForTests: () -> (),
}

return {}
