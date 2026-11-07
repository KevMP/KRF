--!strict
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

export type BindingDefinition = {
	keyCode: Enum.KeyCode?,
	forward: Enum.KeyCode?,
	backward: Enum.KeyCode?,
	left: Enum.KeyCode?,
	right: Enum.KeyCode?,
	up: Enum.KeyCode?,
	down: Enum.KeyCode?,
	primaryModifier: Enum.KeyCode?,
	secondaryModifier: Enum.KeyCode?,
	pressedThreshold: number?,
	releasedThreshold: number?,
	scale: number?,
	vector2Scale: Vector2?,
	vector3Scale: Vector3?,
	responseCurve: number?,
	clampMagnitudeToOne: boolean?,
	pointerIndex: number?,
	uiButton: GuiButton?,
	uiModifier: GuiButton?,
	displayName: string?,
	displayImage: Content?,
}

export type ContextDefinition = { priority: number, sink: boolean }

export type InputDefinition = {
	context: string,
	type: Enum.InputActionType,
	displayName: string?,
	bindings: { [string]: BindingDefinition },
}

export type InputSourceDefinition = {
	read priority: number?,
	read contexts: { [string]: ContextDefinition }?,
	read inputs: { [string]: InputDefinition }?,
	read bindingOverrides: { [string]: { [string]: BindingDefinition } }?,
	read gestures: { [string]: GestureDefinitions }?,
	read sequences: { [string]: SequenceDefinition }?,
	read sequenceGroups: { [string]: SequenceGroupDefinition }?,
	read recognizers: { [string]: RecognizerDefinition }?,
}

export type InputSequenceStep = { inputId: string, kind: "Pressed" | GestureKind }
export type CustomSequenceStep = { recognizerId: string, kind: "Custom" }
export type SequenceStep = string | InputSequenceStep | CustomSequenceStep
export type WatchedToken = InputSequenceStep | CustomSequenceStep

export type SequenceDefinition = {
	steps: { SequenceStep },
	maxGapSeconds: number?,
	maxTotalSeconds: number?,
	scope: { string }?,
	watchedTokens: { WatchedToken }?,
	exclusiveGroup: string?,
}

export type SequenceGroupDefinition = {
	policy: "DeferredPrefix",
	maxGapSeconds: number,
	maxTotalSeconds: number,
	scope: { string },
	watchedTokens: { WatchedToken }?,
}

export type RecognitionScalar = string | number | boolean
export type CustomMatch = { metadata: { [string]: RecognitionScalar }? }

-- Framework-owned scalar storage; consumer closures are trusted, unsandboxed code.
export type RecognizerContext = {
	read GetState: (self: RecognizerContext, key: string) -> RecognitionScalar?,
	read SetState: (self: RecognizerContext, key: string, value: RecognitionScalar?) -> (boolean, string?),
	read Now: (self: RecognizerContext) -> number,
	read ScheduleAfter: (self: RecognizerContext, seconds: number) -> (boolean, string?),
	read ClearDeadline: (self: RecognizerContext) -> (),
}

export type RecognizerEvent = SemanticInputEvent | (GestureEvent & { read kind: "Gesture" })

export type RecognizerDefinition = {
	inputs: { string },
	gestures: { [string]: { GestureKind } }?,
	maxWindowSeconds: number,
	onEvent: (RecognizerContext, RecognizerEvent) -> CustomMatch?,
	onDeadline: ((RecognizerContext) -> CustomMatch?)?,
}

export type SequenceSnapshot = { read sequenceId: string, read sourceId: string, read definition: SequenceDefinition }

export type RecognizerSnapshot = {
	read recognizerId: string,
	read sourceId: string,
	read definition: RecognizerDefinition,
	read faulted: boolean,
	read faultReason: string?,
}

export type SequenceMatchEvent = {
	read sequenceId: string,
	read sourceId: string,
	read recognizedAt: number,
	read timestamp: number,
	read ordinal: number,
	read matchedStepCount: number,
	read triggerTokenOrdinal: number,
}

export type CustomRecognitionEvent = {
	read recognizerId: string,
	read sourceId: string,
	read timestamp: number,
	read ordinal: number,
	read triggerTokenOrdinal: number?,
	read metadata: { [string]: RecognitionScalar }?,
}

-- Private I4 seam: these identities do not select or execute Actions.
export type RecognitionRouteKey =
	{ kind: "Input", inputId: string, gesture: "Pressed" | GestureKind }
	| { kind: "Sequence", sequenceId: string }
	| { kind: "Custom", recognizerId: string }

