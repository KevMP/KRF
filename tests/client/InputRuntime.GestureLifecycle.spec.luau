--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("preserves a pending deadline and first-tap history across equivalent and unrelated updates", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(Utils.pending(fixture) > 0).toBe(true)
	local jobs: number = #fixture.jobs
	local action: InputAction = fixture.input.actions.Primary
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)

	expect(fixture.input.owner.SetSource("Unrelated", { contexts = { Menu = { priority = 1, sink = false } } })).toBe(
		true
	)

	expect(#fixture.jobs).toBe(jobs)
	expect(fixture.input.actions.Primary).toBe(action)
	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
end)

for _, constituent: string in { "Tap", "DoubleTapped" } do
	it("retires the shared deferred history when " .. constituent .. " changes", function()
		expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
		Utils.tap(fixture, 0, 0.125)
		local changed: Types.GestureDefinitions = Utils.pair("DeferredTap")

		if constituent == "Tap" then
			assert(changed.Tap, "Expected Tap").maxDurationSeconds = 0.5
			assert(changed.DoubleTapped, "Expected DoubleTapped").maxTapDurationSeconds = 0.5
		else
			assert(changed.DoubleTapped, "Expected DoubleTapped").maxGapSeconds = 1
		end

		expect(Utils.install(fixture, changed)).toBe(true)
		Utils.emit(fixture, 0.25, "Pressed")
		Utils.wake(fixture, 2)
		expect(Utils.kinds(fixture)).toEqual({})
	end)
end

it("preserves foreign Tap history when an unrelated Held is removed", function()
	expect(Utils.install(fixture, Utils.pair(), "Pair")).toBe(true)
	expect(Utils.install(fixture, { Held = { afterSeconds = 1 } }, "Hold")).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(fixture.input.owner.RemoveSource("Hold")).toBe(true)
	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "Tap", "DoubleTapped" })
end)

for _, operation: string in { "ContextDisable", "BindingChange", "SourceRemoval", "Destroy" } do
	it("retires dormant first-tap history and stale callbacks on " .. operation, function()
		expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
		Utils.tap(fixture, 0, 0.125)
		expect(#fixture.jobs > 0).toBe(true)
		local oldJobs: { Utils.Job } = table.clone(fixture.jobs)

		if operation == "ContextDisable" then
			expect(fixture.input.owner.SetContextEnabled("Gameplay", false)).toBe(true)
			expect(fixture.input.owner.SetContextEnabled("Gameplay", true)).toBe(true)
		elseif operation == "BindingChange" then
			expect(
				fixture.input.owner.SetSource(
					"Remap",
					{ priority = 1, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
				)
			).toBe(true)
		elseif operation == "SourceRemoval" then
			expect(fixture.input.owner.RemoveSource("Gestures")).toBe(true)
		else
			fixture.input.owner.Destroy()
		end

		fixture.input.now = 5

		for _, job: Utils.Job in oldJobs do
			job.callback()
		end

		expect(Utils.kinds(fixture)).toEqual({})
		expect(Utils.pending(fixture)).toBe(0)

		if operation ~= "Destroy" then
			Utils.emit(fixture, 5, "Pressed")
			expect(Utils.kinds(fixture)).toEqual({})
		end
	end)
end

it("starts newly installed recognition on the next press rather than an already-held epoch", function()
	Utils.emit(fixture, 0, "Pressed")
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 }, Held = { afterSeconds = 0.25 } })).toBe(true)
	Utils.wake(fixture, 0.5)
	Utils.emit(fixture, 0.5, "Released")
	expect(Utils.kinds(fixture)).toEqual({})
	Utils.tap(fixture, 1, 1.125)
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
end)

it("retains old native and recognition state when a combined replacement rolls back", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(Utils.pending(fixture) > 0).toBe(true)
	fixture.input.failAt[#fixture.input.writes + 1] = true

	expect({
		fixture.input.owner.SetSource("Gestures", {
			priority = 1,
			bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } },
			gestures = { Primary = { Held = { afterSeconds = 1 } } },
		}),
	}).toEqual({ false, "NativeCommitFailed" })

	expect(assert(fixture.input.owner.GetGestures("Primary"), "Expected old pair").DoubleTapped.sourceId).toBe(
		"Gestures"
	)

	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
end)

it("retires recognition and timers if native restoration cannot be proven", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(#fixture.jobs > 0).toBe(true)
	local stale: { Utils.Job } = table.clone(fixture.jobs)

	fixture.input.onWrite = function(operation: string)
		if operation == "ConfigureContext:Gameplay" then
			fixture.input.contexts.Gameplay.Enabled = true
			error("UnprovableRollback", 0)
		end
	end

	expect({ fixture.input.owner.SetContextEnabled("Gameplay", false) }).toEqual({ false, "InputRuntimeFaulted" })
	fixture.input.onWrite = nil
	fixture.input.now = 5

	for _, job: Utils.Job in stale do
		job.callback()
	end

	expect(fixture.input.owner.GetGestures("Primary")).toBeNil()
	expect(Utils.kinds(fixture)).toEqual({})
	expect(Utils.pending(fixture)).toBe(0)
	expect(fixture.input.connections).toBe(0)
end)

it("does not deliver timer candidates from inside native graph application", function()
	expect(Utils.install(fixture, Utils.pair("DeferredTap"))).toBe(true)
	Utils.tap(fixture, 0, 0.125)
	expect(#fixture.jobs > 0).toBe(true)
	local stale: { Utils.Job } = table.clone(fixture.jobs)
	local inside: boolean = false

	fixture.input.owner.ObserveDispatchGroup(function()
		expect(inside).toBe(false)
	end)

	fixture.input.onWrite = function()
		inside = true
		fixture.input.now = 2

		for _, job: Utils.Job in stale do
			job.callback()
		end

		inside = false
	end

	expect(fixture.input.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(Utils.kinds(fixture)).toEqual({})
	expect(fixture.input.faults).toEqual({})
end)

it("keeps other logical inputs independent when one input is invalidated", function()
	local second: InputTestUtils.CoreDefinition = InputTestUtils.definition()
	second.contexts = { OtherContext = { priority = 1, sink = false } }
	second.inputs.Other = second.inputs.Primary
	second.inputs.Primary = nil :: any
	second.inputs.Other.context = "OtherContext"
	expect(fixture.input.owner.SetSource("Other", second)).toBe(true)
	expect(fixture.input.owner.SetContextEnabled("OtherContext", true)).toBe(true)

	expect(fixture.input.owner.SetSource("Gestures", { gestures = { Primary = Utils.pair(), Other = Utils.pair() } })).toBe(
		true
	)

	Utils.tap(fixture, 0, 0.125)
	Utils.tap(fixture, 0.25, 0.375, "Other")
	expect(fixture.input.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	Utils.emit(fixture, 0.5, "Pressed", "Other")
	expect(Utils.kinds(fixture)).toEqual({ "Tap", "Tap", "DoubleTapped" })
	expect(fixture.events[3].inputId).toBe("Other")
end)
