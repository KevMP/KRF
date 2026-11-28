--!strict
-- Public package entrypoint. Wally mounts KRF behind a link module without children,
-- so game code reaches the framework through this module instead of instance paths.
-- Members load on first access: a client never requires server modules it does not use.
local ServerTypes = require(script.server.types)
local ActorTypes = require(script.server.Actor.types)
local ControllerTypes = require(script.server.Controller.types)
local TagTypes = require(script.server.Tags.types)
local ResourceTypes = require(script.server.Resource.types)
local PropertyTypes = require(script.server.Property.types)
local ActionTypes = require(script.server.Action.types)
local ReplicationTypes = require(script.server.Replication.types)
local NetworkingTypes = require(script.server.Networking.types)
local ActionRequestTypes = require(script.server.ActionRequest.types)
local SharedNetworkingTypes = require(script.shared.Networking.types)
local SharedActionRequestTypes = require(script.shared.ActionRequest.types)
local ClientTypes = require(script.client.types)
local PresentationTypes = require(script.client.Presentation.types)
local ViewTypes = require(script.client.Actor.types)
local ClientActionTypes = require(script.client.Action.types)
local ClientNetworkingTypes = require(script.client.Networking.types)
local ControlTypes = require(script.client.Controls.types)
local InputTypes = require(script.client.Input.types)
local SignalTypes = require(script.shared.Signal.types)

-- Signals
export type Event<T...> = SignalTypes.Event<T...>
export type Connection = SignalTypes.Connection
export type Signal<T...> = SignalTypes.Signal<T...>
export type OwnedSignals = SignalTypes.OwnedSignals

-- Server startup and authoring
export type ServerStartConfig = ServerTypes.ServerStartConfig
export type ServerStartupFailure = ServerTypes.StartupFailure
export type Actor = ActorTypes.Actor
export type RegisterActorOpts = ActorTypes.RegisterActorOpts
export type Controller = ControllerTypes.Controller
export type ControllerDefinition = ControllerTypes.ControllerDef

export type TagDefinition = TagTypes.TagDefinition
export type TagVisibility = TagTypes.TagVisibility
export type PropertyModifier = TagTypes.PropertyModifier
export type TagApplication = TagTypes.TagApplication
export type AddTagOptions = TagTypes.AddTagOptions
export type TagController = TagTypes.TagController
export type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot

export type ResourceDefinition = ResourceTypes.ResourceDefinition
export type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition
export type ResourceVisibility = ResourceTypes.ResourceVisibility
export type ResourceRegenDefinition = ResourceTypes.ResourceRegenDefinition
export type ResourceChange = ResourceTypes.ResourceChange
export type ResourceController = ResourceTypes.ResourceController

export type PropertyDefinition = PropertyTypes.PropertyDefinition
export type PropertyChange = PropertyTypes.PropertyChange
export type PropertyController = PropertyTypes.PropertyController

export type ActionDefinition = ActionTypes.ActionDefinition
export type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
export type ActionFactory = ActionTypes.ActionFactory
export type ActionVisibility = ActionTypes.ActionVisibility
export type OnCanStart = ActionTypes.OnCanStart
export type OnStart = ActionTypes.OnStart
export type OnStopRequested = ActionTypes.OnStopRequested
export type OnUpdate = ActionTypes.OnUpdate
export type OnEnd = ActionTypes.OnEnd
export type OnInterrupt = ActionTypes.OnInterrupt
export type CanBeInterruptedBy = ActionTypes.CanBeInterruptedBy
export type ActionStartContext = ActionTypes.ActionStartContext
export type ActionExecutionContext = ActionTypes.ActionExecutionContext
export type ActionInterruptionContext = ActionTypes.ActionInterruptionContext
export type ActionStopRequest = ActionTypes.ActionStopRequest
export type LockClaim = ActionTypes.LockClaim
export type ActionResourceRequirement = ActionTypes.ActionResourceRequirement
export type ActionResourceCost = ActionTypes.ActionResourceCost
export type ActionTagApplication = ActionTypes.ActionTagApplication
export type ActionTagApplicationOptions = ActionTypes.ActionTagApplicationOptions
export type ActionRequestAccepted = ActionTypes.ActionRequestAccepted
export type ActionRequestRejected = ActionTypes.ActionRequestRejected
export type ActionRequestResult = ActionTypes.ActionRequestResult
export type ActionLifecycleEvent = ActionTypes.ActionLifecycleEvent
export type ActionInterruptedEvent = ActionTypes.ActionInterruptedEvent
export type ActionController = ActionTypes.ActionController
export type ActionControlAuthority = ActionRequestTypes.ActionControlAuthority
export type ActionRequestSchemas = SharedActionRequestTypes.ActionRequestSchemas

