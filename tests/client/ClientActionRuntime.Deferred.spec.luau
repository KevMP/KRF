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

for _, flush: string in { "Timeout", "Mismatch" } do
	it("routes a " .. flush .. " DeferredPrefix separately using the current equipment mapping", function()
		expect({ fixture.input.input.owner.SetSource("Sequences", SequenceUtils.deferred()) }).toEqual({ true })

		Utils.set(fixture, {
			Utils.fixed(Utils.key("Q"), "Sign.Q"),
			Utils.fixed(Utils.key("C"), "Sign.C"),
			Utils.fixed({ kind = "Sequence", sequenceId = "Short" }, "Technique.Old"),
		})

		Utils.select(fixture)
		SequenceUtils.play(fixture.input, { "X", "Q" })
		expect(Utils.actions(fixture)).toEqual({ "Sign.Q" })

		Utils.set(
			fixture,
			{ Utils.fixed({ kind = "Sequence", sequenceId = "Short" }, "Technique.New") },
			"Equipment",
			10
		)

		if flush == "Timeout" then
			SequenceUtils.wake(fixture.input, 0.625001)
		else
			Utils.press(fixture, 0.25, "C")
		end

		expect(Utils.actions(fixture)).toEqual(
			if flush == "Timeout" then { "Sign.Q", "Technique.New" } else { "Sign.Q", "Technique.New", "Sign.C" }
		)

		local deferred: Types.ActionRouteSelection = fixture.selections[2]
		expect(deferred.envelope.kind).toBe("Deferred")
		expect(deferred.holdOwner).toBeNil()
		expect(deferred.envelope.occurrenceOrdinal > fixture.selections[1].envelope.occurrenceOrdinal).toBe(true)

		if flush == "Mismatch" then
			expect(fixture.selections[3].envelope.kind).toBe("Root")
			expect(fixture.selections[3].envelope.occurrenceOrdinal > deferred.envelope.occurrenceOrdinal).toBe(true)
		end

		expect(SequenceUtils.ids(fixture.input)).toEqual({ "Short" })
	end)
end

it("routes a delayed custom recognition independently of the earlier native key", function()
	local recognizer: InputTypes.RecognizerDefinition = SequenceUtils.recognizer(
		function(context: InputTypes.RecognizerContext, event: InputTypes.RecognizerEvent): InputTypes.CustomMatch?
			if event.kind == "Pressed" then
				context:ScheduleAfter(0.25)
			end

			return nil
		end
	)

	recognizer.onDeadline = function(): InputTypes.CustomMatch?
		return {}
	end

	expect({ fixture.input.input.owner.SetSource("Custom", { recognizers = { Timed = recognizer } }) }).toEqual({ true })

	local custom: Types.ActionRoute = Utils.fixed({ kind = "Custom", recognizerId = "Timed" }, "Motion.Cast")
	custom.dispatch = { mode = "Exclusive" }
	Utils.set(fixture, { Utils.fixed(), custom })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
	SequenceUtils.wake(fixture.input, 0.250001)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch", "Motion.Cast" })
	expect(fixture.selections[2].envelope.kind).toBe("Deferred")
	expect(fixture.selections[2].holdOwner).toBeNil()
end)

it("resolves deferred Tap from the current mapping and never replays a previous Pressed selection", function()
	expect({
		fixture.input.input.owner.SetSource("Gestures", {
			gestures = {
				X = {
					Tap = { maxDurationSeconds = 0.25 },
					DoubleTapped = {
						maxTapDurationSeconds = 0.25,
						maxGapSeconds = 0.5,
						arbitration = "DeferredTap",
					},
				},
			},
		}),
	}).toEqual({ true })

	Utils.set(fixture, { Utils.fixed(), Utils.fixed(Utils.key("X", "Tap"), "Tap.Old") })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	Utils.set(fixture, { Utils.fixed(Utils.key("X", "Tap"), "Tap.New") }, "Equipment", 100)
	SequenceUtils.wake(fixture.input, 0.500001)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch", "Tap.New" })
	expect(fixture.selections[2].holdOwner).toBeNil()
	expect(fixture.selections[2].envelope.kind).toBe("Deferred")
end)

