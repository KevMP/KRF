--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Adapter = require(KRF.server.Networking.utils.ResourcesReplication)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("captures authoritative assigned visible state through N3 without registered-only or private entries", function()
	expect(fixture.resources:AddResource("Resource.Rage", 12)).toBe(true)
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)

	expect(publication:CaptureBaseline(fixture.actor)).toEqual({
		sequence = 0,
		domains = {
			["KRF.Resources"] = {
				value = {
					["Resource.Mana"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
					["Resource.Stamina"] = { anchorValue = 20, anchorTime = 1000, min = 0, max = 100, regenRate = 5 },
					["Resource.Rage"] = { anchorValue = 12, anchorTime = 1000, min = 0, max = 50 },
				},
			},
		},
	})

	expect(fixture.commits).toEqual({})
	expect(fixture.resources:HasResource("Private.Secret")).toBe(true)
	expect(fixture.resources:HasResource("Resource.Unassigned")).toBe(false)
end)

it("captures an empty Map for an Actor owning only ServerOnly Resources", function()
	TestUtils.destroy(fixture)
	local catalog: { ResourceTypes.ResourceDefinition } = TestUtils.catalog()

	for _, definition: ResourceTypes.ResourceDefinition in catalog do
		if definition.visibility == "ClientVisible" then
			definition.autoAssign = false
		end
	end

	fixture = TestUtils.new(catalog)
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)

	expect(publication:CaptureBaseline(fixture.actor)).toEqual({
		sequence = 0,
		domains = { ["KRF.Resources"] = { value = {} } },
	})

	expect(fixture.commits).toEqual({})
end)

it(
	"samples one synchronized time for all initial anchors and uses current stepped authority on late attachment",
	function()
		fixture.resources:Step(2)
		fixture.clock.now = 1002
		TestUtils.attach(fixture)
		expect(fixture.clock.reads).toBe(1)

		expect(TestUtils.snapshot(fixture)).toEqual({
			["Resource.Mana"] = { anchorValue = 60, anchorTime = 1002, min = 0, max = 100, regenRate = 10 },
			["Resource.Stamina"] = { anchorValue = 30, anchorTime = 1002, min = 0, max = 100, regenRate = 5 },
		})
	end
)

it("captures resolved Property bounds and preserves zero and negative configured regen rates", function()
	expect(fixture.properties:SetBaseProperty("ManaMin", 10)).toBe(true)
	expect(fixture.properties:SetBaseProperty("ManaMax", 120)).toBe(true)
	expect(fixture.properties:SetBaseProperty("ManaRegen", -5)).toBe(true)
	TestUtils.attach(fixture)

	expect(TestUtils.snapshot(fixture)["Resource.Mana"]).toEqual({
		anchorValue = 40,
		anchorTime = 1000,
		min = 10,
		max = 120,
		regenRate = -5,
	})
end)

it("retains immutable old snapshots and untouched anchors after a different Resource changes", function()
	TestUtils.attach(fixture)
	local before: Adapter.ReplicatedResourcesState = TestUtils.snapshot(fixture)
	expect(table.isfrozen(before)).toBe(true)

	expect(before["Resource.Stamina"]).toEqual({
		anchorValue = 20,
		anchorTime = 1000,
		min = 0,
		max = 100,
		regenRate = 5,
	})

	expect(table.isfrozen(before["Resource.Stamina"])).toBe(true)
	fixture.clock.now = 1001
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	local after: Adapter.ReplicatedResourcesState = TestUtils.snapshot(fixture)
	expect(after["Resource.Stamina"]).toBe(before["Resource.Stamina"])
	expect(before["Resource.Mana"].anchorValue).toBe(40)
	expect(after["Resource.Mana"]).toEqual({ anchorValue = 35, anchorTime = 1001, min = 0, max = 100, regenRate = 10 })
end)

it("fails attachment observably when ResourceController is missing rather than inventing empty state", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local runtime: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime({ fixture.definition })

	fixture.runtime = runtime
	local attached: boolean, reason: string? = runtime:AttachActor(actor)
	expect(attached).toBe(false)
	expect(reason).toBe("PublicationSnapshotError:KRF.Resources")
	expect(runtime:CaptureBaseline(actor)).toBeNil()
	expect(runtime:GetAttachedActors()).toEqual({})
end)

for _, invalidTime: number in { math.huge, -math.huge, 0 / 0 } do
	it(
		"rejects non-finite initial server time and retries from fresh authority (" .. tostring(invalidTime) .. ")",
		function()
			fixture.clock.now = invalidTime

			local runtime: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime({ fixture.definition })

			fixture.runtime = runtime
			local attached: boolean, reason: string? = runtime:AttachActor(fixture.actor)
			expect(attached).toBe(false)
			expect(reason ~= nil).toBe(true)
			expect(runtime:CaptureBaseline(fixture.actor)).toBeNil()
			expect(runtime:GetAttachedActors()).toEqual({})
			fixture.clock.now = 1001
			expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
			local retried: boolean, retryReason: string? = runtime:AttachActor(fixture.actor)
			expect(retryReason).toBeNil()
			expect(retried).toBe(true)

			expect(TestUtils.snapshot(fixture)["Resource.Mana"]).toEqual({
				anchorValue = 35,
				anchorTime = 1001,
				min = 0,
				max = 100,
				regenRate = 10,
			})
		end
	)
end

it("cleans an observer after another domain rejects attachment and admits fresh Resource truth on retry", function()
	local invalid: PublicationUtils.DomainFixture = PublicationUtils.createDomain("ZGame.Invalid", Schema.U8, 256)

	local runtime: NetworkingTypes.PublicationRuntime =
		PublicationUtils.createRuntime({ fixture.definition, invalid.definition })

	fixture.runtime = runtime

	runtime:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(fixture.commits, commit)
	end)

	local attached: boolean, reason: string? = runtime:AttachActor(fixture.actor)
	expect(attached).toBe(false)
	expect(reason).toBe("InvalidPublicationSnapshot:ZGame.Invalid")
	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	expect(fixture.commits).toEqual({})
	invalid.value = 1
	fixture.clock.now = 1001
	local retried: boolean, retryReason: string? = runtime:AttachActor(fixture.actor)
	expect(retryReason).toBeNil()
	expect(retried).toBe(true)

	expect(TestUtils.snapshot(fixture)["Resource.Mana"]).toEqual({
		anchorValue = 35,
		anchorTime = 1001,
		min = 0,
		max = 100,
		regenRate = 10,
	})

	expect(fixture.resources:Spend("Resource.Mana", 5)).toBe(true)
	expect(#fixture.commits).toBe(1)
end)

it("drops detached projection caches and reconnects once using latest authority", function()
	local runtime: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)
	runtime:DetachActor(fixture.actor)
	runtime:DetachActor(fixture.actor)
	fixture.clock.now = 1010
	expect(fixture.resources:Spend("Resource.Mana", 10)).toBe(true)
	expect(fixture.commits).toEqual({})
	local attached: boolean, reason: string? = runtime:AttachActor(fixture.actor)
	expect(reason).toBeNil()
	expect(attached).toBe(true)

	expect(TestUtils.snapshot(fixture)["Resource.Mana"]).toEqual({
		anchorValue = 30,
		anchorTime = 1010,
		min = 0,
		max = 100,
		regenRate = 10,
	})

	expect(fixture.resources:Restore("Resource.Mana", 5)).toBe(true)
	expect(#fixture.commits).toBe(1)
end)