export type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
export type LoadedReplicationDomainDefinition = ReplicationTypes.LoadedReplicationDomainDefinition
export type ReplicationAudience = ReplicationTypes.ReplicationAudience
export type CommandDefinition = NetworkingTypes.CommandDefinition
export type LoadedCommandDefinition = NetworkingTypes.LoadedCommandDefinition
export type CommandContext = NetworkingTypes.CommandContext
export type CommandHandlerResult = NetworkingTypes.CommandHandlerResult
export type HintDefinition = NetworkingTypes.HintDefinition
export type LoadedHintDefinition = NetworkingTypes.LoadedHintDefinition
export type HintContext = NetworkingTypes.HintContext
export type Schema = SharedNetworkingTypes.Schema
export type SchemaDefinition = SharedNetworkingTypes.SchemaDefinition

-- Client startup and views
export type ClientInitConfig = ClientTypes.ClientInitConfig
export type ClientStartupFailure = ClientTypes.StartupFailure
export type PresentationDefinition = PresentationTypes.PresentationDefinition
export type PresentationEntryBinding = PresentationTypes.PresentationEntryBinding
export type PresentationStateEntryBinding = PresentationTypes.PresentationStateEntryBinding
export type PresentationDefinitionEntry = PresentationTypes.PresentationDefinitionEntry
export type PresentationEntry = PresentationTypes.PresentationEntry
export type PresentationEntryEvent = PresentationTypes.PresentationEntryEvent
export type PresentationStateEntry = PresentationTypes.PresentationStateEntry
export type PresentationEventDescriptor = PresentationTypes.PresentationEventDescriptor
export type PresentationStateDescriptor = PresentationTypes.PresentationStateDescriptor
export type PresentationStateEntryDescriptor = PresentationTypes.PresentationStateEntryDescriptor
export type PresentationContext = PresentationTypes.PresentationContext
export type PresentationOn = PresentationTypes.PresentationOn
export type PresentationWatch = PresentationTypes.PresentationWatch
export type TagStateEntry = PresentationTypes.TagStateEntry
export type ActionStateEntry = PresentationTypes.ActionStateEntry
export type ActionEntryEvent = PresentationTypes.ActionEntryEvent
export type TagEntryEvent = PresentationTypes.TagEntryEvent
export type ResourceEntryEvent = PresentationTypes.ResourceEntryEvent
export type HintEntryEvent = PresentationTypes.HintEntryEvent
export type PredictedActionEntry = PresentationTypes.PredictedActionEntry
export type PredictedHintEntry = PresentationTypes.PredictedHintEntry
export type ActionPredictionPolicy = PresentationTypes.ActionPredictionPolicy
export type ActionPredictionPolicies = PresentationTypes.ActionPredictionPolicies
export type ActionPredictionCheckContext = PresentationTypes.ActionPredictionCheckContext
export type ActionPredictionResourceRequirement = PresentationTypes.ActionPredictionResourceRequirement
export type ActionPredictionResourceCost = PresentationTypes.ActionPredictionResourceCost
export type HintPredictionPolicy = PresentationTypes.HintPredictionPolicy
export type HintPredictionPolicies = PresentationTypes.HintPredictionPolicies
export type LocalPredictionDescriptor = PresentationTypes.LocalPredictionDescriptor
export type LocalPredictionStatus = PresentationTypes.LocalPredictionStatus
export type LocalPredictionSnapshot = PresentationTypes.LocalPredictionSnapshot
export type LocalPredictionFollowUp = PresentationTypes.LocalPredictionFollowUp
export type LocalPredictionInputDecision = PresentationTypes.LocalPredictionInputDecision
export type AnimationPlayOptions = PresentationTypes.AnimationPlayOptions
export type AnimationPlayback = PresentationTypes.AnimationPlayback
export type PreloadDescriptor = PresentationTypes.PreloadDescriptor
export type PreloadItem = PresentationTypes.PreloadItem
export type PreloadReport = PresentationTypes.PreloadReport
export type ActorView = ViewTypes.ActorView
export type ActorViewRegistry = ViewTypes.ActorViewRegistry
export type DomainView = ViewTypes.DomainView
export type DomainChange = ViewTypes.DomainChange
export type DomainChangeSource = ViewTypes.DomainChangeSource
export type DomainMembershipChange = ViewTypes.DomainMembershipChange
export type TagsView = ViewTypes.TagsView
export type ActiveTagSnapshot = ViewTypes.ActiveTagSnapshot
export type ResourcesView = ViewTypes.ResourcesView
export type ResourceSnapshot = ViewTypes.ResourceSnapshot
export type ResourceViewChange = ViewTypes.ResourceViewChange
export type ActionsView = ViewTypes.ActionsView
export type ActionSnapshot = ViewTypes.ActionSnapshot
export type ActionInputPolicy = ClientActionTypes.ActionInputPolicy
export type ActionInputPolicies = ClientActionTypes.ActionInputPolicies
export type ActionInputContext = ClientActionTypes.ActionInputContext
export type ActionRequestEvent = ClientActionTypes.ActionRequestEvent
export type ActionInputInterruptReason = SharedActionRequestTypes.ActionInputInterruptReason
export type RouteKey = ClientActionTypes.RouteKey
export type ResolvedAction = ClientActionTypes.ResolvedAction
export type ControlProfile = ClientActionTypes.ControlProfile
export type RouteQuerySnapshot = ClientActionTypes.RouteQuerySnapshot
export type ProfileSourceSnapshot = ClientActionTypes.ProfileSourceSnapshot
export type ClientActionRuntime = ClientActionTypes.ClientActionRuntime
export type ClientControls = ControlTypes.ClientControls
export type ControlChangeSet = ControlTypes.ControlChangeSet
export type InputRuntime = InputTypes.InputRuntime
export type InputSourceDefinition = InputTypes.InputSourceDefinition
export type InputDefinition = InputTypes.InputDefinition
export type BindingDefinition = InputTypes.BindingDefinition
export type ContextDefinition = InputTypes.ContextDefinition
export type InputSnapshot = InputTypes.InputSnapshot
export type ContextSnapshot = InputTypes.ContextSnapshot
export type BindingSnapshot = InputTypes.BindingSnapshot
export type SemanticInputEvent = InputTypes.SemanticInputEvent
export type GestureKind = InputTypes.GestureKind
export type GestureDefinitions = InputTypes.GestureDefinitions
export type TapDefinition = InputTypes.TapDefinition
export type HoldDefinition = InputTypes.HoldDefinition
export type DoubleTapDefinition = InputTypes.DoubleTapDefinition
export type DoubleTapArbitration = InputTypes.DoubleTapArbitration
export type GestureSnapshot = InputTypes.GestureSnapshot
export type GestureEvent = InputTypes.GestureEvent
export type SequenceDefinition = InputTypes.SequenceDefinition
export type SequenceStep = InputTypes.SequenceStep
export type WatchedToken = InputTypes.WatchedToken
export type SequenceGroupDefinition = InputTypes.SequenceGroupDefinition
export type SequenceSnapshot = InputTypes.SequenceSnapshot
export type SequenceMatchEvent = InputTypes.SequenceMatchEvent
export type RecognizerDefinition = InputTypes.RecognizerDefinition
export type RecognizerContext = InputTypes.RecognizerContext
export type RecognizerEvent = InputTypes.RecognizerEvent
export type RecognitionScalar = InputTypes.RecognitionScalar
export type CustomMatch = InputTypes.CustomMatch
export type RecognizerSnapshot = InputTypes.RecognizerSnapshot
export type CustomRecognitionEvent = InputTypes.CustomRecognitionEvent
export type CommandRuntime = ClientNetworkingTypes.CommandRuntime
export type CommandResult = ClientNetworkingTypes.CommandResult
export type HintReceived = ClientNetworkingTypes.HintReceived

