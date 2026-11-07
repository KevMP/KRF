--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local InputTypes = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Registry = require(ReplicatedStorage.Packages.KRF.client.Actor.utils.ActorViewRegistryState)
local Limits = require(ReplicatedStorage.Packages.KRF.client.Action.utils.ActionRouteLimits)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("resolves only the selected route once at occurrence time against the captured Actor", function()
	local calls: number = 0
	local equipped: string = "Technique.Rasengan"
	local contexts: { Types.RouteResolveContext } = {}

	local route: Types.ActionRoute = Utils.dynamic(
		Utils.key(),
		function(context: Types.RouteResolveContext): Types.ResolvedAction?
			calls += 1
			table.insert(contexts, context)

			return { actionId = equipped }
		end
	)

	Utils.set(
		fixture,
		{ Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
			error("Shadow resolver executed", 0)
		end) }
	)

	Utils.set(fixture, { route }, "Equipment", 100)

	Utils.set(fixture, {
		Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
			error("Other Actor resolver executed", 0)
		end),
	}, "Equipment", 100, fixture.other)

	expect(calls).toBe(0)
	Utils.select(fixture)
	Utils.press(fixture, 0, "Q")
	expect(calls).toBe(0)
	Utils.press(fixture, 1)
	equipped = "Technique.Fireball"
	Utils.press(fixture, 2)
	expect(Utils.actions(fixture)).toEqual({ "Technique.Rasengan", "Technique.Fireball" })
	expect(calls).toBe(2)
	expect(contexts[1].actor).toBe(fixture.actor)
	expect(contexts[1].actorId).toBe("ActorA")
	expect(contexts[1].sourceId).toBe("Equipment")
	expect(contexts[1].key).toEqual(Utils.key())
	expect(contexts[1].timestamp).toBe(1)
	expect(contexts[2].timestamp).toBe(2)
	expect(table.isfrozen(contexts[1])).toBe(true)
	expect(table.isfrozen(contexts[1].key)).toBe(true)
	expect(contexts[1].envelope.kind).toBe("Root")
	expect(contexts[1].candidate.kind).toBe("Input")
end)

local failures: { { name: string, callback: (Types.RouteResolveContext) -> any, reason: string } } = {
	{
		name = "nil",
		callback = function()
			return nil
		end,
		reason = "ResolvedNoAction",
	},
	{
		name = "throw",
		callback = function()
			error("GameResolverFailure", 0)
		end,
		reason = "RouteResolverFailed",
	},
	{
		name = "yield",
		callback = function()
			coroutine.yield()

			return { actionId = "TooLate" }
		end,
		reason = "RouteResolverYielded",
	},
	{
		name = "string",
		callback = function()
			return "Combat.Punch"
		end,
		reason = "InvalidResolvedAction",
	},
	{
		name = "false",
		callback = function()
			return false
		end,
		reason = "InvalidResolvedAction",
	},
	{
		name = "missing action",
		callback = function()
			return { parameters = {} }
		end,
		reason = "InvalidActionId",
	},
	{
		name = "empty action",
		callback = function()
			return { actionId = "" }
		end,
		reason = "InvalidActionId",
	},
	{
		name = "oversized action",
		callback = function()
			return { actionId = string.rep("A", Limits.MAX_ID_BYTES + 1) }
		end,
		reason = "InvalidActionId",
	},
	{
		name = "action callback",
		callback = function()
			return { actionId = function() end }
		end,
		reason = "InvalidActionId",
	},
	{
		name = "lifecycle policy",
		callback = function()
			return { actionId = "Combat.Punch", activation = "WhileDown" }
		end,
		reason = "InvalidResolvedAction",
	},
	{
		name = "stop callback",
		callback = function()
			return { actionId = "Combat.Punch", stopParameters = function() end }
		end,
		reason = "InvalidResolvedAction",
	},
}

for _, case in failures do
	it("contains resolver " .. case.name .. " without lower-source fallback or corrupting future input", function()
		local calls: number = 0
		Utils.set(fixture, { Utils.fixed() })

		Utils.set(fixture, {
			Utils.dynamic(Utils.key(), function(context: Types.RouteResolveContext): Types.ResolvedAction?
				calls += 1

				return case.callback(context)
			end),
		}, "Equipment", 10)

		Utils.select(fixture)
		Utils.press(fixture, 0)
		expect(calls).toBe(1)
		expect(Utils.actions(fixture)).toEqual({})
		expect(fixture.faults).toEqual({ case.reason })
		expect(Utils.route(fixture)).toMatchObject({ sourceId = "Equipment" })
		expect(#fixture.input.input.events).toBe(2)
		expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Equipment") }).toEqual({ true })
		Utils.press(fixture, 1)
		expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
	end)
end

it("hands opaque parameters synchronously to mock I5 validation before retaining only a copied payload", function()
	local parameters: any = { aim = { x = 3 }, untrusted = Instance.new("Folder") }
	local copied: { number } = {}
	local insideResolver: boolean = false
	local calls: number = 0

	Utils.set(fixture, {
		Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
			calls += 1
			insideResolver = true

			return { actionId = "Technique.Cast", parameters = parameters }
		end),
	})

	fixture.onSink = function(selection: Types.ActionRouteSelection, payload: any?): ()
		expect(insideResolver).toBe(true)
		expect(payload).toBe(parameters)
		expect(table.isfrozen(payload)).toBe(false)
		expect(selection.actionId).toBe("Technique.Cast")
		expect((selection :: any).parameters).toBeNil()
		-- Model I5's synchronous schema boundary; arbitrary route data is untrusted.
		assert(type(payload.aim.x) == "number", "Invalid mock schema payload")
		table.insert(copied, payload.aim.x)
	end

	Utils.select(fixture)
	Utils.press(fixture, 0)
	insideResolver = false
	parameters.aim.x = 99
	expect(copied).toEqual({ 3 })
	expect(calls).toBe(1)
	expect(table.isfrozen(parameters)).toBe(false)
	parameters.untrusted:Destroy()
end)

