--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local InputTypes = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("publishes complete old-to-new profile and shadow-restoration snapshots before returning success", function()
	Utils.set(fixture, { Utils.fixed() })
	local original: Types.RouteQuerySnapshot = Utils.route(fixture)
	table.clear(fixture.transitions)
	local observedDuringCommit: boolean = false

	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		expect(Utils.route(fixture)).toEqual(change.next)
		expect(table.isfrozen(change)).toBe(true)
		expect(table.isfrozen(change.previous)).toBe(true)
		expect(table.isfrozen(change.next)).toBe(true)
		expect(change.actor).toBe(fixture.actor)
		expect(change.key).toEqual(Utils.key())
		expect(#change.reason > 0).toBe(true)
		observedDuringCommit = true
	end)

	Utils.set(fixture, { Utils.fixed(nil, "Combat.SwordSlash") }, "Sword", 100)
	expect(observedDuringCommit).toBe(true)
	expect(fixture.transitions[1].previous).toEqual(original)
	expect(fixture.transitions[1].next).toMatchObject({ sourceId = "Sword", actionId = "Combat.SwordSlash" })
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Sword") }).toEqual({ true })
	expect(#fixture.transitions).toBe(2)
	expect(fixture.transitions[2].previous).toMatchObject({ sourceId = "Sword" })
	expect(fixture.transitions[2].next).toMatchObject({ sourceId = "Base", actionId = "Combat.Punch" })
end)

it("notifies mock I6 of gate-only invalidation while a Bool remains down without invoking a Stop hook", function()
	local calls: number = 0

	local route: Types.ActionRoute = Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
		calls += 1

		return { actionId = "Combat.Block" }
	end)

	route.requiredContexts = { "Aim" }
	Utils.set(fixture, { route })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local original: Types.ActionRouteSelection = fixture.selections[1]
	local interrupts: { Types.ActionRouteSelection } = {}
	local stopCalls: number = 0
	local retired: boolean = false

	fixture.input.input.owner.ObservePrimitive("Routing", function(occurrence): ()
		if
			occurrence.event.kind == "Released"
			and occurrence.pressEpochId == assert(original.holdOwner, "Expected original epoch").pressEpochId
			and not retired
		then
			stopCalls += 1
		end
	end)

	-- This is a mock future I6 retirement observer, not an Action lifetime owner.
	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		if change.actor == original.actor and change.next.status == "Gated" then
			retired = true
			table.insert(interrupts, original)
		end
	end)

	table.clear(fixture.transitions)
	local primitiveCount: number = #fixture.input.input.events
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	expect(#fixture.input.input.events).toBe(primitiveCount)
	expect(#fixture.transitions).toBe(1)
	expect(fixture.transitions[1].previous).toMatchObject({ status = "Mapped", sourceId = "Base" })
	expect(fixture.transitions[1].next).toEqual({ status = "Gated", candidateSources = { "Base" } })
	expect(interrupts).toEqual({ original })
	expect(calls).toBe(1)
	expect(stopCalls).toBe(0)
	local hold = assert(original.holdOwner, "Expected unchanged native epoch")

	expect(fixture.input.input.owner.IsPressEpochActive(hold.inputId, hold.pressEpochId, hold.inputGeneration)).toBe(
		true
	)

	expect({ fixture.input.input.owner.SetContextEnabled("Aim", true) }).toEqual({ true })
	expect(fixture.transitions[2].previous.status).toBe("Gated")
	expect(fixture.transitions[2].next.status).toBe("Mapped")
	expect(calls).toBe(1)
	Utils.emit(fixture, 1, "X", "Released")
	expect(stopCalls).toBe(0)
end)

it("does not speculate about a changed game-owned target behind an unchanged dynamic route", function()
	local equipped: string = "Technique.Rasengan"
	local calls: number = 0

	local route: Types.ActionRoute = Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
		calls += 1

		return { actionId = equipped }
	end)

	Utils.set(fixture, { route })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local original: Types.ActionRouteSelection = fixture.selections[1]
	table.clear(fixture.transitions)
	equipped = "Technique.Fireball"
	Utils.set(fixture, { route })
	expect(fixture.transitions).toEqual({})
	expect(calls).toBe(1)
	Utils.emit(fixture, 1, "X", "Released")
	expect(calls).toBe(1)
	expect(original.actionId).toBe("Technique.Rasengan")
	Utils.press(fixture, 2)
	expect(Utils.actions(fixture)).toEqual({ "Technique.Rasengan", "Technique.Fireball" })
end)

