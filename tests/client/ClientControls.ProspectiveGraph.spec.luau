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
local ActorTypes = require(KRF.client.Actor.types)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("installs new context, input, gesture, sequence and routes as one prospective graph", function()
	Utils.install(fixture)
	expect(fixture.base.input.GetContext("HandSigns")).toMatchObject({ sourceId = "Manual", enabled = true })
	expect(fixture.base.input.GetInput("Sign")).toMatchObject({ sourceId = "Manual", contextId = "HandSigns" })
	expect(fixture.base.input.GetSequence("Combo")).toMatchObject({ sourceId = "Manual" })

	expect(Runtime.GetEffectiveRoute(fixture.base.actor, { kind = "Sequence", sequenceId = "Combo" })).toMatchObject({
		status = "Mapped",
	})

	ActionUtils.tap(fixture.base, "X")
	ActionUtils.tap(fixture.base, "Sign")
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	expect(ActionUtils.packets(fixture.base)[1].actionId).toBe("Combat.Fireball")
end)

it("allows joint profile and defining-source removal where standalone input removal rejects", function()
	Utils.install(fixture)
	expect({ fixture.base.input.RemoveSource("Manual") }).toEqual({ false, "ProfileDependencyMissing" })

	Utils.apply({
		inputs = { { kind = "Remove", sourceId = "Manual" } },
		profiles = { { kind = "Remove", actor = fixture.base.actor, sourceId = "Manual" } },
	})

	expect(fixture.base.input.GetInput("Sign")).toBeNil()
	expect(fixture.base.input.GetContext("HandSigns")).toBeNil()
	expect(Runtime.GetProfileSources(fixture.base.actor)).toEqual({})
end)

