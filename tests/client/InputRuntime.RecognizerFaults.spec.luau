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

for _, mode: string in { "Throw", "Yield", "Return", "State", "Deadline" } do
	it("isolates " .. mode .. " faults and preserves other committed recognition", function()
		local callback = function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): any
			if event.kind ~= "Pressed" then
				return nil
			end

			if mode == "Throw" then
				error("InjectedCustomFault")
			elseif mode == "Yield" then
				coroutine.yield()
			elseif mode == "Return" then
				return { metadata = { nested = {} } }
			elseif mode == "State" then
				ctx:SetState("bad", {} :: any)
			else
				ctx:ScheduleAfter(2)
			end

			return {}
		end

		expect({
			fixture.input.owner.SetSource("Custom", {
				recognizers = {
					Bad = Utils.recognizer(callback),
					Good = Utils.recognizer(
						function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
							return if event.kind == "Pressed" then {} else nil
						end
					),
				},
			}),
		}).toEqual({ true })

		Utils.press(fixture, 0, "X")
		expect(#fixture.recognizers).toBe(1)
		expect(fixture.recognizers[1].recognizerId).toBe("Good")
		expect(assert(fixture.input.owner.GetRecognizer("Bad")).faulted).toBe(true)
		expect(assert(fixture.input.owner.GetRecognizer("Good")).faulted).toBe(false)
		expect(#fixture.input.events).toBe(2)
		expect(#fixture.input.faults > 0).toBe(true)
		Utils.wake(fixture, 10)
		expect(Utils.pending(fixture)).toBe(0)
	end)
end

it("persists faults through equivalent reapplication and reset but recovers on material replacement", function()
	local calls: number = 0

	local definition: Types.RecognizerDefinition = Utils.recognizer(function(): Types.CustomMatch?
		calls += 1
		error("Broken")
	end)

	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Broken = definition } }) }).toEqual({ true })
	Utils.press(fixture, 0, "X")
	expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Broken = definition } }) }).toEqual({ true })
	expect({ fixture.input.owner.ResetRecognition(nil, "ActorChanged") }).toEqual({ true })
	Utils.press(fixture, 0.125, "X")
	expect(calls).toBe(1)
	expect(assert(fixture.input.owner.GetRecognizer("Broken")).faulted).toBe(true)

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Broken = Utils.recognizer(
					function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						return if event.kind == "Pressed" then {} else nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0.25, "X")
	expect(assert(fixture.input.owner.GetRecognizer("Broken")).faulted).toBe(false)
	expect(#fixture.recognizers).toBe(1)
end)

for _, deferred: boolean in { false, true } do
	it(
		"silently retires cross-source dependent history on a custom fault with deferred=" .. tostring(deferred),
		function()
			local calls: number = 0

			local definition: Types.RecognizerDefinition = Utils.recognizer(
				function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
					if event.kind ~= "Pressed" then
						return nil
					end

					calls += 1

					if calls == 2 then
						error("LaterFault")
					end

					return {}
				end
			)

			expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Sign = definition } }) }).toEqual({
				true,
			})

			local source: Types.InputSourceDefinition = if deferred
				then {
					sequenceGroups = {
						Group = {
							policy = "DeferredPrefix",
							maxGapSeconds = 0.5,
							maxTotalSeconds = 2,
							scope = { "X", "Q" },
						},
					},
					sequences = {
						Short = { steps = { { recognizerId = "Sign", kind = "Custom" } }, exclusiveGroup = "Group" },
						Long = { steps = { { recognizerId = "Sign", kind = "Custom" }, "Q" }, exclusiveGroup = "Group" },
					},
				}
				else { sequences = { Combo = Utils.pattern({ { recognizerId = "Sign", kind = "Custom" }, "Q" }) } }

			expect({ fixture.input.owner.SetSource("Foreign", source) }).toEqual({ true })
			Utils.press(fixture, 0, "X")
			expect(Utils.ids(fixture)).toEqual({})
			Utils.press(fixture, 0.125, "X")
			Utils.press(fixture, 0.25, "Q")
			Utils.wake(fixture, 10)
			expect(Utils.ids(fixture)).toEqual({})
			expect(#fixture.recognizers).toBe(1)
			expect(Utils.pending(fixture)).toBe(0)
		end
	)
end

for _, mode: string in { "Throw", "Yield", "Return" } do
	it("contains onDeadline " .. mode .. " failure without terminating InputRuntime", function()
		local definition: Types.RecognizerDefinition = Utils.recognizer(
			function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
				if event.kind == "Pressed" then
					ctx:ScheduleAfter(0.25)
				end

				return nil
			end
		)

		definition.onDeadline = function(): any
			if mode == "Throw" then
				error("DeadlineFault")
			elseif mode == "Yield" then
				coroutine.yield()
			end

			return false
		end

		expect({ fixture.input.owner.SetSource("Custom", { recognizers = { Timed = definition } }) }).toEqual({ true })
		Utils.press(fixture, 0, "X")
		Utils.wake(fixture, 0.250001)
		expect(assert(fixture.input.owner.GetRecognizer("Timed")).faulted).toBe(true)
		expect(#fixture.recognizers).toBe(0)
		expect({ fixture.input.owner.SetSource("Unrelated", {}) }).toEqual({ true })
		Utils.press(fixture, 0.5, "Q")
		expect(#fixture.input.events).toBe(4)
	end)
end