type KRF = {
	read Server: typeof(require(script.server)),
	read Client: typeof(require(script.client)),
	read Schema: typeof(require(script.shared.Networking.Schema)),
	read Signal: typeof(require(script.shared.Signal.SignalModule)),
	read OwnedSignals: typeof(require(script.shared.Signal.OwnedSignals)),

	read ActorRuntime: typeof(require(script.server.Actor.ActorRuntime)),
	read ActorRegistry: typeof(require(script.server.Actor.ActorRegistry)),
	read ControllerRegistry: typeof(require(script.server.Controller.ControllerRegistry)),
	read PropertyRegistry: typeof(require(script.server.Property.PropertyRegistry)),
	read TagRegistry: typeof(require(script.server.Tags.TagRegistry)),
	read ResourceRegistry: typeof(require(script.server.Resource.ResourceRegistry)),
	read ActionRegistry: typeof(require(script.server.Action.ActionRegistry)),
	read ReplicationDomainRegistry: typeof(require(script.server.Replication.ReplicationDomainRegistry)),
	read CommandRegistry: typeof(require(script.server.Networking.CommandRegistry)),
	read CommandAuthorization: typeof(require(script.server.Networking.CommandAuthorization)),
	read HintRegistry: typeof(require(script.server.Networking.HintRegistry)),
	read HintAuthorization: typeof(require(script.server.Networking.HintAuthorization)),
	read ServerHintRuntime: typeof(require(script.server.Networking.HintRuntime)),

	read PresentationEvents: typeof(require(script.client.Presentation.PresentationEvents)),
	read PresentationStates: typeof(require(script.client.Presentation.PresentationStates)),
	read Animations: typeof(require(script.client.Presentation.Animations)),
	read Assets: typeof(require(script.client.Presentation.Assets)),
	read ActorViewRegistry: typeof(require(script.client.Actor.ActorViewRegistry)),
	read ClientActionRuntime: typeof(require(script.client.Action.ClientActionRuntime)),
	read ClientControls: typeof(require(script.client.Controls.ClientControls)),
	read InputRuntime: typeof(require(script.client.Input.InputRuntime)),
	read CommandRuntime: typeof(require(script.client.Networking.CommandRuntime)),
	read ClientHintRuntime: typeof(require(script.client.Networking.HintRuntime)),
}

