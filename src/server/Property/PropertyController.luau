--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local PropertyTypes = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local OwnedSignalsModule = require(SignalFolder.OwnedSignals)

export type PropertyController = PropertyTypes.PropertyController
type Actor = ActorTypes.Actor

type PropertyRecord = {
	baseValue: number,
	resolvedValue: number,
}

local PropertyController = {}

function PropertyController.new(actor: Actor): PropertyController
	local controller: PropertyController = {} :: PropertyController
	local destroyed: boolean = false
	local propertiesById: { [string]: PropertyRecord } = {
		WalkSpeed = {
			baseValue = 16,
			resolvedValue = 16,
		},

		JumpPower = {
			baseValue = 50,
			resolvedValue = 50,
		},
	}

	local OnBasePropertyChangedSignal: SignalTypes.Signal<Actor, string, number?, number> = SignalModule.new()
	local OnResolvedPropertyChangedSignal: SignalTypes.Signal<Actor, string, number?, number> = SignalModule.new()
	local OnPropertyChangedSignal: SignalTypes.Signal<PropertyTypes.PropertyChange> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals = OwnedSignalsModule.new({
		OnBasePropertyChangedSignal,
		OnResolvedPropertyChangedSignal,
		OnPropertyChangedSignal,
	})

	function controller:SetBaseProperty(propertyName: string, value: number): (boolean, string?)
		if typeof(value) ~= "number" then
			return false, "InvalidPropertyValue"
		end

		local propertyRecord: PropertyRecord? = propertiesById[propertyName]

		if not propertyRecord then
			propertiesById[propertyName] = {
				baseValue = value,
				resolvedValue = value,
			}

			ownedSignals:WithDeferredDestroy(function()
				OnBasePropertyChangedSignal:Fire(actor, propertyName, nil, value)
				OnResolvedPropertyChangedSignal:Fire(actor, propertyName, nil, value)
				OnPropertyChangedSignal:Fire({
					actor = actor,
					propertyName = propertyName,
					oldBaseValue = nil,
					newBaseValue = value,
					oldResolvedValue = nil,
					newResolvedValue = value,
				})
			end)
			return true, nil
		end

		if propertyRecord.baseValue == value then
			return true, nil
		end

		local previousBaseValue: number = propertyRecord.baseValue
		local previousResolvedValue: number = propertyRecord.resolvedValue

		propertyRecord.baseValue = value
		propertyRecord.resolvedValue = value

		ownedSignals:WithDeferredDestroy(function()
			OnBasePropertyChangedSignal:Fire(actor, propertyName, previousBaseValue, value)
			OnResolvedPropertyChangedSignal:Fire(actor, propertyName, previousResolvedValue, value)
			OnPropertyChangedSignal:Fire({
				actor = actor,
				propertyName = propertyName,
				oldBaseValue = previousBaseValue,
				newBaseValue = value,
				oldResolvedValue = previousResolvedValue,
				newResolvedValue = value,
			})
		end)

		return true, nil
	end

	function controller:GetBaseProperty(propertyName: string): number?
		local propertyRecord: PropertyRecord? = propertiesById[propertyName]
		if propertyRecord then
			return propertyRecord.baseValue
		end

		return nil
	end

	function controller:GetResolvedProperty(propertyName: string): number?
		local propertyRecord: PropertyRecord? = propertiesById[propertyName]
		if propertyRecord then
			return propertyRecord.resolvedValue
		end

		return nil
	end

	function controller:GetResolvedProperties(): { [string]: number }
		local resolvedProperties: { [string]: number } = {}
		for propId: string, propertyRecord: PropertyRecord in propertiesById do
			resolvedProperties[propId] = propertyRecord.resolvedValue
		end

		return table.freeze(resolvedProperties)
	end

	function controller:HasProperty(propertyName: string): boolean
		return propertiesById[propertyName] ~= nil
	end

	function controller:Destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
		ownedSignals:Destroy()
	end

	controller.OnBasePropertyChanged = SignalModule.wrapEvent(OnBasePropertyChangedSignal)
	controller.OnResolvedPropertyChanged = SignalModule.wrapEvent(OnResolvedPropertyChangedSignal)
	controller.OnPropertyChanged = SignalModule.wrapEvent(OnPropertyChangedSignal)

	return controller
end

return PropertyController
