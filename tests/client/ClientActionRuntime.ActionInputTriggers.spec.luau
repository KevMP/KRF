--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, gesture: "DoubleTapped" | "Held" | "LongHeld" in { "DoubleTapped", "Held", "LongHeld" } do
	it("starts WhileDown from a still-live " .. gesture .. " root and stops only on that epoch's release", function()
		Utils.ready(fixture, Utils.policies())

		expect({
			fixture.input.SetSource("Gestures", {
				gestures = {
					AbilitySlot1 = {
						DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
						Held = { afterSeconds = 0.5 },
						LongHeld = { afterSeconds = 1 },
					},
				},
			}),
		}).toEqual({ true })

		Utils.set(fixture, { Utils.route("Combat.Rasengan", Utils.key(nil, gesture)) })

		if gesture == "DoubleTapped" then
			Utils.tap(fixture)
			fixture.clock.Advance(0.125)
		end

		Utils.emit(fixture, "Pressed")

		if gesture ~= "DoubleTapped" then
			fixture.clock.Advance(if gesture == "Held" then 0.5 else 1)
		end

		local original: number = Utils.started(fixture)
		Utils.tap(fixture, "Other")
		expect(#Utils.packets(fixture)).toBe(1)
		Utils.emit(fixture, "Released")
		expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
	end)
end

it("charges an immediate X Q Z sequence on final Z and ignores earlier keys' releases", function()
	Utils.ready(fixture, Utils.policies())

	expect({
		fixture.input.SetSource(
			"Signs",
			{ sequences = { Cast = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 } } }
		),
	}).toEqual({ true })

	Utils.set(fixture, {
		Utils.route("Combat.Rasengan", { kind = "Sequence", sequenceId = "Cast" }),
		Utils.route("Combat.Fireball", Utils.key("Z")),
	})

	Utils.tap(fixture, "X")
	fixture.clock.Advance(0.125)
	Utils.tap(fixture, "Q")
	fixture.clock.Advance(0.125)
	Utils.emit(fixture, "Pressed", "Z")
	local original: number = Utils.started(fixture)
	Utils.emit(fixture, "Released", "X")
	Utils.emit(fixture, "Released", "Q")
	expect(#Utils.packets(fixture)).toBe(1)
	Utils.emit(fixture, "Released", "Z")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("uses the verified immediate Custom root rather than forged ownership in consumer metadata", function()
	local stopInput: InputTypes.RecognitionHoldOwner? = nil

	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Combat.Rasengan"].stopParameters = function(context): any
		stopInput = context.input

		return { releaseAim = 2 }
	end

	Utils.ready(fixture, policies)

	expect({
		fixture.input.SetSource("Custom", {
			recognizers = {
				Motion = {
					inputs = { "X" },
					maxWindowSeconds = 1,
					onEvent = function(_context, event): InputTypes.CustomMatch?
						return if event.kind == "Pressed"
							then { metadata = { inputId = "Q", pressEpochId = 999, inputGeneration = -1 } }
							else nil
					end,
				},
			},
		}),
	}).toEqual({ true })

	Utils.set(fixture, { Utils.route("Combat.Rasengan", { kind = "Custom", recognizerId = "Motion" }) })
	Utils.emit(fixture, "Pressed", "X")
	local original: number = Utils.started(fixture)
	Utils.tap(fixture, "Q")
	expect(#Utils.packets(fixture)).toBe(1)
	Utils.emit(fixture, "Released", "X")
	expect(assert(stopInput).inputId).toBe("X")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
end)

for _, trigger: string in { "Tap", "DeferredTap", "HeldCatchup", "Analog", "CustomDeadline", "DeferredPrefix" } do
	it("refuses a selected WhileDown from " .. trigger .. " while preserving I4's single selection", function()
		local startCalls: number = 0

		local policies: Types.ActionInputPolicies = Utils.policies()

		policies["Combat.Rasengan"].startParameters = function(): any
			startCalls += 1

			return { aim = 1 }
		end

		Utils.ready(fixture, policies)
		local selections: { Types.ActionRouteSelection } = {}

		assert(State.Get()).ObserveSelection(function(selection: Types.ActionRouteSelection): ()
			table.insert(selections, selection)
		end)

		local key: Types.RouteKey = Utils.key(nil, "Tap")

		if trigger == "Tap" or trigger == "DeferredTap" then
			local gestures: InputTypes.GestureDefinitions = { Tap = { maxDurationSeconds = 0.25 } }

			if trigger == "DeferredTap" then
				gestures.DoubleTapped =
					{ maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = "DeferredTap" }
			end

			expect({ fixture.input.SetSource("Gestures", { gestures = { AbilitySlot1 = gestures } }) }).toEqual({ true })
		elseif trigger == "HeldCatchup" then
			key = Utils.key(nil, "Held")

			expect({
				fixture.input.SetSource(
					"Gestures",
					{ gestures = { AbilitySlot1 = { Held = { afterSeconds = 0.5 } } } }
				),
			}).toEqual({ true })
		elseif trigger == "DeferredPrefix" then
			key = { kind = "Sequence", sequenceId = "Short" }

			expect({
				fixture.input.SetSource("Signs", {
					sequenceGroups = {
						Prefix = {
							policy = "DeferredPrefix",
							maxGapSeconds = 0.5,
							maxTotalSeconds = 2,
							scope = { "X", "Q", "Z" },
						},
					},
					sequences = {
						Short = { steps = { "X", "Q" }, exclusiveGroup = "Prefix" },
						Long = { steps = { "X", "Q", "Z" }, exclusiveGroup = "Prefix" },
					},
				}),
			}).toEqual({ true })
		else
			key = { kind = "Custom", recognizerId = "Motion" }

			local definition: InputTypes.RecognizerDefinition = {
				inputs = { if trigger == "Analog" then "Axis" else "X" },
				maxWindowSeconds = 1,
				onEvent = function(context, event): InputTypes.CustomMatch?
					if trigger == "Analog" then
						return {}
					elseif event.kind == "Pressed" then
						context:ScheduleAfter(0.25)
					end

					return nil
				end,
				onDeadline = function(): InputTypes.CustomMatch
					return { metadata = { inputId = "X", pressEpochId = 1 } }
				end,
			}

			expect({ fixture.input.SetSource("Custom", { recognizers = { Motion = definition } }) }).toEqual({ true })
		end

		Utils.set(fixture, { Utils.route("Combat.Rasengan", key) })

		if trigger == "Analog" then
			Utils.emit(fixture, "StateChanged", "Axis", 0.75)
		elseif trigger == "CustomDeadline" then
			Utils.emit(fixture, "Pressed", "X")
			fixture.clock.Advance(0.250001)
		elseif trigger == "DeferredPrefix" then
			Utils.tap(fixture, "X")
			Utils.emit(fixture, "Pressed", "Q")
			fixture.clock.Advance(0.500001)
		elseif trigger == "HeldCatchup" then
			Utils.emit(fixture, "Pressed")
			-- Advance observed time without firing the delayed timer first.
			fixture.inputTime = 100.75
			Utils.emit(fixture, "Released")
		else
			Utils.tap(fixture)

			if trigger == "DeferredTap" then
				fixture.clock.Advance(0.500001)
			end
		end

		expect(#selections).toBe(1)
		expect(selections[1].actionId).toBe("Combat.Rasengan")
		expect(selections[1].holdOwner).toBeNil()
		expect(startCalls).toBe(0)
		expect(Utils.packets(fixture)).toEqual({})
	end)
end

it("does not reopen a masked final-key route after the chosen sequence's Start callback fails", function()
	local calls: number = 0
	local fallbackCalls: number = 0

	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Combat.Rasengan"].startParameters = function(): any
		calls += 1

		error("Selected sequence Start failure", 0)
	end

	Utils.ready(fixture, policies)

	expect({
		fixture.input.SetSource(
			"Signs",
			{ sequences = { Cast = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 } } }
		),
	}).toEqual({ true })

	Utils.set(fixture, {
		Utils.route("Combat.Rasengan", { kind = "Sequence", sequenceId = "Cast" }),
		{
			when = Utils.key("Z"),
			target = {
				kind = "Dynamic",
				resolve = function(): Types.ResolvedAction
					fallbackCalls += 1

					return { actionId = "Combat.Fireball" }
				end,
			},
		},
	})

	Utils.tap(fixture, "X")
	Utils.tap(fixture, "Q")
	Utils.tap(fixture, "Z")
	expect(calls).toBe(1)
	expect(fallbackCalls).toBe(0)
	expect(Utils.packets(fixture)).toEqual({})
end)

it("consumes an original release before routing a new release-derived Tap Action", function()
	Utils.ready(fixture, Utils.policies())

	expect({
		fixture.input.SetSource("Gestures", { gestures = { AbilitySlot1 = { Tap = { maxDurationSeconds = 0.25 } } } }),
	}).toEqual({ true })

	Utils.set(fixture, { Utils.route("Combat.Rasengan"), Utils.route("Combat.Fireball", Utils.key(nil, "Tap")) })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	Utils.emit(fixture, "Released")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
	expect(Utils.packets(fixture)[3]).toMatchObject({ kind = "KRF.Action.Start", actionId = "Combat.Fireball" })
end)
