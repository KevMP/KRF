--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Controls.types)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local InputTypes = require(KRF.client.Input.types)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("preserves native identity, live Bool epoch, route version and activation on equivalent Apply", function()
	local original: number = Utils.charge(fixture)
	local action: InputAction = fixture.base.actions.AbilitySlot1
	local graph: InputTypes.InputGraphSnapshot = fixture.base.input.GetGraphSnapshot()
	local route: ActionTypes.RouteQuerySnapshot = Utils.route(fixture)
	local writes: number = #fixture.writes
	local occurrences: { InputTypes.PrimitiveOccurrence } = {}

	local stop = fixture.base.input.ObservePrimitive("Routing", function(occurrence): ()
		table.insert(occurrences, occurrence)
	end)

	Utils.apply({
		profiles = {
			{
				kind = "Set",
				actor = fixture.base.actor,
				sourceId = "Base",
				profile = { routes = { ActionUtils.route("Combat.Rasengan") } },
			},
		},
		selection = { kind = "Set", actor = fixture.base.actor },
		contexts = { { contextId = "Combat", enabled = true } },
	})

	expect(fixture.base.actions.AbilitySlot1).toBe(action)
	expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
	expect(Utils.route(fixture)).toEqual(route)
	expect(#fixture.writes).toBe(writes)
	expect(occurrences).toEqual({})
	ActionUtils.emit(fixture.base, "Released")

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Stop",
		originalStartRequestId = original,
	})

	stop()
end)

for _, explicit: boolean in { false, true } do
	it("retains enablement for the same context owner unless explicitly disabled " .. tostring(explicit), function()
		expect({ fixture.base.input.SetSource("Manual", Utils.manual()) }).toEqual({ true })
		expect({ fixture.base.input.SetContextEnabled("HandSigns", true) }).toEqual({ true })
		local context: Instance? = fixture.base.actions.Sign.Parent
		local definition: InputTypes.InputSourceDefinition = Utils.manual()
		assert(definition.contexts).HandSigns.priority = 4000

		local changes: Types.ControlChangeSet =
			{ inputs = { { kind = "Set", sourceId = "Manual", definition = definition } } }

		if explicit then
			changes.contexts = { { contextId = "HandSigns", enabled = false } }
		end

		Utils.apply(changes)

		expect(fixture.base.input.GetContext("HandSigns")).toMatchObject({
			enabled = not explicit,
			priority = 4000,
			sourceId = "Manual",
		})

		expect(fixture.base.actions.Sign.Parent).toBe(context)
	end)
end

for _, enabled: boolean in { false, true } do
	it("gives a transferred context a new disabled lifetime unless enabled explicitly " .. tostring(enabled), function()
		expect({ fixture.base.input.SetSource("Old", Utils.manual()) }).toEqual({ true })
		expect({ fixture.base.input.SetContextEnabled("HandSigns", true) }).toEqual({ true })
		ActionUtils.set(fixture.base, { ActionUtils.route("Combat.Rasengan", ActionUtils.key("Sign")) })
		ActionUtils.emit(fixture.base, "Pressed", "Sign")
		local original: number = ActionUtils.started(fixture.base)
		local occurrences: { InputTypes.PrimitiveOccurrence } = {}

		local stop = fixture.base.input.ObservePrimitive("Routing", function(occurrence): ()
			table.insert(occurrences, occurrence)
		end)

		local changes: Types.ControlChangeSet = {
			inputs = {
				{ kind = "Set", sourceId = "New", definition = Utils.manual() },
				{ kind = "Remove", sourceId = "Old" },
			},
		}

		if enabled then
			changes.contexts = { { contextId = "HandSigns", enabled = true } }
		end

		Utils.apply(changes)
		expect(fixture.base.input.GetContext("HandSigns")).toMatchObject({ enabled = enabled, sourceId = "New" })
		expect(#occurrences).toBe(1)
		expect(occurrences[1].event.kind).toBe("Cancelled")

		expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
		})

		ActionUtils.emit(fixture.base, "Pressed", "Sign")
		expect(#ActionUtils.packets(fixture.base)).toBe(2)
		stop()
	end)
end