local MEMBERS: { [string]: ModuleScript } = {
	Server = script.server,
	Client = script.client,
	Schema = script.shared.Networking.Schema,
	Signal = script.shared.Signal.SignalModule,
	OwnedSignals = script.shared.Signal.OwnedSignals,

	ActorRuntime = script.server.Actor.ActorRuntime,
	ActorRegistry = script.server.Actor.ActorRegistry,
	ControllerRegistry = script.server.Controller.ControllerRegistry,
	PropertyRegistry = script.server.Property.PropertyRegistry,
	TagRegistry = script.server.Tags.TagRegistry,
	ResourceRegistry = script.server.Resource.ResourceRegistry,
	ActionRegistry = script.server.Action.ActionRegistry,
	ReplicationDomainRegistry = script.server.Replication.ReplicationDomainRegistry,
	CommandRegistry = script.server.Networking.CommandRegistry,
	CommandAuthorization = script.server.Networking.CommandAuthorization,
	HintRegistry = script.server.Networking.HintRegistry,
	HintAuthorization = script.server.Networking.HintAuthorization,
	ServerHintRuntime = script.server.Networking.HintRuntime,

	PresentationEvents = script.client.Presentation.PresentationEvents,
	PresentationStates = script.client.Presentation.PresentationStates,
	Animations = script.client.Presentation.Animations,
	Assets = script.client.Presentation.Assets,
	ActorViewRegistry = script.client.Actor.ActorViewRegistry,
	ClientActionRuntime = script.client.Action.ClientActionRuntime,
	ClientControls = script.client.Controls.ClientControls,
	InputRuntime = script.client.Input.InputRuntime,
	CommandRuntime = script.client.Networking.CommandRuntime,
	ClientHintRuntime = script.client.Networking.HintRuntime,
}

table.freeze(MEMBERS)

-- Freezing both tables keeps the facade and its lookup from being replaced.
local lookup = table.freeze({
	__index = function(_: {}, key: unknown): unknown
		local member: ModuleScript? = if type(key) == "string" then MEMBERS[key] else nil

		if member == nil then
			error(`KRF has no public member '{tostring(key)}'`, 2)
		end

		return (require :: any)(member)
	end,
})

local KRF = table.freeze(setmetatable({}, lookup))

return (KRF :: any) :: KRF
