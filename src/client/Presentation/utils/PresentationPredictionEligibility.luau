--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

local TAGS_DOMAIN: string = "KRF.Tags"
local RESOURCES_DOMAIN: string = "KRF.Resources"
local MAX_CALLBACK_SECONDS: number = 0.005

local Eligibility = {}

type Verdict = {
	blocked: string?,
	unknown: string?,
}

local function block(verdict: Verdict, reason: string): ()
	if verdict.blocked == nil then
		verdict.blocked = reason
	end
end

local function unknown(verdict: Verdict, reason: string): ()
	if verdict.unknown == nil then
		verdict.unknown = reason
	end
end

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function evaluateTags(
	policy: Types.CompiledActionPredictionPolicy,
	actor: ActorTypes.ActorView,
	ready: boolean,
	verdict: Verdict
): ()
	if #policy.requiredTags == 0 and #policy.blockedTags == 0 then
		return
	elseif not ready then
		unknown(verdict, "StateNotReady")

		return
	elseif actor:GetDomain(TAGS_DOMAIN) == nil then
		unknown(verdict, "TagsUnavailable")

		return
	end

	local tags: ActorTypes.TagsView = actor:GetTags()

	for _, tagId: string in policy.requiredTags do
		if not tags:HasTag(tagId) then
			block(verdict, "RequiredTagMissing:" .. tagId)
		end
	end

	for _, tagId: string in policy.blockedTags do
		if tags:HasTag(tagId) then
			block(verdict, "BlockedTagPresent:" .. tagId)
		end
	end
end

local function evaluateResource(
	policy: Types.CompiledActionPredictionPolicy,
	resourceId: string,
	snapshot: ActorTypes.ResourceSnapshot,
	verdict: Verdict
): ()
	local current: number = snapshot.current
	local minimum: number = snapshot.min
	local maximum: number = snapshot.max
	local requirement: Types.ActionPredictionResourceRequirement? = policy.resourceRequirements[resourceId]

	if requirement ~= nil then
		if
			(requirement.min ~= nil and current < requirement.min)
			or (requirement.max ~= nil and current > requirement.max)
		then
			block(verdict, "ResourceRequirementNotSatisfied:" .. resourceId)
		end

		if requirement.minPercent ~= nil or requirement.maxPercent ~= nil then
			local normalized: number = if maximum > minimum then (current - minimum) / (maximum - minimum) else 0 / 0

			if not finite(normalized) then
				block(verdict, "ResourceRangeInvalid:" .. resourceId)
			elseif
				(requirement.minPercent ~= nil and normalized < requirement.minPercent)
				or (requirement.maxPercent ~= nil and normalized > requirement.maxPercent)
			then
				block(verdict, "ResourceRequirementNotSatisfied:" .. resourceId)
			end
		end
	end

	local cost: Types.ActionPredictionResourceCost? = policy.costs[resourceId]

	if cost == nil then
		return
	elseif cost.multiplierProperty ~= nil then
		unknown(verdict, "ResourceCostMultiplierUnresolved:" .. resourceId)

		return
	end

	local amount: number

	if cost.amount ~= nil then
		amount = cost.amount
	elseif not finite(minimum) or not finite(maximum) or maximum < minimum then
		block(verdict, "ResourceCostRangeInvalid:" .. resourceId)

		return
	else
		amount = (maximum - minimum) * (cost.percent :: number)
	end

	if not finite(amount) or amount < 0 then
		block(verdict, "ResourceCostInvalid:" .. resourceId)
	elseif current - minimum < amount then
		block(verdict, "ResourceCostUnaffordable:" .. resourceId)
	end
end

local function evaluateResources(
	policy: Types.CompiledActionPredictionPolicy,
	actor: ActorTypes.ActorView,
	ready: boolean,
	verdict: Verdict
): ()
	if #policy.resourceIds == 0 then
		return
	elseif not ready then
		unknown(verdict, "StateNotReady")

		return
	elseif actor:GetDomain(RESOURCES_DOMAIN) == nil then
		unknown(verdict, "ResourcesUnavailable")

		return
	end

	local resources: ActorTypes.ResourcesView = actor:GetResources()

	for _, resourceId: string in policy.resourceIds do
		local snapshot: ActorTypes.ResourceSnapshot? = resources:GetResource(resourceId)

		if snapshot == nil then
			unknown(verdict, "ResourceUnavailable:" .. resourceId)
		else
			evaluateResource(policy, resourceId, snapshot, verdict)
		end
	end
end

local function evaluateCallback(
	callback: (Types.ActionPredictionCheckContext) -> boolean?,
	context: Types.ActionPredictionCheckContext,
	measure: () -> number,
	verdict: Verdict
): string?
	local started: number = measure()
	local success: boolean, failure: string?, result: any = Observers.Run(callback, context)
	local elapsed: number = measure() - started

	if not success then
		local reason: string = if failure == "Yielded"
			then "CallbackYielded"
			else "CallbackFailed:" .. (failure or "NonStringError")

		unknown(verdict, reason)

		return reason
	elseif elapsed > MAX_CALLBACK_SECONDS then
		unknown(verdict, "CallbackOverBudget")

		return "CallbackOverBudget"
	elseif result == true then
		return nil
	elseif result == false then
		block(verdict, "CallbackBlocked")
	elseif result == nil then
		unknown(verdict, "CallbackUndecided")
	else
		unknown(verdict, "CallbackReturnInvalid")

		return "CallbackReturnInvalid"
	end

	return nil
end

function Eligibility.Estimate(
	policy: Types.CompiledActionPredictionPolicy,
	actor: ActorTypes.ActorView,
	ready: boolean,
	context: Types.ActionPredictionCheckContext,
	measure: () -> number
): (Types.ActionPredictionEstimate, string?, string?)
	local verdict: Verdict = { blocked = nil, unknown = nil }
	local diagnostic: string? = nil

	evaluateTags(policy, actor, ready, verdict)
	evaluateResources(policy, actor, ready, verdict)

	local callback: ((Types.ActionPredictionCheckContext) -> boolean?)? = policy.canPredictStart

	if callback ~= nil and verdict.blocked == nil then
		diagnostic = evaluateCallback(callback, context, measure, verdict)
	end

	if verdict.blocked ~= nil then
		return "LikelyBlocked", verdict.blocked, diagnostic
	elseif verdict.unknown ~= nil then
		return "Unknown", verdict.unknown, diagnostic
	end

	return "LikelyAllowed", nil, diagnostic
end

return table.freeze(Eligibility)
