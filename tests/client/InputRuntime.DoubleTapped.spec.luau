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

for _, case in
	{
		{ duration = 0.25, gap = 0.5, qualifies = true },
		{ duration = 0.250001, gap = 0.125, qualifies = false },
		{ duration = 0.125, gap = 0.500001, qualifies = false },
		{ duration = 0.25, gap = 0, qualifies = true },
	}
do
	it(
		"uses inclusive first duration " .. tostring(case.duration) .. " and release gap " .. tostring(case.gap),
		function()
			expect(Utils.install(fixture, { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } })).toBe(
				true
			)

			Utils.tap(fixture, 0, case.duration)
			Utils.emit(fixture, case.duration + case.gap, "Pressed")
			expect(Utils.kinds(fixture)).toEqual(if case.qualifies then { "DoubleTapped" } else {})

			if case.qualifies then
				local event: Types.GestureEvent = fixture.events[1]
				assert(event.gesture == "DoubleTapped", "Expected DoubleTapped variant")
				expect(event.gapSeconds).toBe(case.gap)
				expect(event.triggerInputOrdinal).toBe(fixture.input.events[3].ordinal)
			end
		end
	)
end

it("recognizes on press two even when that press subsequently becomes a long hold", function()
	expect(
		Utils.install(
			fixture,
			{ DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 }, Held = { afterSeconds = 1 } }
		)
	).toBe(true)

	Utils.tap(fixture, 0, 0.125)
	Utils.emit(fixture, 0.25, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
	Utils.wake(fixture, 2)
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped", "Held" })
end)

it("does not reuse press two for a rolling triple and starts a new pair with press three", function()
	expect(Utils.install(fixture, { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } })).toBe(true)
	Utils.tap(fixture, 0, 0.0625)
	Utils.tap(fixture, 0.125, 0.1875)
	Utils.tap(fixture, 0.25, 0.3125)
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped" })
	Utils.emit(fixture, 0.375, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({ "DoubleTapped", "DoubleTapped" })
end)

local policies: { Types.DoubleTapArbitration } = { "PreferSpecific", "Independent" }

for _, policy: Types.DoubleTapArbitration in policies do
	it("preserves truthful second-release Tap and explicit eligibility under " .. policy, function()
		expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } }, "TapOwner")).toBe(true)

		expect(
			Utils.install(
				fixture,
				{ DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = policy } },
				"DoubleOwner"
			)
		).toBe(true)

		Utils.tap(fixture, 0, 0.125)
		Utils.emit(fixture, 0.25, "Pressed")
		expect(Utils.kinds(fixture)).toEqual({ "Tap", "DoubleTapped" })
		local secondPress: Types.GestureDispatchGroup = fixture.groups[#fixture.groups]
		expect(Utils.candidates(secondPress)).toEqual({ "DoubleTapped", "Pressed" })
		expect(secondPress.policy).toBe(policy)
		Utils.emit(fixture, 0.375, "Released")
		expect(Utils.kinds(fixture)).toEqual({ "Tap", "DoubleTapped", "Tap" })
		local release: Types.GestureDispatchGroup = fixture.groups[#fixture.groups]
		expect(Utils.candidates(release)).toEqual(if policy == "Independent" then { "Tap" } else {})
		expect(release.candidates[1].key).toBe("Tap")
		expect(release.candidates[1].routeEligible).toBe(policy == "Independent")
	end)
end

it("does not recognize two simultaneously held or duplicate Pressed notifications as a pair", function()
	expect(Utils.install(fixture, { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } })).toBe(true)
	Utils.emit(fixture, 0, "Pressed")
	Utils.emit(fixture, 0.125, "Pressed")
	expect(Utils.kinds(fixture)).toEqual({})
end)
