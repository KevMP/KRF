--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local PropertyTypes = require(KRF.server.Property.types)
local TagTypes = require(KRF.server.Tags.types)
local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local Server = require(KRF.server)
local ResourceTestUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type ActionDefinition = ActionTypes.ActionDefinition
type ResourceController = ResourceTypes.ResourceController
type PropertyController = PropertyTypes.PropertyController
type TagController = TagTypes.TagController

beforeEach(ResourceTestUtils.reset)
afterEach(ResourceTestUtils.cleanup)

local mana: ResourceTypes.ResourceDefinition = {
	id = "Mana",
	visibility = "ServerOnly",
	autoAssign = true,
	min = { value = 20 },
	max = { value = 100 },
	initialValue = 60,
}
local chakra: ResourceTypes.ResourceDefinition = {
	id = "Chakra",
	visibility = "ServerOnly",
	autoAssign = true,
	max = { value = 100 },
	initialValue = 100,
}

type RequirementCase = {
	name: string,
	requirement: ActionTypes.ActionResourceRequirement,
	accepted: boolean,
	current: number?,
}
local requirementCases: { RequirementCase } = {
	{ name = "absolute minimum equality", requirement = { min = 60 }, accepted = true },
	{ name = "absolute maximum equality", requirement = { max = 60 }, accepted = true },
	{ name = "below absolute minimum", requirement = { min = 61 }, accepted = false },
	{ name = "above absolute maximum", requirement = { max = 59 }, accepted = false },
	{
		name = "the zero relative endpoint",
		requirement = { minPercent = 0, maxPercent = 0 },
		current = 20,
		accepted = true,
	},
	{
		name = "the full relative endpoint",
		requirement = { minPercent = 1, maxPercent = 1 },
		current = 100,
		accepted = true,
	},
	{
		name = "relative minimum equality within a nonzero minimum range",
		requirement = { minPercent = 0.5 },
		accepted = true,
	},
	{
		name = "relative maximum equality within a nonzero minimum range",
		requirement = { maxPercent = 0.5 },
		accepted = true,
	},
	{
		name = "below relative minimum despite current divided by max passing",
		requirement = { minPercent = 0.55 },
		accepted = false,
	},
	{ name = "above relative maximum", requirement = { maxPercent = 0.49 }, accepted = false },
	{
		name = "all four constraints passing",
		requirement = { min = 60, max = 60, minPercent = 0.5, maxPercent = 0.5 },
		accepted = true,
	},
	{
		name = "one absolute constraint failing among passing relative constraints",
		requirement = { max = 59, minPercent = 0.5 },
		accepted = false,
	},
	{
		name = "one relative constraint failing among passing absolute constraints",
		requirement = { min = 60, maxPercent = 0.49 },
		accepted = false,
	},
}
for _, case: RequirementCase in requirementCases do
	it("enforces " .. case.name .. " without consuming requirement-only Resources", function()
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				resourceRequirements = { Mana = case.requirement },
			},
			{ id = "Probe", visibility = "ServerOnly", autoGrant = true },
		}, { mana })
		local _actor: Actor, actions: ActionController, resources: ResourceController =
			ResourceTestUtils.registerActor()
		if case.current ~= nil then
			expect((resources:SetCurrent("Mana", case.current))).toBe(true)
		end
		local changes: { ResourceTypes.ResourceChange } = {}
		resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
			table.insert(changes, change)
		end)
		local result: ActionTypes.ActionRequestResult = actions:RequestAction("Cast")
		if case.accepted then
			expect(result).toEqual({ accepted = true, sequenceId = 1 })
		else
			local reason: string = ResourceTestUtils.expectRejected(result)
			expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
			expect(actions:RequestAction("Probe")).toEqual({ accepted = true, sequenceId = 1 })
		end
		expect(resources:GetCurrent("Mana")).toBe(case.current or 60)
		expect(changes).toEqual({})
	end)
end

it("checks all Resources and evaluates a shared requirement and cost against pre-spend state", function()
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			resourceRequirements = { Mana = { min = 60 }, Chakra = { min = 100 } },
			costs = { Mana = 30 },
		},
	}, { mana, chakra })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	expect((resources:SetCurrent("Chakra", 99))).toBe(true)
	local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
	expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
	expect(resources:GetCurrent("Mana")).toBe(60)
	expect((resources:SetCurrent("Chakra", 100))).toBe(true)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(resources:GetCurrent("Mana")).toBe(30)
	expect(resources:GetCurrent("Chakra")).toBe(100)
