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
	initialValue: number,
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

return {}
