--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local Limits = require(ReplicatedStorage.Packages.KRF.client.Action.utils.ActionRouteLimits)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

local invalidRoutes: { { name: string, route: any, reason: string } } = {
	{
		name = "physical key",
		route = { when = Enum.KeyCode.X, target = { kind = "Fixed", actionId = "Punch" } },
		reason = "InvalidRouteKey",
	},
	{
		name = "untagged input",
		route = { when = { inputId = "X", gesture = "Pressed" }, target = { kind = "Fixed", actionId = "Punch" } },
		reason = "InvalidRouteKey",
	},
	{ name = "string target", route = { when = Utils.key(), target = "Punch" }, reason = "InvalidRouteTarget" },
	{ name = "callback sink", route = { when = Utils.key(), target = function() end }, reason = "InvalidRouteTarget" },
	{
		name = "empty action",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = "" } },
		reason = "InvalidActionId",
	},
	{
		name = "nonstring action",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = function() end } },
		reason = "InvalidActionId",
	},
	{
		name = "oversized action",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = string.rep("A", Limits.MAX_ID_BYTES + 1) } },
		reason = "InvalidActionId",
	},
	{
		name = "missing resolver",
		route = { when = Utils.key(), target = { kind = "Dynamic" } },
		reason = "InvalidRouteTarget",
	},
	{
		name = "noncallable resolver",
		route = { when = Utils.key(), target = { kind = "Dynamic", resolve = "Punch" } },
		reason = "InvalidRouteTarget",
	},
	{
		name = "mixed fixed and dynamic",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = "Punch", resolve = function() end } },
		reason = "InvalidRouteTarget",
	},
	{
		name = "dynamic with actionId",
		route = { when = Utils.key(), target = { kind = "Dynamic", actionId = "Punch", resolve = function() end } },
		reason = "InvalidRouteTarget",
	},
	{
		name = "released start",
		route = {
			when = { kind = "Input", inputId = "X", gesture = "Released" },
			target = { kind = "Fixed", actionId = "Punch" },
		},
		reason = "InvalidRouteKey",
	},
	{
		name = "cancelled start",
		route = {
			when = { kind = "Input", inputId = "X", gesture = "Cancelled" },
			target = { kind = "Fixed", actionId = "Punch" },
		},
		reason = "InvalidRouteKey",
	},
	{
		name = "analog start",
		route = {
			when = { kind = "Input", inputId = "Aim", gesture = "StateChanged" },
			target = { kind = "Fixed", actionId = "Aim" },
		},
		reason = "InvalidRouteKey",
	},
	{ name = "analog Pressed", route = Utils.fixed(Utils.key("Aim")), reason = "RouteInputNotBool" },
	{ name = "missing input", route = Utils.fixed(Utils.key("Missing")), reason = "UnknownRouteInput" },
	{ name = "undefined gesture", route = Utils.fixed(Utils.key("X", "Held")), reason = "UnknownRouteGesture" },
	{
		name = "missing sequence",
		route = Utils.fixed({ kind = "Sequence", sequenceId = "Missing" }),
		reason = "UnknownRouteSequence",
	},
	{
		name = "missing custom",
		route = Utils.fixed({ kind = "Custom", recognizerId = "Missing" }),
		reason = "UnknownRouteRecognizer",
	},
	{ name = "fake sequence input", route = Utils.fixed(Utils.key("Combo")), reason = "UnknownRouteInput" },
	{
		name = "unknown context gate",
		route = {
			when = Utils.key(),
			target = { kind = "Fixed", actionId = "Punch" },
			requiredContexts = { "Missing" },
		},
		reason = "UnknownRouteContext",
	},
	{
		name = "invalid gate list",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = "Punch" }, requiredContexts = "Signs" },
		reason = "InvalidRequiredContexts",
	},
	{
		name = "empty gate identity",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = "Punch" }, requiredContexts = { "" } },
		reason = "InvalidRequiredContexts",
	},
	{
		name = "unknown dispatch mode",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = "Punch" }, dispatch = { mode = "Sink" } },
		reason = "InvalidDispatchPolicy",
	},
	{
		name = "fractional dispatch priority",
		route = { when = Utils.key(), target = { kind = "Fixed", actionId = "Punch" }, dispatch = { priority = 0.5 } },
		reason = "InvalidDispatchPolicy",
	},
	{
		name = "infinite dispatch priority",
		route = {
			when = Utils.key(),
			target = { kind = "Fixed", actionId = "Punch" },
			dispatch = { priority = math.huge },
		},
		reason = "InvalidDispatchPolicy",
	},
}

for _, case in invalidRoutes do
	it("rejects " .. case.name .. " atomically with a stable reason", function()
		local success: boolean, reason: string? =
			fixture.owner.SetProfileSource(fixture.actor, "Invalid", { routes = { case.route } })

		expect({ success, reason }).toEqual({ false, case.reason })
		expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
		expect(fixture.selections).toEqual({})
	end)
end