export type RecognitionHoldOwner = {
	read inputId: string,
	read inputGeneration: number,
	read pressEpochId: number,
	read isActiveAfterCommit: boolean,
}

export type InputRecognitionCandidate = {
	read pressEpochGeneration: number?,
	read kind: "Input",
	read inputId: string,
	read gesture: "Pressed" | GestureKind,
	read recognitionOrdinal: number,
	read pressEpochId: number?,
	read routeEligible: boolean,
}

export type SequenceRecognitionCandidate = {
	read kind: "Sequence",
	read sequenceId: string,
	read recognitionOrdinal: number,
	read matchedStepCount: number,
	read immediate: boolean,
	read rootInputOrdinal: number?,
	read holdOwner: RecognitionHoldOwner?,
}

export type CustomRecognitionCandidate = {
	read kind: "Custom",
	read recognizerId: string,
	read recognitionOrdinal: number,
	read immediate: boolean,
	read rootInputOrdinal: number?,
	read holdOwner: RecognitionHoldOwner?,
}

export type RecognitionCandidate = InputRecognitionCandidate | SequenceRecognitionCandidate | CustomRecognitionCandidate

type CandidateEmission = {
	read occurrenceOrdinal: number,
	read timestamp: number,
	read inputGeneration: number,
	read candidates: { RecognitionCandidate },
	read inputPolicy: DoubleTapArbitration?,
}

export type RootCandidateEnvelope = CandidateEmission & {
	read rootInputEpochGeneration: number?,
	read kind: "Root",
	read rootInputOrdinal: number,
	read rootInputId: string,
	read rootContextId: string,
	read rootInputEpochId: number?,
	read isRootEpochActiveAfterCommit: boolean,
	read lifecycleDelivered: boolean,
}

export type DeferredCandidateEnvelope = CandidateEmission & {
	read kind: "Deferred",
	read causeRootInputOrdinal: number?,
}

export type InputCandidateEnvelope = RootCandidateEnvelope | DeferredCandidateEnvelope

-- Compiled framework-private recognition graph. Built before native application.
export type RecognitionToken = {
	read key: string,
	read ordinal: number,
	read causeRootInputOrdinal: number?,
}

export type SequenceNode = { edges: { [string]: number }, completed: { string } }

export type SequenceMachine = {
	id: string,
	sourceId: string,
	deferred: boolean,
	dependencies: { [string]: unknown },
	nodes: { SequenceNode },
	watched: { [string]: boolean },
	inputs: { [string]: boolean },
	recognizers: { [string]: boolean },
	maxGapSeconds: number,
	maxTotalSeconds: number,
}

export type RecognitionCatalog = {
	sequenceMachines: { [string]: SequenceMachine },
	sequences: { [string]: SequenceSnapshot },
	recognizers: { [string]: RecognizerSnapshot },
	machines: { [string]: SequenceMachine },
	machineIndex: { [string]: { string } },
	recognizerIndex: { [string]: { string } },
	recognizerDependencies: { [string]: { [string]: unknown } },
}

export type GestureKind = "Tap" | "Held" | "LongHeld" | "DoubleTapped"
export type DoubleTapArbitration = "PreferSpecific" | "Independent" | "DeferredTap"
export type TapDefinition = { maxDurationSeconds: number, suppressIfHoldRecognized: boolean? }
export type HoldDefinition = { afterSeconds: number }

export type DoubleTapDefinition = {
	maxTapDurationSeconds: number,
	maxGapSeconds: number,
	arbitration: DoubleTapArbitration?,
}

export type GestureDefinitions = {
	Tap: TapDefinition?,
	Held: HoldDefinition?,
	LongHeld: HoldDefinition?,
	DoubleTapped: DoubleTapDefinition?,
}

export type GestureSnapshot = {
	read sourceId: string,
	read definition: TapDefinition | HoldDefinition | DoubleTapDefinition,
}

type GestureIdentity = {
	read inputId: string,
	read contextId: string,
	read timestamp: number,
	read ordinal: number,
	read triggerInputOrdinal: number,
}

export type TapGestureEvent = GestureIdentity & {
	read gesture: "Tap",
	read pressDurationSeconds: number,
	read recognizedAt: number,
}

export type HoldGestureEvent = GestureIdentity & {
	read gesture: "Held" | "LongHeld",
	read thresholdSeconds: number,
	read elapsedSeconds: number,
}

