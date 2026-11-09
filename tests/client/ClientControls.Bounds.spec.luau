--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local InputTypes = require(KRF.client.Input.types)
local InputLimits = require(KRF.client.Input.utils.InputConstants)
local RouteLimits = require(KRF.client.Action.utils.ActionRouteLimits)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("accepts the existing I1 source budget and rejects overflow before native mutation", function()
	local inputs: { Types.InputSourceChange } = {}

	for index = 1, InputLimits.MAX_SOURCES - 1 do
		table.insert(
			inputs,
			{
				kind = "Set",
				sourceId = "Source" .. index,
				definition = {
					inputs = {
						["Input" .. index] = { context = "Combat", type = Enum.InputActionType.Bool, bindings = {} },
					},
				},
			} :: Types.InputSourceChange
		)
	end

	Utils.apply({ inputs = inputs })

	expect(fixture.base.input.GetInput("Input" .. (InputLimits.MAX_SOURCES - 1))).toMatchObject({
		sourceId = "Source" .. (InputLimits.MAX_SOURCES - 1),
	})

	local writes: number = #fixture.writes

	expect({
		Controls.Apply({
			inputs = {
				{
					kind = "Set",
					sourceId = "Overflow",
					definition = {
						inputs = {
							Overflow = { context = "Combat", type = Enum.InputActionType.Bool, bindings = {} },
						},
					},
				},
			},
		}),
	}).toEqual({ false, "InputSourceLimitExceeded" })

	expect(#fixture.writes).toBe(writes)
	expect(fixture.base.input.GetInput("Overflow")).toBeNil()
end)

it("shares the I4 per-Actor source budget and preserves a rejected joint graph", function()
	local profiles: { Types.ProfileSourceChange } = {}

	for _, actor in { fixture.base.actor, fixture.base.other } do
		for index = 1, RouteLimits.MAX_SOURCES_PER_ACTOR do
			table.insert(
				profiles,
				{
					kind = "Set",
					actor = actor,
					sourceId = "Profile" .. index,
					profile = { priority = index, routes = { ActionUtils.route("Combat.Fireball") } },
				} :: Types.ProfileSourceChange
			)
		end
	end

	Utils.apply({ profiles = profiles })
	local writes: number = #fixture.writes

	expect({
		Controls.Apply({
			inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } },
			profiles = {
				{
					kind = "Set",
					actor = fixture.base.other,
					sourceId = "Overflow",
					profile = { priority = 1000, routes = { ActionUtils.route("Combat.Fireball") } },
				},
			},
		}),
	}).toEqual({ false, "ProfileSourceLimitExceeded" })

	expect(#fixture.writes).toBe(writes)
	expect(#Runtime.GetProfileSources(fixture.base.other)).toBe(RouteLimits.MAX_SOURCES_PER_ACTOR)
	expect(fixture.base.input.GetInput("Sign")).toBeNil()
end)

it("rejects oversized context and route declarations using owner limits", function()
	local contexts: { [string]: InputTypes.ContextDefinition } = {}

	for index = 1, InputLimits.MAX_CONTEXTS + 1 do
		contexts["Context" .. index] = { priority = 1, sink = false }
	end

	local writes: number = #fixture.writes

	expect({
		Controls.Apply({ inputs = { { kind = "Set", sourceId = "Large", definition = { contexts = contexts } } } }),
	}).toEqual({ false, "InputContextLimitExceeded" })

	local routes: { ActionTypes.ActionRoute } = {}

	for _ = 1, RouteLimits.MAX_ROUTES_PER_SOURCE + 1 do
		table.insert(routes, ActionUtils.route("Combat.Fireball"))
	end

	expect({
		Controls.Apply({
			profiles = {
				{ kind = "Set", actor = fixture.base.actor, sourceId = "Large", profile = { routes = routes } },
			},
		}),
	}).toEqual({ false, "ProfileRouteLimitExceeded" })

	expect(#fixture.writes).toBe(writes)
end)

it(
	"returns native objects, listeners, timers and prepared capacity to baseline after repeated changes and failures",
	function()
		local nativeCount: number = #fixture.base.container:GetDescendants()
		local observerCount: number = 0

		for _ in fixture.base.callbacks do
			observerCount += 1
		end

		local timers: number = fixture.base.clock.Count()

		for _ = 1, 100 do
			Utils.install(fixture)

			expect({ Controls.Apply({ contexts = { { contextId = "Missing", enabled = true } } }) }).toEqual({
				false,
				"UnknownContext",
			})

			Utils.apply({
				inputs = { { kind = "Remove", sourceId = "Manual" } },
				profiles = { { kind = "Remove", actor = fixture.base.actor, sourceId = "Manual" } },
			})

			Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
			Utils.apply({ selection = { kind = "Set", actor = fixture.base.actor } })
		end

		local remaining: number = 0

		for _ in fixture.base.callbacks do
			remaining += 1
		end

		expect(remaining).toBe(observerCount)
		expect(#fixture.base.container:GetDescendants()).toBe(nativeCount)
		expect(fixture.base.clock.Count()).toBe(timers)
		expect(fixture.connections).toBe(1)
		expect(Runtime.GetProfileSources(fixture.base.actor)).toEqual({})
		Utils.apply({})
	end
)

it("does not compile or write native configuration on the ordinary input hot path", function()
	local compilations: number = 0

	local stop = fixture.base.input.RegisterGraphValidator(function(): (boolean, string?)
		compilations += 1

		return true, nil
	end)

	Utils.apply({
		profiles = {
			{
				kind = "Set",
				actor = fixture.base.actor,
				sourceId = "Base",
				profile = { routes = { ActionUtils.route("Combat.Fireball") } },
			},
		},
	})

	local baseline: number = compilations
	local writes: number = #fixture.writes

	for _ = 1, 10 do
		ActionUtils.tap(fixture.base)
	end

	expect(compilations).toBe(baseline)
	expect(#fixture.writes).toBe(writes)
	expect(#ActionUtils.packets(fixture.base)).toBe(10)
	stop()
end)
