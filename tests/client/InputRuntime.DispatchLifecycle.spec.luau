--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Constants = require(KRF.client.Input.utils.InputConstants)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)
local fixture: Utils.Fixture
local custom: InputTestUtils.Fixture? = nil

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)

	if custom ~= nil then
		InputTestUtils.destroy(custom)
		custom = nil
	end
end)

it("keeps private gesture recognition available without a public gesture publisher", function()
	custom = InputTestUtils.new()
	local input: InputTestUtils.Fixture = assert(custom, "Expected input fixture")
	InputTestUtils.install(input)
	InputTestUtils.enable(input)
	expect(input.owner.SetSource("Tap", { gestures = { Primary = { Tap = { maxDurationSeconds = 1 } } } })).toBe(true)
	local candidates: { string } = {}

	input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		for _, candidate: Types.GestureCandidate in group.candidates do
			if candidate.routeEligible then
				table.insert(candidates, candidate.key)
			end
		end
	end)

	InputTestUtils.emit(input, "Pressed", true)
	input.now += 0.125
	InputTestUtils.emit(input, "Released", false)
	expect(candidates).toEqual({ "Pressed", "Tap" })
	expect(InputTestUtils.kinds(input)).toEqual({ "Pressed", "Released" })
	expect(input.faults).toEqual({})
end)

it("skips disconnected group observers and defers newly registered observers until the next occurrence", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 1 } })).toBe(true)
	local order: { string } = {}
	local stopSecond: () -> () = function() end

	fixture.input.owner.ObserveDispatchGroup(function()
		table.insert(order, "First")
		stopSecond()

		fixture.input.owner.ObserveDispatchGroup(function()
			table.insert(order, "Late")
		end)
	end)

	stopSecond = fixture.input.owner.ObserveDispatchGroup(function()
		table.insert(order, "Second")
	end)

	Utils.emit(fixture, 0, "Pressed")
	expect(order).toEqual({ "First" })
	Utils.emit(fixture, 0.125, "Released")
	expect(order).toEqual({ "First", "First", "Late" })
	expect(Utils.kinds(fixture)).toEqual({ "Tap" })
	expect(fixture.input.faults).toEqual({})
end)

it("does not deliver threshold candidates after client readiness is revoked", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.5 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	fixture.input.ready = false
	Utils.wake(fixture, 1)
	expect(Utils.kinds(fixture)).toEqual({})
	expect(#fixture.groups).toBe(1)
	expect(Utils.candidates(fixture.groups[1])).toEqual({ "Pressed" })
	expect(fixture.input.faults).toEqual({})
end)

it("fails closed when a fenced timer cannot join a full mutation queue", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.5 } })).toBe(true)
	local queued: number = 0

	fixture.input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		if group.candidates[1].key ~= "Pressed" then
			return
		end

		for index: number = 1, Constants.MAX_PENDING_MUTATIONS do
			local accepted: boolean = fixture.input.owner.SetSource("Queued" .. index, {})

			if accepted then
				queued += 1
			end
		end

		fixture.input.now = 1
		fixture.jobs[1].callback()
	end)

	Utils.emit(fixture, 0, "Pressed")
	expect(queued).toBe(Constants.MAX_PENDING_MUTATIONS)
	expect(fixture.input.owner.GetInput("Primary")).toBeNil()
	expect(fixture.input.faults).toEqual({ "InputRuntimeFaulted" })
	expect(fixture.input.connections).toBe(0)
	expect(Utils.pending(fixture)).toBe(0)
	expect(Utils.kinds(fixture)).toEqual({})
end)
