--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local Types = require(KRF.client.Input.types)
local Ownership = require(KRF.client.Input.utils.InputNativeOwnership)
local Utils = require(script.Parent.Utils.InputTestUtils)

for _, scenario in
	{
		{ priority = 3000, sink = true, enabled = true, key = Enum.KeyCode.Q, blocked = true },
		{ priority = 3000, sink = false, enabled = true, key = Enum.KeyCode.Q, blocked = false },
		{ priority = 2000, sink = true, enabled = true, key = Enum.KeyCode.Q, blocked = false },
		{ priority = 1000, sink = true, enabled = true, key = Enum.KeyCode.Q, blocked = false },
		{ priority = 3000, sink = true, enabled = false, key = Enum.KeyCode.Q, blocked = false },
		{ priority = 3000, sink = true, enabled = true, key = Enum.KeyCode.E, blocked = false },
	}
do
	it(
		"compares physical reachability at priority "
			.. scenario.priority
			.. " with sink "
			.. tostring(scenario.sink)
			.. " enabled "
			.. tostring(scenario.enabled)
			.. " key "
			.. scenario.key.Name,
		function()
			local fixture: Utils.Fixture = Utils.new()
			Utils.install(fixture)
			Utils.enable(fixture)
			Utils.emit(fixture, "Pressed", true)

			expect({
				fixture.owner.SetSource("Menu", {
					contexts = { Menu = { priority = scenario.priority, sink = scenario.sink } },
					inputs = {
						Confirm = {
							context = "Menu",
							type = Enum.InputActionType.Bool,
							bindings = {
								Keyboard = { keyCode = scenario.key, primaryModifier = Enum.KeyCode.LeftShift },
							},
						},
					},
				}),
			}).toEqual({ true })

			expect({ fixture.owner.SetContextEnabled("Menu", scenario.enabled) }).toEqual({ true })
			local blocked: Ownership.Blocked = Ownership.Blocked(fixture.owner.GetGraphSnapshot())
			expect(blocked.Primary or {}).toEqual(if scenario.blocked then { [Enum.KeyCode.Q] = true } else {})
			expect(Utils.kinds(fixture)).toEqual(if scenario.blocked then { "Pressed", "Cancelled" } else { "Pressed" })
			Utils.destroy(fixture)
		end
	)
end

it(
	"indexes composite directions, shared UI buttons and viewport pointers without mixing independent drivers",
	function()
		local fixture: Utils.Fixture = Utils.new()
		local shared: TextButton = Instance.new("TextButton")
		local separate: TextButton = Instance.new("TextButton")

		local definition: Types.InputSourceDefinition = {
			contexts = { Low = { priority = 1, sink = false }, High = { priority = 2, sink = true } },
			inputs = {
				Move = {
					context = "Low",
					type = Enum.InputActionType.Direction3D,
					bindings = {
						Keys = {
							forward = Enum.KeyCode.W,
							backward = Enum.KeyCode.S,
							left = Enum.KeyCode.A,
							right = Enum.KeyCode.D,
						},
					},
				},
				Look = {
					context = "Low",
					type = Enum.InputActionType.ViewportPosition,
					bindings = { Pointer = { keyCode = Enum.KeyCode.MousePosition, pointerIndex = 0 } },
				},
				OtherLook = {
					context = "Low",
					type = Enum.InputActionType.ViewportPosition,
					bindings = { Pointer = { keyCode = Enum.KeyCode.MousePosition, pointerIndex = 1 } },
				},
				Touch = {
					context = "Low",
					type = Enum.InputActionType.Bool,
					bindings = { UI = { uiButton = shared } },
				},
				OtherTouch = {
					context = "Low",
					type = Enum.InputActionType.Bool,
					bindings = { UI = { uiButton = separate } },
				},
				MenuMove = {
					context = "High",
					type = Enum.InputActionType.Direction1D,
					bindings = { Keys = { up = Enum.KeyCode.W, down = Enum.KeyCode.S } },
				},
				MenuLook = {
					context = "High",
					type = Enum.InputActionType.ViewportPosition,
					bindings = { Pointer = { keyCode = Enum.KeyCode.MousePosition } },
				},
				MenuTouch = {
					context = "High",
					type = Enum.InputActionType.Bool,
					bindings = { UI = { uiButton = shared } },
				},
			},
		}

		Utils.install(fixture, definition)
		expect({ fixture.owner.SetContextEnabled("Low", true) }).toEqual({ true })
		expect({ fixture.owner.SetContextEnabled("High", true) }).toEqual({ true })
		local blocked: Ownership.Blocked = Ownership.Blocked(fixture.owner.GetGraphSnapshot())
		expect(blocked.Move).toEqual({ [Enum.KeyCode.W] = true, [Enum.KeyCode.S] = true })
		expect(blocked.Look).toEqual({ ["MousePosition:0"] = true })
		expect(blocked.OtherLook).toBeNil()
		expect(blocked.Touch).toEqual({ [shared] = true })
		expect(blocked.OtherTouch).toBeNil()
		Utils.destroy(fixture)
		shared:Destroy()
		separate:Destroy()
	end
)
