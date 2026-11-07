--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("keeps same-named profile sources independent across Actors and the Input registry", function()
	Utils.set(fixture, { Utils.fixed() }, "Core")
	Utils.set(fixture, { Utils.fixed(nil, "Mount.Charge") }, "Core", nil, fixture.other)
	expect(Utils.route(fixture)).toMatchObject({ status = "Mapped", sourceId = "Core", actionId = "Combat.Punch" })
	expect(Utils.route(fixture, nil, fixture.other)).toMatchObject({ status = "Mapped", actionId = "Mount.Charge" })
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Core") }).toEqual({ true })
	expect(Utils.route(fixture)).toEqual({ status = "Unmapped" })
	expect(Utils.route(fixture, nil, fixture.other)).toMatchObject({ status = "Mapped", actionId = "Mount.Charge" })
	expect(fixture.input.input.owner.GetInput("X")).toMatchObject({ sourceId = "Core" })
end)

it("fully replaces one source and treats an empty contribution as withdrawal", function()
	Utils.set(fixture, { Utils.fixed(), Utils.fixed(Utils.key("Q"), "Movement.Dash") })
	Utils.set(fixture, { Utils.fixed(Utils.key("Q"), "Combat.Kick") })
	expect(Utils.route(fixture)).toEqual({ status = "Unmapped" })
	expect(Utils.route(fixture, Utils.key("Q"))).toMatchObject({ actionId = "Combat.Kick" })
	Utils.set(fixture, {})
	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
	expect(Utils.route(fixture, Utils.key("Q"))).toEqual({ status = "Unmapped" })
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
end)

