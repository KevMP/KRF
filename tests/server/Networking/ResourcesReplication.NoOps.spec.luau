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
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, case: { operation: string, initial: number, amount: number, next: number } in
	{
		{ operation = "Restore", initial = 100, amount = 5, next = 99 },
		{ operation = "Drain", initial = 0, amount = 5, next = 1 },
	}
do
	it(
		"does not reanchor " .. case.operation .. " at its bound but resumes on the next actual current change",
		function()
			expect(fixture.resources:SetCurrent("Resource.Mana", case.initial)).toBe(true)
			local publication: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)
			local before: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)

			fixture.clock.reads = 0

			local mutate: (ResourceTypes.ResourceController, string, number) -> (boolean, string?) = (
				fixture.resources :: any
			)[case.operation]

			local success: boolean, reason: string? = mutate(fixture.resources, "Resource.Mana", case.amount)
			expect(reason).toBeNil()
			expect(success).toBe(true)
			expect(fixture.commits).toEqual({})
			expect(fixture.clock.reads).toBe(0)
			expect(publication:CaptureBaseline(fixture.actor)).toEqual(before)
			expect(fixture.resources:SetCurrent("Resource.Mana", case.next)).toBe(true)
			expect(#fixture.commits).toBe(1)
		end
	)
end

it("does no N3 work for duplicate assignment and still publishes the next new visible assignment", function()
	TestUtils.attach(fixture)
	fixture.clock.reads = 0
	local added: boolean, reason: string? = fixture.resources:AddResource("Resource.Mana")
	expect(added).toBe(false)
	expect(reason).toBe("ResourceAlreadyAssigned")
	expect(fixture.commits).toEqual({})
	expect(fixture.clock.reads).toBe(0)
	expect(fixture.resources:AddResource("Resource.Rage", 12)).toBe(true)
	expect(#fixture.commits).toBe(1)
end)

it("filters a live ServerOnly assignment before downstream work without disabling visible assignment", function()
	TestUtils.destroy(fixture)
	local catalog: { ResourceTypes.ResourceDefinition } = TestUtils.catalog()

	local private: ResourceTypes.ResourceDefinition =
		{ id = "Private.Live", visibility = "ServerOnly", max = { value = 100 } }

	table.insert(catalog, private)
	fixture = TestUtils.new(catalog)
	TestUtils.attach(fixture)
	fixture.clock.reads = 0
	expect(fixture.resources:AddResource("Private.Live", 12)).toBe(true)
	expect(fixture.resources:HasResource("Private.Live")).toBe(true)
	expect(TestUtils.snapshot(fixture)["Private.Live"]).toBeNil()
	expect(fixture.commits).toEqual({})
	expect(fixture.clock.reads).toBe(0)
	expect(fixture.resources:AddResource("Resource.Rage", 12)).toBe(true)
	expect(#fixture.commits).toBe(1)
end)
