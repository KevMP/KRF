--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local Server = require(KRF.server)
local PropertyRegistry = require(KRF.server.Property.PropertyRegistry)
local PropertyTypes = require(KRF.server.Property.types)
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local TagTypes = require(KRF.server.Tags.types)
local ActionTypes = require(KRF.server.Action.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local PropertyController = require(KRF.server.Property.PropertyController)
local TagController = require(KRF.server.Tags.TagController)
local ResourceController = require(KRF.server.Resource.ResourceController)

local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}

JestGlobals.beforeEach(function()
	Server._ResetForTests()
	TagController._setAutomaticSteppingEnabledForTests(false)
	ResourceController._setAutomaticSteppingEnabledForTests(false)
end)

local referenceCases: { { system: string, config: any, load: () -> (boolean, string?), unknownReason: string } } = {
	{
		system = "Tag",
		config = {
			tags = {
				{
					id = "Buff",
					visibility = "ServerOnly",
					duplicateBehavior = "Ignore",
					properties = { Defense = { add = 1 } },
				},
			},
		},
		load = function(): (boolean, string?)
			return TagRegistry.Load({
				{
					id = "Buff",
					visibility = "ServerOnly",
					duplicateBehavior = "Ignore",
					properties = { Defense = { add = 1 } },
				},
			})
		end,
		unknownReason = "UnknownPropertyId:Defense",
	},
	{
		system = "Resource",
		config = { resources = { { id = "Guard", visibility = "ServerOnly", max = { propertyName = "Defense" } } } },
		load = function(): (boolean, string?)
			return ResourceRegistry.Load({
				{ id = "Guard", visibility = "ServerOnly", max = { propertyName = "Defense" } },
			})
		end,
		unknownReason = "UnknownPropertyId:Defense",
	},
	{
		system = "Action",
		config = {
			resources = { { id = "Guard", visibility = "ServerOnly", max = { value = 100 } } },
			actions = {
				function(): ActionTypes.ActionDefinition
					return {
						id = "Block",
						visibility = "ServerOnly",
						costs = { Guard = { amount = 1, multiplierProperty = "Defense" } },
					}
				end,
			},
		},
		load = function(): (boolean, string?)
			return ActionRegistry.Load({
				function(): ActionTypes.ActionDefinition
					return {
						id = "Block",
						visibility = "ServerOnly",
						costs = { Guard = { amount = 1, multiplierProperty = "Defense" } },
					}
				end,
			}, {}, { Guard = true })
		end,
		unknownReason = "ActionCostMultiplierPropertyUnknown:Defense",
	},
}

for _, case in referenceCases do
	it("checks " .. case.system .. " references during preparation and direct loading", function()
		local loaded, reason = case.load()
		expect(loaded).toBe(false)
		expect(reason).toBe("PropertyDefinitionsNotLoaded")
		assert(PropertyRegistry.Load({}))
		loaded, reason = case.load()
		expect(loaded).toBe(false)
		expect(reason).toBe(case.unknownReason)
		Server._ResetForTests()
		local started, failure = Server.Init(case.config)
		expect(started).toBe(false)
		expect(failure).toEqual({ system = case.system, reason = case.unknownReason })
		expect(PropertyRegistry.IsLoaded()).toBe(false)
		Server._ResetForTests()

		local config = table.clone(case.config)
		config.properties = { { id = "Defense", defaultBaseValue = 10 } }
		started, failure = Server.Init(config)
		expect(started).toBe(true)
		expect(failure).toBeNil()
		Server._ResetForTests()
		assert(PropertyRegistry.Load({ { id = "Defense", defaultBaseValue = 10 } }))
		loaded, reason = case.load()
		expect(loaded).toBe(true)
		expect(reason).toBeNil()
	end)
end

JestGlobals.afterEach(function()
	for _, actor in actors do
		ActorRuntime.UnregisterActor(actor, "TestCleanup")
	end

	for _, model in models do
		model:Destroy()
	end

	table.clear(actors)
	table.clear(models)
	TagController._setAutomaticSteppingEnabledForTests(true)
	ResourceController._setAutomaticSteppingEnabledForTests(true)
	Server._ResetForTests()
end)

local function model(): Model
	local created: Model = Instance.new("Model")
	created.Parent = workspace
	table.insert(models, created)

	return created
end

