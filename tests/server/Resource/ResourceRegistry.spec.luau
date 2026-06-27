--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ResourceTypes: unknown = require(KRF.server.Resource.types)
local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)

type ResourceRegistry = ResourceTypes.ResourceRegistry
type ResourceDefinition = ResourceTypes.ResourceDefinition
type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition

local Registry: ResourceRegistry = ResourceRegistry

local function createMinimalResourceDefinition(): ResourceDefinition
	return {
		id = "Resource.Stamina",
		max = {
			value = 100,
		},
		visibility = "ServerOnly",
	}
end

it("ResourceRegistry.Load defaults min and autoAssign without inventing an initialValue", function()
	Registry._resetForTests()

	local definitions: { ResourceDefinition } = {
		createMinimalResourceDefinition(),
	}

	local loaded: boolean, reason: string? = Registry.Load(definitions)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	expect(Registry.IsLoaded()).toBe(true)

	local loadedDefinition: LoadedResourceDefinition? = Registry.Get("Resource.Stamina")
	expect(loadedDefinition).never.toBeNil()
	expect((loadedDefinition :: LoadedResourceDefinition).id).toBe("Resource.Stamina")
	expect((loadedDefinition :: LoadedResourceDefinition).min.value).toBe(0)
	expect((loadedDefinition :: LoadedResourceDefinition).max.value).toBe(100)
	expect((loadedDefinition :: LoadedResourceDefinition).initialValue).toBeNil()
	expect((loadedDefinition :: LoadedResourceDefinition).autoAssign).toBe(false)
	expect((loadedDefinition :: LoadedResourceDefinition).regen).toBeNil()
end)

it("ResourceRegistry.Load preserves explicit values and property-backed sources in loaded definitions", function()
	Registry._resetForTests()

	local definitions: { ResourceDefinition } = {
		{
			id = "Resource.Mana",
			min = {
				propertyName = "MinMana",
				defaultBaseValue = -10,
			},
			max = {
				propertyName = "MaxMana",
				defaultBaseValue = 75,
			},
			initialValue = 25,
			visibility = "ClientVisible",
			autoAssign = true,
			regen = {
				rate = {
					propertyName = "ManaRegen",
					defaultBaseValue = 5,
				},
			},
		},
		{
			id = "Resource.Focus",
			max = {
				propertyName = "MaxFocus",
				defaultBaseValue = 40,
			},
			visibility = "ServerOnly",
		},
	}

	local loaded: boolean, reason: string? = Registry.Load(definitions)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()

	local loadedDefinition: LoadedResourceDefinition = Registry.Get("Resource.Mana") :: LoadedResourceDefinition
	expect(loadedDefinition.min.propertyName).toBe("MinMana")
	expect(loadedDefinition.min.defaultBaseValue).toBe(-10)
	expect(loadedDefinition.max.propertyName).toBe("MaxMana")
	expect(loadedDefinition.max.defaultBaseValue).toBe(75)
	expect(loadedDefinition.initialValue).toBe(25)
	expect(loadedDefinition.visibility).toBe("ClientVisible")
	expect(loadedDefinition.autoAssign).toBe(true)
	expect((loadedDefinition.regen :: any).rate.propertyName).toBe("ManaRegen")
	expect((loadedDefinition.regen :: any).rate.defaultBaseValue).toBe(5)

	local focusDefinition: LoadedResourceDefinition = Registry.Get("Resource.Focus") :: LoadedResourceDefinition
	expect(focusDefinition.initialValue).toBeNil()
end)

it("ResourceRegistry.Load remains atomic when a later definition fails validation", function()
	Registry._resetForTests()

	local loaded: boolean, reason: string? = Registry.Load({
		createMinimalResourceDefinition(),
		{
			id = "Resource.Broken",
			max = {
				value = 50,
			},
			visibility = "Everyone" :: any,
		},
	})

	expect(loaded).toBe(false)
	expect(reason).toBe("ResourceVisibilityInvalid")
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("Resource.Stamina")).toBeNil()
	expect(#Registry.GetAll()).toBe(0)
	expect(Registry.GetAllById()["Resource.Stamina"]).toBeNil()
end)

it("ResourceRegistry.Get, GetAll, and GetAllById expose stable loaded definitions after startup load", function()
	Registry._resetForTests()

	local definitions: { ResourceDefinition } = {
		createMinimalResourceDefinition(),
		{
			id = "Resource.Energy",
			max = {
				value = 60,
			},
			initialValue = 30,
			visibility = "ClientVisible",
		},
	}

	local loaded: boolean, reason: string? = Registry.Load(definitions)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()

	local staminaDefinition: LoadedResourceDefinition = Registry.Get("Resource.Stamina") :: LoadedResourceDefinition
	local energyDefinition: LoadedResourceDefinition = Registry.Get("Resource.Energy") :: LoadedResourceDefinition
	local allDefinitions: { LoadedResourceDefinition } = Registry.GetAll()
	local allDefinitionsById: { [string]: LoadedResourceDefinition } = Registry.GetAllById()

	expect(staminaDefinition.initialValue).toBeNil()
	expect(energyDefinition.initialValue).toBe(30)
	expect(#allDefinitions).toBe(2)
	expect(allDefinitions[1]).toBe(staminaDefinition)
	expect(allDefinitions[2]).toBe(energyDefinition)
	expect(allDefinitionsById["Resource.Stamina"]).toBe(staminaDefinition)
	expect(allDefinitionsById["Resource.Energy"]).toBe(energyDefinition)
	expect(Registry.Get("Resource.Unknown")).toBeNil()

	local mutateLoadedDefinitionSucceeded: boolean = pcall(function()
		staminaDefinition.initialValue = 50
	end)
	expect(mutateLoadedDefinitionSucceeded).toBe(false)

	local mutateLoadedDefinitionMinSucceeded: boolean = pcall(function()
		(staminaDefinition.min :: any).value = 10
	end)
	expect(mutateLoadedDefinitionMinSucceeded).toBe(false)

	local mutateAllDefinitionsSucceeded: boolean = pcall(function()
		table.insert(allDefinitions, staminaDefinition)
	end)
	expect(mutateAllDefinitionsSucceeded).toBe(false)

	local mutateAllDefinitionsByIdSucceeded: boolean = pcall(function()
		allDefinitionsById["Resource.New"] = staminaDefinition
	end)
	expect(mutateAllDefinitionsByIdSucceeded).toBe(false)
end)

it("ResourceRegistry rejects a second load after a successful startup load", function()
	Registry._resetForTests()

	local firstLoaded: boolean, firstReason: string? = Registry.Load({
		createMinimalResourceDefinition(),
	})
	expect(firstLoaded).toBe(true)
	expect(firstReason).toBeNil()

	local secondLoaded: boolean, secondReason: string? = Registry.Load({
		{
			id = "Resource.Mana",
			max = {
				value = 50,
			},
			visibility = "ServerOnly",
		},
	})
	expect(secondLoaded).toBe(false)
	expect(secondReason).toBe("ResourceDefinitionsAlreadyLoaded")
end)