export type DoubleTapGestureEvent = GestureIdentity & { read gesture: "DoubleTapped", read gapSeconds: number }
export type GestureEvent = TapGestureEvent | HoldGestureEvent | DoubleTapGestureEvent

-- Framework-private: recognition truth and eligibility for a future Action start differ.
export type GestureCandidate = {
	read key: string,
	read inputId: string,
	read rootInputOrdinal: number,
	read generation: number,
	read pressEpochId: number?,
	read routeEligible: boolean,
	read timestamp: number,
	read recognizedAt: number,
}

export type GestureDispatchGroup = {
	read inputId: string,
	read contextId: string,
	read triggerInputOrdinal: number,
	read candidates: { GestureCandidate },
	read policy: DoubleTapArbitration?,
}

export type GestureScheduler = {
	-- Absolute deadlines use InputOwnerOptions.Now; returns idempotent cancellation.
	Schedule: (deadline: number, callback: () -> ()) -> () -> (),
}

export type PreparedRecognitionReset = { read generation: number, read token: unknown }

export type ContextSnapshot = {
	read id: string,
	read sourceId: string,
	read priority: number,
	read sink: boolean,
	read enabled: boolean,
}

export type BindingSnapshot = { read sourceId: string, read definition: BindingDefinition }

export type InputSnapshot = {
	read id: string,
	read sourceId: string,
	read contextId: string,
	read inputType: Enum.InputActionType,
	read displayName: string?,
}

type EventIdentity = {
	read inputId: string,
	read contextId: string,
	read inputType: Enum.InputActionType,
	read timestamp: number,
	read ordinal: number,
}

export type BoolTransition = EventIdentity & { read kind: "Pressed" | "Released", read value: boolean }
export type ValueChange = EventIdentity & { read kind: "StateChanged", read value: number | Vector2 | Vector3 }
export type InputCancellation = EventIdentity & { read kind: "Cancelled", read reason: string }
export type SemanticInputEvent = BoolTransition | ValueChange | InputCancellation

export type InputRuntime = {
	read GetSequence: (sequenceId: string) -> SequenceSnapshot?,
	read GetRecognizer: (recognizerId: string) -> RecognizerSnapshot?,
	read OnSequenceMatched: SignalTypes.Event<SequenceMatchEvent>,
	read OnRecognizerMatched: SignalTypes.Event<CustomRecognitionEvent>,
	read GetGestures: (inputId: string) -> { [GestureKind]: GestureSnapshot }?,
	read OnGesture: SignalTypes.Event<GestureEvent>,
	read SetSource: (sourceId: string, definition: InputSourceDefinition) -> (boolean, string?),
	read RemoveSource: (sourceId: string) -> (boolean, string?),
	read SetContextEnabled: (contextId: string, enabled: boolean) -> (boolean, string?),
	read GetInput: (inputId: string) -> InputSnapshot?,
	read GetContext: (contextId: string) -> ContextSnapshot?,
	read GetEffectiveBindings: (inputId: string) -> { [string]: BindingSnapshot }?,
	read BindActionLabel: (inputId: string, label: InputActionLabel) -> (boolean, string?),
	read UnbindActionLabel: (label: InputActionLabel) -> (boolean, string?),
	read OnInput: SignalTypes.Event<SemanticInputEvent>,
}

export type InputGraphSnapshot = {
	read recognition: RecognitionCatalog?,
	read generation: number,
	read sources: { [string]: InputSourceDefinition },
	read contexts: { [string]: ContextSnapshot },
	read inputs: { [string]: InputSnapshot },
	read bindings: { [string]: { [string]: BindingSnapshot } },
}

export type InputCommitContext = {
	read previous: InputGraphSnapshot,
	read invalidatedInputIds: { [string]: string },
}

export type InputGraphChange = {
	read previous: InputGraphSnapshot,
	read next: InputGraphSnapshot,
	read affectedInputIds: { string },
	read affectedContextIds: { string },
	read reasons: { string },
	read invalidatedEpochIds: { number },
	read generation: number,
}

export type PrimitiveOccurrence = {
	read event: SemanticInputEvent,
	read generation: number,
	read pressEpochId: number?,
}

export type ObserverPhase = "Interpretation" | "Arbitration" | "Routing"
export type PreparedInputUpdate = { read generation: number, read token: unknown }
export type PreparedInputInvalidation = { read generation: number, read token: unknown }
-- Rejected guarantees that commit was not attempted. Failed requires callers to
-- treat the local commit as uncertain, even if native rollback was possible.
export type InputCommitFailurePhase = "Rejected" | "Failed"
export type NativeTransition = "Pressed" | "Released" | "StateChanged"