end)

for _, field: string in { "resourceRequirements", "costs" } do
	it("rejects an unassigned " .. field .. " Resource without assigning it or invoking consumer decisions", function()
		local calls: number = 0
		local definition: ActionDefinition = {
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			onCanStart = function(): (boolean, string?)
				calls += 1
				return true, nil
			end,
		}
		if field == "costs" then
			definition.costs = { Mana = 10 }
		else
			definition.resourceRequirements = { Mana = { min = 0 } }
		end
		local unassigned: ResourceTypes.ResourceDefinition = table.clone(mana)
		unassigned.autoAssign = false
		ResourceTestUtils.initialize({ definition }, { unassigned })
		local _actor: Actor, actions: ActionController, resources: ResourceController =
			ResourceTestUtils.registerActor()
		local added: number = 0
		resources.OnResourceAdded:Connect(function()
			added += 1
		end)
		local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
		expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
		expect(resources:HasResource("Mana")).toBe(false)
		expect(resources:GetCurrent("Mana")).toBeNil()
		expect(calls).toBe(0)
		expect(added).toBe(0)
		expect((resources:AddResource("Mana"))).toBe(true)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	end)
end

for _, usePercentRequirement: boolean in { true, false } do
	it(
		if usePercentRequirement
			then "rejects percentage normalization for zero-width ranges"
			else "accepts a zero percentage cost from zero-width capacity",
		function()
			local definition: ActionDefinition = { id = "Cast", visibility = "ServerOnly", autoGrant = true }
			if usePercentRequirement then
				definition.resourceRequirements = { Mana = { minPercent = 0 } }
			else
				definition.costs = { Mana = { percent = 0.25 } }
			end
			ResourceTestUtils.initialize({ definition }, {
				{
					id = "Mana",
					visibility = "ServerOnly",
					autoAssign = true,
					min = { value = 20 },
					max = { value = 20 },
				},
			})
			local _actor: Actor, actions: ActionController, resources: ResourceController =
				ResourceTestUtils.registerActor()
			local changes: number = 0
			resources.OnResourceChanged:Connect(function()
				changes += 1
			end)
			if usePercentRequirement then
				local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
				expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
			else
				expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
			end
			expect(resources:GetCurrent("Mana")).toBe(20)
			expect(changes).toBe(0)
		end
	)
end

type CostCase = { name: string, cost: number | ActionTypes.ActionResourceCost, multiplier: number?, expected: number }
local costCases: { CostCase } = {
	{ name = "numeric shorthand", cost = 20, expected = 40 },
	{ name = "exact affordability at the resolved minimum", cost = 40, expected = 20 },
	{ name = "structured amount", cost = { amount = 20 }, expected = 40 },
	{
		name = "capacity percentage rather than current or maximum percentage",
		cost = { percent = 0.25 },
		expected = 40,
	},
	{ name = "fractional amount", cost = 0.125, expected = 59.875 },
	{ name = "fractional capacity percentage", cost = { percent = 0.003125 }, expected = 59.75 },
	{
		name = "fixed cost multiplier",
		cost = { amount = 10, multiplierProperty = "Multiplier" },
		multiplier = 2,
		expected = 40,
	},
	{
		name = "percentage cost multiplier",
		cost = { percent = 0.25, multiplierProperty = "Multiplier" },
		multiplier = 0.5,
		expected = 50,
	},
	{
		name = "zero multiplier",
		cost = { amount = 20, multiplierProperty = "Multiplier" },
		multiplier = 0,
		expected = 60,
	},
	{
		name = "percentage greater than one discounted to an affordable cost",
		cost = { percent = 2, multiplierProperty = "Multiplier" },
		multiplier = 0.25,
		expected = 20,
	},
}
for _, case: CostCase in costCases do
	it("spends the exact resolved " .. case.name .. " before Started and onStart", function()
		local observed: { number? } = {}
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = case.cost },
				onStart = function(context: ActionTypes.ActionExecutionContext)
					local resources: ResourceController =
						context.actor:GetController("ResourceController") :: ResourceController
					table.insert(observed, resources:GetCurrent("Mana"))
				end,
			},
		}, { mana })
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		if case.multiplier ~= nil then
			expect((properties:SetBaseProperty("Multiplier", case.multiplier))).toBe(true)
		end
		local changes: { ResourceTypes.ResourceChange } = {}
		resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
			table.insert(changes, change)
		end)
		actions.OnActionStarted:Connect(function()
			table.insert(observed, resources:GetCurrent("Mana"))
		end)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		expect(resources:GetCurrent("Mana")).toBe(case.expected)
		expect(observed).toEqual({ case.expected, case.expected })
		expect(#changes).toBe(if case.expected == 60 then 0 else 1)
	end)