for _, cause: string in { "Profile", "Gate" } do
	it("retires the original Action for a " .. cause .. " change while retaining the primitive epoch", function()
		local route: ActionTypes.ActionRoute = ActionUtils.route("Combat.Rasengan")
		route.requiredContexts = { "Gate" }
		ActionUtils.set(fixture.base, { route })
		local held: InputTypes.PrimitiveOccurrence? = nil

		local stop = fixture.base.input.ObservePrimitive("Routing", function(occurrence): ()
			if occurrence.event.kind == "Pressed" then
				held = occurrence
			end
		end)

		ActionUtils.emit(fixture.base, "Pressed")
		local original: number = ActionUtils.started(fixture.base)
		local occurrence: InputTypes.PrimitiveOccurrence = assert(held, "Expected original press")
		local epoch: number = assert(occurrence.pressEpochId, "Expected Bool epoch")
		local events: number = #fixture.events

		if cause == "Profile" then
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
		else
			Utils.apply({ contexts = { { contextId = "Gate", enabled = false } } })
		end

		expect(fixture.base.input.IsPressEpochActive("AbilitySlot1", epoch, occurrence.generation)).toBe(true)
		expect(#fixture.events).toBe(events)
		expect(fixture.stopCalls).toBe(0)

		expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
			kind = "KRF.Action.Interrupt",
			originalStartRequestId = original,
		})

		ActionUtils.emit(fixture.base, "Released")
		expect(#ActionUtils.packets(fixture.base)).toBe(2)
		expect(fixture.events[#fixture.events].kind).toBe("Released")
		stop()
	end)
end

it("restores a shadowed route on withdrawal without rebuilding native inputs", function()
	ActionUtils.set(fixture.base, { ActionUtils.route("Combat.Fireball") })

	expect({
		Runtime.SetProfileSource(
			fixture.base.actor,
			"Sword",
			{ priority = 10, routes = { ActionUtils.route("Movement.Sprint") } }
		),
	}).toEqual({ true })

	local writes: number = #fixture.writes
	local action: InputAction = fixture.base.actions.AbilitySlot1
	Utils.apply({ profiles = { { kind = "Remove", actor = fixture.base.actor, sourceId = "Sword" } } })
	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Fireball", sourceId = "Base" })
	expect(#fixture.writes).toBe(writes)
	expect(fixture.base.actions.AbilitySlot1).toBe(action)
end)

it("targets a Q to E overlay while preserving the gamepad binding and unrelated live input", function()
	expect({ fixture.base.input.SetSource("Manual", Utils.manual()) }).toEqual({ true })
	expect({ fixture.base.input.SetContextEnabled("HandSigns", true) }).toEqual({ true })
	local gamepad: Instance? = fixture.base.actions.Sign:FindFirstChild("Gamepad")
	local other: InputAction = fixture.base.actions.Other
	ActionUtils.emit(fixture.base, "Pressed", "Sign")
	ActionUtils.emit(fixture.base, "Pressed", "Other")
	local events: number = #fixture.events

	Utils.apply({
		inputs = {
			{
				kind = "Set",
				sourceId = "Keybinds",
				definition = {
					priority = 100,
					bindingOverrides = { Sign = { Keyboard = { keyCode = Enum.KeyCode.E } } },
				},
			},
		},
	})

	expect(assert(fixture.base.input.GetEffectiveBindings("Sign")).Keyboard.definition.keyCode).toBe(Enum.KeyCode.E)
	expect(fixture.base.actions.Sign:FindFirstChild("Gamepad")).toBe(gamepad)
	expect(fixture.base.actions.Other).toBe(other)
	expect(#fixture.events).toBe(events + 1)
	expect(fixture.events[#fixture.events]).toMatchObject({ inputId = "Sign", kind = "Cancelled" })
	ActionUtils.emit(fixture.base, "Released", "Other")
	expect(fixture.events[#fixture.events]).toMatchObject({ inputId = "Other", kind = "Released" })
end)

it("does not re-resolve an unchanged dynamic route when the equipped concrete Action changes", function()
	local equipped: string = "Combat.Rasengan"
	local resolutions: number = 0

	local route: ActionTypes.ActionRoute = {
		when = ActionUtils.key(),
		target = {
			kind = "Dynamic",
			resolve = function(): ActionTypes.ResolvedAction
				resolutions += 1

				return { actionId = equipped }
			end,
		},
	}

	ActionUtils.set(fixture.base, { route })
	ActionUtils.emit(fixture.base, "Pressed")
	local original: number = ActionUtils.started(fixture.base)
	equipped = "Combat.Fireball"

	Utils.apply({
		profiles = { { kind = "Set", actor = fixture.base.actor, sourceId = "Base", profile = { routes = { route } } } },
	})

	expect(resolutions).toBe(1)
	ActionUtils.emit(fixture.base, "Released")

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Stop",
		actionId = "Combat.Rasengan",
		originalStartRequestId = original,
	})

	ActionUtils.tap(fixture.base)

	expect(ActionUtils.packets(fixture.base)[3]).toMatchObject({
		kind = "KRF.Action.Start",
		actionId = "Combat.Fireball",
	})

	expect(resolutions).toBe(2)
end)

for _, change: string in { "Equivalent", "Unrelated", "Actor" } do
	it("preserves only continuous recognition history for " .. change .. " changes", function()
		expect({
			fixture.base.input.SetSource(
				"Recognition",
				{ sequences = { Pair = { steps = { "X", "Q" }, maxGapSeconds = 1, maxTotalSeconds = 2 } } }
			),
		}).toEqual({ true })

		ActionUtils.set(
			fixture.base,
			{ ActionUtils.route("Combat.Fireball", { kind = "Sequence", sequenceId = "Pair" }) }
		)

		ActionUtils.set(
			fixture.base,
			{ ActionUtils.route("Combat.Fireball", { kind = "Sequence", sequenceId = "Pair" }) },
			fixture.base.other
		)

		ActionUtils.tap(fixture.base, "X")

		if change == "Actor" then
			Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
		elseif change == "Unrelated" then
			Utils.apply({ inputs = { { kind = "Set", sourceId = "Empty", definition = {} } } })
		else
			Utils.apply({ selection = { kind = "Set", actor = fixture.base.actor } })
		end

		ActionUtils.tap(fixture.base, "Q")
		expect(#ActionUtils.packets(fixture.base)).toBe(if change == "Actor" then 0 else 1)
	end)
end
