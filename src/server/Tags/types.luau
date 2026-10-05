--!strict
local serverFolder = script.Parent.Parent

local ActorTypes = require(serverFolder.Actor.types)
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
	onTick: ((ActorTypes.Actor, number) -> ())?,
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

export type ActionTagApplication = { id: string, duration: number? }
export type ActionTagHandle = { tagId: string, record: any, version: number }

export type TagInstanceSnapshot = {
	tagId: string,
	duration: number?,
	remainingDuration: number?,
	appliedOrder: number,
}

export type ActiveTagSnapshot = {
	tagId: string,
	stackCount: number,
	remainingDuration: number?,
}

export type TagController = {
	Destroy: (any) -> (),

	-- events
	OnTagAdded: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagRemoved: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagRefreshed: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagChanged: SignalTypes.Event<ActorTypes.Actor, string>,
	OnTagExpired: SignalTypes.Event<ActorTypes.Actor, string>,

	-- mutations
	AddTag: (any, tagId: string, options: AddTagOptions?) -> (boolean, string?),
	RemoveTag: (any, tagId: string) -> (boolean, string?),
	RemoveSingleTag: (any, tagId: string) -> (boolean, string?),

	-- queries
	HasTag: (any, tagId: string) -> boolean,
	GetActiveTags: (any) -> { ActiveTagSnapshot },
	GetTagInstances: (any, tagId: string) -> { TagInstanceSnapshot },
}

export type InternalTagController = TagController & {
	_beginActionBatch: (self: InternalTagController) -> (),
	_endActionBatch: (self: InternalTagController) -> (),
	_canApplyActionTags: (self: InternalTagController, applications: { ActionTagApplication }) -> string?,
	_addActionTag: (
		self: InternalTagController,
		application: ActionTagApplication,
		ownedHandles: { ActionTagHandle }?
	) -> (ActionTagHandle?, string?),
	_removeActionTag: (self: InternalTagController, handle: ActionTagHandle) -> (),
}

return TagTypes
