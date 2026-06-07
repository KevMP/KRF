--!strict
local serverFolder = script.Parent.Parent

local SignalTypes = require(serverFolder.Parent.shared.Signal.types)
local ActorTypes = require(serverFolder.Actor.types)

local types = {}

export type PropertyChange = {
	actor: ActorTypes.Actor,
	propertyName: string,

	oldBaseValue: number?,
	newBaseValue: number,

	oldResolvedValue: number?,
	newResolvedValue: number,
}

export type PropertyController = {
	SetBaseProperty: (self: any, propertyName: string, value: number) -> (boolean, string?),
	GetBaseProperty: (self: any, propertyName: string) -> number?,
	GetResolvedProperty: (self: any, propertyName: string) -> number?,
	GetResolvedProperties: (self: any) -> { [string]: number },
	HasProperty: (self: any, propertyName: string) -> boolean,

	OnBasePropertyChanged: SignalTypes.Event<ActorTypes.Actor, string, number?, number>,
	OnResolvedPropertyChanged: SignalTypes.Event<ActorTypes.Actor, string, number?, number>,
	OnPropertyChanged: SignalTypes.Event<PropertyChange>,

	Destroy: (self: any) -> (),
}

return types
