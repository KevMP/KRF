--!strict
-- Run input:controls:manual in Studio with one client. Use actual hardware for
-- native priority/sink, focus, unplug/reconnect and touch checks; scriptable
-- bindings in the automated fixture do not prove physical-device behavior.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local SignalTypes = require(KRF.shared.Signal.types)
local Types = require(KRF.client.Controls.types)
local InputTypes = require(KRF.client.Input.types)
local ActionTypes = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local Client = require(KRF.client)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local schemas = require(ReplicatedStorage.ControlSchemas)
local player: Player = Players.LocalPlayer
local selectedMount: boolean = false
local enabled: boolean = true
local highEnabled: boolean = false
local rebound: boolean = false
local equipped: string = "Combat.Rasengan"
local starts: number = 0
local stops: number = 0
local interrupts: number = 0
local cancellations: number = 0
local history: { string } = {}
local connections: { RBXScriptConnection } = {}
local inputConnection: SignalTypes.Connection? = nil

local gui: ScreenGui = Instance.new("ScreenGui")
gui.Name = "KRFControlsManual"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local status: TextLabel = Instance.new("TextLabel")
status.Size = UDim2.fromOffset(720, 430)
status.Position = UDim2.fromOffset(20, 20)
status.TextSize = 16
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = gui

local instructions: string = [[I7 physical IAS checks (observe counters and original Action/Actor IDs):
1. Hold Q / Mouse1 / R2 / touch: one Start; genuine release: one Stop.
2. While held, switch Actor, disable context or rebind: Interrupt/Cancelled, zero Stop; neutral then fresh press required.
3. Equip Fireball while charging: release still Stops original Rasengan; next press starts Fireball.
4. Enable High (higher native priority + Sink): Q reaches High, low context stays enabled. Disable High and verify rearm.
5. Alt-tab while held, return: one cancellation/Interrupt, no phantom Start.
6. Unplug gamepad while R2/stick held, reconnect: neutral then fresh input. Independently held keyboard remains live when provenance is provable.
7. Move stick: typed StateChanged only. Recover from nonzero through neutral.
8. Tap touch on an actual touch device; cancellation is never release aim.
9. Repeat switches/rebinds; Reset must destroy KRFInputs and stop all callbacks.
]]

local function refresh(): ()
	status.Text = instructions
		.. "\nStarts "
		.. starts
		.. " Stops "
		.. stops
		.. " Interrupts "
		.. interrupts
		.. " Cancelled "
		.. cancellations
		.. "\n"
		.. table.concat(history, "\n")
end

local function record(message: string): ()
	table.insert(history, message)

	if #history > 6 then
		table.remove(history, 1)
	end

	refresh()
end

local function button(text: string, index: number, callback: () -> ()): TextButton
	local control: TextButton = Instance.new("TextButton")
	control.Size = UDim2.fromOffset(145, 44)
	control.Position = UDim2.fromOffset(20 + (index % 4) * 155, 460 + math.floor(index / 4) * 54)
	control.Text = text
	control.Parent = gui

	table.insert(
		connections,
		control.Activated:Connect(function(): ()
			local success: boolean, failure: unknown = pcall(callback)

			if not success then
				record("FAIL: " .. tostring(failure))
			end
		end)
	)

	return control
end

local policies: ActionTypes.ActionInputPolicies = {
	["Combat.Rasengan"] = {
		activation = "WhileDown",
		startParameters = function(): { aim: number }
			return { aim = 1 }
		end,
		stopParameters = function(): { releaseAim: number }
			return { releaseAim = 8 }
		end,
	},
	["Combat.Fireball"] = {
		startParameters = function(): { aim: number }
			return { aim = 3 }
		end,
	},
}

local initialized: boolean, failure = Client.Init({ actionRequestSchemas = schemas, actionInputPolicies = policies })

assert(initialized, if failure ~= nil then failure.reason else "ManualClientInitFailed")

local function actor(attribute: string): ActorTypes.ActorView
	local deadline: number = os.clock() + 10

	while os.clock() < deadline do
		local id: unknown = player:GetAttribute(attribute)
		local view: ActorTypes.ActorView? = if type(id) == "string" then Registry.GetActorViewById(id) else nil

		if view ~= nil then
			return view
		end

		RunService.Heartbeat:Wait()
	end

	error("ManualActorUnavailable:" .. attribute, 0)