it("reports native epoch invalidation even when the effective mapped Action does not change", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	table.clear(fixture.transitions)

	expect({
		fixture.input.input.owner.SetSource(
			"Rebind",
			{ priority = 1, bindingOverrides = { X = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		),
	}).toEqual({ true })

	expect(#fixture.transitions).toBe(1)
	expect(fixture.transitions[1].key).toEqual(Utils.key())
	expect(fixture.transitions[1].previous).toMatchObject({ status = "Mapped", actionId = "Combat.Punch" })
	expect(fixture.transitions[1].next).toMatchObject({ status = "Mapped", actionId = "Combat.Punch" })

	expect(fixture.input.input.events[#fixture.input.input.events]).toMatchObject({
		kind = "Cancelled",
		reason = "BindingChanged",
	})

	expect(#fixture.selections).toBe(1)
end)

it("emits no transition for unrelated graph edits or a failed profile replacement", function()
	Utils.set(fixture, { Utils.fixed() })
	table.clear(fixture.transitions)
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })

	expect({ fixture.owner.SetProfileSource(fixture.actor, "Base", { routes = { Utils.fixed(Utils.key("Missing")) } }) }).toEqual({
		false,
		"UnknownRouteInput",
	})

	expect(fixture.transitions).toEqual({})
	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Punch" })
end)

it("contains throwing or yielding route observers without hiding a committed synchronous mutation", function()
	fixture.owner.ObserveRoutes(function()
		error("ProfileObserverFailed", 0)
	end)

	fixture.owner.ObserveRoutes(function()
		coroutine.yield()
	end)

	Utils.set(fixture, { Utils.fixed() })
	expect(Utils.route(fixture)).toMatchObject({ status = "Mapped", actionId = "Combat.Punch" })
	expect(#fixture.transitions).toBe(1)
	expect({ fixture.owner.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
	expect(Utils.route(fixture)).toEqual({ status = "Unmapped" })
end)

it("reports sequence and custom epoch invalidation without a fabricated physical cancellation", function()
	local recognize = SequenceUtils.recognizer(function(): InputTypes.CustomMatch?
		return nil
	end)

	expect({
		fixture.input.input.owner.SetSource(
			"Recognition",
			{ sequences = { Combo = SequenceUtils.pattern({ "X", "Q" }) }, recognizers = { Motion = recognize } }
		),
	}).toEqual({ true })

	Utils.set(fixture, {
		Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }),
		Utils.fixed({ kind = "Custom", recognizerId = "Motion" }),
	})

	table.clear(fixture.transitions)

	expect({
		fixture.input.input.owner.SetSource(
			"Rebind",
			{ priority = 1, bindingOverrides = { X = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		),
	}).toEqual({ true })

	expect(#fixture.transitions).toBe(2)
	expect(fixture.input.input.events).toEqual({})
	table.clear(fixture.transitions)

	expect({
		fixture.input.input.owner.SetSource(
			"Rebind",
			{ priority = 1, bindingOverrides = { Z = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		),
	}).toEqual({ true })

	-- Restoring X invalidates both watched routes once more.
	expect(#fixture.transitions).toBe(2)
	table.clear(fixture.transitions)
	expect({ fixture.input.input.owner.RemoveSource("Rebind") }).toEqual({ true })
	expect(fixture.transitions).toEqual({})

	local replacement: InputTypes.RecognizerDefinition = table.clone(recognize)
	replacement.maxWindowSeconds = 2

	expect({
		fixture.input.input.owner.SetSource(
			"Recognition",
			{ sequences = { Combo = SequenceUtils.pattern({ "Q", "Z" }) }, recognizers = { Motion = replacement } }
		),
	}).toEqual({ true })

	expect(#fixture.transitions).toBe(2)

	for _, change: Types.EffectiveRouteTransition in fixture.transitions do
		expect(#change.reason > 0).toBe(true)
	end
end)

it("reports changes between fully gated source sets with no resolver evaluation", function()
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })

	local route: Types.ActionRoute = Utils.fixed()
	route.requiredContexts = { "Aim" }
	Utils.set(fixture, { route }, "Alpha")
	Utils.set(fixture, { route }, "Beta", 1)
	table.clear(fixture.transitions)
	Utils.set(fixture, { route }, "Beta", 1)
	expect(fixture.transitions).toEqual({})

	local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
		{ actor = fixture.actor, sourceId = "Beta" },
		{ actor = fixture.actor, sourceId = "Gamma", profile = { priority = 1, routes = { route } } },
	}))

	local plan: InputTypes.PreparedInputUpdate = assert(fixture.input.input.owner.PrepareSource("Empty", {}, profiles))

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
			expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
		end),
	}).toEqual({ true })

	expect(fixture.transitions[1].previous).toEqual({ status = "Gated", candidateSources = { "Beta", "Alpha" } })
	expect(fixture.transitions[1].next).toEqual({ status = "Gated", candidateSources = { "Gamma", "Alpha" } })
end)