end

for _, case in
	{
		{ name = "a negative multiplier", value = -1 },
		{ name = "an infinite multiplier", value = math.huge },
		{ name = "a negative infinite multiplier", value = -math.huge },
		{ name = "a NaN multiplier", value = 0 / 0 },
		{ name = "an overflowed final cost", value = 1e308 },
	}
do
	it("rejects " .. case.name .. " atomically", function()
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = { amount = 20, multiplierProperty = "Multiplier" }, Chakra = 10 },
			},
		}, { mana, chakra })
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		expect((properties:SetBaseProperty("Multiplier", case.value))).toBe(true)
		local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
		expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
		expect(resources:GetCurrent("Mana")).toBe(60)
		expect(resources:GetCurrent("Chakra")).toBe(100)
	end)
end

it("rejects an obvious affordability failure before constructing a request execution", function()
	local factoryCalls: number = 0
	local decisionCalls: number = 0
	local started: boolean, failure = Server.Init({
		resources = { mana },
		actions = {
			function(): ActionDefinition
				factoryCalls += 1
				return {
					id = "Cast",
					visibility = "ServerOnly",
					autoGrant = true,
					costs = { Mana = 50 },
					onCanStart = function(): (boolean, string?)
						decisionCalls += 1
						return true, nil
					end,
				}
			end,
		},
	})
	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(factoryCalls).toBe(1)
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
	expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
	expect(factoryCalls).toBe(1)
	expect(decisionCalls).toBe(0)
	expect(resources:GetCurrent("Mana")).toBe(60)
end)

it("still requires assignment when a zero multiplier would make a declared cost free", function()
	local unassigned: ResourceTypes.ResourceDefinition = table.clone(mana)
	unassigned.autoAssign = false
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = { amount = 20, multiplierProperty = "Multiplier" } },
		},
	}, { unassigned })
	local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
		ResourceTestUtils.registerActor()
	expect((properties:SetBaseProperty("Multiplier", 0))).toBe(true)
	local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
	expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
	expect(resources:HasResource("Mana")).toBe(false)
end)

it("rejects a missing multiplier Property without seeding it or spending another Resource", function()
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = { amount = 20, multiplierProperty = "Missing" }, Chakra = 10 },
		},
	}, { mana, chakra })
	local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
		ResourceTestUtils.registerActor()
	local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
	expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
	expect(properties:HasProperty("Missing")).toBe(false)
	expect(resources:GetCurrent("Mana")).toBe(60)
	expect(resources:GetCurrent("Chakra")).toBe(100)
end)

for _, mutation: string in { "requirement", "cost", "bounds", "multiplier", "nested Action" } do
	it("replans after onCanStart changes " .. mutation .. " without undoing consumer work", function()
		local nested: ActionTypes.ActionRequestResult? = nil
		local definition: ActionDefinition = {
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			onCanStart = function(context: ActionTypes.ActionStartContext): (boolean, string?)
				local resources: ResourceController =
					context.actor:GetController("ResourceController") :: ResourceController
				local properties: PropertyController =
					context.actor:GetController("PropertyController") :: PropertyController
				if mutation == "bounds" then
					expect((properties:SetBaseProperty("MaxMana", 200))).toBe(true)
				elseif mutation == "multiplier" then
					expect((properties:SetBaseProperty("Multiplier", 3))).toBe(true)
				elseif mutation == "nested Action" then
					nested = (context.actor:GetController("ActionController") :: ActionController):RequestAction(
						"Nested"
					)
				else
					expect((resources:SetCurrent("Mana", 30))).toBe(true)
				end
				return true, nil
			end,
		}
		if mutation == "requirement" then
			definition.resourceRequirements = { Mana = { min = 60 } }
			definition.costs = { Mana = 5 }
		end
		if mutation == "bounds" then
			definition.costs = { Mana = { percent = 0.25 } }
		end
		if mutation == "multiplier" then
			definition.costs = { Mana = { amount = 20, multiplierProperty = "Multiplier" } }
		end
		local dynamicMana: ResourceTypes.ResourceDefinition = table.clone(mana)
		dynamicMana.max = { propertyName = "MaxMana", defaultBaseValue = 100 }
		ResourceTestUtils.initialize({
			definition,
			{ id = "Nested", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 30 } },
			{ id = "Probe", visibility = "ServerOnly", autoGrant = true },
		}, { dynamicMana })
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		expect((properties:SetBaseProperty("Multiplier", 1))).toBe(true)
		ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
		expect(resources:GetCurrent("Mana")).toBe(if mutation == "bounds" or mutation == "multiplier" then 60 else 30)
		if mutation == "nested Action" then
			expect(nested).toEqual({ accepted = true, sequenceId = 1 })
		end
		expect(actions:RequestAction("Probe")).toEqual({
			accepted = true,
			sequenceId = if mutation == "nested Action" then 2 else 1,
		})
	end)
