--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)

type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController
type ResourceChange = ResourceTypes.ResourceChange
type ResourceController = ResourceTypes.ResourceController
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ResourceControllerModule = require(KRF.server.Resource.ResourceController)
local ResourceControllerTestUtils = require(script.Parent.Parent.Utils.Resource.ResourceControllerTestUtils)

it("restores static regen in units per second and preserves fractional values", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Stamina",
			max = {
				value = 100,
			},
			initialValue = 10,
			visibility = "ServerOnly",
			regen = {
				rate = {
					value = 4,
				},
			},
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Stamina")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	resourceController:Step(2.5)
	resourceController:Step(0.125)

	expect(resourceController:GetCurrent("Resource.Stamina")).toBe(20.5)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("does nothing without regen or when deltaTime is invalid or non-positive", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Focus",
			max = {
				value = 50,
			},
			initialValue = 25,
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Focus")
	local changedCount: number = 0

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(_change: ResourceChange)
		changedCount += 1
	end)

	resourceController:Step(1)
	resourceController:Step(0)
	resourceController:Step(-1)
	resourceController:Step(0 / 0)
	resourceController:Step(math.huge)
	resourceController:Step("invalid" :: any)
	task.wait()
	task.wait()

	expect(resourceController:GetCurrent("Resource.Focus")).toBe(25)
	expect(changedCount).toBe(0)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("clamps regen at max and does not fire a second change for a no-op step", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Guard",
			max = {
				value = 10,
			},
			initialValue = 9,
			visibility = "ServerOnly",
			regen = {
				rate = {
					value = 2,
				},
			},
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Guard")
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	resourceController:Step(1)
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return #changes == 1
	end)).toBe(true)

	expect(resourceController:GetCurrent("Resource.Guard")).toBe(10)
	expect(changes[1].currentOldValue).toBe(9)
	expect(changes[1].currentNewValue).toBe(10)

	resourceController:Step(1)
	task.wait()
	task.wait()

	expect(resourceController:GetCurrent("Resource.Guard")).toBe(10)
	expect(#changes).toBe(1)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("uses later property-backed regen rates without firing for the regen-only recompute", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Mana",
			max = {
				value = 100,
			},
			initialValue = 0,
			visibility = "ServerOnly",
			regen = {
				rate = {
					propertyName = "ManaRegen",
					defaultBaseValue = 2,
				},
			},
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Mana")
	local changedCount: number = 0

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(_change: ResourceChange)
		changedCount += 1
	end)

	resourceController:Step(2)
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return changedCount == 1
	end)).toBe(true)
	expect(resourceController:GetCurrent("Resource.Mana")).toBe(4)

	local setRegenOk: boolean, setRegenReason: string? = propertyController:SetBaseProperty("ManaRegen", 5)
	expect(setRegenOk).toBe(true)
	expect(setRegenReason).toBeNil()
	task.wait()
	task.wait()
	expect(changedCount).toBe(1)

	resourceController:Step(2)
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return changedCount == 2
	end)).toBe(true)
	expect(resourceController:GetCurrent("Resource.Mana")).toBe(14)

	local disableRegenOk: boolean, disableRegenReason: string? = propertyController:SetBaseProperty("ManaRegen", 0)
	expect(disableRegenOk).toBe(true)
	expect(disableRegenReason).toBeNil()
	task.wait()
	task.wait()

	resourceController:Step(2)
	task.wait()
	task.wait()

	expect(resourceController:GetCurrent("Resource.Mana")).toBe(14)
	expect(changedCount).toBe(2)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("recomputes property-backed bounds and clamps current in both directions", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				propertyName = "MinResolve",
				defaultBaseValue = 0,
			},
			max = {
				propertyName = "MaxResolve",
				defaultBaseValue = 100,
			},
			initialValue = 50,
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve")
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	local lowerMaxOk: boolean, lowerMaxReason: string? = propertyController:SetBaseProperty("MaxResolve", 40)
	expect(lowerMaxOk).toBe(true)
	expect(lowerMaxReason).toBeNil()
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return #changes == 1
	end)).toBe(true)

	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(40)
	expect(resourceController:GetMax("Resource.Resolve")).toBe(40)
	expect(changes[1]).toEqual({
		actor = actor,
		resourceId = "Resource.Resolve",
		currentOldValue = 50,
		currentNewValue = 40,
		minOldValue = 0,
		minNewValue = 0,
		maxOldValue = 100,
		maxNewValue = 40,
	})

	local raiseMaxOk: boolean, raiseMaxReason: string? = propertyController:SetBaseProperty("MaxResolve", 100)
	expect(raiseMaxOk).toBe(true)
	expect(raiseMaxReason).toBeNil()
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return #changes == 2
	end)).toBe(true)

	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(40)
	expect(changes[2].currentOldValue).toBe(40)
	expect(changes[2].currentNewValue).toBe(40)
	expect(changes[2].maxOldValue).toBe(40)
	expect(changes[2].maxNewValue).toBe(100)

	local raiseMinOk: boolean, raiseMinReason: string? = propertyController:SetBaseProperty("MinResolve", 60)
	expect(raiseMinOk).toBe(true)
	expect(raiseMinReason).toBeNil()
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return #changes == 3
	end)).toBe(true)

	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(60)
	expect(resourceController:GetMin("Resource.Resolve")).toBe(60)
	expect(changes[3].currentOldValue).toBe(40)
	expect(changes[3].currentNewValue).toBe(60)
	expect(changes[3].minOldValue).toBe(0)
	expect(changes[3].minNewValue).toBe(60)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("preserves the last valid bounds when property-backed bounds become invalid", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Posture",
			min = {
				propertyName = "MinPosture",
				defaultBaseValue = 10,
			},
			max = {
				propertyName = "MaxPosture",
				defaultBaseValue = 100,
			},
			initialValue = 50,
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Posture")
	local changedCount: number = 0

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(_change: ResourceChange)
		changedCount += 1
	end)

	local invalidateOk: boolean, invalidateReason: string? = propertyController:SetBaseProperty("MinPosture", 120)
	expect(invalidateOk).toBe(true)
	expect(invalidateReason).toBeNil()
	task.wait()
	task.wait()

	expect(resourceController:GetCurrent("Resource.Posture")).toBe(50)
	expect(resourceController:GetMin("Resource.Posture")).toBe(10)
	expect(resourceController:GetMax("Resource.Posture")).toBe(100)
	expect(changedCount).toBe(0)

	local restoreValidityOk: boolean, restoreValidityReason: string? =
		propertyController:SetBaseProperty("MaxPosture", 150)
	expect(restoreValidityOk).toBe(true)
	expect(restoreValidityReason).toBeNil()
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return changedCount == 1
	end)).toBe(true)

	expect(resourceController:GetCurrent("Resource.Posture")).toBe(120)
	expect(resourceController:GetMin("Resource.Posture")).toBe(120)
	expect(resourceController:GetMax("Resource.Posture")).toBe(150)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("ignores unrelated property changes without recomputing assigned resources", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Heat",
			max = {
				propertyName = "MaxHeat",
				defaultBaseValue = 100,
			},
			initialValue = 50,
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Heat")
	local changedCount: number = 0

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(_change: ResourceChange)
		changedCount += 1
	end)

	local setUnrelatedOk: boolean, setUnrelatedReason: string? =
		propertyController:SetBaseProperty("UnrelatedResourceProperty", 25)
	expect(setUnrelatedOk).toBe(true)
	expect(setUnrelatedReason).toBeNil()
	task.wait()
	task.wait()

	expect(resourceController:GetCurrent("Resource.Heat")).toBe(50)
	expect(resourceController:GetMax("Resource.Heat")).toBe(100)
	expect(changedCount).toBe(0)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)
