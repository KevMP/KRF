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
type ResourceController = ResourceTypes.ResourceController
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ResourceControllerModule = require(KRF.server.Resource.ResourceController)
local ResourceControllerTestUtils = require(script.Parent.Parent.Utils.Resource.ResourceControllerTestUtils)

local function createActorWithPropertyController(): (Actor, PropertyController)
	return ResourceControllerTestUtils.createActorWithPropertyController()
end

local function resetAndLoadDefinitions(definitions: { ResourceDefinition }): ()
	ResourceControllerTestUtils.resetAndLoadDefinitions(definitions)
end

it("updates current values, clamps out-of-bounds inputs, and rejects invalid SetCurrent calls", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 5,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
		{
			id = "Resource.Focus",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local setCurrentOk: boolean, setCurrentReason: string? = resourceController:SetCurrent("Resource.Resolve", 20)

	expect(setCurrentOk).toBe(true)
	expect(setCurrentReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(20)

	local setAboveMaxOk: boolean, setAboveMaxReason: string? = resourceController:SetCurrent("Resource.Resolve", 999)

	expect(setAboveMaxOk).toBe(true)
	expect(setAboveMaxReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(30)

	local setBelowMinOk: boolean, setBelowMinReason: string? = resourceController:SetCurrent("Resource.Resolve", -100)

	expect(setBelowMinOk).toBe(true)
	expect(setBelowMinReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(5)

	local missingOk: boolean, missingReason: string? = resourceController:SetCurrent("Resource.Focus", 10)

	expect(missingOk).toBe(false)
	expect(missingReason).toBe("ResourceNotAssigned")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(5)

	local invalidOk: boolean, invalidReason: string? = resourceController:SetCurrent("Resource.Resolve", "boom" :: any)

	expect(invalidOk).toBe(false)
	expect(invalidReason).toBe("InvalidResourceValue")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(5)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("returns true only when enough spendable value exists and rejects invalid CanSpend calls", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
		{
			id = "Resource.Focus",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local canSpendSmallOk: boolean, canSpendSmallReason: string? = resourceController:CanSpend("Resource.Resolve", 5)

	expect(canSpendSmallOk).toBe(true)
	expect(canSpendSmallReason).toBeNil()

	local canSpendLargeOk: boolean, canSpendLargeReason: string? = resourceController:CanSpend("Resource.Resolve", 6)

	expect(canSpendLargeOk).toBe(false)
	expect(canSpendLargeReason).toBe("InsufficientResourceValue")

	local missingOk: boolean, missingReason: string? = resourceController:CanSpend("Resource.Focus", 1)

	expect(missingOk).toBe(false)
	expect(missingReason).toBe("ResourceNotAssigned")

	local invalidTypeOk: boolean, invalidTypeReason: string? =
		resourceController:CanSpend("Resource.Resolve", "boom" :: any)

	expect(invalidTypeOk).toBe(false)
	expect(invalidTypeReason).toBe("InvalidResourceAmount")

	local invalidNegativeOk: boolean, invalidNegativeReason: string? =
		resourceController:CanSpend("Resource.Resolve", -1)

	expect(invalidNegativeOk).toBe(false)
	expect(invalidNegativeReason).toBe("InvalidResourceAmount")

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("subtracts current value only when enough spendable value exists and rejects invalid Spend calls", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
		{
			id = "Resource.Focus",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local spendOk: boolean, spendReason: string? = resourceController:Spend("Resource.Resolve", 5)

	expect(spendOk).toBe(true)
	expect(spendReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	local insufficientOk: boolean, insufficientReason: string? = resourceController:Spend("Resource.Resolve", 1)

	expect(insufficientOk).toBe(false)
	expect(insufficientReason).toBe("InsufficientResourceValue")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	local missingOk: boolean, missingReason: string? = resourceController:Spend("Resource.Focus", 1)

	expect(missingOk).toBe(false)
	expect(missingReason).toBe("ResourceNotAssigned")

	local invalidTypeOk: boolean, invalidTypeReason: string? =
		resourceController:Spend("Resource.Resolve", "boom" :: any)

	expect(invalidTypeOk).toBe(false)
	expect(invalidTypeReason).toBe("InvalidResourceAmount")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	local invalidNegativeOk: boolean, invalidNegativeReason: string? = resourceController:Spend("Resource.Resolve", -1)

	expect(invalidNegativeOk).toBe(false)
	expect(invalidNegativeReason).toBe("InvalidResourceAmount")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("adds current value up to the resolved max and rejects invalid Restore calls", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
		{
			id = "Resource.Focus",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local restoreOk: boolean, restoreReason: string? = resourceController:Restore("Resource.Resolve", 5)

	expect(restoreOk).toBe(true)
	expect(restoreReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(20)

	local clampOk: boolean, clampReason: string? = resourceController:Restore("Resource.Resolve", 50)

	expect(clampOk).toBe(true)
	expect(clampReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(30)

	local missingOk: boolean, missingReason: string? = resourceController:Restore("Resource.Focus", 1)

	expect(missingOk).toBe(false)
	expect(missingReason).toBe("ResourceNotAssigned")

	local invalidTypeOk: boolean, invalidTypeReason: string? =
		resourceController:Restore("Resource.Resolve", "boom" :: any)

	expect(invalidTypeOk).toBe(false)
	expect(invalidTypeReason).toBe("InvalidResourceAmount")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(30)

	local invalidNegativeOk: boolean, invalidNegativeReason: string? =
		resourceController:Restore("Resource.Resolve", -1)

	expect(invalidNegativeOk).toBe(false)
	expect(invalidNegativeReason).toBe("InvalidResourceAmount")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(30)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("subtracts current value down to the resolved min and rejects invalid Drain calls", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
		{
			id = "Resource.Focus",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local drainOk: boolean, drainReason: string? = resourceController:Drain("Resource.Resolve", 3)

	expect(drainOk).toBe(true)
	expect(drainReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(12)

	local clampOk: boolean, clampReason: string? = resourceController:Drain("Resource.Resolve", 50)

	expect(clampOk).toBe(true)
	expect(clampReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	local missingOk: boolean, missingReason: string? = resourceController:Drain("Resource.Focus", 1)

	expect(missingOk).toBe(false)
	expect(missingReason).toBe("ResourceNotAssigned")

	local invalidTypeOk: boolean, invalidTypeReason: string? =
		resourceController:Drain("Resource.Resolve", "boom" :: any)

	expect(invalidTypeOk).toBe(false)
	expect(invalidTypeReason).toBe("InvalidResourceAmount")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	local invalidNegativeOk: boolean, invalidNegativeReason: string? = resourceController:Drain("Resource.Resolve", -1)

	expect(invalidNegativeOk).toBe(false)
	expect(invalidNegativeReason).toBe("InvalidResourceAmount")
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(10)

	resourceController:Destroy()
	propertyController:Destroy()
end)
