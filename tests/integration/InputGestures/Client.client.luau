--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Client = require(KRF.client)
local Types = require(KRF.client.Input.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Input: Types.InputRuntime = require(KRF.client.Input.InputRuntime)
local Controls = require(ReplicatedStorage.InputControls)
local Gestures = require(ReplicatedStorage.InputGestures)
local State = require(KRF.client.Input.utils.InputRuntimeState)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("InputTestControl") :: RemoteEvent

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 5

	while not predicate() do
		assert(os.clock() < deadline, reason)
		RunService.Heartbeat:Wait()
	end
end

local function run(): ()
	local initialized: boolean, failure = Client.Init()
	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")

	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local button: TextButton = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(160, 60)
	button.Text = "Tap / hold / double tap"
	button.Parent = gui

	local label: InputActionLabel = Instance.new("InputActionLabel")
	label.Parent = gui
	Controls.Install(button, label)

	local container: Instance =
		assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs"), "MissingManagedInputs")

	local context: InputContext = assert(container:FindFirstChild("Gameplay"), "MissingGameplayContext") :: InputContext
	local action: InputAction = assert(context:FindFirstChild("Primary"), "MissingPrimaryAction") :: InputAction

	-- Private engine driver; ordinary consumers use keyboard/mouse/gamepad/UIButton.
	local driver: InputBinding = Instance.new("InputBinding")
	driver.Type = Enum.InputBindingType.Scriptable
	driver.Parent = action

	local events: { Types.GestureEvent } = {}
	local primitives: { Types.SemanticInputEvent } = {}

	local gestureConnection: SignalTypes.Connection = Input.OnGesture:Connect(function(event: Types.GestureEvent)
		table.insert(events, event)
	end)

	local primitiveConnection: SignalTypes.Connection = Input.OnInput:Connect(function(event: Types.SemanticInputEvent)
		table.insert(primitives, event)
	end)

	Gestures.Install("PreferSpecific")
	driver:Fire(true)
	driver:Fire(false)

	waitFor(function(): boolean
		return #events == 1
	end, "ImmediateTapMissing")

	assert(events[1].gesture == "Tap", "ImmediateTapWrongKind")
	local owner: Types.InputOwner = assert(State.Get(), "MissingInputOwner")
	assert(owner.ResetRecognition(nil, "FixtureReset"), "RecognitionResetFailed")
	table.clear(events)
	Gestures.Install("DeferredTap")
	driver:Fire(true)
	driver:Fire(false)
	assert(#events == 0, "DeferredTapWasImmediate")

	waitFor(function(): boolean
		return #events == 1
	end, "DeferredTapNeverExpired")

	local deferred: Types.GestureEvent = events[1]
	assert(deferred.gesture == "Tap", "DeferredTapWrongKind")
	assert(deferred.timestamp > deferred.recognizedAt + 0.5, "DeferredTapExpiredAtInclusiveBoundary")
	table.clear(events)
	driver:Fire(true)
	driver:Fire(false)
	driver:Fire(true)

	waitFor(function(): boolean
		return #events == 1
	end, "NativeDoubleTapMissing")

	assert(events[1].gesture == "DoubleTapped", "NativeDoubleTapWrongKind")
	driver:Fire(false)
	assert(#events == 1, "PairedSecondTapNotSuppressed")

	assert(owner.ResetRecognition(nil, "FixtureReset"), "RecognitionResetFailed")
	table.clear(events)
	Gestures.Install("PreferSpecific")
	driver:Fire(true)

	waitFor(function(): boolean
		return #events >= 2
	end, "NativeHoldTimersMissing")

	assert(events[1].gesture == "Held" and events[2].gesture == "LongHeld", "NativeHoldOrder")
	assert(Input.SetContextEnabled("Gameplay", false), "DisableFailed")
	assert(primitives[#primitives].kind == "Cancelled", "ContextDisableFabricatedRelease")
	local count: number = #events
	Gestures.Remove()
	driver:Fire(false)
	RunService.Heartbeat:Wait()
	assert(#events == count, "GestureAfterRemoval")
	gestureConnection:Disconnect()
	primitiveConnection:Disconnect()
	Controls.Remove()
	gui:Destroy()
	Client._ResetForTests()
	assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs") == nil, "NativeInputContainerLeak")
end

local success: boolean, reason: any = pcall(run)
control:FireServer(success, if success then nil else tostring(reason))
