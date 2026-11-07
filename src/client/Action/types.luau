--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Input.types)

export type RouteKey = InputTypes.RecognitionRouteKey
export type DispatchMode = "Exclusive" | "Independent"
export type ResolvedAction = { actionId: string, parameters: any? }

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

export type ClientActionRuntime = {
	read SetProfileSource: (ActorTypes.ActorView, string, ControlProfile) -> (boolean, string?),
	read RemoveProfileSource: (ActorTypes.ActorView, string) -> (boolean, string?),
	read SetControlledActor: (ActorTypes.ActorView?) -> (boolean, string?),
	read GetControlledActor: () -> ActorTypes.ActorView?,
	read GetEffectiveRoute: (ActorTypes.ActorView, RouteKey) -> RouteQuerySnapshot?,
	read GetProfileSources: (ActorTypes.ActorView) -> { ProfileSourceSnapshot },
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

export type ClientActionOwner = ClientActionRuntime & {
	CommitPreparedProfiles: (PreparedProfileGraph) -> (boolean, string?),
	ObserveSelection: ((ActionRouteSelection) -> ()) -> () -> (),
	ObserveRoutes: ((EffectiveRouteTransition) -> ()) -> () -> (),
	PrepareControlledActor: (ActorTypes.ActorView?) -> (PreparedActorSwitch?, string?),
	CommitControlledActor: (PreparedActorSwitch) -> (boolean, string?),
	PrepareProfiles: ({ ProfileUpdate }, InputTypes.InputGraphSnapshot?) -> (PreparedProfileGraph?, string?),
	Destroy: () -> (),
}

return {}