for _, field: string in { "activation", "startParameters", "stopParameters" } do
	it("rejects route-owned " .. field .. " without invoking gameplay callbacks", function()
		local calls: number = 0

		local route: any = Utils.fixed()

		route[field] = if field == "activation"
			then "WhileDown"
			else function(): ()
				calls += 1
			end

		expect({ fixture.owner.SetProfileSource(fixture.actor, "Invalid", { routes = { route } }) }).toEqual({
			false,
			"InvalidActionRoute",
		})

		expect(calls).toBe(0)
	end)
end

for _, priority: number in { 0 / 0, math.huge, -math.huge, 0.5, Limits.MAX_PRIORITY + 1, -Limits.MAX_PRIORITY - 1 } do
	it("rejects nonfinite, fractional or out-of-budget source priority " .. tostring(priority), function()
		expect({
			fixture.owner.SetProfileSource(
				fixture.actor,
				"Invalid",
				{ priority = priority, routes = { Utils.fixed() } }
			),
		}).toEqual({ false, "InvalidProfilePriority" })
	end)
end

for _, sourceId: string in { "", string.rep("S", Limits.MAX_ID_BYTES + 1) } do
	it("rejects invalid profile source IDs on replace and remove", function()
		expect({ fixture.owner.SetProfileSource(fixture.actor, sourceId, { routes = {} }) }).toEqual({
			false,
			"InvalidProfileSourceId",
		})

		expect({ fixture.owner.RemoveProfileSource(fixture.actor, sourceId) }).toEqual({
			false,
			"InvalidProfileSourceId",
		})
	end)
end

it("rejects duplicate canonical keys within one source without installing its valid prefix", function()
	Utils.set(fixture, { Utils.fixed() })
	local before: Types.RouteQuerySnapshot = Utils.route(fixture)

	expect({
		fixture.owner.SetProfileSource(
			fixture.actor,
			"Base",
			{ routes = { Utils.fixed(), Utils.fixed(nil, "Other") } }
		),
	}).toEqual({ false, "DuplicateRouteKey" })

	expect(Utils.route(fixture)).toEqual(before)
end)

it("keeps Input, Sequence and Custom with the same ID in distinct canonical namespaces", function()
	expect({
		fixture.input.input.owner.SetSource("Recognition", {
			sequences = { X = SequenceUtils.pattern({ "Q" }) },
			recognizers = { X = SequenceUtils.recognizer(function()
				return nil
			end) },
		}),
	}).toEqual({ true })

	Utils.set(fixture, {
		Utils.fixed(Utils.key("X"), "Input.Action"),
		Utils.fixed({ kind = "Sequence", sequenceId = "X" }, "Sequence.Action"),
		Utils.fixed({ kind = "Custom", recognizerId = "X" }, "Custom.Action"),
	})

	expect(Utils.route(fixture)).toMatchObject({ actionId = "Input.Action" })

	expect(Utils.route(fixture, { kind = "Sequence", sequenceId = "X" })).toMatchObject({
		actionId = "Sequence.Action",
		dispatchMode = "Exclusive",
	})

	expect(Utils.route(fixture, { kind = "Custom", recognizerId = "X" })).toMatchObject({
		actionId = "Custom.Action",
		dispatchMode = "Independent",
	})
end)

it("accepts all defined built-in gesture keys and structurally valid unregistered Action IDs", function()
	expect({
		fixture.input.input.owner.SetSource("Gestures", {
			gestures = {
				X = {
					Tap = { maxDurationSeconds = 0.25 },
					Held = { afterSeconds = 0.5 },
					LongHeld = { afterSeconds = 1 },
					DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 },
				},
			},
		}),
	}).toEqual({ true })

	Utils.set(fixture, {
		Utils.fixed(Utils.key()),
		Utils.fixed(Utils.key("X", "Tap")),
		Utils.fixed(Utils.key("X", "Held")),
		Utils.fixed(Utils.key("X", "LongHeld")),
		Utils.fixed(Utils.key("X", "DoubleTapped"), "Game.UnregisteredClientTarget"),
	})

	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({
		{ sourceId = "Base", priority = 0, routeCount = 5 },
	})

	expect(fixture.selections).toEqual({})
end)

it("rejects sparse or dictionary route collections rather than silently omitting declarations", function()
	for _, routes: any in { { [2] = Utils.fixed() }, { X = Utils.fixed() } } do
		expect({ fixture.owner.SetProfileSource(fixture.actor, "Invalid", { routes = routes }) }).toEqual({
			false,
			"InvalidControlProfile",
		})
	end
end)

it("does not execute metatable accessors while validating untrusted profile data", function()
	local calls: number = 0

	local profile: any = setmetatable({}, {
		__index = function(): any
			calls += 1

			return {}
		end,
	})

	expect({ fixture.owner.SetProfileSource(fixture.actor, "Invalid", profile) }).toEqual({
		false,
		"InvalidControlProfile",
	})

	expect(calls).toBe(0)
end)
