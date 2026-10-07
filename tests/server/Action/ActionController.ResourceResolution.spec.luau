--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTestUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type PropertyController = PropertyTypes.PropertyController
type ResourceController = ResourceTypes.ResourceController
type ResourceChange = ResourceTypes.ResourceChange
type TagController = TagTypes.TagController

beforeEach(ResourceTestUtils.reset)
afterEach(ResourceTestUtils.cleanup)

local mana: ResourceTypes.ResourceDefinition = {
	id = "Mana",
	visibility = "ServerOnly",
	min = { propertyName = "MinMana", defaultBaseValue = 10 },
	max = { propertyName = "MaxMana", defaultBaseValue = 100 },
	regen = { rate = { propertyName = "ManaRegen", defaultBaseValue = 5 } },
	initialValue = 60,
}
local initial: { [string]: number } = { MinMana = 10, MaxMana = 100, ManaRegen = 5 }
local recovered: { [string]: number } = { MinMana = 15, MaxMana = 90, ManaRegen = 9 }
type InvalidValueCase = { name: string, value: number }
local invalidValues: { InvalidValueCase } = {
	{ name = "positive infinity", value = math.huge },
	{ name = "negative infinity", value = -math.huge },
	{ name = "NaN", value = 0 / 0 },
}

for _, propertyName: string in { "MinMana", "MaxMana", "ManaRegen" } do
	for _, case: InvalidValueCase in invalidValues do
		it("preserves the complete Resource snapshot when " .. propertyName .. " resolves to " .. case.name, function()
			ResourceTestUtils.initialize({}, { mana })
			local _actor: Actor, _actions: ActionController, resources: ResourceController, properties: PropertyController =
				ResourceTestUtils.registerActor()
			expect((properties:SetBaseProperty(propertyName, case.value))).toBe(true)
			local assigned: boolean, reason: string? = resources:AddResource("Mana")
			expect(assigned).toBe(false)
			expect(reason).toBe("ResourcePropertyNonFinite:" .. propertyName)
			expect(resources:HasResource("Mana")).toBe(false)
			expect(resources:GetCurrent("Mana")).toBeNil()

			expect((properties:SetBaseProperty(propertyName, initial[propertyName]))).toBe(true)
			expect((resources:AddResource("Mana"))).toBe(true)
			expect((resources:Spend("Mana", 20))).toBe(true)
			local changes: { ResourceChange } = {}
			resources.OnResourceChanged:Connect(function(change: ResourceChange)
				table.insert(changes, change)
			end)
			expect((properties:SetBaseProperty(propertyName, case.value))).toBe(true)
			for _, otherName: string in { "MinMana", "MaxMana", "ManaRegen" } do
				if otherName ~= propertyName then
					expect((properties:SetBaseProperty(otherName, recovered[otherName]))).toBe(true)
				end
			end
			expect(resources:GetMin("Mana")).toBe(10)
			expect(resources:GetMax("Mana")).toBe(100)
			expect(resources:GetCurrent("Mana")).toBe(40)
			expect(changes).toEqual({})
			resources:Step(2)
			expect(resources:GetCurrent("Mana")).toBe(50)

			expect((properties:SetBaseProperty(propertyName, recovered[propertyName]))).toBe(true)
			expect(resources:GetMin("Mana")).toBe(15)
			expect(resources:GetMax("Mana")).toBe(90)
			expect(resources:GetCurrent("Mana")).toBe(50)
			resources:Step(1)
			expect(resources:GetCurrent("Mana")).toBe(59)
		end)
	end

	it("keeps acceptance and prepared costs when a Tag overflows " .. propertyName, function()
		local observed: { { number? } } = {}
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = 20 },
				appliedTags = { "Overflow" },
				onStart = function(context: ActionTypes.ActionExecutionContext)
					local resources: ResourceController =
						context.actor:GetController("ResourceController") :: ResourceController
					table.insert(
						observed,
						{ resources:GetCurrent("Mana"), resources:GetMin("Mana"), resources:GetMax("Mana") }
					)
				end,
			},
		}, { mana }, {
			{
				id = "Overflow",
				visibility = "ServerOnly",
				duplicateBehavior = "Ignore",
				properties = { [propertyName] = { multiply = 1e308 } },
			},
		})
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController, tags: TagController =
			ResourceTestUtils.registerActor()
		expect((resources:AddResource("Mana"))).toBe(true)
		local changes: { ResourceChange } = {}
		resources.OnResourceChanged:Connect(function(change: ResourceChange)
			table.insert(changes, change)
		end)
		actions.OnActionStarted:Connect(function()
			table.insert(observed, { resources:GetCurrent("Mana"), resources:GetMin("Mana"), resources:GetMax("Mana") })
		end)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		expect(properties:GetResolvedProperty(propertyName)).toBe(math.huge)
		expect(observed).toEqual({ { 40, 10, 100 }, { 40, 10, 100 } })
		expect(#changes).toBe(1)
		expect(changes[1]).toEqual({
			actor = _actor,
			resourceId = "Mana",
			currentOldValue = 60,
			currentNewValue = 40,
			minOldValue = 10,
			minNewValue = 10,
			maxOldValue = 100,
			maxNewValue = 100,
		})
		resources:Step(1)
		expect(resources:GetCurrent("Mana")).toBe(45)
		expect((tags:RemoveTag("Overflow"))).toBe(true)
		expect(properties:GetResolvedProperty(propertyName)).toBe(initial[propertyName])
		resources:Step(1)
		expect(resources:GetCurrent("Mana")).toBe(50)
	end)
end