end

local human: ActorTypes.ActorView = actor("ControlHumanId")
local mount: ActorTypes.ActorView = actor("ControlMountId")
local touch: TextButton = button("Touch / Hold", 0, function(): () end)

assert(Input.SetSource("Core", {
	contexts = { Gameplay = { priority = 2000, sink = false }, High = { priority = 3000, sink = true } },
	inputs = {
		Ability = {
			context = "Gameplay",
			type = Enum.InputActionType.Bool,
			bindings = {
				Keyboard = { keyCode = Enum.KeyCode.Q },
				Mouse = { keyCode = Enum.KeyCode.MouseLeftButton },
				Gamepad = { keyCode = Enum.KeyCode.ButtonR2 },
				Touch = { uiButton = touch },
			},
		},
		High = {
			context = "High",
			type = Enum.InputActionType.Bool,
			bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
		},
		Stick = {
			context = "Gameplay",
			type = Enum.InputActionType.Direction2D,
			bindings = { Gamepad = { keyCode = Enum.KeyCode.Thumbstick1 } },
		},
	},
}))

assert(Input.SetContextEnabled("Gameplay", true))

local profile: ActionTypes.ControlProfile = {
	routes = {
		{
			when = { kind = "Input", inputId = "Ability", gesture = "Pressed" },
			target = {
				kind = "Dynamic",
				resolve = function(): ActionTypes.ResolvedAction
					return { actionId = equipped }
				end,
			},
		},
	},
}

assert(Runtime.SetProfileSource(human, "Base", profile))
assert(Runtime.SetProfileSource(mount, "Base", profile))
assert(Runtime.SetControlledActor(human))
local requests: RequestTypes.ClientActionRequestRuntime = assert(RequestState.Get(), "NormalInstallerMissingI5")

local stopAdmissions = requests:ObserveAdmissions(function(admission): ()
	if admission.kind == "Start" then
		starts += 1
	elseif admission.kind == "Stop" then
		stops += 1
	else
		interrupts += 1
	end

	record(
		admission.kind
			.. " "
			.. admission.actionId
			.. " Actor="
			.. admission.actor:GetId()
			.. " original="
			.. admission.originalStartRequestId
	)
end)

inputConnection = Input.OnInput:Connect(function(event): ()
	if event.kind == "Cancelled" then
		cancellations += 1
	end

	record(event.inputId .. " " .. event.kind)
end)

button("Switch Actor", 1, function(): ()
	selectedMount = not selectedMount
	assert(Controls.Apply({ selection = { kind = "Set", actor = if selectedMount then mount else human } }))
end)

button("Enable/disable", 2, function(): ()
	enabled = not enabled
	assert(Controls.Apply({ contexts = { { contextId = "Gameplay", enabled = enabled } } }))
end)

button("Q / E rebind", 3, function(): ()
	rebound = not rebound

	assert(Controls.Apply({
		inputs = {
			if rebound
				then {
					kind = "Set",
					sourceId = "Keybinds",
					definition = {
						priority = 100,
						bindingOverrides = { Ability = { Keyboard = { keyCode = Enum.KeyCode.E } } },
					},
				}
				else { kind = "Remove", sourceId = "Keybinds" },
		},
	}))
end)

button("Equip Fireball", 4, function(): ()
	equipped = "Combat.Fireball"
	record("Next selection: Fireball")
end)

button("Equip Rasengan", 5, function(): ()
	equipped = "Combat.Rasengan"
	record("Next selection: Rasengan")
end)

button("Toggle High", 6, function(): ()
	highEnabled = not highEnabled
	assert(Controls.Apply({ contexts = { { contextId = "High", enabled = highEnabled } } }))
end)

button("Reset", 7, function(): ()
	stopAdmissions()
	Client._ResetForTests()

	for _, connection in connections do
		connection:Disconnect()
	end

	if inputConnection ~= nil then
		inputConnection:Disconnect()
	end

	assert(player.PlayerScripts:FindFirstChild("KRFInputs") == nil, "NativeInputsLeaked")
	assert(Controls.Apply({}) == false, "StaleControlsOwner")
	record("Reset complete; verify no new counters or native KRFInputs.")
end)

refresh()
