--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local Limits = require(KRF.client.Action.utils.ActionRouteLimits)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("bounds source records per Actor and reclaims capacity after withdrawal", function()
	for index: number = 1, Limits.MAX_SOURCES_PER_ACTOR do
		Utils.set(fixture, { Utils.fixed() }, "Source" .. index, index)
	end

	expect({
		fixture.owner.SetProfileSource(
			fixture.actor,
			"Overflow",
			{ priority = Limits.MAX_SOURCES_PER_ACTOR + 1, routes = { Utils.fixed() } }
		),
	}).toEqual({ false, "ProfileSourceLimitExceeded" })

	expect(#fixture.owner.GetProfileSources(fixture.actor)).toBe(Limits.MAX_SOURCES_PER_ACTOR)
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Source1") }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed() }, "Replacement", -1)
	expect(#fixture.owner.GetProfileSources(fixture.actor)).toBe(Limits.MAX_SOURCES_PER_ACTOR)
end)

it("bounds profile Actors without rejecting available views that have no profile graph", function()
	Utils.set(fixture, { Utils.fixed() })

	for index: number = 2, Limits.MAX_ACTORS do
		local actor: ActorTypes.ActorView = Utils.actor(fixture, "Dormant" .. index)
		Utils.set(fixture, { Utils.fixed() }, "Base", nil, actor)
	end

	expect({ fixture.owner.SetProfileSource(fixture.other, "Overflow", { routes = { Utils.fixed() } }) }).toEqual({
		false,
		"ProfileActorLimitExceeded",
	})

	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed() }, "Base", nil, fixture.other)
end)

it("accepts the route-count boundary and rejects one extra route atomically", function()
	local inputs: { [string]: InputTypes.InputDefinition } = {}
	local routes: { Types.ActionRoute } = {}

	for index: number = 1, Limits.MAX_ROUTES_PER_SOURCE + 1 do
		local id: string = "Input" .. index

		inputs[id] = { context = "Signs", type = Enum.InputActionType.Bool, bindings = {} }
		table.insert(routes, Utils.fixed(Utils.key(id)))
	end

	expect({ fixture.input.input.owner.SetSource("ManyInputs", { inputs = inputs }) }).toEqual({ true })
	local extra: Types.ActionRoute = assert(table.remove(routes), "Expected over-budget declaration")
	Utils.set(fixture, routes)
	local before: { Types.ProfileSourceSnapshot } = fixture.owner.GetProfileSources(fixture.actor)
	table.insert(routes, extra)

	expect({ fixture.owner.SetProfileSource(fixture.actor, "Base", { routes = routes }) }).toEqual({
		false,
		"ProfileRouteLimitExceeded",
	})

	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual(before)
end)

it("bounds deduplicated context predicates while accepting the exact context budget", function()
	local contexts: { [string]: InputTypes.ContextDefinition } = {}
	local required: { string } = {}

	for index: number = 1, Limits.MAX_REQUIRED_CONTEXTS + 1 do
		local id: string = "Gate" .. index

		contexts[id] = { priority = index, sink = false }
		table.insert(required, id)
	end

	expect({ fixture.input.input.owner.SetSource("Gates", { contexts = contexts }) }).toEqual({ true })

	local route: Types.ActionRoute = Utils.fixed()
	route.requiredContexts = required

	expect({ fixture.owner.SetProfileSource(fixture.actor, "Base", { routes = { route } }) }).toEqual({
		false,
		"RouteContextLimitExceeded",
	})

	table.remove(required)
	table.insert(required, required[1])
	Utils.set(fixture, { route })
	expect(Utils.route(fixture).status).toBe("Gated")
end)

