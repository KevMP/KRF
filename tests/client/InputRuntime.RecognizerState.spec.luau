--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Constants = require(ReplicatedStorage.Packages.KRF.client.Input.utils.InputConstants)
local Utils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("keeps finite scalar state private and removes keys with nil", function()
	local observations: { any } = {}

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Counter = Utils.recognizer(
					function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						if event.kind ~= "Pressed" then
							return nil
						end

						expect((ctx :: any).state).toBeNil()
						expect(ctx:GetState("missing")).toBeNil()
						expect({ ctx:SetState("flag", false) }).toEqual({ true })
						expect(ctx:GetState("flag")).toBe(false)
						local count: number = (ctx:GetState("count") :: number?) or 0
						expect({ ctx:SetState("count", count + 1) }).toEqual({ true })
						expect({ ctx:SetState("text", "right") }).toEqual({ true })
						expect({ ctx:SetState("text", nil) }).toEqual({ true })
						expect(ctx:GetState("text")).toBeNil()
						table.insert(observations, { ctx:GetState("count"), ctx:Now() })

						return nil
					end
				),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	Utils.press(fixture, 0.125, "X")
	expect(observations).toEqual({ { 1, 0 }, { 2, 0.125 } })
end)

for _, value: any in { {}, setmetatable({}, {}), function() end, math.huge, -math.huge, 0 / 0, Vector2.zero } do
	it(
		"faults on invalid scalar state value " .. typeof(value) .. " even when the callback ignores rejection",
		function()
			expect({
				fixture.input.owner.SetSource("Custom", {
					recognizers = {
						Bad = Utils.recognizer(function(ctx: Types.RecognizerContext): Types.CustomMatch?
							local success: boolean, reason: string? = ctx:SetState("bad", value)
							expect({ success, reason }).toEqual({ false, "InvalidRecognizerState" })

							return { metadata = { shouldNotPublish = true } }
						end),
					},
				}),
			}).toEqual({ true })

			Utils.press(fixture, 0, "X")
			expect(#fixture.recognizers).toBe(0)
			expect(assert(fixture.input.owner.GetRecognizer("Bad")).faultReason).toBe("InvalidRecognizerState")
		end
	)
end

for _, key: string in { "", string.rep("k", Constants.MAX_RECOGNIZER_KEY_BYTES + 1) } do
	it("rejects state keys outside the byte bound", function()
		expect({
			fixture.input.owner.SetSource("Custom", {
				recognizers = {
					Bad = Utils.recognizer(function(ctx: Types.RecognizerContext): Types.CustomMatch?
						expect({ ctx:SetState(key, 1) }).toEqual({ false, "InvalidRecognizerState" })

						return nil
					end),
				},
			}),
		}).toEqual({ true })

		Utils.press(fixture, 0, "X")
		expect(assert(fixture.input.owner.GetRecognizer("Bad")).faultReason).toBe("InvalidRecognizerState")
	end)
end

it("enforces state slot capacity and allows replacement and deletion at capacity", function()
	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				State = Utils.recognizer(function(ctx: Types.RecognizerContext): Types.CustomMatch?
					for index: number = 1, Constants.MAX_RECOGNIZER_STATE_SLOTS do
						expect({ ctx:SetState(tostring(index), true) }).toEqual({ true })
					end

					expect({ ctx:SetState("1", false) }).toEqual({ true })
					expect({ ctx:SetState("1", nil) }).toEqual({ true })
					expect({ ctx:SetState("replacement", 1) }).toEqual({ true })
					expect({ ctx:SetState("overflow", 1) }).toEqual({ false, "RecognizerStateLimitExceeded" })

					return {}
				end),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	expect(#fixture.recognizers).toBe(0)
	expect(assert(fixture.input.owner.GetRecognizer("State")).faultReason).toBe("RecognizerStateLimitExceeded")
end)

it("bounds state bytes independently of slot count", function()
	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				State = Utils.recognizer(function(ctx: Types.RecognizerContext): Types.CustomMatch?
					expect({ ctx:SetState("blob", string.rep("x", Constants.MAX_RECOGNIZER_STATE_BYTES + 1)) }).toEqual({
						false,
						"RecognizerStateLimitExceeded",
					})

					return nil
				end),
			},
		}),
	}).toEqual({ true })

	Utils.press(fixture, 0, "X")
	expect(assert(fixture.input.owner.GetRecognizer("State")).faulted).toBe(true)
end)

it("copies flat output metadata before another callback mutates its original table", function()
	local metadata: { [string]: Types.RecognitionScalar } = { direction = "Right", speed = 2, exact = false }

	expect({
		fixture.input.owner.SetSource("Custom", {
			recognizers = {
				Alpha = Utils.recognizer(
					function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						return if event.kind == "Pressed" then { metadata = metadata } else nil
					end
				),
				Zebra = Utils.recognizer(function(): Types.CustomMatch?
					metadata.direction = "Changed"

					return nil
				end),
			},
		}),
	}).toEqual({ true })

	Utils.emit(fixture, 0, "X")
	expect(#fixture.recognizers).toBe(1)
	local event: Types.CustomRecognitionEvent = fixture.recognizers[1]
	expect(event.metadata).toEqual({ direction = "Right", speed = 2, exact = false })
	expect(table.isfrozen(event)).toBe(true)
	expect(table.isfrozen(assert(event.metadata, "Expected copied metadata"))).toBe(true)
end)

for _, output: any in
	{
		false,
		1,
		"match",
		{ actionId = "Forged" },
		{ inputId = "Q", kind = "Pressed" },
		{ metadata = { nested = {} } },
		{ metadata = { value = math.huge } },
		{ metadata = { value = function() end } },
		{ metadata = setmetatable({}, {}) },
		setmetatable({}, {}),
	}
do
	it("faults malformed custom output instead of publishing it", function()
		expect({
			fixture.input.owner.SetSource(
				"Custom",
				{ recognizers = { Bad = Utils.recognizer(function(): any
					return output
				end) } }
			),
		}).toEqual({ true })

		Utils.press(fixture, 0, "X")
		expect(#fixture.recognizers).toBe(0)
		expect(assert(fixture.input.owner.GetRecognizer("Bad")).faultReason).toBe("InvalidRecognizerResult")
		expect(fixture.input.events[1].kind).toBe("Pressed")
	end)
end

for _, mode: string in { "Slots", "Bytes", "Key" } do
	it("enforces custom metadata " .. mode .. " bounds", function()
		local metadata: { [string]: Types.RecognitionScalar } = {}

		if mode == "Slots" then
			for index: number = 1, Constants.MAX_RECOGNIZER_METADATA_SLOTS + 1 do
				metadata[tostring(index)] = true
			end
		elseif mode == "Bytes" then
			metadata.blob = string.rep("x", Constants.MAX_RECOGNIZER_METADATA_BYTES + 1)
		else
			metadata[string.rep("x", Constants.MAX_RECOGNIZER_KEY_BYTES + 1)] = true
		end

		expect({
			fixture.input.owner.SetSource("Custom", {
				recognizers = {
					Bad = Utils.recognizer(function(): Types.CustomMatch?
						return { metadata = metadata }
					end),
				},
			}),
		}).toEqual({ true })

		Utils.press(fixture, 0, "X")
		expect(#fixture.recognizers).toBe(0)
		expect(assert(fixture.input.owner.GetRecognizer("Bad")).faulted).toBe(true)
	end)
end
