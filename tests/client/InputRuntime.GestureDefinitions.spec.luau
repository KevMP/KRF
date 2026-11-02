--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Constants = require(ReplicatedStorage.Packages.KRF.client.Input.utils.InputConstants)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)
local Utils = require(script.Parent.Utils.GestureTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("installs combined native and gesture declarations with copied frozen ownership", function()
	local source: Types.InputSourceDefinition = {
		contexts = { Menu = { priority = 3000, sink = false } },
		inputs = { Confirm = { context = "Menu", type = Enum.InputActionType.Bool, bindings = {} } },
		gestures = { Confirm = Utils.pair() },
	}

	expect({ fixture.input.owner.SetSource("Menu", source) }).toEqual({ true })
	local snapshots = assert(fixture.input.owner.GetGestures("Confirm"), "Expected configured gestures")
	expect(snapshots.Tap.sourceId).toBe("Menu")

	expect(snapshots.DoubleTapped.definition).toEqual({
		maxTapDurationSeconds = 0.25,
		maxGapSeconds = 0.5,
		arbitration = "PreferSpecific",
	})

	expect(table.isfrozen(snapshots)).toBe(true)
	expect(table.isfrozen(snapshots.Tap)).toBe(true)
	expect(table.isfrozen(snapshots.Tap.definition)).toBe(true)
	local declaration = assert(source.gestures, "Expected declarations")
	assert(declaration.Confirm.Tap, "Expected Tap").maxDurationSeconds = 10
	expect(snapshots.Tap.definition).toEqual({ maxDurationSeconds = 0.25, suppressIfHoldRecognized = false })
end)

it("lets different sources own different kinds without native graph churn", function()
	local action: InputAction = fixture.input.actions.Primary
	local writes: number = #fixture.input.writes
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } }, "TapOwner")).toBe(true)
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.5 } }, "HoldOwner")).toBe(true)
	expect(fixture.input.actions.Primary).toBe(action)
	expect(#fixture.input.writes).toBe(writes)
	local snapshots = assert(fixture.input.owner.GetGestures("Primary"), "Expected gestures")
	expect(snapshots.Tap.sourceId).toBe("TapOwner")
	expect(snapshots.Held.sourceId).toBe("HoldOwner")
	expect(fixture.input.owner.RemoveSource("HoldOwner")).toBe(true)
	expect(assert(fixture.input.owner.GetGestures("Primary"), "Expected Tap").Tap.sourceId).toBe("TapOwner")
	expect(#fixture.input.events).toBe(0)
end)

it("rejects duplicate ownership even with identical config and higher overlay priority", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.25 } }, "First")).toBe(true)
	local writes: number = #fixture.input.writes

	expect({
		fixture.input.owner.SetSource("Second", {
			priority = 10000,
			gestures = { Primary = { Held = { afterSeconds = 0.25 } } },
		}),
	}).toEqual({ false, "DuplicateGestureOwner" })

	expect(#fixture.input.writes).toBe(writes)
	expect(assert(fixture.input.owner.GetGestures("Primary"), "Expected Held").Held.sourceId).toBe("First")
end)

for _, inputType: Enum.InputActionType in
	{
		Enum.InputActionType.Direction1D,
		Enum.InputActionType.Direction2D,
		Enum.InputActionType.Direction3D,
		Enum.InputActionType.ViewportPosition,
	}
do
	it("rejects gestures targeting " .. inputType.Name .. " without native writes", function()
		local definition: InputTestUtils.CoreDefinition = InputTestUtils.definition(inputType)
		definition.inputs.Primary.bindings = {}
		expect(fixture.input.owner.SetSource("Core", definition)).toBe(true)
		local writes: number = #fixture.input.writes

		expect({ Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } }) }).toEqual({
			false,
			"GestureRequiresBool",
		})

		expect(#fixture.input.writes).toBe(writes)
	end)
end

it("rejects unknown references and removal or type replacement that strands a foreign gesture", function()
	expect({ fixture.input.owner.SetSource("Unknown", { gestures = { Missing = { Held = { afterSeconds = 1 } } } }) }).toEqual({
		false,
		"UnknownGestureInput",
	})

	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } })).toBe(true)
	local writes: number = #fixture.input.writes
	expect({ fixture.input.owner.RemoveSource("Core") }).toEqual({ false, "UnknownGestureInput" })

	local analog: InputTestUtils.CoreDefinition = InputTestUtils.definition(Enum.InputActionType.Direction1D)
	analog.inputs.Primary.bindings = {}
	expect({ fixture.input.owner.SetSource("Core", analog) }).toEqual({ false, "GestureRequiresBool" })
	expect(#fixture.input.writes).toBe(writes)
	expect(assert(fixture.input.owner.GetInput("Primary"), "Expected Bool").inputType).toBe(Enum.InputActionType.Bool)
end)

