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
