--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)

local RegistryTypes: nil = nil

export type TagVisibility = "ServerOnly" | "ClientVisible"

export type PropertyModifier = {
	set: number?,
	add: number?,
	multiply: number?,
	min: number?,
	max: number?,
}

export type TagDefinition = {
	id: string,
	defaultDuration: number?,
	tickInterval: number?,
	duplicateBehavior: "Stack" | "Refresh" | "Ignore",
	maxStacks: number?,
	visibility: TagVisibility,
	onTick: ((ActorTypes.Actor) -> ())?,
	properties: { [string]: PropertyModifier }?,
}

export type TagRegistry = {
	Load: (definitions: { TagDefinition }) -> (boolean, string?),
	Get: (tagId: string) -> TagDefinition?,
	GetAll: () -> { TagDefinition },
	GetAllById: () -> { [string]: TagDefinition },
	IsLoaded: () -> boolean,
}

return RegistryTypes
