--!strict
local ActionTypes = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local ResourceTypes = require(script.Parent.Parent.Parent.Resource.types)
local PropertyTypes = require(script.Parent.Parent.Parent.Property.types)

export type ResourcePlan = { controller: ResourceTypes.InternalResourceController, commit: () -> () }
local ActionControllerResources = {}

function ActionControllerResources.Resolve(
	actor: ActorTypes.Actor,
	definition: ActionTypes.LoadedActionDefinition
): (ResourcePlan?, string?)
	local referenced: { [string]: boolean } = {}
	for id: string in definition.resourceRequirements do
		referenced[id] = true
	end
	for id: string in definition.costs do
		referenced[id] = true
	end
	if next(referenced) == nil then
		return nil, nil
	end
	local resources: ResourceTypes.InternalResourceController? =
		actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController?
	if resources == nil or resources:_isDestroyed() then
		return nil, "ActionResourceControllerUnavailable"
	end
	local properties: PropertyTypes.PropertyController? =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController?
	local ids: { string } = {}
	for id: string in referenced do
		table.insert(ids, id)
	end
	table.sort(ids)
	local amounts: { [string]: number } = {}
	for _, id: string in ids do
		if not resources:HasResource(id) then
			return nil, "ActionResourceNotAssigned:" .. id
		end
		local current: number = resources:GetCurrent(id) :: number
		local minimum: number = resources:GetMin(id) :: number
		local maximum: number = resources:GetMax(id) :: number
		local requirement: ActionTypes.ActionResourceRequirement? = definition.resourceRequirements[id]
		if requirement ~= nil then
			if
				(requirement.min ~= nil and current < requirement.min)
				or (requirement.max ~= nil and current > requirement.max)
			then
				return nil, "ActionResourceRequirementNotSatisfied:" .. id
			end
			if requirement.minPercent ~= nil or requirement.maxPercent ~= nil then
				if not (maximum > minimum) then
					return nil, "ActionResourceRequirementRangeInvalid:" .. id
				end
				local normalized: number = (current - minimum) / (maximum - minimum)
				if not math.isfinite(normalized) then
					return nil, "ActionResourceRequirementRangeInvalid:" .. id
				end
				if
					(requirement.minPercent ~= nil and normalized < requirement.minPercent)
					or (requirement.maxPercent ~= nil and normalized > requirement.maxPercent)
				then
					return nil, "ActionResourceRequirementNotSatisfied:" .. id
				end
			end
		end
		local cost: (number | ActionTypes.ActionResourceCost)? = definition.costs[id]
		if cost ~= nil then
			local amount: number
			if type(cost) == "number" then
				amount = cost
			else
				local structured: ActionTypes.ActionResourceCost = cost :: ActionTypes.ActionResourceCost
				if structured.amount ~= nil then
					amount = structured.amount
				else
					if not math.isfinite(minimum) or not math.isfinite(maximum) or maximum < minimum then
						return nil, "ActionResourceCostRangeInvalid:" .. id
					end
					amount = (maximum - minimum) * (structured.percent :: number)
				end
				local name: string? = structured.multiplierProperty
				if name ~= nil then
					local multiplier: number? = if properties ~= nil and properties:HasProperty(name)
						then properties:GetResolvedProperty(name)
						else nil
					if multiplier == nil or not math.isfinite(multiplier) or multiplier < 0 then
						return nil, "ActionResourceMultiplierInvalid:" .. id .. ":" .. name
					end
					amount *= multiplier
				end
			end
			if not math.isfinite(amount) or amount < 0 then
				return nil, "ActionResourceCostInvalid:" .. id
			end
			amounts[id] = amount
		end
	end
	local commit: (() -> ())?, reason: string? = resources:_prepareSpends(amounts)
	if commit == nil then
		return nil, "ActionResourcePlanningFailed:" .. (reason or "Unknown")
	end
	return { controller = resources, commit = commit }, nil
end

return ActionControllerResources
