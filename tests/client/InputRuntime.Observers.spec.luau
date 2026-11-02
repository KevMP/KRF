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

it(
	"delivers committed frozen primitives in explicit phase then registration order before public publication",
	function()
		TestUtils.install(fixture)
		TestUtils.enable(fixture)
		local order: { string } = {}

		fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
			expect(#fixture.events).toBe(0)
			expect(table.isfrozen(occurrence)).toBe(true)
			expect(table.isfrozen(occurrence.event)).toBe(true)

			expect(
				fixture.owner.IsPressEpochActive(
					"Primary",
					assert(occurrence.pressEpochId, "Expected Bool press epoch"),
					occurrence.generation
				)
			).toBe(true)

			table.insert(order, "Routing")
		end)

		fixture.owner.ObservePrimitive("Interpretation", function()
			table.insert(order, "First")
		end)

		fixture.owner.ObservePrimitive("Arbitration", function()
			table.insert(order, "Arbitration")
		end)

		fixture.owner.ObservePrimitive("Interpretation", function()
			table.insert(order, "Second")
		end)

		TestUtils.emit(fixture, "Pressed", true)
		expect(order).toEqual({ "First", "Second", "Arbitration", "Routing" })
		expect(#fixture.events).toBe(1)
	end
)

it("contains private observer errors and yields without dropping other observers or public input", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local routed: number = 0

	fixture.owner.ObservePrimitive("Interpretation", function()
		error("ConsumerFailure")
	end)

	fixture.owner.ObservePrimitive("Arbitration", function()
		coroutine.yield()
	end)

	fixture.owner.ObservePrimitive("Routing", function()
		routed += 1
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(routed).toBe(1)
	expect(#fixture.events).toBe(1)
	expect(#fixture.faults).toBe(2)
	TestUtils.emit(fixture, "Released", false)
	expect(routed).toBe(2)
	expect(#fixture.events).toBe(2)
end)

it("snapshots each phase and skips disconnected observers during delivery", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local order: { string } = {}
	local stopSecond: () -> () = function() end

	fixture.owner.ObservePrimitive("Interpretation", function()
		table.insert(order, "First")
		stopSecond()

		fixture.owner.ObservePrimitive("Interpretation", function()
			table.insert(order, "Late")
		end)
	end)

	stopSecond = fixture.owner.ObservePrimitive("Interpretation", function()
		table.insert(order, "Second")
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(order).toEqual({ "First" })
	TestUtils.emit(fixture, "Released", false)
	expect(order).toEqual({ "First", "First", "Late" })
	stopSecond()
end)

it("retires release provenance before routing and never reuses a press epoch ID", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local occurrences: { Types.PrimitiveOccurrence } = {}

	fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		table.insert(occurrences, occurrence)

		if occurrence.event.kind == "Released" then
			expect(
				fixture.owner.IsPressEpochActive(
					"Primary",
					assert(occurrence.pressEpochId, "Expected Bool press epoch"),
					occurrence.generation
				)
			).toBe(false)
		end
	end)

	TestUtils.emit(fixture, "Pressed", true)
	TestUtils.emit(fixture, "Released", false)
	TestUtils.emit(fixture, "Pressed", true)
	expect(assert(occurrences[1].pressEpochId, "Expected Bool press epoch")).never.toBeNil()

	expect(assert(occurrences[2].pressEpochId, "Expected Bool press epoch")).toBe(
		assert(occurrences[1].pressEpochId, "Expected Bool press epoch")
	)

	expect(
		assert(occurrences[3].pressEpochId, "Expected Bool press epoch")
			> assert(occurrences[1].pressEpochId, "Expected Bool press epoch")
	).toBe(true)

	expect(
		fixture.owner.IsPressEpochActive(
			"Other",
			assert(occurrences[3].pressEpochId, "Expected Bool press epoch"),
			occurrences[3].generation
		)
	).toBe(false)

	expect(
		fixture.owner.IsPressEpochActive(
			"Primary",
			assert(occurrences[3].pressEpochId, "Expected Bool press epoch"),
			occurrences[3].generation + 1
		)
	).toBe(false)

	expect(fixture.faults).toEqual({})
end)

it("serializes source mutations requested during primitive delivery until all observers see the old graph", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local routingSawInput: boolean = false

	fixture.owner.ObservePrimitive("Interpretation", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind == "Pressed" then
			fixture.owner.RemoveSource("Core")
		end
	end)

	fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind == "Pressed" then
			routingSawInput = fixture.owner.GetInput("Primary") ~= nil
		end
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(routingSawInput).toBe(true)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
end)