it("restores a shadowed route without recreating native bindings or ending a live epoch", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local action: InputAction = fixture.input.input.actions.X
	local binding: InputBinding = fixture.input.input.bindings["X:Keyboard"]
	local writes: number = #fixture.input.input.writes
	local envelope = fixture.input.envelopes[1]
	assert(envelope.kind == "Root", "Expected original press root")
	Utils.set(fixture, { Utils.fixed(nil, "Combat.SwordSlash") }, "Sword", 100)
	expect(Utils.route(fixture)).toMatchObject({ sourceId = "Sword", priority = 100, shadowedSources = { "Base" } })
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Sword") }).toEqual({ true })
	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Punch" })
	expect(fixture.input.input.actions.X).toBe(action)
	expect(fixture.input.input.bindings["X:Keyboard"]).toBe(binding)
	expect(#fixture.input.input.writes).toBe(writes)

	expect(
		fixture.input.input.owner.IsPressEpochActive(
			"X",
			assert(envelope.rootInputEpochId, "Expected press epoch"),
			envelope.inputGeneration
		)
	).toBe(true)

	expect(#fixture.input.input.events).toBe(1)
end)

it("rejects equal-priority overlaps even with disjoint-looking context predicates and preserves the graph", function()
	Utils.set(fixture, { Utils.fixed() }, "Base", 5)

	local route: Types.ActionRoute = Utils.fixed(nil, "Combat.SwordSlash")
	route.requiredContexts = { "Aim" }

	expect({ fixture.owner.SetProfileSource(fixture.actor, "Sword", { priority = 5, routes = { route } }) }).toEqual({
		false,
		"ProfilePriorityConflict",
	})

	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({
		{ sourceId = "Base", priority = 5, routeCount = 1 },
	})

	expect(Utils.route(fixture)).toMatchObject({ sourceId = "Base", actionId = "Combat.Punch" })
end)

it("applies priority per tagged key and permits equal-priority nonoverlapping sources", function()
	Utils.set(fixture, { Utils.fixed() }, "Base", 10)
	Utils.set(fixture, { Utils.fixed(Utils.key("Q"), "Movement.Dash") }, "Movement", 10)
	expect(Utils.route(fixture)).toMatchObject({ sourceId = "Base" })
	expect(Utils.route(fixture, Utils.key("Q"))).toMatchObject({ sourceId = "Movement" })

	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({
		{ sourceId = "Base", priority = 10, routeCount = 1 },
		{ sourceId = "Movement", priority = 10, routeCount = 1 },
	})
end)

it("owns nested key, fixed target and dispatch declarations after registration", function()
	local route: Types.ActionRoute = Utils.fixed()
	route.dispatch = { priority = 7 }
	Utils.set(fixture, { route })
	local key: any = route.when
	local target: any = route.target

	key.inputId = "Q"
	target.actionId = "Wrong.Action"
	assert(route.dispatch, "Expected mutable source declaration").priority = 99
	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Punch", dispatchPriority = 7 })
	expect(Utils.route(fixture, Utils.key("Q"))).toEqual({ status = "Unmapped" })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
end)

it("copies nested declarations and returns frozen inspection without exposing callbacks", function()
	local calls: number = 0

	local route: Types.ActionRoute = Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
		calls += 1

		return { actionId = "Technique.Cast" }
	end)

	route.requiredContexts = { "Signs", "Aim", "Signs" }

	local profile: Types.ControlProfile = { routes = { route } }
	expect({ fixture.owner.SetProfileSource(fixture.actor, "Manual", profile) }).toEqual({ true })
	profile.routes[1] = Utils.fixed(nil, "Wrong.Action")
	table.clear(assert(route.requiredContexts, "Expected gate declarations"))
	local snapshot: Types.RouteQuerySnapshot = Utils.route(fixture)
	expect(snapshot).toMatchObject({ status = "Mapped", targetKind = "Dynamic", requiredContexts = { "Aim", "Signs" } })
	expect(table.isfrozen(snapshot)).toBe(true)
	expect((snapshot :: any).resolve).toBeNil()
	expect((snapshot :: any).activation).toBeNil()
	expect((snapshot :: any).actionId).toBeNil()
	assert(snapshot.status == "Mapped", "Expected mapped route")
	expect(table.isfrozen(snapshot.requiredContexts)).toBe(true)
	expect(table.isfrozen(snapshot.shadowedSources)).toBe(true)
	local sources: { Types.ProfileSourceSnapshot } = fixture.owner.GetProfileSources(fixture.actor)
	expect(table.isfrozen(sources)).toBe(true)
	expect(table.isfrozen(sources[1])).toBe(true)
	expect(calls).toBe(0)
end)

it("preserves route identity and emits no transition for equivalent reapplication", function()
	local route: Types.ActionRoute = Utils.fixed()
	Utils.set(fixture, { route })
	local before: Types.RouteQuerySnapshot = Utils.route(fixture)
	table.clear(fixture.transitions)
	Utils.set(fixture, { Utils.fixed() })
	expect(Utils.route(fixture)).toEqual(before)
	expect(fixture.transitions).toEqual({})
	expect(fixture.selections).toEqual({})
end)

it("uses AND gates and reveals a lower eligible source before invoking the selected resolver", function()
	local calls: number = 0
	Utils.set(fixture, { Utils.fixed() })

	local route: Types.ActionRoute = Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
		calls += 1

		return nil
	end)

	route.requiredContexts = { "Signs", "Aim" }
	Utils.set(fixture, { route }, "Equipment", 100)
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	expect(Utils.route(fixture)).toMatchObject({ sourceId = "Base" })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
	expect(calls).toBe(0)
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", true) }).toEqual({ true })
	Utils.press(fixture, 1)
	expect(calls).toBe(1)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
end)

it("distinguishes Gated and Unmapped for an available unselected Actor", function()
	local route: Types.ActionRoute = Utils.fixed()
	route.requiredContexts = { "Aim" }
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	Utils.set(fixture, { route }, "Sword", nil, fixture.other)
	expect(Utils.route(fixture, nil, fixture.other)).toEqual({ status = "Gated", candidateSources = { "Sword" } })
	expect(Utils.route(fixture)).toEqual({ status = "Unmapped" })
	expect(fixture.owner.GetControlledActor()).toBeNil()
end)
