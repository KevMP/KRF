--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("prepares held invalidation without retiring epochs and commits selection before new dispatch", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local pressed: Types.PrimitiveOccurrence? = nil

	fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind == "Pressed" then
			pressed = occurrence
		end
	end)

	TestUtils.emit(fixture, "Pressed", true)
	assert(pressed ~= nil, "Expected initialized input state")
	local original: Types.PrimitiveOccurrence = pressed
	local before: number = #fixture.writes

	local plan: Types.PreparedInputInvalidation?, reason: string? =
		fixture.owner.PrepareEpochInvalidation("ActorChanged")

	expect(reason).toBeNil()
	assert(plan ~= nil, "Expected prepared input plan")
	expect(#fixture.writes).toBe(before)

	expect(
		fixture.owner.IsPressEpochActive(
			"Primary",
			assert(original.pressEpochId, "Expected Bool press epoch"),
			original.generation
		)
	).toBe(true)

	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed" })
	local selected: string = "Old"

	fixture.owner.ObserveConfigurationCommit(function()
		expect(selected).toBe("New")

		expect(
			fixture.owner.IsPressEpochActive(
				"Primary",
				assert(original.pressEpochId, "Expected Bool press epoch"),
				original.generation
			)
		).toBe(false)
	end)

	expect(fixture.owner.CommitEpochInvalidation(plan, function()
		selected = "New"
	end)).toBe(true)

	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	TestUtils.emit(fixture, "Pressed", true)
	expect(#fixture.events).toBe(2)
end)

it("rejects stale and foreign plans without changing the current graph", function()
	TestUtils.install(fixture)
	local plan: Types.PreparedInputInvalidation? = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	assert(plan ~= nil, "Expected prepared input plan")
	TestUtils.enable(fixture)

	expect({ fixture.owner.CommitEpochInvalidation(plan, function()
		error("MustNotPublish")
	end) }).toEqual({ false, "StaleInputPlan", "Rejected" })

	local other: TestUtils.Fixture = TestUtils.new()
	local foreign: Types.PreparedInputInvalidation? = other.owner.PrepareEpochInvalidation("ActorChanged")
	assert(foreign ~= nil, "Expected prepared input plan")

	local success: boolean, reason: string?, phase: Types.InputCommitFailurePhase? = fixture.owner.CommitEpochInvalidation(
		foreign,
		function()
			error("MustNotPublish")
		end
	)

	TestUtils.destroy(other)
	expect({ success, reason, phase }).toEqual({ false, "InvalidInputPlan", "Rejected" })
	expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(true)
end)

it("fails closed if selected-Actor publication cannot complete", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	local plan: Types.PreparedInputInvalidation? = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	assert(plan ~= nil, "Expected prepared input plan")

	expect({ fixture.owner.CommitEpochInvalidation(plan, function()
		error("SelectionFailure")
	end) }).toEqual({ false, "InputRuntimeFaulted", "Failed" })

	expect(fixture.connections).toBe(0)
	expect(#fixture.container:GetDescendants()).toBe(0)
end)
