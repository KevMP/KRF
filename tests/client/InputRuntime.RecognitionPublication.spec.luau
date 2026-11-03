--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Utils = require(script.Parent.Utils.InputTestUtils)
local fixture: Utils.Fixture? = nil

afterEach(function()
	if fixture ~= nil then
		Utils.destroy(fixture)
		fixture = nil
	end
end)

for _, mode: string in { "Missing", "Throw", "Destroy" } do
	it("keeps recognition publication safe when publishers " .. mode, function()
		local sequenceCalls: number = 0
		local customCalls: number = 0
		local input: Utils.Fixture
		local publishSequence: ((Types.SequenceMatchEvent) -> ())? = nil
		local publishCustom: ((Types.CustomRecognitionEvent) -> ())? = nil

		if mode ~= "Missing" then
			publishSequence = function(): ()
				sequenceCalls += 1
				error("SequencePublicationFault", 0)
			end

			publishCustom = function(): ()
				customCalls += 1

				if mode == "Destroy" then
					input.owner.Destroy()
				else
					error("CustomPublicationFault", 0)
				end
			end
		end

		input = Utils.new({
			Scheduler = {
				Schedule = function(): () -> ()
					return function() end
				end,
			},
			PublishGesture = function() end,
			PublishSequence = publishSequence,
			PublishRecognizer = publishCustom,
		})

		fixture = input
		Utils.install(input)
		Utils.enable(input)

		local recognizer: Types.RecognizerDefinition = {
			inputs = { "Primary" },
			maxWindowSeconds = 1,
			onEvent = function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
				return if event.kind == "Pressed" then {} else nil
			end,
		}

		expect({
			input.owner.SetSource("Recognition", {
				sequences = { Combo = { steps = { "Primary" }, maxGapSeconds = 1, maxTotalSeconds = 2 } },
				recognizers = if mode == "Destroy"
					then { Sign = recognizer, Second = recognizer }
					else { Sign = recognizer },
			}),
		}).toEqual({ true })

		Utils.emit(input, "Pressed", true)
		expect(#input.events).toBe(1)

		if mode == "Throw" then
			expect(input.faults).toEqual({ "CustomPublicationFault", "SequencePublicationFault" })
			expect(sequenceCalls).toBe(1)
			expect(customCalls).toBe(1)
			expect(input.owner.GetSequence("Combo") ~= nil).toBe(true)
		elseif mode == "Destroy" then
			expect(input.owner.GetSequence("Combo")).toBeNil()
			expect(sequenceCalls).toBe(0)
			expect(customCalls).toBe(1)
			expect(input.connections).toBe(0)
		else
			expect(input.faults).toEqual({})
			expect(input.owner.GetSequence("Combo") ~= nil).toBe(true)
		end
	end)
end