local function register(options: ActorTypes.RegisterActorOpts?): ActorTypes.Actor
	local actor, reason = ActorRuntime.RegisterActor(model(), options)
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	table.insert(actors, actor)

	return actor
end

local stamina: ResourceTypes.ResourceDefinition = {
	id = "Stamina",
	max = { propertyName = "MaxStamina" },
	regen = { rate = { propertyName = "StaminaRegen" } },
	autoAssign = true,
	visibility = "ServerOnly",
}

it(
	"installs initial bases within the dependency-sorted pass before Resources and custom factories read them",
	function()
		local order: { string } = {}

		local started, failure = Server.Init({
			properties = {
				{ id = "MaxStamina", defaultBaseValue = 100 },
				{ id = "StaminaRegen", defaultBaseValue = 5 },
				{ id = "Defense", defaultBaseValue = 10 },
			},
			resources = { stamina },
			tags = {
				{
					id = "Rested",
					visibility = "ServerOnly",
					duplicateBehavior = "Ignore",
					properties = { MaxStamina = { add = 25 } },
				},
			},
			controllers = {
				{
					key = "Last",
					dependsOn = { "First" },
					factory = function(actor: ActorTypes.Actor)
						expect(actor:GetController("First")).never.toBeNil()
						table.insert(order, "Last")

						return { Destroy = function() end }
					end,
				},
				{
					key = "First",
					dependsOn = { "PropertyController" },
					factory = function(actor: ActorTypes.Actor)
						local properties = actor:GetController("PropertyController") :: PropertyTypes.PropertyController
						expect(properties:GetBaseProperty("MaxStamina")).toBe(150)
						expect(properties:GetResolvedProperty("Defense")).toBe(20)
						table.insert(order, "First")

						return { Destroy = function() end }
					end,
				},
			},
		})

		expect(started).toBe(true)
		expect(failure).toBeNil()
		local actor = register({ properties = { MaxStamina = 150, Defense = 20 } })
		expect(order).toEqual({ "First", "Last" })
		local resources = actor:GetController("ResourceController") :: ResourceTypes.ResourceController
		local properties = actor:GetController("PropertyController") :: PropertyTypes.PropertyController
		local tags = actor:GetController("TagController") :: TagTypes.TagController
		expect(resources:GetCurrent("Stamina")).toBe(150)
		expect(resources:GetMax("Stamina")).toBe(150)
		expect(properties:GetBaseProperty("StaminaRegen")).toBe(5)
		expect((tags:AddTag("Rested"))).toBe(true)
		expect(resources:GetMax("Stamina")).toBe(175)
		expect(resources:GetCurrent("Stamina")).toBe(150)
	end
)

local invalidOptions: { { value: any, reason: string } } = {
	{ value = false, reason = "InvalidActorRegistrationOptions" },
	{ value = { other = true }, reason = "InvalidActorRegistrationOptions" },
	{ value = { properties = false }, reason = "InvalidActorProperties" },
	{ value = { properties = { [1] = 2 } }, reason = "InvalidPropertyId" },
	{ value = { properties = { [""] = 2 } }, reason = "InvalidPropertyId" },
	{ value = { properties = { Unknown = 2 } }, reason = "UnknownPropertyId" },
	{ value = { properties = { WalkSpeed = "2" } }, reason = "InvalidInitialPropertyValue" },
	{ value = { properties = { WalkSpeed = math.huge } }, reason = "InvalidInitialPropertyValue" },
	{ value = { properties = { WalkSpeed = 0 / 0 } }, reason = "InvalidInitialPropertyValue" },
}

for index, case in invalidOptions do
	it("rejects malformed registration options before binding or notifications: " .. tostring(index), function()
		assert((Server.Init({})), "Expected server startup")
		local target = model()
		local events: number = 0

		local connection = ActorRuntime.OnActorRegistered:Connect(function()
			events += 1
		end)

		local actor, reason = ActorRuntime.RegisterActor(target, case.value)
		connection:Disconnect()
		expect(actor).toBeNil()
		expect(reason).toBe(case.reason)
		expect(ActorRegistry.GetActorByModel(target)).toBeNil()
		expect(events).toBe(0)
		local valid = register({ properties = {} })
		expect(valid.enabled).toBe(true)
	end)
end