export type NativeInputAdapter = {
	CreateContext: (id: string, definition: ContextDefinition) -> InputContext,
	ConfigureContext: (context: InputContext, definition: ContextDefinition, enabled: boolean) -> (),
	CreateAction: (id: string, definition: InputDefinition, context: InputContext) -> InputAction,
	CreateBinding: (slot: string, definition: BindingDefinition, action: InputAction) -> InputBinding,
	ObserveAction: (action: InputAction, callback: (NativeTransition, any) -> ()) -> () -> (),
	ReadState: (action: InputAction) -> any,
	Destroy: (instance: Instance) -> (),
	DestroyContainer: () -> (),
}

export type InputOwnerOptions = {
	PublishSequence: ((event: SequenceMatchEvent) -> ())?,
	PublishRecognizer: ((event: CustomRecognitionEvent) -> ())?,
	Scheduler: GestureScheduler?,
	PublishGesture: ((event: GestureEvent) -> ())?,
	Native: NativeInputAdapter,
	Now: () -> number,
	IsReady: () -> boolean,
	Publish: (event: SemanticInputEvent) -> (),
	ReportFault: (reason: string) -> (),
}

export type GraphValidator = (nextGraph: InputGraphSnapshot, proposedProfiles: any?) -> (boolean, string?)

export type InputOwner = {
	GetCommitContext: () -> InputCommitContext?,
	IsCommitFenced: () -> boolean,
	ValidatePrepared: (plan: { read token: unknown, read generation: number }) -> (boolean, string?),
	Disarm: (reason: string) -> (boolean, string?),
	ReleasePrepared: (plan: { read token: unknown, read generation: number }) -> (),
	GetGraphSnapshot: () -> InputGraphSnapshot,
	GetMutationStatus: () -> string?,
	GetSequence: (sequenceId: string) -> SequenceSnapshot?,
	GetRecognizer: (recognizerId: string) -> RecognizerSnapshot?,
	ObserveCandidateEnvelope: (callback: (InputCandidateEnvelope) -> ()) -> () -> (),
	GetGestures: (inputId: string) -> { [GestureKind]: GestureSnapshot }?,
	ObserveDispatchGroup: (callback: (GestureDispatchGroup) -> ()) -> () -> (),
	ResetRecognition: (inputIds: { string }?, reason: string) -> (boolean, string?),
	PrepareRecognitionReset: (inputIds: { string }?, reason: string) -> (PreparedRecognitionReset?, string?),
	CommitPreparedRecognitionReset: (plan: PreparedRecognitionReset) -> (boolean, string?),
	SetSource: (sourceId: string, definition: InputSourceDefinition) -> (boolean, string?),
	RemoveSource: (sourceId: string) -> (boolean, string?),
	SetContextEnabled: (contextId: string, enabled: boolean) -> (boolean, string?),
	GetInput: (inputId: string) -> InputSnapshot?,
	GetContext: (contextId: string) -> ContextSnapshot?,
	GetEffectiveBindings: (inputId: string) -> { [string]: BindingSnapshot }?,
	BindActionLabel: (inputId: string, label: InputActionLabel) -> (boolean, string?),
	UnbindActionLabel: (label: InputActionLabel) -> (boolean, string?),
	ObservePrimitive: (phase: ObserverPhase, callback: (PrimitiveOccurrence) -> ()) -> () -> (),
	RegisterGraphValidator: (callback: GraphValidator) -> () -> (),
	ObserveConfigurationCommit: (callback: (InputGraphChange) -> ()) -> () -> (),
	IsPressEpochActive: (inputId: string, epochId: number, generation: number) -> boolean,
	PrepareSource: (
		sourceId: string,
		definition: InputSourceDefinition?,
		proposedProfiles: any?
	) -> (PreparedInputUpdate?, string?),
	CommitPrepared: (plan: PreparedInputUpdate) -> (boolean, string?),
	CommitPreparedWithPublication: (plan: PreparedInputUpdate, publishSelection: () -> ()) -> (boolean, string?),
	PrepareEpochInvalidation: (reason: string) -> (PreparedInputInvalidation?, string?),
	CommitEpochInvalidation: (
		plan: PreparedInputInvalidation,
		publishSelection: () -> ()
	) -> (boolean, string?, InputCommitFailurePhase?),
	Destroy: () -> (),
}

return {}
