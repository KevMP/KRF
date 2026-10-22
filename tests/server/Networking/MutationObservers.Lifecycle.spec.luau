--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local TagController = require(KRF.server.Tags.TagController)
local ResourceController = require(KRF.server.Resource.ResourceController)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local disconnects: { () -> () } = {}
local connections: { SignalTypes.Connection } = {}

beforeEach(function()
	ActionUtils.reset()
	disconnects = {}
	connections = {}
end)

afterEach(function()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	for _, disconnect in disconnects do
		disconnect()
	end

	ActionUtils.cleanup()
end)

for _, source: string in { "Expiry", "Regeneration" } do
	it(`finishes all due {source} work on every Actor before propagating the first private failure`, function()
		ActionUtils.initialize({}, {
			{
				id = "Mana",
				visibility = "ClientVisible",
				autoAssign = true,
				initialValue = if source == "Expiry" then 100 else 0,
				max = { propertyName = "MaxMana", defaultBaseValue = 100 },
				regen = { rate = { value = 1 } },
			},
			{
				id = "Stamina",
				visibility = "ClientVisible",
				autoAssign = true,
				initialValue = 0,
				max = { value = 100 },
				regen = { rate = { value = 1 } },
			},
		}, {
			{
				id = "Capacity",
				visibility = "ClientVisible",
				duplicateBehavior = "Stack",
				properties = { MaxMana = { multiply = 0.5 } },
			},
		})

		local actors: { ActorTypes.Actor } = {}
		local resourcesByActor: { ResourceTypes.ResourceController } = {}
		local tagsByActor: { TagTypes.TagController } = {}
		local failures: { {} } = {}
		local dispatches: number = 0
		local publicChanges: number = 0
		local expirations: number = 0

		for index = 1, 2 do
			local actor: ActorTypes.Actor, _, publicResources: ResourceTypes.ResourceController, _, publicTags: TagTypes.TagController =
				ActionUtils.registerActor()

			table.insert(actors, actor)
			table.insert(resourcesByActor, publicResources)
			table.insert(tagsByActor, publicTags)
			local original = { actor = index }

			local function fail(): ()
				table.insert(failures, original)
				error(original, 0)
			end

			local function dispatched(): ()
				dispatches += 1
			end

			if source == "Expiry" then
				expect(publicTags:AddTag("Capacity", { duration = 1 })).toBe(true)
				expect(publicTags:AddTag("Capacity", { duration = 1 })).toBe(true)
				local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController
				table.insert(disconnects, tags:_observeMutations({ Commit = fail, Dispatch = dispatched }))

				table.insert(
					connections,
					tags.OnTagExpired:Connect(function(): ()
						expirations += 1
					end)
				)
			else
				local resources: ResourceTypes.InternalResourceController =
					publicResources :: ResourceTypes.InternalResourceController

				table.insert(disconnects, resources:_observeMutations({ Commit = fail, Dispatch = dispatched }))
			end

			table.insert(
				connections,
				publicResources.OnResourceChanged:Connect(function(): ()
					publicChanges += 1
				end)
			)
		end

		local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()

		local function step(): ()
			if source == "Expiry" then
				TagController.Step(1)
			else
				ResourceController.Step(1)
			end
		end

		local success: boolean, failure: any = pcall(step)
		expect(success).toBe(false)
		expect(failure).toBe(failures[1])
		expect(#failures).toBe(4)
		expect(dispatches).toBe(4)
		expect(publicChanges).toBe(4)
		expect(expirations).toBe(if source == "Expiry" then 4 else 0)
		expect(#commits).toBe(if source == "Expiry" then 8 else 0)

		for index, actor: ActorTypes.Actor in actors do
			expect(tagsByActor[index]:HasTag("Capacity")).toBe(false)
			expect(resourcesByActor[index]:GetMax("Mana")).toBe(100)
			expect(resourcesByActor[index]:GetCurrent("Mana")).toBe(if source == "Expiry" then 25 else 1)
			expect(resourcesByActor[index]:GetCurrent("Stamina")).toBe(if source == "Expiry" then 0 else 1)
			local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
			assert(baseline ~= nil, "Expected retained Actor publication")
			expect(baseline.domains["KRF.Tags"].value).toEqual({})
			expect(baseline.domains["KRF.Resources"].value.Mana.max).toBe(100)
		end

		for _, disconnect in disconnects do
			disconnect()
		end

		step()
		expect(#failures).toBe(4)
		expect(dispatches).toBe(4)
		expect(expirations).toBe(if source == "Expiry" then 4 else 0)
		expect(publicChanges).toBe(if source == "Expiry" then 4 else 8)

		if source == "Regeneration" then
			for _, resources: ResourceTypes.ResourceController in resourcesByActor do
				expect(resources:GetCurrent("Mana")).toBe(2)
				expect(resources:GetCurrent("Stamina")).toBe(2)
			end
		end
	end)
end

it("retains the original Tag observer error when that observer destroys the controller", function()
	ActionUtils.initialize({}, {}, {
		{ id = "Marker", visibility = "ClientVisible", duplicateBehavior = "Stack" },
	})

	local _, _, _, _, publicTags: TagTypes.TagController = ActionUtils.registerActor()
	local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController
	local original = { reason = "TeardownFailure" }
	local notifications: number = 0

	table.insert(
		connections,
		tags.OnTagAdded:Connect(function(): ()
			notifications += 1
		end)
	)

	table.insert(
		disconnects,
		tags:_observeMutations({
			Commit = function(): ()
				tags:Destroy()
				error(original, 0)
			end,
			Dispatch = function(): ()
				error("Destroyed observer dispatched", 0)
			end,
		})
	)

	local success: boolean, failure: any = pcall(function(): ()
		tags:AddTag("Marker", { duration = 1 })
	end)

	expect(success).toBe(false)
	expect(failure).toBe(original)
	expect(notifications).toBe(0)
	expect(tags:GetActiveTags()).toEqual({})
	local added: boolean, reason: string? = tags:AddTag("Marker", { duration = 1 })
	expect(added).toBe(false)
	expect(reason).toBe("TagControllerDestroyed")
	expect(tags:GetActiveTags()).toEqual({})
	TagController.Step(1)
end)

it("does not mutate retained Property truth or accept private observers after controller destruction", function()
	ActionUtils.initialize({}, {}, {})

	local _, _, _, publicProperties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
		ActionUtils.registerActor()

	local properties: PropertyTypes.InternalPropertyController =
		publicProperties :: PropertyTypes.InternalPropertyController

	local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController
	properties:Destroy()
	local success: boolean, reason: string? = properties:SetBaseProperty("WalkSpeed", 25)
	expect(success).toBe(false)
	expect(reason).toBe("PropertyControllerDestroyed")
	expect(properties:GetResolvedProperty("WalkSpeed")).toBe(16)

	expect(function(): ()
		properties:_observeResolvedMutations({ Commit = function() end, Dispatch = function() end })
	end).toThrow("PropertyControllerDestroyed")

	tags:Destroy()

	expect(function(): ()
		tags:_observeMutations({ Commit = function() end, Dispatch = function() end })
	end).toThrow("TagControllerDestroyed")
end)