for _, value: any in { 0, -1, math.huge, -math.huge, 0 / 0, "0.25", true, Constants.MAX_GESTURE_DURATION_SECONDS + 1 } do
	for _, kind: string in { "Tap", "Held", "LongHeld", "DoubleTapped" } do
		it("rejects invalid " .. kind .. " duration " .. tostring(value) .. " atomically", function()
			local definitions: any = {}

			definitions[kind] = if kind == "Tap"
				then { maxDurationSeconds = value }
				else if kind == "DoubleTapped"
					then { maxTapDurationSeconds = value, maxGapSeconds = 0.5 }
					else { afterSeconds = value }

			local writes: number = #fixture.input.writes
			expect({ Utils.install(fixture, definitions) }).toEqual({ false, "InvalidGesture" })
			expect(#fixture.input.writes).toBe(writes)
		end)
	end
end

for _, value: any in { 0, -1, math.huge, 0 / 0, "0.5", Constants.MAX_GESTURE_DURATION_SECONDS + 1 } do
	it("rejects invalid double gap " .. tostring(value), function()
		expect({ Utils.install(fixture, { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = value } }) }).toEqual({
			false,
			"InvalidGesture",
		})
	end)
end

for _, definitions: any in
	{
		{ Tap = {} },
		{ Held = {} },
		{ LongHeld = {} },
		{ DoubleTapped = {} },
		{ Swipe = { afterSeconds = 1 } },
		{ Tap = { maxDurationSeconds = 1, extra = true } },
		{ Held = { afterSeconds = 1, extra = true } },
		{ DoubleTapped = { maxTapDurationSeconds = 1, maxGapSeconds = 1, extra = true } },
		{ Tap = { maxDurationSeconds = 1, suppressIfHoldRecognized = "true" } },
		{},
		setmetatable({ Held = { afterSeconds = 1 } }, {}),
	}
do
	it("rejects malformed gesture fields without replacing prior recognition", function()
		expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } })).toBe(true)
		expect({ Utils.install(fixture, definitions) }).toEqual({ false, "InvalidGesture" })
		expect(assert(fixture.input.owner.GetGestures("Primary"), "Expected Tap").Tap.sourceId).toBe("Gestures")
	end)
end

it("rejects suppression without same-source hold even if another source owns one", function()
	expect(Utils.install(fixture, { Held = { afterSeconds = 0.125 } }, "Other")).toBe(true)

	expect({ Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25, suppressIfHoldRecognized = true } }) }).toEqual({
		false,
		"GestureHoldDependencyMissing",
	})
end)

for _, threshold: number in { 0.25, 0.125 } do
	it("rejects LongHeld not strictly after foreign Held at " .. tostring(threshold), function()
		expect(Utils.install(fixture, { Held = { afterSeconds = 0.25 } }, "Other")).toBe(true)

		expect({ Utils.install(fixture, { LongHeld = { afterSeconds = threshold } }) }).toEqual({
			false,
			"InvalidHoldThresholdOrder",
		})
	end)
end

for _, policy: any in { "Unknown", true, false, 3 } do
	it("rejects invalid arbitration " .. tostring(policy), function()
		expect({
			Utils.install(
				fixture,
				{ DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = policy } }
			),
		}).toEqual({ false, "InvalidGesturePolicy" })
	end)
end

local invalidPairs: { Types.GestureDefinitions } = {
	{ DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = "DeferredTap" } },
	{
		Tap = { maxDurationSeconds = 0.125 },
		DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = "DeferredTap" },
	},
	{
		Tap = { maxDurationSeconds = 0.25, suppressIfHoldRecognized = true },
		Held = { afterSeconds = 0.125 },
		DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = "DeferredTap" },
	},
}

for _, definitions: Types.GestureDefinitions in invalidPairs do
	it("rejects incompatible DeferredTap dependencies before changing native bindings", function()
		local definition: Types.InputSourceDefinition = {
			bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } },
			gestures = { Primary = definitions },
		}

		local writes: number = #fixture.input.writes
		expect({ fixture.input.owner.SetSource("Pair", definition) }).toEqual({ false, "InvalidDeferredTapPair" })
		expect(#fixture.input.writes).toBe(writes)
		expect(fixture.input.bindings["Primary:Keyboard"].KeyCode).toBe(Enum.KeyCode.Q)
	end)
end

it("does not let a DeferredTap contribution delay another source's Tap", function()
	expect(Utils.install(fixture, { Tap = { maxDurationSeconds = 0.25 } }, "Other")).toBe(true)

	expect({
		Utils.install(
			fixture,
			{ DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = "DeferredTap" } }
		),
	}).toEqual({ false, "InvalidDeferredTapPair" })
end)

it("validates prepared gesture replacements against the prospective graph without publication", function()
	local plan: Types.PreparedInputUpdate?, reason: string? =
		fixture.input.owner.PrepareSource("Pair", { gestures = { Primary = Utils.pair() } })

	expect(reason).toBeNil()
	expect(plan ~= nil).toBe(true)
	expect(fixture.input.owner.GetGestures("Primary")).toEqual({})
	expect(fixture.input.owner.CommitPrepared(assert(plan, "Expected prepared plan"))).toBe(true)
	expect(assert(fixture.input.owner.GetGestures("Primary"), "Expected gestures").Tap.sourceId).toBe("Pair")
end)
