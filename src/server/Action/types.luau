--!strict

export type ActionVisibility = "ServerOnly" | "ClientVisible"

local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

export type ActionStartContext = {
	actor: ActorTypes.Actor,
	actionId: string,
	parameters: any?,
}

export type ActionStopRequest = {
	parameters: any?,
}

export type ActionExecutionContext = {
	actor: ActorTypes.Actor,
	actionId: string,
	sequenceId: number,
	parameters: any?,
	state: { [any]: any },
	OnStopRequested: SignalTypes.Event<ActionStopRequest>,
	IsActive: (self: ActionExecutionContext) -> boolean,
	End: (self: ActionExecutionContext) -> (boolean, string?),
	Interrupt: (self: ActionExecutionContext, reason: string) -> (boolean, string?),
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

export type ActionDefinition = {
	id: string,
	visibility: ActionVisibility,
	autoGrant: boolean?,
	requiredTags: { string }?,
	blockedTags: { string }?,
	costs: { [string]: number }?,
	locks: { string }?,
	interruptibleBy: { string }?,
	onCanStart: ((ActionStartContext) -> (boolean, string?))?,
	onStart: ((ActionExecutionContext) -> ())?,
	onUpdate: ((...any) -> ())?,
	onEnd: ((ActionExecutionContext) -> ())?,
	onInterrupt: ((ActionExecutionContext, string) -> ())?,
	canBeInterruptedBy: ((...any) -> boolean)?,
}

export type LoadedActionDefinition = ActionDefinition & {
	autoGrant: boolean,
	requiredTags: { string },
	blockedTags: { string },
	costs: { [string]: number },
	locks: { string },
	interruptibleBy: { string },
}

export type ActionRegistry = {
	Load: (
		definitions: { ActionDefinition },
		preparedTagIds: { [string]: boolean },
		preparedResourceIds: { [string]: boolean }
	) -> (boolean, string?),
	Get: (actionId: string) -> LoadedActionDefinition?,
	GetAll: () -> { LoadedActionDefinition },
	GetAllById: () -> { [string]: LoadedActionDefinition },
	IsLoaded: () -> boolean,
	_resetForTests: () -> (),
}

return {}
