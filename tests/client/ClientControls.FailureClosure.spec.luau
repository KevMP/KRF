--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local InputTypes = require(KRF.client.Input.types)
local ActionTypes = require(KRF.client.Action.types)
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Controls.utils.ControlRuntimeState)
local Native = require(KRF.client.Controls.utils.NativeControlLifecycle)
local ActionState = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Installation = require(KRF.client.Controls.utils.ControlInstallation)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local fixture: Utils.Fixture
local originalObserve = Native.Observe

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Native.Observe = originalObserve
	Utils.destroy(fixture)
end)

it("rejects a destroyed coordinator and makes repeated cleanup a no-op", function()
	local owner: Types.ControlOwner = assert(State.Get(), "Expected controls owner")
	owner.Destroy()
	owner.Destroy()
	expect({ owner.Apply({}) }).toEqual({ false, "ClientNotReady" })
	owner.OnLifecycle({ kind = "FocusLost" })
	expect(ActionUtils.packets(fixture.base)).toEqual({})
end)

it("returns the input owner's preparation fence denial without changing selection", function()
	fixture.base.input.BeginControlChange = function(): (boolean, string?)
		return false, "DispatchInProgress"
	end

	expect({ Controls.Apply({ selection = { kind = "Set" } }) }).toEqual({ false, "DispatchInProgress" })
	expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
end)

for _, phase: string in { "Compiler", "FollowUpDrain", "SafetyPrepare", "SafetyCommit", "IdleQueue" } do
	it("fails closed without retaining native input or Action routing when " .. phase .. " fails", function()
		Utils.charge(fixture)

		if phase == "Compiler" then
			fixture.base.input.CompileUpdate = function(): (InputTypes.InputGraphSnapshot?, string?)
				error("UnexpectedCompilerFault", 0)
			end
		elseif phase == "FollowUpDrain" then
			fixture.base.input.DrainControlFollowUps = function(): ()
				error("MandatoryDrainFault", 0)
			end
		elseif phase == "SafetyPrepare" then
			fixture.base.input.PrepareEpochInvalidation = function(): (InputTypes.PreparedInputInvalidation?, string?)
				return nil, "InputPlanLimitExceeded"
			end
		elseif phase == "SafetyCommit" then
			fixture.base.input.CommitEpochInvalidation = function(): (
				boolean,
				string?,
				InputTypes.InputCommitFailurePhase?
			)
				return false, "NativeCommitFailed", "Failed"
			end
		else
			fixture.base.input.WhenIdle = function(): (boolean, string?)
				return false, "InputMutationQueueLimitExceeded"
			end
		end

		if phase == "Compiler" or phase == "FollowUpDrain" then
			expect({ Controls.Apply({}) }).toEqual({ false, "InputRuntimeFaulted" })
		else
			Utils.loss(fixture, { kind = "FocusLost" })
		end

		expect(Runtime.GetControlledActor()).toBeNil()
		expect(fixture.base.input.GetInput("AbilitySlot1")).toBeNil()
		expect(fixture.base.callbacks).toEqual({})
		expect(fixture.connections).toBe(0)
		expect(fixture.stopCalls).toBe(0)
	end)
end

for _, phase: string in { "NativeSubscription", "CommitSubscription" } do
	it("releases a partial coordinator installation when " .. phase .. " fails", function()
		local before: number = fixture.connections
		local old: Types.ControlOwner? = State.Get()

		if phase == "NativeSubscription" then
			Native.Observe = function(): () -> ()
				error("NativeSubscriptionFailed", 0)
			end
		else
			fixture.base.input.ObserveConfigurationCommit = function(): () -> ()
				error("CommitSubscriptionFailed", 0)
			end
		end

		local installed: boolean, reason: unknown = pcall(Installation.Install, function(): boolean
			return true
		end)

		expect(installed).toBe(false)

		expect(reason).toBe(
			if phase == "NativeSubscription" then "NativeSubscriptionFailed" else "CommitSubscriptionFailed"
		)

		expect(fixture.connections).toBe(before)
		expect(State.Get()).toBe(old)
	end)
end

it("does not resurrect a candidate graph when client teardown occurs inside a native write", function()
	fixture.onWrite = function(): ()
		fixture.onWrite = nil
		Client._ResetForTests()
	end

	local accepted: boolean =
		Controls.Apply({ inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } } })

	expect(accepted).toBe(false)
	expect(Runtime.GetControlledActor()).toBeNil()
	expect(#fixture.base.container:GetDescendants()).toBe(0)
	expect(fixture.base.callbacks).toEqual({})
	expect(fixture.connections).toBe(0)
end)

it("rejects the generation retired immediately after Actor-switch preparation", function()
	local actions: ActionTypes.ClientActionOwner = assert(ActionState.Get(), "Expected Action owner")
	local prepare = actions.PrepareControlledActor

	actions.PrepareControlledActor = function(target, coordinated): (ActionTypes.PreparedActorSwitch?, string?)
		local plan: ActionTypes.PreparedActorSwitch?, reason: string? = prepare(target, coordinated)
		Client._ResetForTests()

		return plan, reason
	end

	expect({ Controls.Apply({ selection = { kind = "Set", actor = fixture.base.other } }) }).toEqual({
		false,
		"ClientNotReady",
	})

	expect(fixture.base.callbacks).toEqual({})
	expect(fixture.connections).toBe(0)
end)
