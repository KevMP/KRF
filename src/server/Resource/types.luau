local serverFolder = script.Parent.Parent
local SignalTypes = require(serverFolder.Parent.shared.Signal.types)
local ActorTypes = require(serverFolder.Actor.types)

export type ResourceVisibility = "ServerOnly" | "ClientVisible"

export type ResourceNumericSource = {
	value: number?,
	propertyName: string?,
	defaultBaseValue: number?,
}

export type ResourceRegenDefinition = {
	rate: ResourceNumericSource,
}

export type ResourceDefinition = {
	id: string,

	min: ResourceNumericSource?,
	max: ResourceNumericSource,

	initialValue: number?,

	visibility: ResourceVisibility,
	autoAssign: boolean?,

	regen: ResourceRegenDefinition?,
}

export type LoadedResourceDefinition = ResourceDefinition & {
	min: ResourceNumericSource,
	autoAssign: boolean,
}

export type ResourceRegistry = {
	Load: (definitions: { ResourceDefinition }) -> (boolean, string?),

	IsLoaded: () -> boolean,

	Get: (resourceId: string) -> LoadedResourceDefinition?,
	GetAll: () -> { LoadedResourceDefinition },
	GetAllById: () -> { [string]: LoadedResourceDefinition },

	_resetForTests: () -> (),
}

export type ResourceChange = {
	actor: ActorTypes.Actor,
	resourceId: string,

	currentOldValue: number,
	currentNewValue: number,

	minOldValue: number,
	minNewValue: number,

	maxOldValue: number,
	maxNewValue: number,
}

export type ResourceController = {
	Destroy: (self: any) -> (),

	OnResourceAdded: SignalTypes.Event<ActorTypes.Actor, string>,
	OnResourceChanged: SignalTypes.Event<ResourceChange>,

	AddResource: (self: any, resourceId: string, initialValueOverride: number?) -> (boolean, string?),
	SetCurrent: (self: any, resourceId: string, value: number) -> (boolean, string?),

	CanSpend: (self: any, resourceId: string, amount: number) -> (boolean, string?),
	Spend: (self: any, resourceId: string, amount: number) -> (boolean, string?),
	Restore: (self: any, resourceId: string, amount: number) -> (boolean, string?),
	Drain: (self: any, resourceId: string, amount: number) -> (boolean, string?),

	Step: (self: any, deltaTime: number) -> (),

	HasResource: (self: any, resourceId: string) -> boolean,
	GetCurrent: (self: any, resourceId: string) -> number?,
	GetMax: (self: any, resourceId: string) -> number?,
	GetMin: (self: any, resourceId: string) -> number?,
}

return {}