end

for _, invalidation: string in { "remove", "destroy" } do
	it("rejects ResourceController invalidation during decisions before activation " .. invalidation, function()
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = 20 },
				onCanStart = function(context: ActionTypes.ActionStartContext): (boolean, string?)
					if invalidation == "remove" then
						context.actor:RemoveController("ResourceController")
					else
						(context.actor:GetController("ResourceController") :: ResourceController):Destroy()
					end
					return true, nil
				end,
			},
			{ id = "Probe", visibility = "ServerOnly", autoGrant = true },
		}, { mana })
		local actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
		local started: number = 0
		actions.OnActionStarted:Connect(function()
			started += 1
		end)
		ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
		expect(started).toBe(0)
		if invalidation == "remove" then
			expect(resources:GetCurrent("Mana")).toBe(60)
			expect(actor:SetController("ResourceController", resources)).toBe(true)
		end
		expect(actions:RequestAction("Probe")).toEqual({ accepted = true, sequenceId = 1 })
	end)
end

it("uses loaded metadata when the execution factory returns different Resource prices", function()
	-- Register immutable metadata first, then mutate only the consumer source.
	local definition: ActionDefinition =
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20 } }
	ResourceTestUtils.initialize({ definition }, { mana })
	definition.costs = { Mana = 1 }
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	expect((ActionRegistry.Get("Cast") :: ActionTypes.LoadedActionDefinition).costs.Mana).toBe(20)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(resources:GetCurrent("Mana")).toBe(40)
end)

for _, changed: string in { "bounds", "multiplier" } do
	it("accepts the exact new price resolved after onCanStart changes " .. changed, function()
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = {
					Mana = if changed == "bounds"
						then { percent = 0.25 }
						else { amount = 20, multiplierProperty = "Multiplier" },
				},
				onCanStart = function(context: ActionTypes.ActionStartContext): (boolean, string?)
					local properties: PropertyController =
						context.actor:GetController("PropertyController") :: PropertyController
					local succeeded: boolean, reason: string? = properties:SetBaseProperty(
						if changed == "bounds" then "MaxMana" else "Multiplier",
						if changed == "bounds" then 200 else 0.5
					)
					return succeeded, reason
				end,
			},
		}, {
			{
				id = "Mana",
				visibility = "ServerOnly",
				autoAssign = true,
				max = { propertyName = "MaxMana", defaultBaseValue = 100 },
				initialValue = 100,
			},
		})
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		expect((properties:SetBaseProperty("Multiplier", 1))).toBe(true)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		expect(resources:GetCurrent("Mana")).toBe(if changed == "bounds" then 50 else 90)
	end)
end

for _, invalidBounds: string in { "non-finite maximum", "overflowed capacity" } do
	local name: string = if invalidBounds == "non-finite maximum"
		then "prices percentage costs from the last valid bounds after a non-finite maximum"
		else "rejects overflowed percentage costs before spending any Resource"
	it(name, function()
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = { percent = 0.25 }, Chakra = 10 },
			},
		}, {
			{
				id = "Mana",
				visibility = "ServerOnly",
				autoAssign = true,
				min = { value = if invalidBounds == "overflowed capacity" then -1e308 else 0 },
				max = { propertyName = "MaxMana", defaultBaseValue = 100 },
				initialValue = 60,
			},
			chakra,
		})
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		expect(
			(properties:SetBaseProperty("MaxMana", if invalidBounds == "overflowed capacity" then 1e308 else math.huge))
		).toBe(true)
		if invalidBounds == "non-finite maximum" then
			expect(resources:GetMax("Mana")).toBe(100)
			expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
			expect(resources:GetCurrent("Mana")).toBe(35)
			expect(resources:GetCurrent("Chakra")).toBe(90)
		else
			expect(actions:RequestAction("Cast")).toEqual({
				accepted = false,
				reason = "ActionResourceCostInvalid:Mana",
			})
			expect(resources:GetCurrent("Mana")).toBe(60)
			expect(resources:GetCurrent("Chakra")).toBe(100)
		end
	end)
