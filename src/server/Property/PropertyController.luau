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

export type PropertyController = PropertyTypes.InternalPropertyController
type Actor = ActorTypes.Actor
type TagController = TagTypes.InternalTagController

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
	local journal: PropertyControllerEventUtils.PropertyEventJournal = PropertyControllerEventUtils.new(eventContext)
	local disconnectTagMutations: (() -> ())? = nil
	local mutationObservers: { [PropertyTypes.PropertyMutationObserver]: boolean } = {}

	function controller:_observeResolvedMutations(observer: PropertyTypes.PropertyMutationObserver): () -> ()
		mutationObservers[observer] = true
		return function(): ()
			mutationObservers[observer] = nil
		end
	end

	local function commitDerivedState(names: { string }): ()
		for observer: PropertyTypes.PropertyMutationObserver in mutationObservers do
			observer.Commit(names)
		end
	end

	local function dispatchChanges(): ()
		journal:Drain()
		for observer: PropertyTypes.PropertyMutationObserver in mutationObservers do
			observer.Dispatch()
		end
	end

	local function commitTagChanges(events: { TagTypes.TagMutationEvent }): ()
		local changes: { ResolvedChange } =
			PropertyRecompute.RecomputePropertiesAffectedByTags(propertiesById, tagController, events)
		for _, change: ResolvedChange in changes do
			journal:Queue({
				actor = actor,
				propertyName = change.propertyName,
				oldBaseValue = change.oldBaseValue,
				newBaseValue = change.newBaseValue,
				oldResolvedValue = change.oldResolvedValue,
				newResolvedValue = change.newResolvedValue,
			}, false, true)
		end
		local names: { string } = {}
		for _, change: ResolvedChange in changes do
			table.insert(names, change.propertyName)
		end
		commitDerivedState(names)
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

			journal:Queue({
				actor = actor,
				propertyName = propertyName,
				oldBaseValue = nil,
				newBaseValue = value,
				oldResolvedValue = nil,
				newResolvedValue = newResolvedValue,
			}, true, true)
			commitDerivedState({ propertyName })
			dispatchChanges()
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

		journal:Queue({
			actor = actor,
			propertyName = propertyName,
			oldBaseValue = previousBaseValue,
			newBaseValue = value,
			oldResolvedValue = previousResolvedValue,
			newResolvedValue = newResolvedValue,
		}, true, previousResolvedValue ~= newResolvedValue)
		if previousResolvedValue ~= newResolvedValue then
			commitDerivedState({ propertyName })
		end
		dispatchChanges()
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

		local disconnect: (() -> ())? = disconnectTagMutations
		disconnectTagMutations = nil
		if disconnect ~= nil then
			disconnect()
		end
		journal:Destroy()
		table.clear(mutationObservers)

		ownedSignals:Destroy()
	end

	controller.OnBasePropertyChanged = SignalModule.wrapEvent(OnBasePropertyChangedSignal)
	controller.OnResolvedPropertyChanged = SignalModule.wrapEvent(OnResolvedPropertyChangedSignal)
	controller.OnPropertyChanged = SignalModule.wrapEvent(OnPropertyChangedSignal)

	if tagController ~= nil then
		disconnectTagMutations = tagController:_observeMutations({
			Commit = commitTagChanges,
			Dispatch = dispatchChanges,
		})
	end

	return controller
end

return PropertyController