for _, count: number in { Limits.MAX_INTENTS_PER_OCCURRENCE, Limits.MAX_INTENTS_PER_OCCURRENCE + 1 } do
	it("bounds independent fanout before invoking any resolver with count=" .. tostring(count), function()
		local recognizers: { [string]: InputTypes.RecognizerDefinition } = {}
		local routes: { Types.ActionRoute } = {}
		local calls: number = 0

		for index: number = 1, count do
			local id: string = "Motion" .. index

			recognizers[id] = SequenceUtils.recognizer(
				function(
					_context: InputTypes.RecognizerContext,
					event: InputTypes.RecognizerEvent
				): InputTypes.CustomMatch?
					return if event.kind == "Pressed" then {} else nil
				end
			)

			table.insert(
				routes,
				Utils.dynamic({ kind = "Custom", recognizerId = id }, function(): Types.ResolvedAction?
					calls += 1

					return { actionId = id }
				end)
			)
		end

		expect({ fixture.input.input.owner.SetSource("Custom", { recognizers = recognizers }) }).toEqual({ true })
		Utils.set(fixture, routes)
		Utils.select(fixture)
		Utils.emit(fixture, 0)
		expect(calls).toBe(if count <= Limits.MAX_INTENTS_PER_OCCURRENCE then count else 0)
		expect(#fixture.selections).toBe(if count <= Limits.MAX_INTENTS_PER_OCCURRENCE then count else 0)

		expect(fixture.faults).toEqual(
			if count <= Limits.MAX_INTENTS_PER_OCCURRENCE then {} else { "RouteFanoutExceeded" }
		)
	end)
end

it("bounds prepared switches and rejects overflow without changing the selected Actor", function()
	Utils.select(fixture)
	local plans: { Types.PreparedActorSwitch } = {}

	for _ = 1, Limits.MAX_PREPARED_PLANS do
		local plan: Types.PreparedActorSwitch?, reason: string? = fixture.owner.PrepareControlledActor(fixture.other)
		expect(reason).toBeNil()
		local prepared: Types.PreparedActorSwitch = assert(plan, "Expected bounded prepared switch")
		table.insert(plans, prepared)
	end

	expect({ fixture.owner.PrepareControlledActor(fixture.other) }).toEqual({ nil, "ActionPlanLimitExceeded" })
	expect(#plans).toBe(Limits.MAX_PREPARED_PLANS)
	expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
end)

it("accepts exact ID and priority boundaries without a client-side server Action catalog", function()
	local id: string = string.rep("A", Limits.MAX_ID_BYTES)
	Utils.set(fixture, { Utils.fixed(nil, id) }, id, Limits.MAX_PRIORITY)
	expect(Utils.route(fixture)).toMatchObject({ sourceId = id, actionId = id, priority = Limits.MAX_PRIORITY })
	Utils.set(fixture, { Utils.fixed(Utils.key("Q")) }, "Negative", -Limits.MAX_PRIORITY)
	expect(Utils.route(fixture, Utils.key("Q"))).toMatchObject({ priority = -Limits.MAX_PRIORITY })
end)

it("keeps dormant Actors and sources out of selected-occurrence resolver work during sustained churn", function()
	local selectedCalls: number = 0
	local dormantCalls: number = 0

	Utils.set(fixture, {
		Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
			selectedCalls += 1

			return { actionId = "Selected.Action" }
		end),
	})

	for index: number = 2, Limits.MAX_ACTORS do
		local actor: ActorTypes.ActorView = Utils.actor(fixture, "Dormant" .. index)

		Utils.set(fixture, {
			Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
				dormantCalls += 1

				return { actionId = "Dormant.Action" }
			end),
		}, "Base", nil, actor)
	end

	Utils.select(fixture)

	for index: number = 1, 128 do
		Utils.set(fixture, { Utils.fixed(Utils.key("Q"), "Equipment" .. index) }, "Equipment", 100)
		Utils.press(fixture, index)
		expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Equipment") }).toEqual({ true })
	end

	expect(selectedCalls).toBe(128)
	expect(dormantCalls).toBe(0)
	expect(#fixture.selections).toBe(128)
	expect(SequenceUtils.pending(fixture.input)).toBe(0)
	expect(#fixture.owner.GetProfileSources(fixture.actor)).toBe(1)
end)