end

type RejectionCase = {
	name: string,
	reason: string,
	requirement: ActionTypes.ActionResourceRequirement?,
	cost: (number | ActionTypes.ActionResourceCost)?,
	assigned: boolean?,
	zeroRange: boolean?,
	maximumOverride: number?,
	multiplier: number?,
	unavailable: string?,
}
local rejectionCases: { RejectionCase } = {
	{ name = "unassigned Resource", reason = "ActionResourceNotAssigned:Mana", cost = 10, assigned = false },
	{ name = "requirement failure", reason = "ActionResourceRequirementNotSatisfied:Mana", requirement = { min = 61 } },
	{
		name = "invalid requirement range",
		reason = "ActionResourceRequirementRangeInvalid:Mana",
		requirement = { minPercent = 0 },
		zeroRange = true,
	},
	{
		name = "invalid cost range",
		reason = "ActionResourceCostRangeInvalid:Mana",
		cost = { percent = 0.25 },
		maximumOverride = math.huge,
	},
	{
		name = "missing multiplier",
		reason = "ActionResourceMultiplierInvalid:Mana:Multiplier",
		cost = { amount = 20, multiplierProperty = "Multiplier" },
	},
	{
		name = "negative multiplier",
		reason = "ActionResourceMultiplierInvalid:Mana:Multiplier",
		cost = { amount = 20, multiplierProperty = "Multiplier" },
		multiplier = -1,
	},
	{
		name = "invalid effective cost",
		reason = "ActionResourceCostInvalid:Mana",
		cost = { amount = 20, multiplierProperty = "Multiplier" },
		multiplier = 1e308,
	},
	{
		name = "insufficient Resource",
		reason = "ActionResourcePlanningFailed:InsufficientResourceValue:Mana",
		cost = 50,
	},
	{
		name = "missing ResourceController",
		reason = "ActionResourceControllerUnavailable",
		cost = 10,
		unavailable = "missing",
	},
	{
		name = "destroyed ResourceController",
		reason = "ActionResourceControllerUnavailable",
		cost = 10,
		unavailable = "destroyed",
	},
}
for _, case: RejectionCase in rejectionCases do
	it("returns the documented rejection for " .. case.name .. " without consuming an activation", function()
		local definition: ActionDefinition = { id = "Cast", visibility = "ServerOnly", autoGrant = true }
		if case.requirement ~= nil then
			definition.resourceRequirements = { Mana = case.requirement }
		end
		if case.cost ~= nil then
			definition.costs = { Mana = case.cost }
		end
		local resource: ResourceTypes.ResourceDefinition = table.clone(mana)
		resource.autoAssign = case.assigned ~= false
		if case.zeroRange then
			resource.max = { value = 20 }
			resource.initialValue = 20
		end
		ResourceTestUtils.initialize(
			{ definition, { id = "Probe", visibility = "ServerOnly", autoGrant = true } },
			{ resource }
		)
		local actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		if case.multiplier ~= nil then
			expect((properties:SetBaseProperty("Multiplier", case.multiplier))).toBe(true)
		end
		if case.maximumOverride ~= nil then
			-- Exercise the planner's defensive range check without caching invalid
			-- derived state in the native ResourceController.
			resources.GetMax = function(_self: any, _resourceId: string): number?
				return case.maximumOverride
			end
		end
		if case.unavailable == "missing" then
			expect(actor:RemoveController("ResourceController")).toBe(resources)
		elseif case.unavailable == "destroyed" then
			resources:Destroy()
		end
		local previous: number? = resources:GetCurrent("Mana")
		for _attempt: number = 1, 2 do
			expect(actions:RequestAction("Cast")).toEqual({ accepted = false, reason = case.reason })
		end
		expect(resources:GetCurrent("Mana")).toBe(previous)
		expect(actions:RequestAction("Probe")).toEqual({ accepted = true, sequenceId = 1 })
		if case.unavailable == "missing" then
			expect(actor:SetController("ResourceController", resources)).toBe(true)
		end
	end)
end
