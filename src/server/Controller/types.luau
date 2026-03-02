--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)

local ControllerTypes = {}
export type Controller = ActorTypes.Controller

export type ControllerDef = {
	key: string,
	factory: (actor: ActorTypes.Actor) -> ActorTypes.Controller,
	dependsOn: { string }?, --for ordering
	autoAttach: boolean?, --defaults to true
}

export type ControllerRegistry = {
	Register: (ControllerDef) -> (boolean, string?),
	GetAutoAttachKeys: () -> { string },
	GetKeys: () -> { string },
	Get: (key: string) -> ControllerDef?,
	ResolveOrder: (keys: { string }) -> ({ string }?, string?),
	_ResetForTests: () -> (),
}
return ControllerTypes
