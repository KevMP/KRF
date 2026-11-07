--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local InputTypes = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("masks both final-root DoubleTapped and Pressed candidates with one mapped immediate sequence", function()
	expect({
		fixture.input.input.owner.SetSource(
			"Gestures",
			{ gestures = { Q = { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } } } }
		),
	}).toEqual({ true })

	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X", "Q" }) }) }).toEqual({ true })

	Utils.set(fixture, {
		Utils.fixed(Utils.key("Q"), "Pressed"),
		Utils.fixed(Utils.key("Q", "DoubleTapped"), "Double"),
		Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo"),
	})

	Utils.select(fixture)
	Utils.press(fixture, 0, "Q")
	table.clear(fixture.selections)
	Utils.press(fixture, 0.125, "X")
	Utils.emit(fixture, 0.25, "Q")
	expect(Utils.actions(fixture)).toEqual({ "Combo" })
	expect(fixture.input.events[1].gesture).toBe("DoubleTapped")
	expect(SequenceUtils.ids(fixture.input)).toEqual({ "Combo" })
end)

it("selects an explicit Independent sequence alongside a different Exclusive winner", function()
	expect({
		SequenceUtils.install(
			fixture.input,
			{ Alpha = SequenceUtils.pattern({ "X" }), Beta = SequenceUtils.pattern({ "X" }) }
		),
	}).toEqual({ true })

	local independent: Types.ActionRoute = Utils.fixed({ kind = "Sequence", sequenceId = "Beta" }, "Independent")
	independent.dispatch = { mode = "Independent" }

	Utils.set(
		fixture,
		{ Utils.fixed(), Utils.fixed({ kind = "Sequence", sequenceId = "Alpha" }, "Exclusive"), independent }
	)

	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local actions: { string } = Utils.actions(fixture)
	table.sort(actions)
	expect(actions).toEqual({ "Exclusive", "Independent" })
end)