it("evaluates current context gates at deferred emission rather than prefix recognition time", function()
	expect({ fixture.input.input.owner.SetSource("Sequences", SequenceUtils.deferred()) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed({ kind = "Sequence", sequenceId = "Short" }, "Base.Short") })

	local route: Types.ActionRoute = Utils.fixed({ kind = "Sequence", sequenceId = "Short" }, "Equipped.Short")
	route.requiredContexts = { "Aim" }
	Utils.set(fixture, { route }, "Equipment", 100)
	Utils.select(fixture)
	SequenceUtils.play(fixture.input, { "X", "Q" })
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	SequenceUtils.wake(fixture.input, 0.625001)
	expect(Utils.actions(fixture)).toEqual({ "Base.Short" })
end)

for _, pending: string in { "Sequence", "Custom", "Tap" } do
	it("resets pending " .. pending .. " history on Actor switch instead of completing on the new Actor", function()
		local key: Types.RouteKey

		if pending == "Sequence" then
			expect({ fixture.input.input.owner.SetSource("Sequences", SequenceUtils.deferred()) }).toEqual({ true })
			key = { kind = "Sequence", sequenceId = "Short" }
		elseif pending == "Tap" then
			expect({
				fixture.input.input.owner.SetSource("Gestures", {
					gestures = {
						X = {
							Tap = { maxDurationSeconds = 0.25 },
							DoubleTapped = {
								maxTapDurationSeconds = 0.25,
								maxGapSeconds = 0.5,
								arbitration = "DeferredTap",
							},
						},
					},
				}),
			}).toEqual({ true })

			key = Utils.key("X", "Tap")
		else
			local recognizer: InputTypes.RecognizerDefinition = SequenceUtils.recognizer(
				function(
					context: InputTypes.RecognizerContext,
					event: InputTypes.RecognizerEvent
				): InputTypes.CustomMatch?
					if event.kind == "Pressed" then
						context:ScheduleAfter(0.25)
					end

					return nil
				end
			)

			recognizer.onDeadline = function(): InputTypes.CustomMatch?
				return {}
			end

			expect({ fixture.input.input.owner.SetSource("Custom", { recognizers = { Timed = recognizer } }) }).toEqual({
				true,
			})

			key = { kind = "Custom", recognizerId = "Timed" }
		end

		Utils.set(fixture, { Utils.fixed(key, "ActorA.Action") })
		Utils.set(fixture, { Utils.fixed(key, "ActorB.Action") }, "Base", nil, fixture.other)
		Utils.select(fixture)
		Utils.press(fixture, 0)

		if pending == "Sequence" then
			Utils.press(fixture, 0.125, "Q")
		end

		Utils.select(fixture, fixture.other)
		SequenceUtils.wake(fixture.input, 2)
		expect(fixture.selections).toEqual({})
		expect(SequenceUtils.pending(fixture.input)).toBe(0)
	end)
end

it("uses one committed context snapshot for all independent candidates in an envelope", function()
	expect({
		SequenceUtils.install(
			fixture.input,
			{ Alpha = SequenceUtils.pattern({ "X" }), Beta = SequenceUtils.pattern({ "X" }) }
		),
	}).toEqual({ true })

	local routes: { Types.ActionRoute } = {}

	for _, id: string in { "Alpha", "Beta" } do
		local route: Types.ActionRoute = Utils.dynamic(
			{ kind = "Sequence", sequenceId = id },
			function(): Types.ResolvedAction?
				-- I1 defers this mutation until its finalized occurrence fence exits.
				expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })

				return { actionId = id }
			end
		)

		route.requiredContexts = { "Aim" }
		route.dispatch = { mode = "Independent" }
		table.insert(routes, route)
	end

	Utils.set(fixture, routes)
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local actions: { string } = Utils.actions(fixture)
	table.sort(actions)
	expect(actions).toEqual({ "Alpha", "Beta" })
	expect(fixture.input.input.owner.GetContext("Aim")).toMatchObject({ enabled = false })
end)
