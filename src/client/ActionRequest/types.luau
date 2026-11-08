--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)

local types = {}

export type ActionRequestOrigin = "Input" | "Direct"
export type ActionRequestKind = "Start" | "Stop" | "Interrupt"

-- The already resolved original Action. I5 never re-resolves a route or slot.
export type ActionStartSelection = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read origin: ActionRequestOrigin,
	read inputTimestamp: number?,
	-- Framework-only correlation assignment; no consumer code runs here.
	read Reserve: ((ActionRequestAdmission) -> ())?,
}

-- Immutable correlation reserved before egress. Follow-ups carry their original Start's
-- Actor and Action even after that ActorView becomes unavailable.
export type ActionRequestAdmission = {
	read kind: ActionRequestKind,
	read incarnation: number,
	read requestId: number,
	read originalStartRequestId: number,
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read origin: ActionRequestOrigin,
	read inputTimestamp: number?,
	read requestKey: unknown?,
	read originalStartKey: unknown?,
}

-- Accepted carries the real server sequenceId only for Start. Unknown means it may have executed.
export type ActionRequestOutcome = {
	read admission: ActionRequestAdmission,
	read status: "Accepted" | "Rejected" | "Unknown",
	read sequenceId: number?,
	read reason: string?,
}

-- Narrow private N9 port; installation adapts the real ClientCommandRuntime.
export type ActionRequestCommandPort = {
	read SendAdmitted: (
		commandId: string,
		actor: ActorTypes.ActorView?,
		request: any,
		admit: NetworkingTypes.CommandAdmission,
		committed: ((number) -> ())?
	) -> (number?, string?),
	read ObserveOutcomes: (observer: (NetworkingTypes.CommandResult) -> ()) -> () -> (),
	read ObserveCapacity: ((observer: () -> ()) -> () -> ())?,
	read ObserveExpirations: ((observer: (number, string) -> ()) -> () -> ())?,
	read AfterEgress: ((callback: () -> ()) -> ())?,
}

export type ActionFollowUpIntent = {
	read originalStartRequestId: number,
	read kind: "Stop" | "Interrupt",
	read payload: string?,
	read reason: ActionRequestTypes.ActionInputInterruptReason?,
	read OnAdmitted: ((ActionRequestAdmission) -> ())?,
}

export type ClientActionRequestOptions = {
	commands: ActionRequestCommandPort,
	incarnation: number,
	maxOriginalStarts: number?,
}

export type ClientActionRequestRuntime = {
	-- A non-nil ID means locally admitted, not Accepted. Nil means nothing was sent.
	Start: (self: ClientActionRequestRuntime, selection: ActionStartSelection, parameters: any?) -> (number?, string?),
	Stop: (
		self: ClientActionRequestRuntime,
		originalStartRequestId: number,
		parameters: any?,
		automatic: boolean?,
		committed: ((ActionRequestAdmission) -> ())?
	) -> (number?, string?),
	Interrupt: (
		self: ClientActionRequestRuntime,
		originalStartRequestId: number,
		reason: ActionRequestTypes.ActionInputInterruptReason,
		automatic: boolean?,
		committed: ((ActionRequestAdmission) -> ())?
	) -> (number?, string?),
	GetOriginalStart: (self: ClientActionRequestRuntime, requestId: number) -> ActionRequestAdmission?,
	-- I6 releases input follow-up authority; pending command correlation is unaffected.
	Retire: (self: ClientActionRequestRuntime, originalStartRequestId: number) -> (),
	-- Bounded, non-yielding framework observers. They run after the packet is staged or
	-- physically attempted and can never veto, delay or reorder egress.
	ObserveAdmissions: (self: ClientActionRequestRuntime, observer: (ActionRequestAdmission) -> ()) -> () -> (),
	ObserveOutcomes: (self: ClientActionRequestRuntime, observer: (ActionRequestOutcome) -> ()) -> () -> (),
	StageDecision: (self: ClientActionRequestRuntime, originalStartRequestId: number, callback: () -> ()) -> (),
	_GetRetainedCountForTests: (self: ClientActionRequestRuntime) -> number,
	Destroy: (self: ClientActionRequestRuntime) -> (),
}

export type ClientActionRequestRuntimeModule = {
	read new: (
		catalog: ActionRequestTypes.ActionRequestCatalog,
		options: ClientActionRequestOptions
	) -> ClientActionRequestRuntime,
}

return types
