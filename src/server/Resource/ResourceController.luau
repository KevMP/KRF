--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ResourceTypes = require(script.Parent.types)
local ActorTypes = require(serverFolder.Actor.types)
local PropertyTypes = require(serverFolder.Property.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local OwnedSignalsModule = require(SignalFolder.OwnedSignals)
local ResourceRegistry = require(script.Parent.ResourceRegistry)
local ResourceStateResolver = require(script.Parent.utils.ResourceStateResolver)

type Actor = ActorTypes.Actor
type ResourceController = ResourceTypes.ResourceController
type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition
type ResourceChange = ResourceTypes.ResourceChange
type PropertyController = PropertyTypes.PropertyController

type ResourceRecord = {
	currentValue: number,
	resolvedMin: number,
	resolvedMax: number,
}

local ResourceController = {}

function ResourceController.new(actor: Actor): ResourceController
	local propertyController: PropertyController? = actor:GetController("PropertyController") :: PropertyController?

	local controller: ResourceController = {} :: ResourceController
	local resourcesById: { [string]: ResourceRecord } = {}

	local OnResourceAddedSignal: SignalTypes.Signal<Actor, string> = SignalModule.new()
	local OnResourceChangedSignal: SignalTypes.Signal<ResourceChange> = SignalModule.new()

	local ownedSignals: SignalTypes.OwnedSignals =
		OwnedSignalsModule.new({ OnResourceAddedSignal, OnResourceChangedSignal })

	local destroyed: boolean = false

	function controller:AddResource(resourceId: string, initialValueOverride: number?): (boolean, string?)
		local definition: LoadedResourceDefinition? = ResourceRegistry.Get(resourceId)
		if definition == nil then
			return false, "UnknownResourceId:" .. resourceId
		end

		if resourcesById[resourceId] ~= nil then
			return false, "ResourceAlreadyAssigned"
		end

		if initialValueOverride ~= nil and typeof(initialValueOverride) ~= "number" then
			return false, "InvalidResourceOverrideValue"
		end

		local resolvedMin: number?, resolvedMax: number?, resolveReason: string? =
			ResourceStateResolver.Resolve(propertyController, definition)
		if resolvedMin == nil or resolvedMax == nil then
			return false, resolveReason
		end

		local initialValue: number = if initialValueOverride ~= nil
			then initialValueOverride
			elseif definition.initialValue ~= nil then definition.initialValue
			else resolvedMax

		resourcesById[resourceId] = {
			currentValue = math.clamp(initialValue, resolvedMin, resolvedMax),
			resolvedMin = resolvedMin,
			resolvedMax = resolvedMax,
		}

		ownedSignals:WithDeferredDestroy(function()
			OnResourceAddedSignal:Fire(actor, resourceId)
		end)

		return true, nil
	end

	function controller:SetCurrent(resourceId: string, value: number): (boolean, string?)
		if not controller:HasResource(resourceId) then
			return false, "ResourceNotAssigned"
		end

		local resourceRecord: ResourceRecord = resourcesById[resourceId]

		if typeof(value) ~= "number" then
			return false, "InvalidResourceValue"
		end

		local previousCurrentValue: number = resourceRecord.currentValue
		local nextCurrentValue: number = math.clamp(value, resourceRecord.resolvedMin, resourceRecord.resolvedMax)

		if previousCurrentValue == nextCurrentValue then
			return true, nil
		end

		resourceRecord.currentValue = nextCurrentValue

		ownedSignals:WithDeferredDestroy(function()
			OnResourceChangedSignal:Fire({
				actor = actor,
				resourceId = resourceId,
				currentOldValue = previousCurrentValue,
				currentNewValue = nextCurrentValue,
				minOldValue = resourceRecord.resolvedMin,
				minNewValue = resourceRecord.resolvedMin,
				maxOldValue = resourceRecord.resolvedMax,
				maxNewValue = resourceRecord.resolvedMax,
			})
		end)

		return true, nil
	end

	function controller:HasResource(resourceId: string): boolean
		return resourcesById[resourceId] ~= nil
	end

	function controller:GetCurrent(resourceId: string): number?
		local resourceRecord: ResourceRecord? = resourcesById[resourceId]
		if resourceRecord == nil then
			return nil
		end

		return resourceRecord.currentValue
	end

	function controller:GetMax(resourceId: string): number?
		local resourceRecord: ResourceRecord? = resourcesById[resourceId]
		if resourceRecord == nil then
			return nil
		end

		return resourceRecord.resolvedMax
	end

	function controller:GetMin(resourceId: string): number?
		local resourceRecord: ResourceRecord? = resourcesById[resourceId]
		if resourceRecord == nil then
			return nil
		end

		return resourceRecord.resolvedMin
	end

	function controller:CanSpend(resourceId: string, amount: number): (boolean, string?)
		if not controller:HasResource(resourceId) then
			return false, "ResourceNotAssigned"
		end

		if typeof(amount) ~= "number" or amount < 0 then
			return false, "InvalidResourceAmount"
		end

		local resourceRecord: ResourceRecord = resourcesById[resourceId]
		local spendableValue: number = resourceRecord.currentValue - resourceRecord.resolvedMin

		if spendableValue < amount then
			return false, "InsufficientResourceValue"
		end

		return true, nil
	end

	function controller:Spend(resourceId: string, amount: number): (boolean, string?)
		local canSpendOk: boolean, canSpendReason: string? = controller:CanSpend(resourceId, amount)
		if not canSpendOk then
			return false, canSpendReason
		end

		local resourceRecord: ResourceRecord = resourcesById[resourceId]

		return controller:SetCurrent(resourceId, resourceRecord.currentValue - amount)
	end

	function controller:Restore(resourceId: string, amount: number): (boolean, string?)
		if not controller:HasResource(resourceId) then
			return false, "ResourceNotAssigned"
		end

		if typeof(amount) ~= "number" or amount < 0 then
			return false, "InvalidResourceAmount"
		end

		local resourceRecord: ResourceRecord = resourcesById[resourceId]

		return controller:SetCurrent(resourceId, resourceRecord.currentValue + amount)
	end

	function controller:Drain(resourceId: string, amount: number): (boolean, string?)
		if not controller:HasResource(resourceId) then
			return false, "ResourceNotAssigned"
		end

		if typeof(amount) ~= "number" or amount < 0 then
			return false, "InvalidResourceAmount"
		end

		local resourceRecord: ResourceRecord = resourcesById[resourceId]

		return controller:SetCurrent(resourceId, resourceRecord.currentValue - amount)
	end

	function controller:Destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
		ownedSignals:Destroy()
		table.clear(resourcesById)
	end

	controller.OnResourceAdded = SignalModule.wrapEvent(OnResourceAddedSignal)
	controller.OnResourceChanged = SignalModule.wrapEvent(OnResourceChangedSignal)

	for _, definition: LoadedResourceDefinition in ResourceRegistry.GetAll() do
		if definition.autoAssign then
			local addOk: boolean, addReason: string? = controller:AddResource(definition.id)

			if not addOk then
				warn(
					("[ResourceController] Auto-assign failed resourceId=%s reason=%s"):format(
						definition.id,
						tostring(addReason)
					)
				)
			end
		end
	end

	return controller
end

return ResourceController
