--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Input.types)
local RequestTypes = require(script.Parent.Parent.ActionRequest.types)
local SharedRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

export type ActionRequestOperation = "Start" | "Stop" | "Interrupt"
export type LocalInputTransition = "GenuineRelease" | "ToggleOff" | "InvalidatedInterrupt" | "InvalidatedKeep"

export type OriginalActionIdentity = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read originalStartRequestId: number,
	read originalStartKey: string,
	read origin: "Input" | "Direct",
}

export type ObservationMetadata = { read eventOrdinal: number, read observedAt: number }

export type ActionRequestAdmitted = OriginalActionIdentity & ObservationMetadata & {
	read kind: "RequestAdmitted",
	read operation: ActionRequestOperation,
	read requestId: number,
	read requestKey: string,
	read inputOccurredAt: number?,
}

type OutcomeIdentity = OriginalActionIdentity & ObservationMetadata & {
	read kind: "RequestOutcome",
	read requestId: number,
	read requestKey: string,
	read reason: string?,
}

export type ActionRequestOutcome =
	OutcomeIdentity
	& (
		{ read operation: "Start", read status: "Accepted", read sequenceId: number }
		| { read operation: "Stop" | "Interrupt", read status: "Accepted", read sequenceId: nil }
		| { read operation: ActionRequestOperation, read status: "Rejected" | "Unknown", read sequenceId: nil }
	)

export type ActionInputTransition = OriginalActionIdentity & ObservationMetadata & {
	read kind: "InputTransition",
	read transition: LocalInputTransition,
	read reason: string?,
}

export type ActionRequestEvent = ActionRequestAdmitted | ActionRequestOutcome | ActionInputTransition

export type ActionObservationOwner = {
	Observe: ((ActionRequestEvent) -> ()) -> () -> (),
	SetInput: (ActionInputOwner?) -> (),
	SetRequests: (RequestTypes.ClientActionRequestRuntime) -> (),
	SetOrdinalForTests: (number) -> (),
	Destroy: () -> (),
}

export type RouteKey = InputTypes.RecognitionRouteKey
export type DispatchMode = "Exclusive" | "Independent"
export type ResolvedAction = { actionId: string, parameters: any? }

export type ActionInputActivation = "OneShot" | "WhileDown" | "Toggle"
export type InvalidationBehavior = "Interrupt" | "Keep"

export type ActionInputContext = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read routeKey: RouteKey?,
	read resolvedParameters: any?,
	read originalStartRequestId: number?,
	read input: InputTypes.RecognitionHoldOwner?,
}

export type ActionInputPolicy = {
	activation: ActionInputActivation?,
	onInvalidation: InvalidationBehavior?,
	startParameters: ((ActionInputContext) -> any?)?,
	stopParameters: ((ActionInputContext) -> any?)?,
}

export type ActionInputPolicies = { [string]: ActionInputPolicy }

export type CompiledActionInputPolicy = {
	read activation: ActionInputActivation,
	read onInvalidation: InvalidationBehavior,
	read startParameters: ((ActionInputContext) -> any?)?,
	read stopParameters: ((ActionInputContext) -> any?)?,
}

export type ActionInputCatalog = { [string]: CompiledActionInputPolicy }

export type RouteResolveContext = {
	read actor: ActorTypes.ActorView,
	read actorId: string,
	read key: RouteKey,
	read sourceId: string,
	read timestamp: number,
	read envelope: InputTypes.InputCandidateEnvelope,
	read candidate: InputTypes.RecognitionCandidate,
}

export type RouteTarget =
	{ kind: "Fixed", actionId: string }
	| { kind: "Dynamic", resolve: (RouteResolveContext) -> ResolvedAction? }

export type ActionRoute = {
	when: RouteKey,
	target: RouteTarget,
	requiredContexts: { string }?,
	dispatch: { mode: DispatchMode?, priority: number? }?,
}

export type ControlProfile = { priority: number?, routes: { ActionRoute } }

export type MappedRouteSnapshot = {
	read status: "Mapped",
	read sourceId: string,
	read priority: number,
	read targetKind: "Fixed" | "Dynamic",
	read actionId: string?,
	read dispatchMode: DispatchMode,
	read dispatchPriority: number,
	read requiredContexts: { string },
	read shadowedSources: { string },
	read version: number,
}

export type GatedRouteSnapshot = { read status: "Gated", read candidateSources: { string } }

export type RouteQuerySnapshot = MappedRouteSnapshot | GatedRouteSnapshot | { read status: "Unmapped" }

export type ProfileSourceSnapshot = { read sourceId: string, read priority: number, read routeCount: number }

export type ClientActionRoutes = {
	read SetProfileSource: (ActorTypes.ActorView, string, ControlProfile) -> (boolean, string?),
	read RemoveProfileSource: (ActorTypes.ActorView, string) -> (boolean, string?),
	read SetControlledActor: (ActorTypes.ActorView?) -> (boolean, string?),
	read GetControlledActor: () -> ActorTypes.ActorView?,
	read GetEffectiveRoute: (ActorTypes.ActorView, RouteKey) -> RouteQuerySnapshot?,
	read GetProfileSources: (ActorTypes.ActorView) -> { ProfileSourceSnapshot },
}