it("freezes selection provenance once and does not re-resolve old metadata after equipment changes", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 1)
	local selected: Types.ActionRouteSelection = fixture.selections[1]
	local root: InputTypes.InputCandidateEnvelope = selected.envelope
	assert(root.kind == "Root", "Expected original native root")
	expect(selected.actor).toBe(fixture.actor)
	expect(selected.actorId).toBe("ActorA")
	expect(selected.key).toEqual(Utils.key())
	expect(selected.sourceId).toBe("Base")
	expect(selected.routeVersion > 0).toBe(true)
	expect(selected.selectionGeneration > 0).toBe(true)
	expect(table.isfrozen(selected)).toBe(true)
	expect(table.isfrozen(selected.key)).toBe(true)

	expect(selected.holdOwner).toEqual({
		inputId = "X",
		inputGeneration = root.inputGeneration,
		pressEpochId = root.rootInputEpochId,
		isActiveAfterCommit = true,
	})

	Utils.set(fixture, { Utils.fixed(nil, "Combat.SwordSlash") }, "Sword", 100)
	Utils.select(fixture, fixture.other)
	expect(selected.actor).toBe(fixture.actor)
	expect(selected.actionId).toBe("Combat.Punch")
	expect(selected.envelope).toBe(root)
	expect((selected :: any).activation).toBeNil()
	expect((selected :: any).stopParameters).toBeNil()
end)

for _, phase: string in { "Resolver", "SelectionObserver", "Sink", "ProfileObserver" } do
	it("rejects all synchronous public mutations during " .. phase .. " without hidden queued commits", function()
		local results: { { any } } = {}

		local function mutate(): ()
			table.insert(
				results,
				{ fixture.owner.SetProfileSource(fixture.actor, "Intruder", { routes = { Utils.fixed() } }) }
			)

			table.insert(results, { fixture.owner.RemoveProfileSource(fixture.actor, "Base") })
			table.insert(results, { fixture.owner.SetControlledActor(fixture.other) })
		end

		if phase == "ProfileObserver" then
			fixture.owner.ObserveRoutes(function()
				mutate()
			end)
		end

		Utils.set(fixture, {
			Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
				if phase == "Resolver" then
					mutate()
				end

				return { actionId = "Combat.Punch" }
			end),
		})

		Utils.select(fixture)

		if phase == "SelectionObserver" then
			fixture.owner.ObserveSelection(function()
				mutate()
			end)
		end

		if phase == "Sink" then
			fixture.onSink = function()
				mutate()
			end
		end

		if phase ~= "ProfileObserver" then
			Utils.press(fixture, 0)
		end

		expect(#results > 0).toBe(true)

		for _, result in results do
			expect(result).toEqual({ false, "DispatchInProgress" })
		end

		expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)

		expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({
			{ sourceId = "Base", priority = 0, routeCount = 1 },
		})
	end)
end

for _, invalidate: string in { "Identity", "Availability", "Owner" } do
	it("rechecks " .. invalidate .. " after resolver execution and suppresses a stale handoff", function()
		Utils.set(fixture, {
			Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
				if invalidate == "Identity" then
					Registry.Remove(fixture.actor)
				elseif invalidate == "Availability" then
					fixture.actors[1]:InstallUnavailable()
				else
					fixture.owner.Destroy()
				end

				return { actionId = "Combat.Punch" }
			end),
		})

		Utils.select(fixture)
		Utils.press(fixture, 0)
		expect(fixture.selections).toEqual({})
	end)
end

it("isolates a throwing or yielding private observer without moving dispatch to another frame", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)

	fixture.owner.ObserveSelection(function()
		error("ObserverFailed", 0)
	end)

	fixture.owner.ObserveSelection(function()
		coroutine.yield()
	end)

	local observed: number = 0

	local disconnect: () -> () = fixture.owner.ObserveSelection(function()
		observed += 1
	end)

	Utils.press(fixture, 0)
	expect(observed).toBe(1)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
	disconnect()
	disconnect()
	Utils.press(fixture, 1)
	expect(observed).toBe(1)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch", "Combat.Punch" })
end)

it("finishes private routing before a public input observer changes the next occurrence's profile", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)

	fixture.input.input.onPublish = function(event: InputTypes.SemanticInputEvent): ()
		if event.kind == "Pressed" then
			expect(Utils.actions(fixture)[1]).toBe("Combat.Punch")

			expect({
				fixture.owner.SetProfileSource(fixture.actor, "Base", { routes = { Utils.fixed(nil, "Combat.Kick") } }),
			}).toEqual({ true })
		end
	end

	Utils.press(fixture, 0)
	Utils.press(fixture, 1)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch", "Combat.Kick" })
end)

it("contains a private sink failure without retrying a shadowed or masked route", function()
	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X" }) }) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed(), Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })

	fixture.onSink = function(): ()
		error("Expected sink failure", 0)
	end

	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "Combo" })
	expect(fixture.faults).toEqual({ "ActionRouteSinkFailed" })
	fixture.onSink = nil
	Utils.press(fixture, 1)
	expect(Utils.actions(fixture)).toEqual({ "Combo", "Combo" })
end)

it("rechecks identity after a synchronous selection observer before handing parameters to the sink", function()
	Utils.set(fixture, { Utils.fixed() })

	fixture.owner.ObserveSelection(function(): ()
		Registry.Remove(fixture.actor)
	end)

	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(fixture.selections).toEqual({})
end)
