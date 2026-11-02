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
}

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
	read generation: number,
	read sources: { [string]: InputSourceDefinition },
	read contexts: { [string]: ContextSnapshot },
	read inputs: { [string]: InputSnapshot },
	read bindings: { [string]: { [string]: BindingSnapshot } },
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
	Native: NativeInputAdapter,
	Now: () -> number,
	IsReady: () -> boolean,
	Publish: (event: SemanticInputEvent) -> (),
	ReportFault: (reason: string) -> (),
}

export type GraphValidator = (nextGraph: InputGraphSnapshot, proposedProfiles: any?) -> (boolean, string?)

export type InputOwner = {
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
	PrepareEpochInvalidation: (reason: string) -> (PreparedInputInvalidation?, string?),
	CommitEpochInvalidation: (plan: PreparedInputInvalidation, publishSelection: () -> ()) -> (boolean, string?),
	Destroy: () -> (),
}

return {}
