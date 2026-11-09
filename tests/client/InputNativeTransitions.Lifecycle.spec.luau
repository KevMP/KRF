--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local Epochs = require(KRF.client.Input.utils.InputEpochs)
local Gate = require(KRF.client.Input.utils.InputMutationGate)
local NativeTransitions = require(KRF.client.Input.utils.InputNativeTransitions)
local Utils = require(script.Parent.Utils.InputTestUtils)

it("ignores unknown and retired inputs and never replays a release into a replacement epoch", function()
	local fixture: Utils.Fixture = Utils.new()
	Utils.install(fixture)
	Utils.enable(fixture)
	local ready: boolean = false

	local gate: Gate.Owner = Gate.new(function(): boolean
		return ready
	end, function() end)

	local state: Epochs.State = Epochs.new(assert(fixture.owner.GetInput("Primary"), "Expected input"), 1)
	local delivered: { string } = {}

	local transitions: NativeTransitions.Owner = NativeTransitions.new({
		Graph = fixture.owner.GetGraphSnapshot,
		ReadState = function(id: string): unknown
			return fixture.states[fixture.actions[id]]
		end,
		Available = function(): boolean
			return true
		end,
		State = function(id: string): Epochs.State?
			return if id == "Primary" then state else nil
		end,
		NextEpoch = function(): number
			return 1
		end,
		Deliver = function(_input, transition): ()
			table.insert(delivered, transition.kind)
		end,
	}, gate)

	transitions.Receive("Primary", "Pressed", true)
	ready = true
	transitions.Receive("Missing", "Pressed", true)
	expect(delivered).toEqual({})
	transitions.Receive("Primary", "Pressed", true)
	expect(delivered).toEqual({ "Pressed" })
	expect({ gate.BeginCoordination() }).toEqual({ true })
	transitions.Receive("Primary", "Released", false)
	state = Epochs.new(state.input, 2, true)
	transitions.Drain()
	expect(delivered).toEqual({ "Pressed" })
	gate.EndCoordination()
	transitions.Clear()
	gate.Fault()
	transitions.Drain()
	Utils.destroy(fixture)
end)

for _, scenario: string in
	{
		"Complete",
		"Held",
		"PressedAgain",
		"ReadFailure",
		"NotNeutral",
		"Unavailable",
		"Retired",
		"Replaced",
		"Removed",
		"Disabled",
		"FaultDuringRead",
		"SafetyDuringRead",
		"AlreadyDisarmed",
	}
do
	it("reconciles a suppressed idle Bool tap only with trustworthy continuous neutral: " .. scenario, function()
		local fixture: Utils.Fixture = Utils.new()
		Utils.install(fixture)
		Utils.enable(fixture)

		local gate: Gate.Owner = Gate.new(function(): boolean
			return true
		end, function() end)

		local original: Epochs.State = Epochs.new(assert(fixture.owner.GetInput("Primary"), "Expected input"), 1)
		local state: Epochs.State? = original
		local available: boolean = true
		local delivered: { string } = {}

		if scenario == "AlreadyDisarmed" then
			original.disarmed = true
		end

		local transitions: NativeTransitions.Owner = NativeTransitions.new({
			Graph = fixture.owner.GetGraphSnapshot,
			Available = function(): boolean
				return available
			end,
			State = function(): Epochs.State?
				return state
			end,
			NextEpoch = function(): number
				return 1
			end,
			Deliver = function(_input, transition): ()
				table.insert(delivered, transition.kind)
			end,
			ReadState = function(): unknown
				if scenario == "ReadFailure" then
					error("UnreadableInput", 0)
				end

				if scenario == "FaultDuringRead" then
					gate.Fault()
				end

				if scenario == "SafetyDuringRead" then
					gate.SetSafetyPending(true)
				end

				return if scenario == "NotNeutral" then true else false
			end,
		}, gate)

		expect({ gate.BeginCoordination() }).toEqual({ true })
		transitions.Receive("Primary", "Pressed", true)

		if scenario ~= "Held" then
			transitions.Receive("Primary", "Released", false)
		end

		if scenario == "PressedAgain" then
			transitions.Receive("Primary", "Pressed", true)
		elseif scenario == "Unavailable" then
			available = false
		elseif scenario == "Retired" then
			Epochs.Cancel(original, "ActorChanged", 2)
		elseif scenario == "Replaced" then
			state = Epochs.new(original.input, 2, true)
		elseif scenario == "Removed" then
			state = nil
		elseif scenario == "Disabled" then
			expect({ fixture.owner.SetContextEnabled("Gameplay", false) }).toEqual({ true })
		end

		transitions.Drain()
		expect(original.disarmed).toBe(scenario ~= "Complete")
		expect(delivered).toEqual({})
		gate.EndCoordination()
		transitions.Clear()
		Utils.destroy(fixture)
	end)
end