for _, mode: string in { "Unmapped", "Fixed", "Nil", "Error", "Gated", "Independent" } do
	it("routes final Z with an " .. mode .. " sequence without filtering public recognition", function()
		expect({ SequenceUtils.install(fixture.input, { Fireball = SequenceUtils.pattern({ "X", "Q", "Z" }) }) }).toEqual({
			true,
		})

		Utils.set(fixture, {
			Utils.fixed(Utils.key("X"), "Sign.X"),
			Utils.fixed(Utils.key("Q"), "Sign.Q"),
			Utils.fixed(Utils.key("Z"), "Sign.Z"),
		}, "Base", 1000)

		if mode ~= "Unmapped" then
			local key: Types.RouteKey = { kind = "Sequence", sequenceId = "Fireball" }

			local route: Types.ActionRoute = if mode == "Nil" or mode == "Error"
				then Utils.dynamic(key, function(): Types.ResolvedAction?
					if mode == "Error" then
						error("ResolverFailed", 0)
					end

					return nil
				end)
				else Utils.fixed(key, "Technique.Fireball")

			if mode == "Independent" then
				route.dispatch = { mode = "Independent" }
			end

			if mode == "Gated" then
				route.requiredContexts = { "Aim" }
				expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
			end

			Utils.set(fixture, { route }, "Manual", -1000)
		end

		Utils.select(fixture)
		SequenceUtils.play(fixture.input, { "X", "Q", "Z" })
		local actions: { string } = Utils.actions(fixture)

		if mode == "Unmapped" or mode == "Gated" then
			expect(actions).toEqual({ "Sign.X", "Sign.Q", "Sign.Z" })
		elseif mode == "Nil" or mode == "Error" then
			expect(actions).toEqual({ "Sign.X", "Sign.Q" })
		elseif mode == "Fixed" then
			expect(actions).toEqual({ "Sign.X", "Sign.Q", "Technique.Fireball" })
		else
			table.sort(actions)
			expect(actions).toEqual({ "Sign.Q", "Sign.X", "Sign.Z", "Technique.Fireball" })
		end

		expect(SequenceUtils.ids(fixture.input)).toEqual({ "Fireball" })
		expect(#fixture.input.input.events).toBe(6)
		expect(fixture.input.input.events[6].kind).toBe("Released")
	end)
end

for _, mapping: string in { "Unmapped", "Fixed", "Nil", "Error" } do
	it("prefers mapped DoubleTapped over Pressed with " .. mapping .. " resolution", function()
		expect({
			fixture.input.input.owner.SetSource("Gestures", {
				gestures = {
					Q = {
						DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
					},
				},
			}),
		}).toEqual({ true })

		Utils.set(fixture, { Utils.fixed(Utils.key("Q"), "Movement.Dash") })
		local calls: number = 0

		if mapping ~= "Unmapped" then
			Utils.set(fixture, {
				Utils.dynamic(Utils.key("Q", "DoubleTapped"), function(): Types.ResolvedAction?
					calls += 1

					if mapping == "Error" then
						error("DoubleFailed", 0)
					end

					return if mapping == "Nil" then nil else { actionId = "Movement.DoubleDash" }
				end),
			}, "Double", -100)
		end

		Utils.select(fixture)
		Utils.press(fixture, 0, "Q")
		table.clear(fixture.selections)
		Utils.emit(fixture, 0.125, "Q")

		expect(Utils.actions(fixture)).toEqual(
			if mapping == "Unmapped"
				then { "Movement.Dash" }
				elseif mapping == "Fixed" then { "Movement.DoubleDash" }
				else {}
		)

		expect(calls).toBe(if mapping == "Unmapped" then 0 else 1)
		expect(fixture.input.events[1].gesture).toBe("DoubleTapped")
	end)
end

it("never routes the publicly recognized but ineligible second-release Tap", function()
	expect({
		fixture.input.input.owner.SetSource("Gestures", {
			gestures = {
				Q = {
					Tap = { maxDurationSeconds = 0.25 },
					DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
				},
			},
		}),
	}).toEqual({ true })

	Utils.set(fixture, { Utils.fixed(Utils.key("Q", "Tap"), "Movement.Tap") })
	Utils.select(fixture)
	Utils.press(fixture, 0, "Q")
	Utils.press(fixture, 0.125, "Q")
	expect(Utils.actions(fixture)).toEqual({ "Movement.Tap" })
	expect(#fixture.input.events).toBe(3)
	expect(fixture.input.events[3].gesture).toBe("Tap")
end)

for _, explicitExclusive: boolean in { false, true } do
	it("keeps custom default Independent and honors same-root Exclusive=" .. tostring(explicitExclusive), function()
		expect({
			fixture.input.input.owner.SetSource("Custom", {
				recognizers = {
					Motion = SequenceUtils.recognizer(
						function(
							_context: InputTypes.RecognizerContext,
							event: InputTypes.RecognizerEvent
						): InputTypes.CustomMatch?
							return if event.kind == "Pressed" then {} else nil
						end
					),
				},
			}),
		}).toEqual({ true })

		local route: Types.ActionRoute = Utils.fixed({ kind = "Custom", recognizerId = "Motion" }, "Motion.Cast")

		if explicitExclusive then
			route.dispatch = { mode = "Exclusive" }
		end

		Utils.set(fixture, { Utils.fixed(), route })
		Utils.select(fixture)
		Utils.emit(fixture, 0)
		local actions: { string } = Utils.actions(fixture)
		table.sort(actions)
		expect(actions).toEqual(if explicitExclusive then { "Motion.Cast" } else { "Combat.Punch", "Motion.Cast" })
		expect(#fixture.input.recognizers).toBe(1)
		expect(#fixture.input.input.events).toBe(1)
	end)
end

for _, ranking: string in
	{ "DispatchPriority", "SequenceBeforeCustom", "LongerSequence", "Ambiguous", "IndependentSurvives" }
do
	it("arbitrates mapped exclusive collisions by " .. ranking .. " before invoking resolvers", function()
		expect({
			SequenceUtils.install(fixture.input, {
				Alpha = SequenceUtils.pattern({ "X" }),
				Beta = SequenceUtils.pattern(if ranking == "LongerSequence" then { "Q", "X" } else { "X" }),
			}),
		}).toEqual({ true })

		expect({
			fixture.input.input.owner.SetSource("Custom", {
				recognizers = {
					Motion = SequenceUtils.recognizer(
						function(
							_context: InputTypes.RecognizerContext,
							event: InputTypes.RecognizerEvent
						): InputTypes.CustomMatch?
							return if event.kind == "Pressed" then {} else nil
						end
					),
				},
			}),
		}).toEqual({ true })

		local calls: { string } = {}
		local routes: { Types.ActionRoute } = { Utils.fixed() }

		for _, id: string in { "Alpha", "Beta" } do
			if ranking == "SequenceBeforeCustom" and id == "Beta" then
				continue
			end

			local route: Types.ActionRoute = Utils.dynamic(
				{ kind = "Sequence", sequenceId = id },
				function(): Types.ResolvedAction?
					table.insert(calls, id)

					return { actionId = "Sequence." .. id }
				end
			)

			if ranking == "DispatchPriority" and id == "Beta" then
				route.dispatch = { priority = 1 }
			end

			table.insert(routes, route)
		end

		local custom: Types.ActionRoute = Utils.dynamic(
			{ kind = "Custom", recognizerId = "Motion" },
			function(): Types.ResolvedAction?
				table.insert(calls, "Motion")

				return { actionId = "Motion.Cast" }
			end
		)

		custom.dispatch = { mode = if ranking == "IndependentSurvives" then "Independent" else "Exclusive" }
		table.insert(routes, custom)
		Utils.set(fixture, routes)
		Utils.select(fixture)

		if ranking == "LongerSequence" then
			Utils.press(fixture, 0, "Q")
		end

		Utils.emit(fixture, 0.125)

		expect(calls).toEqual(
			if ranking == "SequenceBeforeCustom"
				then { "Alpha" }
				elseif ranking == "Ambiguous" then {}
				elseif ranking == "IndependentSurvives" then { "Motion" }
				else { "Beta" }
		)

		if ranking == "Ambiguous" or ranking == "IndependentSurvives" then
			expect(fixture.faults).toEqual({ "AmbiguousExclusiveRoutes" })
			expect(Utils.actions(fixture)).toEqual(if ranking == "IndependentSurvives" then { "Motion.Cast" } else {})
		else
			expect(#fixture.selections).toBe(1)
		end
	end)
end

it("allows equal-priority exclusive sequences that never overlap", function()
	expect({
		SequenceUtils.install(
			fixture.input,
			{ Left = SequenceUtils.pattern({ "X" }), Right = SequenceUtils.pattern({ "Q" }) }
		),
	}).toEqual({ true })

	Utils.set(fixture, {
		Utils.fixed({ kind = "Sequence", sequenceId = "Left" }, "Left"),
		Utils.fixed({ kind = "Sequence", sequenceId = "Right" }, "Right"),
	})

	Utils.select(fixture)
	Utils.press(fixture, 0)
	Utils.press(fixture, 1, "Q")
	expect(Utils.actions(fixture)).toEqual({ "Left", "Right" })
	expect(fixture.faults).toEqual({})
end)

it("does not reroute a masked final input when a mock downstream command rejects selection", function()
	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X" }) }) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed(), Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Game.NotGranted") })
	local downstream: { string } = {}

	fixture.onSink = function(selection: Types.ActionRouteSelection): ()
		table.insert(downstream, selection.actionId)
		-- Mock I5 admission failure / server denial is not an I4 arbitration retry.
		table.insert(downstream, "Rejected")
	end

	Utils.select(fixture)
	Utils.emit(fixture, 0)
	expect(downstream).toEqual({ "Game.NotGranted", "Rejected" })
	expect(Utils.actions(fixture)).toEqual({ "Game.NotGranted" })
end)
