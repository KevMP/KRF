--!strict
local serverFolder = script.Parent.Parent

local ResourceTypes = require(script.Parent.types)
local ActorTypes = require(serverFolder.Actor.types)
local PropertyTypes = require(serverFolder.Property.types)
local ResourceRegistry = require(script.Parent.ResourceRegistry)
local ResourceStateResolver = require(script.Parent.utils.ResourceStateResolver)

type Actor = ActorTypes.Actor
type ResourceController = ResourceTypes.ResourceController
type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition
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

	function controller:Destroy(): ()
		table.clear(resourcesById)
	end

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
