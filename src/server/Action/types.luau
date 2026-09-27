--!strict

export type ActionVisibility = "ServerOnly" | "ClientVisible"

export type ActionDefinition = {
	id: string,
	visibility: ActionVisibility,
	autoGrant: boolean?,
	requiredTags: { string }?,
	blockedTags: { string }?,
	costs: { [string]: number }?,
	locks: { string }?,
	interruptibleBy: { string }?,
	onCanStart: ((...any) -> (boolean, string?))?,
	onStart: ((...any) -> ())?,
	onUpdate: ((...any) -> ())?,
	onEnd: ((...any) -> ())?,
	onInterrupt: ((...any) -> ())?,
	canBeInterruptedBy: ((...any) -> boolean)?,
}

export type LoadedActionDefinition = ActionDefinition & {
	autoGrant: boolean,
	requiredTags: { string },
	blockedTags: { string },
	costs: { [string]: number },
	locks: { string },
	interruptibleBy: { string },
}

export type ActionRegistry = {
	Load: (
		definitions: { ActionDefinition },
		preparedTagIds: { [string]: boolean },
		preparedResourceIds: { [string]: boolean }
	) -> (boolean, string?),
	Get: (actionId: string) -> LoadedActionDefinition?,
	GetAll: () -> { LoadedActionDefinition },
	GetAllById: () -> { [string]: LoadedActionDefinition },
	IsLoaded: () -> boolean,
	_resetForTests: () -> (),
}

return {}
