--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Utils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("replaces one owned deadline and ignores callbacks from replaced timers", function()
	local calls: number = 0

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			if event.kind == "Pressed" then
				expect({ ctx:ScheduleAfter(0.5) }).toEqual({ true })
			elseif event.kind == "Released" then
				expect({ ctx:ScheduleAfter(0.25) }).toEqual({ true })
			end

			return nil
		end
	)

	definition.onDeadline = function(): Types.CustomMatch?
		calls += 1

		return {}
	end

	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Timed = definition } }) }).toEqual({ true })
	Utils.emit(fixture, 0, "X")
	local old: () -> () = fixture.jobs[#fixture.jobs].callback
	Utils.emit(fixture, 0.125, "X", "Released")
	expect(Utils.pending(fixture)).toBe(1)
	Utils.wake(fixture, 0.375001)
	expect(calls).toBe(1)
	old()
	Utils.wake(fixture, 1)
	expect(calls).toBe(1)
	expect(#fixture.recognizers).toBe(1)
	expect(fixture.envelopes[#fixture.envelopes].kind).toBe("Deferred")
end)

for _, timerFirst: boolean in { true, false } do
	it("processes exact deadline input first with timerFirst=" .. tostring(timerFirst), function()
		local trace: { string } = {}

		local definition: Types.RecognizerDefinition = Utils.recognizer(
			function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
				if event.kind ~= "Pressed" then
					return nil
				end

				table.insert(trace, "input")

				if ctx:GetState("started") == nil then
					expect({ ctx:SetState("started", true) }).toEqual({ true })
					expect({ ctx:ScheduleAfter(0.5) }).toEqual({ true })
				else
					ctx:ClearDeadline()

					return { metadata = { fromInput = true } }
				end

				return nil
			end
		)

		definition.onDeadline = function(): Types.CustomMatch?
			table.insert(trace, "deadline")

			return {}
		end

		expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Timed = definition } }) }).toEqual({ true })
		Utils.press(fixture, 0, "X")

		if timerFirst then
			Utils.wake(fixture, 0.5)
		end

		Utils.press(fixture, 0.5, "X")
		Utils.wake(fixture, 0.500001)
		expect(trace).toEqual({ "input", "input" })
		expect(#fixture.recognizers).toBe(1)
		expect(fixture.recognizers[1].metadata).toEqual({ fromInput = true })
	end)
end

it("delivers a strictly overdue deadline before a later input in its own occurrence", function()
	local trace: { string } = {}

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			if event.kind == "Pressed" then
				table.insert(trace, "input")
				expect({ ctx:ScheduleAfter(0.25) }).toEqual({ true })
			end

			return nil
		end
	)

	definition.onDeadline = function(): Types.CustomMatch?
		table.insert(trace, "deadline")

		return {}
	end

	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Timed = definition } }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")
	local count: number = #fixture.envelopes
	Utils.emit(fixture, 0.5, "X")
	expect(trace).toEqual({ "input", "deadline", "input" })
	expect(fixture.envelopes[count + 1].kind).toBe("Deferred")
	expect(fixture.envelopes[count + 2].kind).toBe("Root")
	expect(fixture.recognizers[1].timestamp).toBe(0.5)
end)

it("fixes the window at the first external event and rejects later deadline extension", function()
	local outcomes: { { any } } = {}

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Timed = Utils.recognizer(
					function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						if event.kind == "Pressed" then
							table.insert(outcomes, { ctx:ScheduleAfter(0.75) })
						end

						return nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	Utils.press(fixture, 0.5, "X")
	expect(outcomes).toEqual({ { true }, { false, "RecognizerWindowExceeded" } })
	expect(assert(fixture.input.owner.GetRecognizer("Timed")).faulted).toBe(true)
	expect(Utils.pending(fixture)).toBe(0)
end)

it("expires scalar history at its horizon without needing an explicit callback deadline", function()
	local seen: { any } = {}

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				State = Utils.recognizer(
					function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						if event.kind ~= "Pressed" then
							return nil
						end

						table.insert(seen, ctx:GetState("seen") == true)
						expect({ ctx:SetState("seen", true) }).toEqual({ true })

						return nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	Utils.wake(fixture, 1.000001)
	expect(Utils.pending(fixture)).toBe(0)
	Utils.press(fixture, 1.25, "X")
	expect(seen).toEqual({ false, false })
end)

it("allows state at exact window equality and retires it strictly afterward", function()
	local seen: { boolean } = {}

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				State = Utils.recognizer(
					function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						if event.kind ~= "Pressed" then
							return nil
						end

						table.insert(seen, ctx:GetState("seen") == true)
						expect({ ctx:SetState("seen", true) }).toEqual({ true })

						return nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	Utils.wake(fixture, 1)
	Utils.press(fixture, 1, "X")
	Utils.wake(fixture, 1.000001)
	Utils.press(fixture, 1.125, "X")
	expect(seen).toEqual({ false, true, false })
end)

for _, seconds: any in { 0, -1, math.huge, 0 / 0, "1" } do
	it("faults invalid custom deadline delay " .. tostring(seconds), function()
		expect({
			fixture.input.owner.SetSource("Custom", {
				recognizers = {
					Bad = Utils.recognizer(function(ctx: Types.RecognizerContext): Types.CustomMatch?
						expect({ ctx:ScheduleAfter(seconds) }).toEqual({ false, "InvalidRecognizerDeadline" })

						return {}
					end),
				},
			}),
		}).toEqual({ true })

		Utils.press(fixture, 0, "X")
		expect(#fixture.recognizers).toBe(0)
		expect(assert(fixture.input.owner.GetRecognizer("Bad")).faultReason).toBe("InvalidRecognizerDeadline")
		expect(Utils.pending(fixture)).toBe(0)
	end)
end

it("cannot perpetually renew a window from onDeadline", function()
	local calls: number = 0

	local definition: Types.RecognizerDefinition = Utils.recognizer(
		function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
			if event.kind == "Pressed" then
				expect({ ctx:ScheduleAfter(0.25) }).toEqual({ true })
			end

			return nil
		end
	)

	definition.onDeadline = function(ctx: Types.RecognizerContext): Types.CustomMatch?
		calls += 1
		ctx:ScheduleAfter(0.25)

		return nil
	end

	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Timed = definition } }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")

	for _, time: number in { 0.250001, 0.500002, 0.750003, 1.000004, 2 } do
		Utils.wake(fixture, time)
	end

	expect(calls <= 4).toBe(true)
	expect(Utils.pending(fixture)).toBe(0)
	expect(#fixture.recognizers).toBe(0)
end)

it("refuses a deadline during cancellation without faulting a recognizer retired by the commit", function()
	local outcomes: { { any } } = {}

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Cancel = Utils.recognizer(function(ctx: Types.RecognizerContext): Types.CustomMatch?
					table.insert(outcomes, { ctx:ScheduleAfter(0.25) })

					return nil
				end),
			},
		}),
	}).toEqual({ true })

	Utils.emit(fixture, 0, "X")
	expect({ fixture.input.owner.SetContextEnabled("Signs", false) }).toEqual({ true })

	expect(outcomes).toEqual({ { true }, { false, "RecognizerCancelled" } })
	expect(assert(fixture.input.owner.GetRecognizer("Cancel"), "Expected recognizer").faulted).toBe(false)
	expect(Utils.pending(fixture)).toBe(0)
end)
