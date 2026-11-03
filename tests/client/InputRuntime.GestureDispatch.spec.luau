--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("offers immediate ordinary Pressed before any second press or timeout", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	expect(#fixture.groups).toBe(1)
	expect(Utils.candidates(fixture.groups[1])).toEqual({ "Pressed" })
	expect(fixture.input.events[1].kind).toBe("Pressed")
	expect(Utils.kinds(fixture)).toEqual({})
end)

it("preserves I1 root and live press provenance on the second-press candidate lane", function()
	expect(Utils.install(fixture, Utils.pair())).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	Utils.emit(fixture, 0.25, "Pressed")
	expect(#fixture.groups).toBe(3)
	local group: Types.GestureDispatchGroup = fixture.groups[3]
	expect(Utils.candidates(group)).toEqual({ "DoubleTapped", "Pressed" })
	expect(group.inputId).toBe("Primary")
	expect(group.contextId).toBe("Gameplay")
	expect(group.triggerInputOrdinal).toBe(fixture.input.events[3].ordinal)

	for _, candidate: Types.GestureCandidate in group.candidates do
		expect(candidate.rootInputOrdinal).toBe(group.triggerInputOrdinal)
		expect(candidate.inputId).toBe("Primary")
		expect(candidate.timestamp).toBe(0.25)

		expect(
			fixture.input.owner.IsPressEpochActive(
				"Primary",
				assert(candidate.pressEpochId, "Expected original epoch"),
				candidate.generation
			)
		).toBe(true)
	end
end)

it("settles catch-up Held then delivers release lifecycle before Tap start routing", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 }, Held = { afterSeconds = 0.25 } })).toBe(true)
	local order: { string } = {}

	fixture.input.owner.ObservePrimitive("Interpretation", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind == "Released" then
			table.insert(order, "OriginalRelease")
		end
	end)

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		for _, candidate: Types.GestureCandidate in group.candidates do
			if candidate.key == "Held" or candidate.key == "Tap" then
				table.insert(order, candidate.key)
			end
		end
	end)

	Utils.tap(fixture, 0, 0.5)
	expect(order).toEqual({ "Held", "OriginalRelease", "Tap" })
	expect(fixture.input.faults).toEqual({})

	-- A recognized late Held is not authority to begin a WhileDown Action after release.
	for _, group: Types.GestureDispatchGroup in fixture.groups do
		for _, candidate: Types.GestureCandidate in group.candidates do
			if candidate.key == "Held" or candidate.key == "Tap" then
				expect(
					fixture.input.owner.IsPressEpochActive(
						"Primary",
						assert(candidate.pressEpochId, "Expected epoch provenance"),
						candidate.generation
					)
				).toBe(false)
			end
		end
	end
end)

it("publishes immutable events and groups with independent monotonic gesture ordinals", function()
	expect(Utils.install(fixture, Utils.pair())).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	Utils.tap(fixture, 0.25, 0.375)
	expect(Utils.kinds(fixture)).toEqual({ "Tap", "DoubleTapped", "Tap" })

	for index: number, event: Types.GestureEvent in fixture.events do
		expect(event.ordinal).toBe(index)
		expect(table.isfrozen(event)).toBe(true)
		expect(event.inputId).toBe("Primary")
		expect(event.contextId).toBe("Gameplay")
	end

	for _, group: Types.GestureDispatchGroup in fixture.groups do
		expect(table.isfrozen(group)).toBe(true)
		expect(table.isfrozen(group.candidates)).toBe(true)

		for _, candidate: Types.GestureCandidate in group.candidates do
			expect(table.isfrozen(candidate)).toBe(true)
		end
	end
end)

it("contains throwing and yielding group observers while completing private and public delivery", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } })).toBe(true)

	fixture.input.owner.ObserveDispatchGroup(function()
		error("RoutingObserverFailure", 0)
	end)

	fixture.input.owner.ObserveDispatchGroup(function()
		coroutine.yield()
	end)

	local delivered: number = 0

	fixture.input.owner.ObserveDispatchGroup(function()
		delivered += 1
	end)

	Utils.tap(fixture, 0, 0.125)
	expect(delivered).toBe(2)
	expect(#fixture.input.events).toBe(2)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	expect(#fixture.input.faults).toBe(4)
end)

it("disconnects group observers idempotently and does not revive them after teardown", function()
	local calls: number = 0

	local stop: () -> () = fixture.input.owner.ObserveDispatchGroup(function()
		calls += 1
	end)

	Utils.emit(fixture, 0, "Pressed")
	expect(calls).toBe(1)
	stop()
	stop()
	Utils.emit(fixture, 0.125, "Released")
	expect(calls).toBe(1)
	fixture.input.owner.Destroy()
	stop()
end)

it("queues source removal requested by a private candidate consumer until the occurrence completes", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } })).toBe(true)

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		if group.candidates[1].key == "Tap" then
			expect(fixture.input.owner.RemoveSource("Gestures")).toBe(true)
		end
	end)

	local sawInstalled: boolean = false

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		if group.candidates[1].key == "Tap" then
			local snapshots = fixture.input.owner.GetGestures("Primary")
			sawInstalled = snapshots ~= nil and snapshots.Tap ~= nil
		end
	end)

	Utils.tap(fixture, 0, 0.125)
	expect(sawInstalled).toBe(true)
	expect(fixture.input.owner.GetGestures("Primary")).toEqual({})
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	expect(fixture.input.faults).toEqual({})
end)