it("prepares owned defaults before factories and publishes them only in the startup transaction", function()
	local definition: PropertyTypes.PropertyDefinition = { id = "MaxStamina", defaultBaseValue = 100 }

	local started, failure = Server.Init({
		properties = { definition, { id = "StaminaRegen", defaultBaseValue = 5 } },
		resources = { stamina },
		actions = {
			function(): ActionTypes.ActionDefinition
				expect(PropertyRegistry.IsLoaded()).toBe(false)
				definition.defaultBaseValue = -1

				return { id = "Rest", visibility = "ServerOnly" }
			end,
		},
	})

	expect(started).toBe(true)
	expect(failure).toBeNil()
	local actor = register(nil)
	local resources = actor:GetController("ResourceController") :: ResourceTypes.ResourceController
	expect(resources:GetMax("Stamina")).toBe(100)
end)

it("rejects malformed Property configuration before evaluating Action factories", function()
	local calls: number = 0

	local started, failure = Server.Init({
		properties = false :: any,
		actions = {
			function(): ActionTypes.ActionDefinition
				calls += 1

				return { id = "Rest", visibility = "ServerOnly" }
			end,
		},
	})

	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Property", reason = "PropertyDefinitionsMustBeTable" })
	expect(calls).toBe(0)
	expect(PropertyRegistry.IsLoaded()).toBe(false)
end)

it("includes PropertyRegistry in loaded-catalog conflicts and failed-publication rollback", function()
	assert(PropertyRegistry.Load({}))
	local started, failure = Server.Init({})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Server", reason = "CatalogAlreadyLoaded" })
	Server._ResetForTests()
	local original = TagRegistry.Load

	TagRegistry.Load = function(): (boolean, string?)
		expect(PropertyRegistry.IsLoaded()).toBe(true)

		return false, "ExpectedPublicationFailure"
	end

	local success, result, reason = pcall(function()
		return Server.Init({})
	end)

	TagRegistry.Load = original
	expect(success).toBe(true)
	expect(result).toBe(false)
	expect(reason).toEqual({ system = "Tag", reason = "ExpectedPublicationFailure" })
	expect(PropertyRegistry.IsLoaded()).toBe(false)
	expect(PropertyRegistry.GetAll()).toEqual({})
	expect(ResourceRegistry.IsLoaded()).toBe(false)
	expect(ActionRegistry.IsLoaded()).toBe(false)
end)

it("applies built-in overrides and custom assignment defaults on newly registered Actors", function()
	assert((Server.Init({
		properties = {
			{ id = "WalkSpeed", defaultBaseValue = 24 },
			{ id = "JumpPower", defaultBaseValue = 70, autoAssign = false },
			{ id = "Defense", defaultBaseValue = 10, autoAssign = true },
			{ id = "Armor", defaultBaseValue = 20 },
		},
	})), "Expected server startup")

	local actor = register(nil)
	local properties = actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	expect(properties:GetResolvedProperty("WalkSpeed")).toBe(24)
	expect(properties:HasProperty("JumpPower")).toBe(false)
	expect(properties:GetBaseProperty("Defense")).toBe(10)
	expect(properties:HasProperty("Armor")).toBe(false)
end)

it("requires a loaded catalog and rejects invalid IDs before state or events", function()
	local actor = ActorEntity.new()
	expect((pcall(PropertyController.new, actor))).toBe(false)
	assert(PropertyRegistry.Load({ { id = "Defense", defaultBaseValue = 10 } }))
	local properties = PropertyController.new(actor) :: PropertyTypes.InternalPropertyController
	local events: number = 0

	properties.OnPropertyChanged:Connect(function()
		events += 1
	end)

	for _, id: any in { false, 1, {}, "", "Unknown" } do
		local accepted, reason = properties:SetBaseProperty(id, 20)
		expect(accepted).toBe(false)
		expect(reason).toBe(if id == "Unknown" then "UnknownPropertyId" else "InvalidPropertyId")
	end

	local accepted, reason = properties:SetBaseProperty(nil :: any, 20)
	expect(accepted).toBe(false)
	expect(reason).toBe("InvalidPropertyId")
	expect(events).toBe(0)
	expect(properties:GetBaseProperty("Defense")).toBeNil()
	properties:_initializeBaseProperties({ Defense = 30 })
	expect(events).toBe(0)
	expect(properties:GetResolvedProperty("Defense")).toBe(30)
	expect((properties:SetBaseProperty("Defense", 40))).toBe(true)
	expect(events).toBe(1)
	properties:Destroy()
end)
