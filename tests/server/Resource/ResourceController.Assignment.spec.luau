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

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ResourceControllerModule = require(KRF.server.Resource.ResourceController)
local ResourceControllerTestUtils = require(script.Parent.Parent.Utils.Resource.ResourceControllerTestUtils)

local function createActorWithPropertyController(): (Actor, PropertyController)
	return ResourceControllerTestUtils.createActorWithPropertyController()
end

local function createActorWithCustomPropertyController(propertyController: any): Actor
	return ResourceControllerTestUtils.createActorWithCustomPropertyController(propertyController)
end

local function resetAndLoadDefinitions(definitions: { ResourceDefinition }): ()
	ResourceControllerTestUtils.resetAndLoadDefinitions(definitions)
end

it("auto-assigns only resources marked with autoAssign and seeds their property-backed sources", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Stamina",
			min = {
				propertyName = "MinStamina",
				defaultBaseValue = 10,
			},
			max = {
				propertyName = "MaxStamina",
				defaultBaseValue = 60,
			},
			visibility = "ServerOnly",
			autoAssign = true,
			regen = {
				rate = {
					propertyName = "StaminaRegen",
					defaultBaseValue = 5,
				},
			},
		},
		{
			id = "Resource.Focus",
			max = {
				value = 25,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)

	expect(resourceController:HasResource("Resource.Stamina")).toBe(true)
	expect(resourceController:HasResource("Resource.Focus")).toBe(false)
	expect(propertyController:GetBaseProperty("MinStamina")).toBe(10)
	expect(propertyController:GetBaseProperty("MaxStamina")).toBe(60)
	expect(propertyController:GetBaseProperty("StaminaRegen")).toBe(5)
	expect(resourceController:GetMin("Resource.Stamina")).toBe(10)
	expect(resourceController:GetMax("Resource.Stamina")).toBe(60)
	expect(resourceController:GetCurrent("Resource.Stamina")).toBe(60)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("seeds missing sources, preserves existing property values, and uses definition initialValue when adding", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Energy",
			min = {
				propertyName = "MinEnergy",
				defaultBaseValue = 5,
			},
			max = {
				propertyName = "MaxEnergy",
				defaultBaseValue = 50,
			},
			initialValue = 20,
			visibility = "ServerOnly",
			regen = {
				rate = {
					propertyName = "EnergyRegen",
					defaultBaseValue = 4,
				},
			},
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local setMaxOk: boolean, setMaxReason: string? = propertyController:SetBaseProperty("MaxEnergy", 120)
	local setRegenOk: boolean, setRegenReason: string? = propertyController:SetBaseProperty("EnergyRegen", 9)
	expect(setMaxOk).toBe(true)
	expect(setMaxReason).toBeNil()
	expect(setRegenOk).toBe(true)
	expect(setRegenReason).toBeNil()

	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Energy")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(propertyController:GetBaseProperty("MinEnergy")).toBe(5)
	expect(propertyController:GetBaseProperty("MaxEnergy")).toBe(120)
	expect(propertyController:GetBaseProperty("EnergyRegen")).toBe(9)
	expect(resourceController:GetMin("Resource.Energy")).toBe(5)
	expect(resourceController:GetMax("Resource.Energy")).toBe(120)
	expect(resourceController:GetCurrent("Resource.Energy")).toBe(20)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("uses explicit overrides and clamps seeded current values to the resolved bounds", function()
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
			id = "Resource.Shield",
			min = {
				value = 10,
			},
			max = {
				propertyName = "MaxShield",
				defaultBaseValue = 80,
			},
			initialValue = 75,
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local setShieldMaxOk: boolean, setShieldMaxReason: string? = propertyController:SetBaseProperty("MaxShield", 40)
	expect(setShieldMaxOk).toBe(true)
	expect(setShieldMaxReason).toBeNil()

	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addResolveOk: boolean, addResolveReason: string? = resourceController:AddResource("Resource.Resolve", -10)
	local addShieldOk: boolean, addShieldReason: string? = resourceController:AddResource("Resource.Shield")

	expect(addResolveOk).toBe(true)
	expect(addResolveReason).toBeNil()
	expect(addShieldOk).toBe(true)
	expect(addShieldReason).toBeNil()
	expect(resourceController:GetCurrent("Resource.Resolve")).toBe(5)
	expect(resourceController:GetCurrent("Resource.Shield")).toBe(40)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("returns nil before add and rejects unknown, duplicate, and invalid resource assignments", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Guard",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)

	expect(resourceController:GetCurrent("Resource.Guard")).toBeNil()
	expect(resourceController:GetMin("Resource.Guard")).toBeNil()
	expect(resourceController:GetMax("Resource.Guard")).toBeNil()

	local missingOk: boolean, missingReason: string? = resourceController:AddResource("Resource.Unknown")
	local invalidOverrideOk: boolean, invalidOverrideReason: string? =
		resourceController:AddResource("Resource.Guard", "boom" :: any)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Guard")
	local duplicateOk: boolean, duplicateReason: string? = resourceController:AddResource("Resource.Guard")

	expect(missingOk).toBe(false)
	expect(missingReason).toBe("UnknownResourceId:Resource.Unknown")
	expect(invalidOverrideOk).toBe(false)
	expect(invalidOverrideReason).toBe("InvalidResourceOverrideValue")
	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(duplicateOk).toBe(false)
	expect(duplicateReason).toBe("ResourceAlreadyAssigned")

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("rejects resource assignment when the resolved max is below the resolved min", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Posture",
			min = {
				propertyName = "MinPosture",
				defaultBaseValue = 20,
			},
			max = {
				propertyName = "MaxPosture",
				defaultBaseValue = 60,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local setMinOk: boolean, setMinReason: string? = propertyController:SetBaseProperty("MinPosture", 30)
	local setMaxOk: boolean, setMaxReason: string? = propertyController:SetBaseProperty("MaxPosture", 10)
	expect(setMinOk).toBe(true)
	expect(setMinReason).toBeNil()
	expect(setMaxOk).toBe(true)
	expect(setMaxReason).toBeNil()

	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Posture")

	expect(addOk).toBe(false)
	expect(addReason).toBe("ResourceResolvedMaxLessThanResolvedMin")
	expect(resourceController:HasResource("Resource.Posture")).toBe(false)

	resourceController:Destroy()
	propertyController:Destroy()
end)

it("surfaces property-backed source failures during manual add and auto-assign seeding", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Heat",
			max = {
				propertyName = "MaxHeat",
				defaultBaseValue = 25,
			},
			visibility = "ServerOnly",
		},
		{
			id = "Resource.Willpower",
			max = {
				value = 25,
			},
			visibility = "ServerOnly",
			regen = {
				rate = {
					propertyName = "WillpowerRegen",
					defaultBaseValue = 3,
				},
			},
		},
	} :: { ResourceDefinition })

	local failingSeedActor: Actor = createActorWithCustomPropertyController({
		Destroy = function() end,
		HasProperty = function(_self: any, _propertyName: string): boolean
			return false
		end,
		SetBaseProperty = function(_self: any, _propertyName: string, _value: number): (boolean, string?)
			return false, "SeedFailed"
		end,
		GetResolvedProperty = function(_self: any, _propertyName: string): number?
			return nil
		end,
	})
	local failingSeedController: ResourceController = ResourceControllerModule.new(failingSeedActor)
	local seedOk: boolean, seedReason: string? = failingSeedController:AddResource("Resource.Heat")

	expect(seedOk).toBe(false)
	expect(seedReason).toBe("ResourcePropertySeedFailed:MaxHeat:SeedFailed")

	local unresolvedActor: Actor = createActorWithCustomPropertyController({
		Destroy = function() end,
		HasProperty = function(_self: any, _propertyName: string): boolean
			return true
		end,
		SetBaseProperty = function(_self: any, _propertyName: string, _value: number): (boolean, string?)
			return true, nil
		end,
		GetResolvedProperty = function(_self: any, propertyName: string): number?
			if propertyName == "WillpowerRegen" then
				return nil
			end

			return 20
		end,
	})
	local unresolvedController: ResourceController = ResourceControllerModule.new(unresolvedActor)
	local unresolvedOk: boolean, unresolvedReason: string? = unresolvedController:AddResource("Resource.Willpower")

	expect(unresolvedOk).toBe(false)
	expect(unresolvedReason).toBe("ResourcePropertyUnresolved:WillpowerRegen")

	resetAndLoadDefinitions({
		{
			id = "Resource.Breath",
			max = {
				propertyName = "MaxBreath",
				defaultBaseValue = 100,
			},
			visibility = "ServerOnly",
			autoAssign = true,
		},
	} :: { ResourceDefinition })

	local autoAssignActor: Actor = createActorWithCustomPropertyController({
		Destroy = function() end,
		HasProperty = function(_self: any, _propertyName: string): boolean
			return true
		end,
		SetBaseProperty = function(_self: any, _propertyName: string, _value: number): (boolean, string?)
			return true, nil
		end,
		GetResolvedProperty = function(_self: any, _propertyName: string): number?
			return nil
		end,
	})
	local resourceController: ResourceController = ResourceControllerModule.new(autoAssignActor)

	expect(resourceController:HasResource("Resource.Breath")).toBe(false)

	failingSeedController:Destroy()
	unresolvedController:Destroy()
	resourceController:Destroy()
end)

it("uses defaultBaseValue fallbacks when PropertyController is missing", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Stamina",
			min = {
				propertyName = "MinStamina",
				defaultBaseValue = 10,
			},
			max = {
				propertyName = "MaxStamina",
				defaultBaseValue = 60,
			},
			initialValue = 25,
			visibility = "ServerOnly",
			autoAssign = true,
			regen = {
				rate = {
					propertyName = "StaminaRegen",
					defaultBaseValue = 5,
				},
			},
		},
		{
			id = "Resource.Mana",
			max = {
				propertyName = "MaxMana",
				defaultBaseValue = 80,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor = ActorEntity.new()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Mana", 120)

	expect(resourceController:HasResource("Resource.Stamina")).toBe(true)
	expect(resourceController:GetMin("Resource.Stamina")).toBe(10)
	expect(resourceController:GetMax("Resource.Stamina")).toBe(60)
	expect(resourceController:GetCurrent("Resource.Stamina")).toBe(25)
	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(resourceController:GetMin("Resource.Mana")).toBe(0)
	expect(resourceController:GetMax("Resource.Mana")).toBe(80)
	expect(resourceController:GetCurrent("Resource.Mana")).toBe(80)

	resourceController:Destroy()
end)
