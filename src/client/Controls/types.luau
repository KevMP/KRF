--!strict
local InputTypes = require(script.Parent.Parent.Input.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)

export type InputSourceChange =
	{ kind: "Set", sourceId: string, definition: InputTypes.InputSourceDefinition }
	| { kind: "Remove", sourceId: string }

export type ProfileSourceChange =
	{ kind: "Set", actor: ActorTypes.ActorView, sourceId: string, profile: ActionTypes.ControlProfile }
	| { kind: "Remove", actor: ActorTypes.ActorView, sourceId: string }

export type ContextEnabledChange = { contextId: string, enabled: boolean }
export type ControlledActorChange = { kind: "Set", actor: ActorTypes.ActorView? }

export type ControlChangeSet = {
	inputs: { InputSourceChange }?,
	profiles: { ProfileSourceChange }?,
	contexts: { ContextEnabledChange }?,
	selection: ControlledActorChange?,
}

export type ControlLifecycleSignals = {
	FocusLost: (() -> ()) -> () -> (),
	FocusGained: (() -> ()) -> () -> (),
	DeviceDisconnected: ((Enum.UserInputType) -> ()) -> () -> (),
	DeviceConnected: ((Enum.UserInputType) -> ()) -> () -> (),
}

export type ControlOwner = {
	Apply: (ControlChangeSet) -> (boolean, string?),
	OnLifecycle: (ControlLifecycleEvent) -> (),
	Destroy: () -> (),
}

export type ClientControls = { read Apply: (ControlChangeSet) -> (boolean, string?) }

-- Framework-private platform boundary. I1 remains the owner of physical epochs.
export type ControlLifecycleEvent =
	{ kind: "FocusLost" | "FocusGained" }
	| { kind: "DeviceDisconnected" | "DeviceConnected", device: Enum.UserInputType }

return {}
