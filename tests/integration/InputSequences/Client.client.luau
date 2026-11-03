--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Client = require(ReplicatedStorage.Packages.KRF.client)
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Input: Types.InputRuntime = require(ReplicatedStorage.Packages.KRF.client.Input.InputRuntime)
local State = require(ReplicatedStorage.Packages.KRF.client.Input.utils.InputRuntimeState)
local Examples = require(ReplicatedStorage.InputSequences)
local Workload = require(ReplicatedStorage.InputRecognitionWorkload)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("InputTestControl") :: RemoteEvent

local function waitFor(predicate: () -> boolean): ()
	local deadline: number = os.clock() + 5

	while not predicate() do
		assert(os.clock() < deadline, "SequenceFixtureTimeout")
		RunService.Heartbeat:Wait()
	end
end

type Measurement = { iterations: number, matches: number, dispatchSeconds: number } & Workload.Measurement
local measurement: Measurement? = nil

local function run(): ()
	local initialized: boolean, failure = Client.Init()
	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")
	assert(Input.SetSource("Game.Signs", Examples.Inputs()))
	assert(Input.SetContextEnabled("Signs", true))
	local success: boolean, reason: string? = Input.SetSource("Manual", Examples.Immediate())
	assert(success, reason or "SequenceInstallFailed")
	local owner: Types.InputOwner = assert(State.Get())
	local container: Instance = assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs"))
	local context: InputContext = assert(container:FindFirstChild("Signs")) :: InputContext
	local drivers: { [string]: InputBinding } = {}

	for _, id: string in { "X", "Q", "Z", "C", "Aim" } do
		local driver: InputBinding = Instance.new("InputBinding")
		driver.Type = Enum.InputBindingType.Scriptable
		driver.Parent = assert(context:FindFirstChild(id))
		drivers[id] = driver
	end

	local matches: { string } = {}
	local customs: { Types.CustomRecognitionEvent } = {}
	local primitives: { Types.SemanticInputEvent } = {}

	local sequenceConnection = Input.OnSequenceMatched:Connect(function(event: Types.SequenceMatchEvent): ()
		table.insert(matches, event.sequenceId)
	end)

	local customConnection = Input.OnRecognizerMatched:Connect(function(event: Types.CustomRecognitionEvent): ()
		table.insert(customs, event)
	end)

	local inputConnection = Input.OnInput:Connect(function(event: Types.SemanticInputEvent): ()
		table.insert(primitives, event)
	end)

	local function press(id: string): ()
		drivers[id]:Fire(true)
		drivers[id]:Fire(false)
	end

	press("X")
	press("Q")
	press("Z")

	waitFor(function(): boolean
		return #matches == 2
	end)

	assert(matches[1] == "Short" and matches[2] == "Fireball", "ImmediatePrefixOrder")
	assert(#primitives == 6, "GenuineReleasesWereConsumed")
	assert(owner.ResetRecognition(nil, "FixtureReset"))
	table.clear(matches)

	-- Rebinding preserves semantic sequence definitions; drive the new native action.
	assert(Input.SetSource("Rebind", {
		priority = 1,
		bindingOverrides = {
			Q = { Keyboard = { keyCode = Enum.KeyCode.E }, Gamepad = { keyCode = Enum.KeyCode.ButtonY } },
		},
	}))

	assert(
		assert(Input.GetEffectiveBindings("Q"), "MissingQBindings").Keyboard.definition.keyCode == Enum.KeyCode.E,
		"QRebindFailed"
	)

	press("X")
	press("Q")
	press("Z")

	waitFor(function(): boolean
		return #matches == 2
	end)

	table.clear(matches)
	assert(Input.SetSource("Manual", Examples.Deferred()))
	press("X")
	press("Q")
	assert(#matches == 0, "DeferredPrefixWasImmediate")
	press("C")

	waitFor(function(): boolean
		return #matches == 1
	end)

	assert(matches[1] == "Short", "WrongKeyLostPendingPrefix")
	table.clear(matches)
	press("X")
	press("Q")
	-- No key remains down: this must use config validity, not active Cancelled.
	local primitiveCount: number = #primitives
	assert(Input.SetContextEnabled("Signs", false))
	assert(#primitives == primitiveCount, "DormantDisableFabricatedTransition")
	assert(Input.SetContextEnabled("Signs", true))
	press("Z")
	task.wait(0.6)
	assert(#matches == 0, "DormantContextRetainedPrefix")
	drivers.X:Fire(true)
	assert(Input.SetContextEnabled("Signs", false), "HeldContextDisableFailed")
	assert(primitives[#primitives].kind == "Cancelled", "NativeDisableFabricatedRelease")
	assert(Input.SetContextEnabled("Signs", true), "HeldContextEnableFailed")
	drivers.X:Fire(false)
	press("Q")
	press("Z")
	assert(#matches == 0, "CancelledPrefixCompleted")
	assert(Input.SetSource("Sword", Examples.Sword()))
	drivers.Aim:Fire(Vector2.new(-1, 0))
	drivers.Aim:Fire(Vector2.new(1, 0))

	waitFor(function(): boolean
		return #customs == 1
	end)

	assert(customs[1].recognizerId == "SwipeRight", "AnalogCustomMissing")
	assert(Input.RemoveSource("Sword"))
	assert(owner.ResetRecognition(nil, "FixtureReset"), "ResetFailed")
	table.clear(matches)
	table.clear(customs)

	assert(
		Input.SetSource(
			"NativeGestures",
			{ gestures = { Q = { DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5 } } } }
		),
		"NativeGestureInstallFailed"
	)

	assert(
		Input.SetSource("NativeCustom", {
			recognizers = {
				DoubleSign = {
					inputs = { "Q" },
					gestures = { Q = { "DoubleTapped" } },
					maxWindowSeconds = 1,
					onEvent = function(_ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
						return if event.kind == "Gesture" then {} else nil
					end,
				},
			},
		}),
		"NativeCustomInstallFailed"
	)

	press("Q")

	assert(
		Input.SetSource("NativeCombos", {
			sequences = {
				DoubleSign = {
					steps = { "X", { inputId = "Q", kind = "DoubleTapped" } },
					maxGapSeconds = 0.5,
					maxTotalSeconds = 2,
				},
				FromCustom = {
					steps = { "X", { recognizerId = "DoubleSign", kind = "Custom" } },
					maxGapSeconds = 0.5,
					maxTotalSeconds = 2,
				},
				OneRoot = {
					steps = { "Q", { inputId = "Q", kind = "DoubleTapped" } },
					maxGapSeconds = 0.5,
					maxTotalSeconds = 2,
				},
			},
		}),
		"NativeSequenceInstallFailed"
	)

	press("X")
	press("Q")

	waitFor(function(): boolean
		return #matches == 2 and #customs == 1
	end)

	assert(matches[1] == "DoubleSign" and matches[2] == "FromCustom", "NativeAlternativeTokenFailure")
	assert(Input.RemoveSource("NativeCombos"), "RemoveNativeSequencesFailed")
	assert(Input.RemoveSource("NativeCustom"), "RemoveNativeCustomFailed")
	assert(Input.RemoveSource("NativeGestures"), "RemoveNativeGesturesFailed")
	assert(Input.RemoveSource("Manual"), "RemoveManualFailed")
	table.clear(matches)
	local catalog: { [string]: Types.SequenceDefinition } = {}

	for index: number = 1, 256 do
		catalog[string.format("Stress%03d", index)] =
			{ steps = { "X", "X", "Q" }, maxGapSeconds = 1, maxTotalSeconds = 2 }
	end

	assert(Input.SetSource("Benchmark", { sequences = catalog }), "BenchmarkInstallFailed")
	local started: number = os.clock()

	for _ = 1, 16 do
		press("X")
		press("X")
		press("Q")
	end

	local dispatchSeconds: number = os.clock() - started

	waitFor(function(): boolean
		return #matches == 4096
	end)

	local matchCount: number = #matches
	assert(Input.RemoveSource("Benchmark"), "BenchmarkCleanupFailed")
	table.clear(matches)

	local custom: Workload.Measurement = Workload.Run(Input, press)

	measurement = {
		iterations = 16,
		matches = matchCount,
		dispatchSeconds = dispatchSeconds,
		customCalls = custom.customCalls,
		customDispatchSeconds = custom.customDispatchSeconds,
		faultCalls = custom.faultCalls,
		faultDispatchSeconds = custom.faultDispatchSeconds,
	}

	assert(Input.RemoveSource("Rebind"))
	assert(Input.RemoveSource("Game.Signs"))
	sequenceConnection:Disconnect()
	customConnection:Disconnect()
	inputConnection:Disconnect()
	Client._ResetForTests()
	assert(State.Get() == nil, "InputOwnerLeaked")
end

local success: boolean, reason: any = pcall(run)
control:FireServer(success, if success then measurement else tostring(reason))
