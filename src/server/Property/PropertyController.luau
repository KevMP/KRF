--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal
local utilsFolder = script.Parent.utils

local PropertyTypes = require(script.Parent.types)
local ActorTypes = require(serverFolder.Actor.types)
local TagTypes = require(serverFolder.Tags.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local OwnedSignalsModule = require(SignalFolder.OwnedSignals)

local PropertyRecompute = require(utilsFolder.PropertyRecompute)
local PropertyControllerEventUtils = require(utilsFolder.PropertyControllerEvent)

export type PropertyController = PropertyTypes.PropertyController
type Actor = ActorTypes.Actor
type TagController = TagTypes.TagController

type PropertyRecord = PropertyRecompute.PropertyRecord
type PropertyRecordsById = PropertyRecompute.PropertyRecordsById
type ResolvedChange = PropertyRecompute.ResolvedChange
type PropertyControllerEventContext = PropertyControllerEventUtils.PropertyControllerEventContext

local PropertyController = {}

function PropertyController.new(actor: Actor): PropertyController
	local controller: PropertyController = {} :: PropertyController
	local destroyed: boolean = false
	local propertiesById: PropertyRecordsById = {
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
	local eventContext: PropertyControllerEventContext = {
		actor = actor,
		ownedSignals = ownedSignals,
		basePropertyChangedSignal = OnBasePropertyChangedSignal,
		resolvedPropertyChangedSignal = OnResolvedPropertyChangedSignal,
		propertyChangedSignal = OnPropertyChangedSignal,
	}

	local tagController: TagController? = actor:GetController("TagController") :: TagController?
	local tagConnections: { SignalTypes.Connection } = {}

	local function recomputePropertiesAffectedByTag(tagId: string): ()
		if destroyed then
			return
		end

		local changes: { ResolvedChange } =
			PropertyRecompute.RecomputePropertiesAffectedByTag(propertiesById, tagController, tagId)

		PropertyControllerEventUtils.FireResolvedChanges(eventContext, changes, function(): boolean
			return not destroyed
		end)
	end

	for propertyName: string in propertiesById do
		PropertyRecompute.RecomputeProperty(propertiesById, tagController, propertyName)
	end

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

			PropertyRecompute.RecomputeProperty(propertiesById, tagController, propertyName)
			local newResolvedValue: number = propertiesById[propertyName].resolvedValue

			PropertyControllerEventUtils.FirePropertyChanged(
				eventContext,
				propertyName,
				nil,
				value,
				nil,
				newResolvedValue,
				true,
				true
			)
			return true, nil
		end

		if propertyRecord.baseValue == value then
			return true, nil
		end

		local previousBaseValue: number = propertyRecord.baseValue
		local previousResolvedValue: number = propertyRecord.resolvedValue

		propertyRecord.baseValue = value
		PropertyRecompute.RecomputeProperty(propertiesById, tagController, propertyName)
		local newResolvedValue: number = propertyRecord.resolvedValue

		PropertyControllerEventUtils.FirePropertyChanged(
			eventContext,
			propertyName,
			previousBaseValue,
			value,
			previousResolvedValue,
			newResolvedValue,
			true,
			previousResolvedValue ~= newResolvedValue
		)

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

		for _, connection: SignalTypes.Connection in tagConnections do
			connection:Disconnect()
		end
		table.clear(tagConnections)

		ownedSignals:Destroy()
	end

	controller.OnBasePropertyChanged = SignalModule.wrapEvent(OnBasePropertyChangedSignal)
	controller.OnResolvedPropertyChanged = SignalModule.wrapEvent(OnResolvedPropertyChangedSignal)
	controller.OnPropertyChanged = SignalModule.wrapEvent(OnPropertyChangedSignal)

	if tagController ~= nil then
		local tagEvents: { SignalTypes.Event<Actor, string> } = {
			tagController.OnTagAdded,
			tagController.OnTagRemoved,
			tagController.OnTagExpired,
			tagController.OnTagRefreshed,
		}

		for _, event: SignalTypes.Event<Actor, string> in tagEvents do
			table.insert(
				tagConnections,
				event:Connect(function(_actor: Actor, tagId: string)
					recomputePropertiesAffectedByTag(tagId)
				end)
			)
		end
	end

	return controller
end

return PropertyController