export type ActionDirectRequests = {
	read RequestAction: (ActorTypes.ActorView, string, any?) -> (number?, string?),
	read RequestStop: (number, any?) -> (number?, string?),
	read RequestInterrupt: (number, SharedRequestTypes.ActionInputInterruptReason) -> (number?, string?),
	read RetireRequest: (number) -> (boolean, string?),
}

export type ClientActionRuntime = ClientActionRoutes & ActionDirectRequests & {
	read OnActionRequest: SignalTypes.Event<ActionRequestEvent>,
}

export type ActionInputDecisionKind = "GenuineRelease" | "ToggleOff" | "InvalidatedInterrupt" | "InvalidatedKeep"

export type ActionInputDecision = {
	read kind: ActionInputDecisionKind,
	read original: RequestTypes.ActionRequestAdmission,
	read generation: number,
	read reason: string,
}

export type ActionInputOwner = ActionDirectRequests & {
	Select: (ActionRouteSelection, any?) -> (),
	Attach: (ActionInputRoutePort) -> (),
	Guard: ActorSwitchGuard,
	ObserveDecisions: ((ActionInputDecision) -> ()) -> () -> (),
	Destroy: () -> (),
}

-- Only metadata may be retained. Resolver parameters travel separately through
-- the synchronous private sink; I5 must validate/copy them before retention.
export type ActionRouteSelection = {
	read actor: ActorTypes.ActorView,
	read actorId: string,
	read sourceId: string,
	read routeVersion: number,
	read selectionGeneration: number,
	read key: RouteKey,
	read actionId: string,
	read envelope: InputTypes.InputCandidateEnvelope,
	read candidate: InputTypes.RecognitionCandidate,
	read holdOwner: InputTypes.RecognitionHoldOwner?,
}

export type EffectiveRouteTransition = {
	read actor: ActorTypes.ActorView,
	read key: RouteKey,
	read previous: RouteQuerySnapshot,
	read next: RouteQuerySnapshot,
	read reason: string,
	read invalidated: boolean?,
}

export type ActionInputRoutePort = {
	GetControlledActor: () -> ActorTypes.ActorView?,
	GetEffectiveRoute: (ActorTypes.ActorView, RouteKey) -> RouteQuerySnapshot?,
	ObserveRoutes: ((EffectiveRouteTransition) -> ()) -> () -> (),
}

export type ActorPublication = { actor: ActorTypes.ActorView? }

export type CoordinatedActorCommit = {
	input: InputTypes.PreparedInputUpdate,
	profiles: PreparedProfileGraph,
}

export type PreparedActorSwitch = { read token: unknown }
export type PreparedProfileGraph = { read token: unknown }
export type ProfileUpdate = { actor: ActorTypes.ActorView, sourceId: string, profile: ControlProfile? }

-- I6 prepares local retirement without sends. AfterCommit may hand the original
-- activation intents to I5 only after all local owners have published.
export type ActorSwitchRetirement = { Commit: () -> (), AfterCommit: () -> () }

-- Revision must change whenever the activation set changes, so a prepared switch
-- cannot publish past activations it did not retire. Stale retirements are dropped
-- without a release, so Prepare must not reserve anything.
export type ActorSwitchGuard = {
	Revision: () -> number,
	HasActive: () -> boolean,
	Prepare: ((ActorTypes.ActorView?, ActorTypes.ActorView?) -> (ActorSwitchRetirement?, string?))?,
}

export type ClientActionOwnerOptions = {
	OnDestroyed: (() -> ())?,
	Input: InputTypes.InputOwner,
	IsReady: () -> boolean,
	Sink: (ActionRouteSelection, any?) -> (),
	ReportFault: (string) -> (),
	ActivationGuard: ActorSwitchGuard?,
}

export type ClientActionOwner = ClientActionRoutes & {
	CommitControlledActorWithInput: (PreparedActorSwitch, CoordinatedActorCommit) -> (boolean, string?),
	ReleasePreparedProfiles: (PreparedProfileGraph) -> (),
	ReleaseControlledActor: (PreparedActorSwitch) -> (),
	CommitPreparedProfiles: (PreparedProfileGraph) -> (boolean, string?),
	ObserveSelection: ((ActionRouteSelection) -> ()) -> () -> (),
	ObserveRoutes: ((EffectiveRouteTransition) -> ()) -> () -> (),
	PrepareControlledActor: (ActorTypes.ActorView?, coordinated: boolean?) -> (PreparedActorSwitch?, string?),
	CommitControlledActor: (PreparedActorSwitch) -> (boolean, string?),
	PrepareProfiles: ({ ProfileUpdate }, InputTypes.InputGraphSnapshot?) -> (PreparedProfileGraph?, string?),
	Destroy: () -> (),
}

return {}
