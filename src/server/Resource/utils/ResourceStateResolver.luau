--!strict
local serverFolder = script.Parent.Parent.Parent

local ResourceTypes = require(serverFolder.Resource.types)
local PropertyTypes = require(serverFolder.Property.types)

type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition
type ResourceNumericSource = ResourceTypes.ResourceNumericSource
type PropertyController = PropertyTypes.PropertyController

local ResourceStateResolver = {}

local function ResolveNumericSource(
	propertyController: PropertyController?,
	source: ResourceNumericSource
): (number?, string?)
	if source.value ~= nil then
		return source.value, nil
	end

	local propertyName: string = source.propertyName :: string
	local defaultBaseValue: number = source.defaultBaseValue :: number

	if propertyController == nil then
		return defaultBaseValue, nil
	end

	if not propertyController:HasProperty(propertyName) then
		local seedOk: boolean, seedReason: string? = propertyController:SetBaseProperty(propertyName, defaultBaseValue)

		if not seedOk then
			return nil, "ResourcePropertySeedFailed:" .. propertyName .. ":" .. tostring(seedReason)
		end
	end

	local resolvedValue: number? = propertyController:GetResolvedProperty(propertyName)
	if resolvedValue == nil then
		return nil, "ResourcePropertyUnresolved:" .. propertyName
	end

	return resolvedValue, nil
end

function ResourceStateResolver.Resolve(
	propertyController: PropertyController?,
	definition: LoadedResourceDefinition
): (number?, number?, string?)
	local resolvedMin: number?, minReason: string? = ResolveNumericSource(propertyController, definition.min)
	if resolvedMin == nil then
		return nil, nil, minReason
	end

	local resolvedMax: number?, maxReason: string? = ResolveNumericSource(propertyController, definition.max)
	if resolvedMax == nil then
		return nil, nil, maxReason
	end

	if definition.regen ~= nil then
		local regenRate: number?, regenReason: string? = ResolveNumericSource(propertyController, definition.regen.rate)
		if regenRate == nil then
			return nil, nil, regenReason
		end
	end

	if resolvedMax < resolvedMin then
		return nil, nil, "ResourceResolvedMaxLessThanResolvedMin"
	end

	return resolvedMin, resolvedMax, nil
end

return ResourceStateResolver
