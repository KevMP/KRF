--!strict
local serverFolder = script.Parent.Parent

local ActorTypes = require(serverFolder.Actor.types)
local ControllerTypes = require(serverFolder.Controller.types)
local SignalTypes = require(serverFolder.Parent.shared.Signal.types)

local TagTypes = {}

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
	_resetForTests: () -> (),
}

export type AddTagOptions = {
	duration: number?,
}

export type TagInstanceSnapshot = {
	tagId: string,
	duration: number?,
	remainingDuration: number?,
	appliedOrder: number,
}

export type ActiveTagSnapshot = {
	tagId: string,
	stackCount: number,
}

export type TagController = ControllerTypes.Controller & {
	-- events
	OnTagAdded: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagRemoved: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagRefreshed: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagChanged: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagExpired: SignalTypes.Event<ActorTypes.Actor, string>,

	-- mutations
	AddTag: (self: TagController, tagId: string, options: AddTagOptions?) -> (boolean, string?),
	RemoveTag: (self: TagController, tagId: string) -> (boolean, string?),
	RemoveSingleTag: (self: TagController, tagId: string) -> (boolean, string?),

	-- queries
	HasTag: (self: TagController, tagId: string) -> boolean,
	GetActiveTags: (self: TagController) -> { ActiveTagSnapshot },
	GetTagInstances: (self: TagController, tagId: string) -> { TagInstanceSnapshot },
}

return TagTypes
