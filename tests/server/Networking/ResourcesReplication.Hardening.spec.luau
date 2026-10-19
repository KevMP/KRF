--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Validate = require(KRF.shared.Networking.utils.SchemaValidator)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, field: string in { "anchorValue", "anchorTime", "min", "max", "regenRate" } do
	for _, invalid: number in { math.huge, -math.huge, 0 / 0 } do
		it("rejects non-finite wire " .. field .. "=" .. tostring(invalid), function()
			local catalog: ReplicationTypes.PreparedReplicationDomainCatalog =
				DomainUtils.prepare({ fixture.definition })

			local entry: { [string]: number } =
				{ anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 }

			entry[field] = invalid

			local valid: boolean, reason: string? =
				Validate.Validate(catalog.orderedDefinitions[1].state, { ["Resource.Mana"] = entry })

			expect(valid).toBe(false)
			expect(reason).toBe("SchemaNumberMustBeFinite")
		end)
	end
end

it("rejects a ServerOnly id at the schema boundary before baseline or patch encoding", function()
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainUtils.prepare({ fixture.definition })

	local valid: boolean, reason: string? = Validate.Validate(catalog.orderedDefinitions[1].state, {
		["Private.Secret"] = { anchorValue = 30, anchorTime = 1000, min = 0, max = 50 },
	})

	expect(valid).toBe(false)
	expect(reason).toBe("SchemaEnumValueInvalid")
end)

for _, invalidField: string in { "current", "min", "max", "regenRate", "range", "time" } do
	it(
		"rejects invalid projected "
			.. invalidField
			.. " atomically with a sibling domain and permits a valid later commit",
		function()
			local counter: PublicationUtils.DomainFixture = PublicationUtils.createDomain("Game.Counter", Schema.U8, 1)
			local publication: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture, { counter.definition })
			local before: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)
			local originalQuery = fixture.resources._getReplicationState

			fixture.resources._getReplicationState = function(
				self: ResourceTypes.InternalResourceController,
				id: string
			): ResourceTypes.ResourceReplicationState?
				if id ~= "Resource.Mana" or invalidField == "time" then
					return originalQuery(self, id)
				end

				return {
					current = if invalidField == "current" then math.huge else 35,
					min = if invalidField == "min" then -math.huge elseif invalidField == "range" then 200 else 0,
					max = if invalidField == "max" then math.huge else 100,
					regenRate = if invalidField == "regenRate" then 0 / 0 else 10,
				}
			end

			fixture.clock.now = if invalidField == "time" then math.huge else 1001

			local accepted: boolean, reason: any = pcall(function()
				publication:WithActorCommit(fixture.actor, function()
					counter.value = 2
					counter.callbacks[fixture.actor]()
					expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
				end)
			end)

			expect(accepted).toBe(false)
			expect(type(reason)).toBe("string")
			expect(publication:CaptureBaseline(fixture.actor)).toEqual(before)
			expect(publication:GetActorSequence(fixture.actor)).toBe(0)
			expect(fixture.commits).toEqual({})
			fixture.resources._getReplicationState = originalQuery
			fixture.clock.now = 1002

			publication:WithActorCommit(fixture.actor, function()
				counter.callbacks[fixture.actor]()
				expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)
			end)

			expect(#fixture.commits).toBe(1)
			expect(#fixture.commits[1].patches).toBe(2)
			expect(fixture.commits[1].events).toEqual({})
		end
	)
end

for _, count: number in { 1, 64, 512 } do
	it("queries one touched Resource and emits one Map key with " .. count .. " assigned visible Resources", function()
		TestUtils.destroy(fixture)
		local catalog: { ResourceTypes.ResourceDefinition } = {}

		for index: number = 1, count do
			local definition: ResourceTypes.ResourceDefinition = {
				id = string.format("Scale.Resource%04d", index),
				visibility = "ClientVisible",
				autoAssign = true,
				initialValue = 40,
				max = { value = 100 },
				regen = { rate = { value = 10 } },
			}

			table.insert(catalog, definition)
		end

		fixture = TestUtils.new(catalog)
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

		fixture.clock.now = 1001
		fixture.clock.reads = 0
		expect(fixture.resources:Spend("Scale.Resource0001", 5)).toBe(true)
		expect(queried).toEqual({ "Scale.Resource0001" })
		expect(fixture.clock.reads).toBe(1)
		expect(#fixture.commits).toBe(1)

		expect(fixture.commits[1].patches).toEqual({
			{
				domainId = "KRF.Resources",
				patch = {
					kind = "Map",
					entries = {
						["Scale.Resource0001"] = {
							anchorValue = 35,
							anchorTime = 1001,
							min = 0,
							max = 100,
							regenRate = 10,
						},
					},
					removed = {},
				},
			},
		})
	end)
end
