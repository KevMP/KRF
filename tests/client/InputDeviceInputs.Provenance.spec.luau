--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local Types = require(KRF.client.Input.types)
local Utils = require(script.Parent.Utils.InputTestUtils)

it("classifies keyboard, generic device loss, and directional gamepad provenance without polling", function()
	local fixture: Utils.Fixture = Utils.new()
	Utils.install(fixture)
	expect(fixture.owner.GetAffectedDeviceInputs(Enum.UserInputType.Keyboard)).toEqual({ "Primary" })
	expect(fixture.owner.GetAffectedDeviceInputs(Enum.UserInputType.MouseMovement)).toEqual({ "Primary" })

	local definition: Utils.CoreDefinition = Utils.definition(Enum.InputActionType.Direction2D)
	definition.inputs.Primary.bindings = { Gamepad = { keyCode = Enum.KeyCode.Thumbstick1 } }
	expect({ fixture.owner.SetSource("Core", definition) }).toEqual({ true })
	expect(fixture.owner.GetAffectedDeviceInputs(Enum.UserInputType.Gamepad1)).toEqual({ "Primary" })

	local dpad: Types.InputSourceDefinition = {
		inputs = {
			Pad = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				bindings = { Gamepad = { keyCode = Enum.KeyCode.DPadUp } },
			},
		},
	}

	expect({ fixture.owner.SetSource("DPad", dpad) }).toEqual({ true })
	expect(fixture.owner.GetAffectedDeviceInputs(Enum.UserInputType.Gamepad1)).toEqual({ "Pad", "Primary" })
	Utils.destroy(fixture)
end)
