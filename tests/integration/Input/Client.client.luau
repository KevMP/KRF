--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Client = require(KRF.client)
local Types = require(KRF.client.Input.types)
local Input: Types.InputRuntime = require(KRF.client.Input.InputRuntime)
local Controls = require(ReplicatedStorage.InputControls)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("InputTestControl") :: RemoteEvent
local player: Player = Players.LocalPlayer

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 5

	while not predicate() do
		assert(os.clock() < deadline, reason)
		RunService.Heartbeat:Wait()
	end
end

local function scriptable(action: InputAction): InputBinding
	local binding: InputBinding = Instance.new("InputBinding")
	binding.Name = "StudioDriver"
	binding.Type = Enum.InputBindingType.Scriptable
	binding.Parent = action

	return binding
end

local function binding(action: InputAction, slot: string): InputBinding
	return assert(action:FindFirstChild(slot), "Expected initialized input state") :: InputBinding
end

local function run(): ()
	local initialized: boolean, failure = Client.Init()
	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")

	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Parent = player:WaitForChild("PlayerGui")

	local button: TextButton = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(160, 60)
	button.Text = "Primary"
	button.Parent = gui

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Size = UDim2.fromOffset(160, 60)
	label.Position = UDim2.fromOffset(0, 70)
	label.Parent = gui
	Controls.Install(button, label)

	local container: Folder =
		assert(player.PlayerScripts:FindFirstChild("KRFInputs"), "Expected initialized input state") :: Folder

	local context: InputContext =
		assert(container:FindFirstChild("Gameplay"), "Expected initialized input state") :: InputContext

	local action: InputAction =
		assert(context:FindFirstChild("Primary"), "Expected initialized input state") :: InputAction

	assert(context:IsDescendantOf(player), "ManagedContextOutsidePlayer")
	assert(not assert(context.Parent, "Expected initialized input state"):IsA("InputContext"), "NestedManagedContext")
	assert(context.Enabled and context.Priority == 2000 and context.Sink, "NativeContextConfiguration")

	assert(
		binding(action, "Touch").UIButton == button and binding(action, "Gamepad").KeyCode == Enum.KeyCode.ButtonR2,
		"MultiDeviceBindings"
	)

	assert(label.InputAction == action, "NativeLabelAssociation")
	local gamepad: InputBinding = binding(action, "Gamepad")
	Controls.Remap()

	assert(
		binding(action, "Keyboard").KeyCode == Enum.KeyCode.E and binding(action, "Gamepad") == gamepad,
		"RemapChangedOtherDevice"
	)

	Controls.Restore()
	assert(binding(action, "Keyboard").KeyCode == Enum.KeyCode.Q, "RemapDidNotRestore")

	local events: { Types.SemanticInputEvent } = {}

	local connection = Input.OnInput:Connect(function(event: Types.SemanticInputEvent)
		table.insert(events, event)
	end)

	local driver: InputBinding = scriptable(action)
	driver:Fire(true)

	waitFor(function(): boolean
		return #events >= 1
	end, "NativeBoolPressMissing")

	assert(events[1].kind == "Pressed", "NativeBoolPressDuplicated")
	driver:Fire(false)

	waitFor(function(): boolean
		return #events >= 2
	end, "NativeBoolReleaseMissing")

	assert(#events == 2 and events[2].kind == "Released", "BoolStateChangedNotDeduplicated")
	driver:Fire(true)

	waitFor(function(): boolean
		return #events >= 3
	end, "SecondNativePressMissing")

	assert(Input.SetContextEnabled("Gameplay", false), "Context enablement failed")

	waitFor(function(): boolean
		return #events >= 4
	end, "NativeDisableCancellationMissing")

	assert(events[4].kind == "Cancelled" and #events == 4, "DisableGeneratedGameplayRelease")
	assert(Input.SetContextEnabled("Gameplay", true), "Context enablement failed")
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	assert(#events == 4, "HeldNativeInputGeneratedPhantomPress")
	driver:Fire(false)
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	assert(#events == 4, "NeutralRearmGeneratedGameplayRelease")
	driver:Fire(true)

	waitFor(function(): boolean
		return #events >= 5
	end, "NativeNeutralDidNotRearm")

	assert(events[5].kind == "Pressed", "NativeRearmGeneratedWrongEvent")
	driver:Fire(false)

	waitFor(function(): boolean
		return #events >= 6
	end, "NativeRearmReleaseMissing")

	driver:Fire(true)

	waitFor(function(): boolean
		return #events >= 7
	end, "NativePressBeforeUnobservedReleaseMissing")

	assert(Input.SetContextEnabled("Gameplay", false), "Context disable failed")

	waitFor(function(): boolean
		return #events >= 8
	end, "NativeUnobservedReleaseCancellationMissing")

	assert(events[8].kind == "Cancelled", "NativeDisableDidNotCancel")
	driver:Fire(false)
	assert(Input.SetContextEnabled("Gameplay", true), "Context enablement failed")
	assert(action:GetState() == false, "NativeInputDidNotConfirmNeutral")
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	assert(#events == 8, "NeutralSampleGeneratedGameplayInput")
	driver:Fire(true)

	waitFor(function(): boolean
		return #events >= 9
	end, "FirstNativePressAfterConfirmedNeutralMissing")

	assert(events[9].kind == "Pressed", "FirstFreshNativePressWasNotAccepted")
	driver:Fire(false)

	waitFor(function(): boolean
		return #events >= 10
	end, "FirstFreshNativeReleaseMissing")

	assert(#events == 10 and events[10].kind == "Released", "FreshNativeReleaseDuplicated")

	connection:Disconnect()

	for _, case in
		{
			{ inputType = Enum.InputActionType.Direction1D, value = 0.75 },
			{ inputType = Enum.InputActionType.Direction2D, value = Vector2.new(0.25, 0.5) },
			{ inputType = Enum.InputActionType.Direction3D, value = Vector3.new(0.25, 0.5, 0.75) },
			{ inputType = Enum.InputActionType.ViewportPosition, value = Vector2.new(100, 50) },
		}
	do
		assert(
			Input.SetSource(
				"Studio.Value",
				{ inputs = {
					Value = { context = "Gameplay", type = case.inputType, bindings = {} },
				} }
			),
			"Input source installation failed"
		)

		local valueAction: InputAction =
			assert(context:FindFirstChild("Value"), "Expected initialized input state") :: InputAction

		local valueDriver: InputBinding = scriptable(valueAction)
		local received: Types.SemanticInputEvent? = nil

		local listener = Input.OnInput:Connect(function(event: Types.SemanticInputEvent)
			if event.inputId == "Value" then
				received = event
			end
		end)

		valueDriver:Fire(case.value)

		waitFor(function(): boolean
			return received ~= nil
		end, "NativeTypedValueMissing")

		assert(received ~= nil, "Expected initialized input state")
		assert(received.kind == "StateChanged" and received.value == case.value, "NativeTypedValueMismatch")
		listener:Disconnect()
		assert(Input.RemoveSource("Studio.Value"), "Input source removal failed")
	end

	Controls.Remove()
	assert(label.InputAction == nil and button.Parent == gui, "ConsumerUIOwnershipViolation")
	assert(#container:GetDescendants() == 0, "NativeInputLeakAfterRemoval")
	Client._ResetForTests()
	assert(player.PlayerScripts:FindFirstChild("KRFInputs") == nil, "NativeInputContainerLeak")
	gui:Destroy()
end

local success: boolean, reason: any = pcall(run)
control:FireServer(success, if success then nil else tostring(reason))
