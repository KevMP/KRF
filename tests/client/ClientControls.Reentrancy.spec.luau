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
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local ActionState = require(KRF.client.Action.utils.ClientActionRuntimeState)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, phase: string in { "Validator", "NativeWrite", "Configuration", "Route", "Retirement", "FollowUp" } do
	it("rejects reentrant Apply and I4 mutations at " .. phase .. " without a success queue", function()
		Utils.charge(fixture)
		local calls: number = 0

		local function nested(): ()
			calls += 1
			expect({ fixture.base.input.SetSource("Nested", {}) }).toEqual({ false, "DispatchInProgress" })
			expect({ fixture.base.input.RemoveSource("Core") }).toEqual({ false, "DispatchInProgress" })
			expect({ fixture.base.input.SetContextEnabled("Gate", true) }).toEqual({ false, "DispatchInProgress" })

			expect({
				Controls.Apply({ inputs = { { kind = "Set", sourceId = "Nested", definition = Utils.manual() } } }),
			}).toEqual({ false, "DispatchInProgress" })

			expect({ Runtime.SetProfileSource(fixture.base.actor, "Nested", { routes = {} }) }).toEqual({
				false,
				"DispatchInProgress",
			})

			expect({ Runtime.SetControlledActor(fixture.base.actor) }).toEqual({ false, "DispatchInProgress" })
			expect({ Runtime.RemoveProfileSource(fixture.base.actor, "Base") }).toEqual({ false, "DispatchInProgress" })
		end

		local stop: (() -> ())? = nil

		if phase == "Validator" then
			stop = fixture.base.input.RegisterGraphValidator(function(): (boolean, string?)
				nested()

				return true, nil
			end)
		elseif phase == "NativeWrite" then
			fixture.onWrite = function(): ()
				nested()
			end
		elseif phase == "Configuration" then
			stop = fixture.base.input.ObserveConfigurationCommit(function(): ()
				nested()
			end)
		elseif phase == "Route" then
			stop = assert(ActionState.Get()).ObserveRoutes(function(): ()
				nested()
			end)
		elseif phase == "Retirement" then
			stop = assert(ActionState.GetInput()).ObserveDecisions(function(): ()
				nested()
			end)
		else
			fixture.base.commands.beforeSend = function(): ()
				nested()
			end
		end

		Utils.apply({
			selection = { kind = "Set", actor = fixture.base.other },
			contexts = { { contextId = "Gate", enabled = false } },
		})

		fixture.onWrite = nil
		fixture.base.commands.beforeSend = nil

		if stop ~= nil then
			(stop :: () -> ())()
		end

		expect(calls > 0).toBe(true)
		task.wait()
		expect(fixture.base.input.GetInput("Sign")).toBeNil()

		expect(Runtime.GetProfileSources(fixture.base.actor)).toEqual({
			{ sourceId = "Base", priority = 0, routeCount = 1 },
		})

		expect(Runtime.GetControlledActor()).toBe(fixture.base.other)
		Utils.apply({})
		expect(fixture.base.input.GetInput("Sign")).toBeNil()
	end)
end

it("rejects Apply from an I4 dynamic resolver and invokes no resolver during preflight", function()
	local resolutions: number = 0

	local route: ActionTypes.ActionRoute = {
		when = ActionUtils.key(),
		target = {
			kind = "Dynamic",
			resolve = function(): ActionTypes.ResolvedAction
				resolutions += 1
				expect({ Controls.Apply({ selection = { kind = "Set" } }) }).toEqual({ false, "DispatchInProgress" })

				return { actionId = "Combat.Fireball" }
			end,
		},
	}

	Utils.apply({
		profiles = { { kind = "Set", actor = fixture.base.actor, sourceId = "Base", profile = { routes = { route } } } },
	})

	expect(resolutions).toBe(0)
	ActionUtils.tap(fixture.base)
	expect(resolutions).toBe(1)
	expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
end)

it("lets a public observer explicitly mutate after ordered cleanup against a coherent graph", function()
	local applied: boolean = false

	local connection = Input.OnInput:Connect(function(event): ()
		if event.kind == "Cancelled" then
			expect(Runtime.GetControlledActor()).toBe(fixture.base.other)
			expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Interrupt" })
			Utils.apply({ inputs = { { kind = "Set", sourceId = "Observed", definition = {} } } })
			applied = true
		end
	end)

	Utils.charge(fixture)
	Utils.apply({ selection = { kind = "Set", actor = fixture.base.other } })
	task.wait()
	expect(applied).toBe(true)
	connection:Disconnect()
end)

it("leaves ordinary one-call sword equip and keybind updates available without Apply", function()
	local action: InputAction = fixture.base.actions.AbilitySlot1
	local writes: number = #fixture.writes

	expect({
		Runtime.SetProfileSource(fixture.base.actor, "Sword", { routes = { ActionUtils.route("Combat.Fireball") } }),
	}).toEqual({ true })

	expect(#fixture.writes).toBe(writes)
	expect(fixture.base.actions.AbilitySlot1).toBe(action)
	ActionUtils.tap(fixture.base)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	expect({ Runtime.RemoveProfileSource(fixture.base.actor, "Sword") }).toEqual({ true })
end)
