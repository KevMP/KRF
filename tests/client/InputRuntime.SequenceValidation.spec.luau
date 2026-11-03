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

for _, steps: any in
	{
		{},
		{ "" },
		{ true },
		{ { inputId = "X", kind = "Released" } },
		{ { inputId = "X", kind = "Cancelled" } },
		{ { inputId = "X", kind = "StateChanged" } },
		{ { inputId = "X", recognizerId = "Other", kind = "Custom" } },
		{ { inputId = "X", kind = "Pressed", extra = 1 } },
		setmetatable({ "X" }, {}),
		{ [1] = "X", [3] = "Q" },
	}
do
	it("rejects malformed or lifecycle sequence steps atomically", function()
		local writes: number = #fixture.input.writes
		expect({ Utils.install(fixture, { Combo = Utils.pattern(steps) }) }).toEqual({ false, "InvalidSequence" })
		expect(#fixture.input.writes).toBe(writes)
	end)
end

for _, field: string in { "maxGapSeconds", "maxTotalSeconds" } do
	for _, value: any in
		{ 0, -1, math.huge, -math.huge, 0 / 0, true, "1", Constants.MAX_RECOGNITION_WINDOW_SECONDS + 1 }
	do
		it("rejects invalid " .. field .. " " .. tostring(value), function()
			local definition: any = Utils.pattern({ "X", "Q" })
			definition[field] = value
			expect({ Utils.install(fixture, { Combo = definition }) }).toEqual({ false, "InvalidSequence" })
		end)
	end
end

for _, declaration: any in
	{
		{ steps = { "X" } },
		{ steps = { "X" }, maxGapSeconds = 1, maxTotalSeconds = 2, extra = true },
		{ steps = { "X" }, maxGapSeconds = 1, maxTotalSeconds = 2, scope = { "Missing" } },
		{ steps = { "X" }, maxGapSeconds = 1, maxTotalSeconds = 2, scope = { "Aim" } },
		{ steps = { "X" }, maxGapSeconds = 1, maxTotalSeconds = 2, scope = { "X", "X" } },
		{
			steps = { "X" },
			maxGapSeconds = 1,
			maxTotalSeconds = 2,
			watchedTokens = { { inputId = "X", kind = "Released" } },
		},
	}
do
	it("rejects malformed timing or watched alphabets without replacing a valid definition", function()
		expect({ Utils.install(fixture, { Combo = Utils.pattern({ "X" }) }) }).toEqual({ true })
		local previous: Types.SequenceSnapshot = assert(fixture.input.owner.GetSequence("Combo"))
		local success: boolean, reason: string? = Utils.install(fixture, { Combo = declaration })
		expect(success).toBe(false)
		expect(type(reason)).toBe("string")
		expect(fixture.input.owner.GetSequence("Combo")).toBe(previous)
	end)
end

for _, size: number in { Constants.MAX_SEQUENCE_STEPS, Constants.MAX_SEQUENCE_STEPS + 1 } do
	it("enforces the step bound at " .. tostring(size), function()
		local steps: { Types.SequenceStep } = table.create(size, "X" :: Types.SequenceStep)

		expect({ Utils.install(fixture, { Combo = Utils.pattern(steps) }) }).toEqual(
			if size <= Constants.MAX_SEQUENCE_STEPS then { true } else { false, "InputSequenceStepLimitExceeded" }
		)
	end)
end

for _, size: number in { Constants.MAX_SEQUENCES, Constants.MAX_SEQUENCES + 1 } do
	it("enforces the composed sequence bound at " .. tostring(size), function()
		local definitions: { [string]: Types.SequenceDefinition } = {}

		for index: number = 1, size - 1 do
			definitions["Combo" .. tostring(index)] = Utils.pattern({ "X" })
		end

		expect({ Utils.install(fixture, definitions, "Catalog") }).toEqual({ true })

		expect({ Utils.install(fixture, { Last = Utils.pattern({ "X" }) }) }).toEqual(
			if size <= Constants.MAX_SEQUENCES then { true } else { false, "InputSequenceLimitExceeded" }
		)
	end)
end