for _, location: string in { "Selected", "Noncontrolled", "Shadowed", "Gated" } do
	for _, dependency: string in { "Input", "Gesture", "Sequence", "Custom", "Context" } do
		it("checks " .. dependency .. " dependencies in " .. location .. " profiles before writes", function()
			local manual: InputTypes.InputSourceDefinition = Utils.manual()

			local definition: InputTypes.InputSourceDefinition = {
				contexts = manual.contexts,
				inputs = manual.inputs,
				gestures = manual.gestures,
				sequences = manual.sequences,
				recognizers = {
					Motion = {
						inputs = { "Sign" },
						maxWindowSeconds = 1,
						onEvent = function(): InputTypes.CustomMatch?
							return nil
						end,
					},
				},
			}

			expect({ fixture.base.input.SetSource("Manual", definition) }).toEqual({ true })

			local key: ActionTypes.RouteKey = if dependency == "Sequence"
				then { kind = "Sequence", sequenceId = "Combo" }
				elseif dependency == "Custom" then { kind = "Custom", recognizerId = "Motion" }
				elseif dependency == "Gesture" then ActionUtils.key("Sign", "Held")
				elseif dependency == "Context" then ActionUtils.key()
				else ActionUtils.key("Sign")

			local actor: ActorTypes.ActorView = if location == "Noncontrolled"
				then fixture.base.other
				else fixture.base.actor

			local route: ActionTypes.ActionRoute = ActionUtils.route("Combat.Fireball", key)

			if dependency == "Context" then
				route.requiredContexts = { "HandSigns" }
			end

			if location == "Gated" then
				route.requiredContexts = if dependency == "Context" then { "HandSigns", "Gate" } else { "Gate" }
			end

			expect({ Runtime.SetProfileSource(actor, "Dependent", { routes = { route } }) }).toEqual({ true })

			if location == "Shadowed" then
				expect({
					Runtime.SetProfileSource(
						actor,
						"Winner",
						{ priority = 10, routes = { ActionUtils.route("Movement.Sprint", key) } }
					),
				}).toEqual({ true })
			elseif location == "Gated" then
				expect({ fixture.base.input.SetContextEnabled("Gate", false) }).toEqual({ true })
			end

			local graph = fixture.base.input.GetGraphSnapshot()
			local writes: number = #fixture.writes

			expect({ Controls.Apply({ inputs = { { kind = "Remove", sourceId = "Manual" } } }) }).toEqual({
				false,
				"ProfileDependencyMissing",
			})

			expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
			expect(#fixture.writes).toBe(writes)

			-- Every referencing route is withdrawn, including a shadowed winner.
			local profiles: { Types.ProfileSourceChange } =
				{ { kind = "Remove", actor = actor, sourceId = "Dependent" } }

			if location == "Shadowed" then
				table.insert(
					profiles,
					{ kind = "Remove", actor = actor, sourceId = "Winner" } :: Types.ProfileSourceChange
				)
			end

			Utils.apply({ inputs = { { kind = "Remove", sourceId = "Manual" } }, profiles = profiles })
			expect(fixture.base.input.GetInput("Sign")).toBeNil()
		end)
	end
end

for _, reverse: boolean in { false, true } do
	it("compiles cross-source dependencies from the final graph in array order " .. tostring(reverse), function()
		local definition: InputTypes.InputSourceDefinition = Utils.manual()
		local sequence: InputTypes.InputSourceDefinition = { sequences = definition.sequences }

		local primitives: InputTypes.InputSourceDefinition =
			{ contexts = definition.contexts, inputs = definition.inputs, gestures = definition.gestures }

		local inputs: { Types.InputSourceChange } = {
			{ kind = "Set", sourceId = "Recognition", definition = sequence },
			{ kind = "Set", sourceId = "Manual", definition = primitives },
		}

		if reverse then
			inputs[1], inputs[2] = inputs[2], inputs[1]
		end

		Utils.apply({
			inputs = inputs,
			contexts = { { contextId = "HandSigns", enabled = true } },
			profiles = {
				{
					kind = "Set",
					actor = fixture.base.other,
					sourceId = "Manual",
					profile = {
						routes = { ActionUtils.route("Combat.Fireball", { kind = "Sequence", sequenceId = "Combo" }) },
					},
				},
			},
			selection = { kind = "Set", actor = fixture.base.other },
		})

		expect(fixture.base.input.GetSequence("Combo")).toMatchObject({ sourceId = "Recognition" })
		expect(Runtime.GetControlledActor()).toBe(fixture.base.other)

		expect(Runtime.GetEffectiveRoute(fixture.base.other, { kind = "Sequence", sequenceId = "Combo" })).toMatchObject({
			actionId = "Combat.Fireball",
		})

		Utils.apply({
			inputs = { { kind = "Remove", sourceId = "Manual" }, { kind = "Remove", sourceId = "Recognition" } },
			profiles = { { kind = "Remove", actor = fixture.base.other, sourceId = "Manual" } },
		})
	end)
end

for _, case in
	{
		{ name = "canonical input collision", reason = "DuplicateInputOwner" },
		{ name = "canonical context collision", reason = "DuplicateContextOwner" },
		{ name = "equal overlay priority", reason = "BindingOverrideConflict" },
		{ name = "equal profile priority", reason = "ProfilePriorityConflict" },
	}
do
	it("rejects " .. case.name .. " for the whole batch before native work", function()
		local changes: Types.ControlChangeSet =
			{ inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } } }

		if case.reason == "DuplicateInputOwner" then
			table.insert(
				assert(changes.inputs, "Expected input operations"),
				{
					kind = "Set",
					sourceId = "Collision",
					definition = {
						inputs = {
							Sign = { context = "HandSigns", type = Enum.InputActionType.Bool, bindings = {} },
						},
					},
				} :: Types.InputSourceChange
			)
		elseif case.reason == "DuplicateContextOwner" then
			table.insert(
				assert(changes.inputs, "Expected input operations"),
				{
					kind = "Set",
					sourceId = "Collision",
					definition = {
						contexts = { HandSigns = { priority = 1, sink = false } },
					},
				} :: Types.InputSourceChange
			)
		elseif case.reason == "BindingOverrideConflict" then
			for _, sourceId: string in { "First", "Second" } do
				table.insert(
					assert(changes.inputs, "Expected input operations"),
					{
						kind = "Set",
						sourceId = sourceId,
						definition = {
							priority = 10,
							bindingOverrides = { Sign = { Keyboard = { keyCode = Enum.KeyCode.E } } },
						},
					} :: Types.InputSourceChange
				)
			end
		else
			changes.profiles = {}

			for _, sourceId: string in { "First", "Second" } do
				table.insert(
					assert(changes.profiles, "Expected profile operations"),
					{
						kind = "Set",
						actor = fixture.base.actor,
						sourceId = sourceId,
						profile = { routes = { ActionUtils.route("Combat.Fireball") } },
					} :: Types.ProfileSourceChange
				)
			end
		end

		local writes: number = #fixture.writes
		expect({ Controls.Apply(changes) }).toEqual({ false, case.reason })
		expect(#fixture.writes).toBe(writes)
		expect(fixture.base.input.GetInput("Sign")).toBeNil()
		expect(Runtime.GetProfileSources(fixture.base.actor)).toEqual({})
	end)
end

it("rejects enabling a missing or deleted final context without applying other changes", function()
	local proposals: { Types.ControlChangeSet } = {
		{ contexts = { { contextId = "Missing", enabled = true } } },
		{
			inputs = { { kind = "Remove", sourceId = "Core" } },
			contexts = { { contextId = "Combat", enabled = true } },
		},
	}

	for _, changes in proposals do
		local writes: number = #fixture.writes
		expect({ Controls.Apply(changes) }).toEqual({ false, "UnknownContext" })
		expect(#fixture.writes).toBe(writes)
		expect(fixture.base.input.GetContext("Combat")).toMatchObject({ enabled = true })
	end
end)

it("rejects forged ActorViews for profiles and selection by registry identity", function()
	local forged: ActorTypes.ActorView = (
		table.freeze({
			GetId = function(): string
				return fixture.base.actor:GetId()
			end,
		}) :: unknown
	) :: ActorTypes.ActorView

	local proposals: { Types.ControlChangeSet } = {
		{ selection = { kind = "Set", actor = forged } },
		{ profiles = { { kind = "Set", actor = forged, sourceId = "Base", profile = { routes = {} } } } },
	}

	for _, changes in proposals do
		local writes: number = #fixture.writes
		expect({ Controls.Apply(changes) }).toEqual({ false, "ActorViewUnavailable" })
		expect(#fixture.writes).toBe(writes)
		expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
	end
end)
