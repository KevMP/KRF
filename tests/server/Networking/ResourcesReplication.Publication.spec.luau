--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ResourceTypes = require(KRF.server.Resource.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Adapter = require(KRF.server.Networking.utils.ResourcesReplication)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

local function expectManaPatch(
	value: number,
	minimum: number?,
	maximum: number?,
	rate: number?,
	anchorTime: number?
): ()
	expect(#fixture.commits).toBe(1)
	expect(fixture.commits[1].events).toEqual({})

	expect(fixture.commits[1].patches).toEqual({
		{
			domainId = "KRF.Resources",
			patch = {
				kind = "Map",
				entries = {
					["Resource.Mana"] = {
						anchorValue = value,
						anchorTime = anchorTime or 1001,
						min = minimum or 0,
						max = maximum or 100,
						regenRate = if rate ~= nil then rate else 10,
					},
				},
				removed = {},
			},
		},
	})
end

for _, case: { operation: string, amount: number, value: number } in
	{
		{ operation = "SetCurrent", amount = 25, value = 25 },
		{ operation = "Spend", amount = 15, value = 25 },
		{ operation = "Restore", amount = 15, value = 55 },
		{ operation = "Drain", amount = 15, value = 25 },
	}
do
	it("reanchors only the touched Map key on explicit " .. case.operation, function()
		TestUtils.attach(fixture)
		fixture.clock.now = 1001

		local mutate: (ResourceTypes.ResourceController, string, number) -> (boolean, string?) = (
			fixture.resources :: any
		)[case.operation]

		local success: boolean, reason: string? = mutate(fixture.resources, "Resource.Mana", case.amount)
		expect(reason).toBeNil()
		expect(success).toBe(true)
		expectManaPatch(case.value)

		expect(TestUtils.snapshot(fixture)["Resource.Stamina"]).toEqual({
			anchorValue = 20,
			anchorTime = 1000,
			min = 0,
			max = 100,
			regenRate = 5,
		})
	end)
end

it("adds one post-clamp visible assignment with no semantic Resource event", function()
	TestUtils.attach(fixture)
	fixture.clock.now = 1001
	expect(fixture.resources:AddResource("Resource.Rage", 80)).toBe(true)
	expect(#fixture.commits).toBe(1)
	expect(fixture.commits[1].events).toEqual({})

	expect(fixture.commits[1].patches).toEqual({
		{
			domainId = "KRF.Resources",
			patch = {
				kind = "Map",
				entries = { ["Resource.Rage"] = { anchorValue = 50, anchorTime = 1001, min = 0, max = 50 } },
				removed = {},
			},
		},
	})
end)

for _, case: { name: string, property: string, value: number, current: number, min: number, max: number, rate: number } in
	{
		{
			name = "max increase without clamp",
			property = "ManaMax",
			value = 150,
			current = 40,
			min = 0,
			max = 150,
			rate = 10,
		},
		{
			name = "max decrease with clamp",
			property = "ManaMax",
			value = 30,
			current = 30,
			min = 0,
			max = 30,
			rate = 10,
		},
		{
			name = "min increase without clamp",
			property = "ManaMin",
			value = 10,
			current = 40,
			min = 10,
			max = 100,
			rate = 10,
		},
		{
			name = "min increase with clamp",
			property = "ManaMin",
			value = 50,
			current = 50,
			min = 50,
			max = 100,
			rate = 10,
		},
		{ name = "regen rate only", property = "ManaRegen", value = 25, current = 40, min = 0, max = 100, rate = 25 },
		{ name = "zero regen", property = "ManaRegen", value = 0, current = 40, min = 0, max = 100, rate = 0 },
		{ name = "negative regen", property = "ManaRegen", value = -5, current = 40, min = 0, max = 100, rate = -5 },
	}
do
	it("publishes one coherent resulting anchor after Property recompute: " .. case.name, function()
		TestUtils.attach(fixture)
		fixture.clock.now = 1001

		local propertySawPublished: boolean = false

		fixture.properties.OnResolvedPropertyChanged:Connect(function()
			propertySawPublished = #fixture.commits == 1
		end)

		expect(fixture.properties:SetBaseProperty(case.property, case.value)).toBe(true)
		expectManaPatch(case.current, case.min, case.max, case.rate)
		expect(propertySawPublished).toBe(true)
		expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(case.current)
	end)
end

it("captures each batched Resource once from final truth before one N3 publication boundary", function()
	TestUtils.attach(fixture)
	fixture.clock.now = 1001

	local queried: { string } = {}
	local originalQuery = fixture.resources._getReplicationState

	fixture.resources._getReplicationState = function(
		self: ResourceTypes.InternalResourceController,
		id: string
	): ResourceTypes.ResourceReplicationState?
		table.insert(queried, id)

		return originalQuery(self, id)
	end

	fixture.resources:_beginMutationBatch()
	expect(fixture.resources:Spend("Resource.Stamina", 5)).toBe(true)
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	expect(fixture.resources:Spend("Resource.Mana", 10)).toBe(true)
	expect(fixture.commits).toEqual({})
	fixture.resources:_finishMutationBatch()
	expect(queried).toEqual({ "Resource.Mana", "Resource.Stamina" })
	expect(#fixture.commits).toBe(1)

	expect(fixture.commits[1].patches).toEqual({
		{
			domainId = "KRF.Resources",
			patch = {
				kind = "Map",
				entries = {
					["Resource.Mana"] = { anchorValue = 25, anchorTime = 1001, min = 0, max = 100, regenRate = 10 },
					["Resource.Stamina"] = { anchorValue = 15, anchorTime = 1001, min = 0, max = 100, regenRate = 5 },
				},
				removed = {},
			},
		},
	})

	fixture.resources:_dispatchChanges()
	expect(#fixture.commits).toBe(1)
end)

it("ignores regen-only batches but preserves a discrete touch mixed with later regen in the same batch", function()
	TestUtils.attach(fixture)
	fixture.resources:_beginMutationBatch()
	fixture.resources:Step(0.1)
	fixture.resources:_finishMutationBatch()
	fixture.resources:_dispatchChanges()
	expect(fixture.commits).toEqual({})
	fixture.clock.now = 1001
	fixture.resources:_beginMutationBatch()
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	fixture.resources:Step(0.1)
	fixture.resources:_finishMutationBatch()
	fixture.resources:_dispatchChanges()
	expectManaPatch(37)
end)

it("does no projection capture, clock sampling or onCommitted work across 100 real 0.1-second regen steps", function()
	local callbacks: number = 0
	local snapshots: number = 0
	local queries: number = 0
	local originalSnapshot = fixture.definition.snapshot
	local originalObserve = fixture.definition.observe
	local originalQuery = fixture.resources._getReplicationState
	assert(originalObserve ~= nil, "Declared adapter must support ordinary observation")

	fixture.definition.snapshot = function(actor): Adapter.ReplicatedResourcesState
		snapshots += 1

		return originalSnapshot(actor)
	end

	fixture.definition.observe = function(actor, onCommitted): (() -> ())?
		return originalObserve(actor, function(events: { ReplicationTypes.ReplicationDomainEvent }?)
			callbacks += 1
			onCommitted(events)
		end)
	end

	fixture.resources._getReplicationState = function(
		self: ResourceTypes.InternalResourceController,
		id: string
	): ResourceTypes.ResourceReplicationState?
		queries += 1

		return originalQuery(self, id)
	end

	local runtime: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)
	local before: NetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(fixture.actor)
	snapshots = 0
	queries = 0
	fixture.clock.reads = 0

	for _ = 1, 100 do
		TestUtils.step(fixture, 0.1)
	end

	expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(100)
	expect(callbacks).toBe(0)
	expect(snapshots).toBe(0)
	expect(queries).toBe(0)
	expect(fixture.clock.reads).toBe(0)
	expect(fixture.commits).toEqual({})
	expect(runtime:GetActorSequence(fixture.actor)).toBe(0)
	expect(runtime:CaptureBaseline(fixture.actor)).toEqual(before)
	fixture.clock.now = 1011
	expect(fixture.resources:Drain("Resource.Mana", 5)).toBe(true)
	expect(callbacks).toBe(1)
	expectManaPatch(95, nil, nil, nil, 1011)
end)

it("filters ServerOnly changes before state query, server-time sampling and N3 invalidation", function()
	TestUtils.attach(fixture)
	local queried: { string } = {}
	local originalQuery = fixture.resources._getReplicationState

	fixture.resources._getReplicationState = function(
		self: ResourceTypes.InternalResourceController,
		id: string
	): ResourceTypes.ResourceReplicationState?
		table.insert(queried, id)

		return originalQuery(self, id)
	end

	fixture.clock.reads = 0
	expect(fixture.resources:Spend("Private.Secret", 5)).toBe(true)
	expect(fixture.properties:SetBaseProperty("PrivateMax", 75)).toBe(true)
	expect(fixture.properties:SetBaseProperty("PrivateRegen", 8)).toBe(true)
	expect(fixture.commits).toEqual({})
	expect(queried).toEqual({})
	expect(fixture.clock.reads).toBe(0)
	fixture.clock.now = 1001
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	expect(queried).toEqual({ "Resource.Mana" })
	expect(fixture.clock.reads).toBe(1)
	expectManaPatch(35)
end)

it(
	"leaves anchors untouched for successful no-ops, rejected spends and unrelated or invalid Property ranges",
	function()
		TestUtils.attach(fixture)
		local before: Adapter.ReplicatedResourcesState = TestUtils.snapshot(fixture)

		fixture.clock.reads = 0
		expect(fixture.resources:SetCurrent("Resource.Mana", 40)).toBe(true)
		expect(fixture.resources:Restore("Resource.Mana", 0)).toBe(true)
		local spent: boolean, reason: string? = fixture.resources:Spend("Resource.Mana", 500)
		expect(spent).toBe(false)
		expect(reason).toBe("InsufficientResourceValue")
		expect(fixture.properties:SetBaseProperty("Unrelated", 12)).toBe(true)
		expect(fixture.properties:SetBaseProperty("ManaMin", 200)).toBe(true)
		expect(fixture.resources:GetMin("Resource.Mana")).toBe(0)
		expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(40)
		expect(TestUtils.snapshot(fixture)).toEqual(before)
		expect(fixture.commits).toEqual({})
		expect(fixture.clock.reads).toBe(0)
		fixture.clock.now = 1001
		expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)
		expectManaPatch(39)
	end
)
